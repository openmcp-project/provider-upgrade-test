#!/usr/bin/env bash

# Check if source directory path is provided
if [ $# -eq 0 ]; then
    echo "Usage: $0 <source_directory>"
    echo "This script copies all folders from the source directory to generated/ and processes INJECT_ENV variables"
    exit 1
fi

source_dir="$1"
generated_dir="./generated"

# Check if source directory exists
if [ ! -d "$source_dir" ]; then
    echo "Error: Source directory '$source_dir' does not exist"
    exit 1
fi

# Function to process INJECT_ENV placeholders in a file
process_file() {
    local input_file="$1"
    local temp_file=$(mktemp)
    local processed_file="${temp_file}_processed"
    
    # Copy original file to temp
    cp "$input_file" "$temp_file"
    
    # Process each line looking for INJECT_ENV placeholders
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ INJECT_ENV\.([a-zA-Z_][a-zA-Z0-9_]*) ]]; then
            var_name="${BASH_REMATCH[1]}"
            env_value="${!var_name}"
            
            if [[ -n "$env_value" ]]; then
                # Special handling for CIS_CREDENTIAL or similar JSON structures
                if [[ "$var_name" == "CIS_CREDENTIAL" ]] || [[ "$var_name" == "CIS_CENTRAL_BINDING" ]]; then
                    # First escape any literal newlines and other control characters for proper JSON parsing
                    escaped_json=$(printf '%s' "$env_value" | sed ':a;N;$!ba;s/\n/\\n/g' | sed 's/\r/\\r/g' | sed 's/\t/\\t/g')
                    
                    # Validate the escaped JSON
                    if ! echo "$escaped_json" | jq empty 2>/dev/null; then
                        echo "Error: $var_name contains invalid JSON"
                        exit 1
                    fi
                    
                    # Process with jq and then clean up the escaped newlines
                    clean_value=$(echo "$escaped_json" | jq -c . | sed 's/\\n//g')
                    line="${line//INJECT_ENV.${var_name}/${clean_value}}"
                else
                    # For non-JSON variables, use direct substitution
                    line="${line//INJECT_ENV.${var_name}/${env_value}}"
                fi
            else
                echo "Warning: Environment variable $var_name is not set or empty. Leaving placeholder unchanged."
            fi
        fi
        echo "$line" >> "$processed_file"
    done < "$temp_file"
    
    # Replace original file with processed content
    mv "$processed_file" "$input_file"
    
    # Clean up temp file
    rm -f "$temp_file"
}

# Function to validate CIS credential structure
validate_cis_credential() {
    local cis_json="$1"
    local required_fields=(
        ".uaa.clientid"
        ".uaa.clientsecret" 
        ".uaa.url"
        ".endpoints.accounts_service_url"
        ".endpoints.entitlements_service_url"
        ".endpoints.provisioning_service_url"
    )
    
    for field in "${required_fields[@]}"; do
        if ! echo "$cis_json" | jq -e "$field" >/dev/null 2>&1; then
            echo "Warning: CIS credential missing required field: $field"
        fi
    done
}

# Validate CIS_CREDENTIAL environment variable if set
if [[ -n "${CIS_CREDENTIAL:-}" ]]; then
    echo "Validating CIS_CREDENTIAL environment variable..."
    if echo "$CIS_CREDENTIAL" | jq empty 2>/dev/null; then
        validate_cis_credential "$CIS_CREDENTIAL"
        echo "CIS_CREDENTIAL validation passed"
    else
        echo "Error: CIS_CREDENTIAL contains invalid JSON"
        exit 1
    fi
fi

# Create or clean the generated directory
if [ -d "$generated_dir" ]; then
    echo "Cleaning existing generated directory..."
    rm -rf "${generated_dir:?}"/*
else
    echo "Creating generated directory..."
    mkdir -p "$generated_dir"
fi

echo "Copying '$source_dir' and its contents to '$generated_dir'..."

# Get the basename of the source directory
source_basename=$(basename "$source_dir")

# Copy the entire source directory to generated
echo "Copying directory: $source_basename"
cp -r "$source_dir" "$generated_dir/$source_basename"

echo "Processing INJECT_ENV variables in copied files..."

# Process all files in the copied directories
find "$generated_dir" -type f | while read -r file; do
    # Check if file contains INJECT_ENV placeholders
    if grep -q "INJECT_ENV\." "$file" 2>/dev/null; then
        echo "Processing: $file"
        process_file "$file"
    fi
done

echo "Script completed successfully!"
echo "Directory '$source_dir' has been copied to '$generated_dir' and INJECT_ENV variables have been processed."