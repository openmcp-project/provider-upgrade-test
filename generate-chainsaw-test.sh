#!/bin/bash
# This script generates a chainsaw-test.yaml file based on YAML files in a specified folder.
# Usage: ./generate-chainsaw-test.sh <folder-location>

# Check if folder location is provided
if [ -z "$1" ]; then
    echo "Usage: $0 <folder-location>"
    exit 1
fi

FOLDER="$1"
OUTPUT_FILE="auto-generated-chainsaw-test.yaml"

# List all YAML files in the folder
FILES=("$FOLDER"/*.yaml)

# Display the files with numbers for ordering
echo "Available files in the folder:"
for i in "${!FILES[@]}"; do
    echo "$((i + 1)). $(basename "${FILES[$i]}")"
done

# Prompt the user for file order
echo
read -p "Enter the file order by numbers (e.g., 1 3 2), or press Enter to use the default order: " ORDER

# Process the user input
if [ -n "$ORDER" ]; then
    ORDERED_FILES=()
    for num in $ORDER; do
        if [[ $num =~ ^[0-9]+$ ]] && ((num >= 1 && num <= ${#FILES[@]})); then
            ORDERED_FILES+=("${FILES[$((num - 1))]}")
        else
            echo "Invalid input: $num. Skipping."
        fi
    done
else
    ORDERED_FILES=("${FILES[@]}")
fi

# Start building the chainsaw-test.yaml file
cat <<EOF > "$OUTPUT_FILE"
apiVersion: chainsaw.kyverno.io/v1alpha1
kind: Test
metadata:
  name: generated-chainsaw-test
spec:
  timeouts: 
    apply: 180s
    assert: 180s
    cleanup: 180s
  steps:
EOF

# Function to extract resource info from a YAML document
extract_resource_info() {
    local yaml_content="$1"
    local apiVersion=$(echo "$yaml_content" | awk '/^apiVersion:/ {print $2; exit}')
    local kind=$(echo "$yaml_content" | awk '/^kind:/ {print $2; exit}')
    local name=$(echo "$yaml_content" | awk '/^  name:/ {print $2; exit}')
    echo "$apiVersion|$kind|$name"
}

# Iterate over the ordered files
for file in "${ORDERED_FILES[@]}"; do
    # Check if file contains multiple YAML documents separated by ---
    if grep -q "^---" "$file"; then
        # Split the file by --- and process each document
        awk 'BEGIN{RS="^---"} NF{print > "/tmp/yaml_doc_" NR ".tmp"}' "$file"
        
        # Process each temporary document file
        for doc_file in /tmp/yaml_doc_*.tmp; do
            if [[ -f "$doc_file" && -s "$doc_file" ]]; then
                # Skip if document is just comments or empty
                if grep -q "^apiVersion:" "$doc_file"; then
                    yaml_content=$(cat "$doc_file")
                    resource_info=$(extract_resource_info "$yaml_content")
                    IFS='|' read -r apiVersion kind name <<< "$resource_info"
                    
                    # Only add if we have valid values
                    if [[ -n "$apiVersion" && -n "$kind" && -n "$name" ]]; then
                        # Append the step to the chainsaw-test.yaml file
                        cat <<EOF >> "$OUTPUT_FILE"
  - timeouts:
      assert: 180s
    try:
    - apply:
        file: crs/$(basename "$file")
    - assert:
        resource:
          apiVersion: $apiVersion
          kind: $kind
          metadata:
            name: $name
          status:
            (conditions[?type == 'Ready']):
            - status: 'True'
            (conditions[?type == 'Synced']):
            - status: 'True'
EOF
                    fi
                fi
            fi
        done
        
        # Clean up temporary files
        rm -f /tmp/yaml_doc_*.tmp
    else
        # Single document - use original logic
        apiVersion=$(awk '/^apiVersion:/ {print $2}' "$file")
        kind=$(awk '/^kind:/ {print $2}' "$file")
        name=$(awk '/^  name:/ {print $2}' "$file")

        # Append the step to the chainsaw-test.yaml file
        cat <<EOF >> "$OUTPUT_FILE"
  - timeouts:
      assert: 180s
    try:
    - apply:
        file: crs/$(basename "$file")
    - assert:
        resource:
          apiVersion: $apiVersion
          kind: $kind
          metadata:
            name: $name
          status:
            (conditions[?type == 'Ready']):
            - status: 'True'
            (conditions[?type == 'Synced']):
            - status: 'True'
EOF
    fi
done

echo "$OUTPUT_FILE has been generated in the current directory."