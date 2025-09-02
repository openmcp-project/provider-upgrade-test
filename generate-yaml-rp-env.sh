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
    # Use -r to preserve backslashes and handle files without trailing newlines
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ "$line" =~ INJECT_ENV\.([a-zA-Z_][a-zA-Z0-9_]*) ]]; then
            var_name="${BASH_REMATCH[1]}"
            env_value="${!var_name}"
            if [[ -n "$env_value" ]]; then
                # For JSON content, compact it to a single line while preserving structure
                if [[ "$env_value" =~ ^\s*\{ ]] || [[ "$env_value" =~ ^\s*\[ ]]; then
                    # This looks like JSON, properly handle escaped characters and newlines
                    # First remove actual newlines and carriage returns (not escaped ones)
                    clean_value=$(echo "$env_value" | tr -d '\n\r')
                    # Remove literal \n and \r sequences that might be in the data
                    clean_value=$(echo "$clean_value" | sed 's/\\n//g' | sed 's/\\r//g' | sed 's/\\t//g')
                    # Try to compact with jq, fallback to manual compacting if jq fails
                    clean_value=$(echo "$clean_value" | jq -c . 2>/dev/null || echo "$clean_value" | tr -s ' ')
                else
                    # For non-JSON content, just remove all whitespace
                    clean_value=$(echo "$env_value" | tr -d '[:space:]')
                fi
                # Properly escape quotes for YAML insertion
                clean_value="${clean_value//\"/\\\"}"
                # Replace the placeholder with the cleaned value in quotes
                line="${line//INJECT_ENV.${var_name}/\"${clean_value}\"}"
            fi
        fi
        echo "$line" >> "$processed_file"
    done < "$temp_file"
    
    # Replace original file with processed content
    mv "$processed_file" "$input_file"
    
    # Clean up temp file
    rm -f "$temp_file"
}

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