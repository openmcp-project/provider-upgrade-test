#!/usr/bin/env bash

# Usage function
usage() {
  echo "Usage: $0 <setup_directory> [crs_directory]"
  echo ""
  echo "  setup_directory: Directory containing setup YAML files to process"
  echo "  crs_directory:   Optional directory containing CRS (Kubernetes manifest) YAML files to process"
  echo ""
  echo "Examples:"
  echo "  $0 ./providers/provider-btp/v1.0.3/setup"
  echo "  $0 ./providers/provider-btp/v1.0.3/setup ./providers/provider-btp/v1.0.3/crs"
  echo ""
  echo "The script will:"
  echo "  - Process all *.yaml files in the specified directories"
  echo "  - Replace INJECT_ENV.VARIABLE_NAME placeholders with actual environment variable values"
  echo "  - Save processed files to ./generated/temp-generated/"
  echo "  - CRS files will be saved in ./generated/temp-generated/crs/ subdirectory"
}

# Check for help flag or no arguments
if [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]] || [[ $# -eq 0 ]]; then
  usage
  exit 0
fi

setup_dir=$1
crs_dir=$2
generated_dir="./generated/temp-generated"

if [ -d "$generated_dir" ]; then
  rm -rf "${generated_dir:?}"/*
else
  mkdir -p "$generated_dir"
fi

# Function to process YAML files in a directory
process_yaml_files() {
  local source_dir=$1
  local target_subdir=$2
  
  # Create subdirectory if specified
  if [[ -n "$target_subdir" ]]; then
    mkdir -p "${generated_dir}/${target_subdir}"
  fi
  
  echo "Processing YAML files in: $source_dir"
  
  for yaml_file in "${source_dir}"/*.yaml; do
    # Check if there are no YAML files
    if ! [[ -e "$yaml_file" ]]; then
      echo "No YAML files found in $source_dir."
      return 0
    fi

    echo "  Processing: $(basename "$yaml_file")"

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
          echo "    Replaced INJECT_ENV.$var_name with value"
        else
          echo "    Warning: Environment variable '$var_name' not found, leaving placeholder unchanged"
        fi
      fi
      echo "$line" >> "${temp_file}_processed"
    done < "$temp_file"

    # Determine target path
    if [[ -n "$target_subdir" ]]; then
      target_path="${generated_dir}/${target_subdir}/$(basename "$yaml_file")"
    else
      target_path="${generated_dir}/$(basename "$yaml_file")"
    fi

    # Move processed file to the generated directory, preserving the original filename
    mv "${temp_file}_processed" "$target_path"

    # Clean up the temporary file
    rm "$temp_file"
  done
}

# Process setup directory if provided
if [[ -n "$setup_dir" ]] && [[ -d "$setup_dir" ]]; then
  process_yaml_files "$setup_dir" ""
elif [[ -n "$setup_dir" ]]; then
  echo "Setup directory doesn't exist: $setup_dir"
fi

# Process CRS directory if provided
if [[ -n "$crs_dir" ]] && [[ -d "$crs_dir" ]]; then
  process_yaml_files "$crs_dir" "crs"
elif [[ -n "$crs_dir" ]]; then
  echo "CRS directory doesn't exist: $crs_dir"
fi

# Check if at least one directory was processed
if [[ -z "$setup_dir" ]] && [[ -z "$crs_dir" ]]; then
  echo "Error: No directories provided to process"
  usage
  exit 1
fi

echo "YAML files processed and saved in $generated_dir."
