#!/usr/bin/env bash

setup_dir=$1
generated_dir="./generated/temp-generated"

if [ -d "$generated_dir" ]; then
  rm -rf "${generated_dir:?}"/*
else
  mkdir -p "$generated_dir"
fi

# Loop through each YAML file in the setup directory
for yaml_file in "${setup_dir}"/*.yaml; do
  # Check if there are no YAML files
  if ! [[ -e "$yaml_file" ]]; then
    echo "No YAML files found in setup directory."
    exit 0
  fi

  # Create a temporary file to store the processed content
  temp_file=$(mktemp)

  cp "$yaml_file" "$temp_file"

  # Loop through each line of the YAML file
  while IFS= read -r line; do
    if [[ "$line" =~ INJECT_ENV\.([a-zA-Z_]+) ]]; then
      var_name="${BASH_REMATCH[1]}"
      env_value="${!var_name}"
      if [[ ! -z "$env_value" ]]; then
        # Replace the placeholder with the actual environment variable value
        line=$(echo "$line" | sed -e "s/INJECT_ENV\.${var_name}/${env_value}/g")
      fi
    fi
    echo "$line" >> "${temp_file}_processed"
  done < "$temp_file"

  # Move processed file to the generated directory, preserving the original filename
  mv "${temp_file}_processed" "${generated_dir}/$(basename "$yaml_file")"

  # Clean up the temporary file
  rm "$temp_file"
done

echo "YAML files processed and saved in $generated_dir."
