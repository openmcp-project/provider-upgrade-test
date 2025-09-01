#!/usr/bin/env bash

setup_dir=$1
generated_dir="./generated/temp-generated"

# Function to process INJECT_ENV placeholders in a file
process_yaml_file() {
  local yaml_file="$1"
  local output_file="$2"
  local temp_file=$(mktemp)

  cp "$yaml_file" "$temp_file"

  # Loop through each line of the YAML file
  while IFS= read -r line; do
    if [[ "$line" =~ INJECT_ENV\.([a-zA-Z_]+) ]]; then
      var_name="${BASH_REMATCH[1]}"
      env_value="${!var_name}"
      if [[ ! -z "$env_value" ]]; then
        # Strip all newlines and format as a simple string
        clean_value=$(echo "$env_value" | tr -d '\n\r' | sed 's/"/\\"/g')
        # Replace the placeholder with the cleaned value in quotes
        line="${line//INJECT_ENV.${var_name}/\"${clean_value}\"}"
      fi
    fi
    echo "$line" >> "${temp_file}_processed"
  done < "$temp_file"

  # Move processed file to the output location
  mv "${temp_file}_processed" "$output_file"

  # Clean up the temporary file
  rm "$temp_file"
}

# Process setup directory files and create generated folder
if [ -d "$generated_dir" ]; then
  rm -rf "${generated_dir:?}"/*
else
  mkdir -p "$generated_dir"
fi

# Loop through each YAML file in the setup directory
setup_files_found=false
for yaml_file in "${setup_dir}"/*.yaml; do
  # Check if there are no YAML files
  if ! [[ -e "$yaml_file" ]]; then
    echo "No YAML files found in setup directory."
    break
  fi

  setup_files_found=true
  process_yaml_file "$yaml_file" "${generated_dir}/$(basename "$yaml_file")"
done

if [ "$setup_files_found" = true ]; then
  echo "YAML files processed and saved in $generated_dir."
fi

# Process CRS files in-place
crs_base_dir=$(dirname "$setup_dir")/crs

if [ -d "$crs_base_dir" ]; then
  echo "Processing CRS files in-place in $crs_base_dir..."
  
  # Find all YAML files in the crs directory
  find "$crs_base_dir" -name "*.yaml" -type f | while read -r crs_file; do
    # Check if file contains INJECT_ENV placeholders
    if grep -q "INJECT_ENV\." "$crs_file"; then
      echo "Processing $crs_file..."
      process_yaml_file "$crs_file" "$crs_file"
    fi
  done
  
  echo "CRS files processing completed."
else
  echo "No CRS directory found at $crs_base_dir"
fi