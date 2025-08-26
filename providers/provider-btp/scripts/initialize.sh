#!/usr/bin/env bash
echo "^^Executing initialize scripts ^^"

# Define the folder containing the YAML files
FOLDER="providers/provider-btp/v1.0.3/crs"

CURRENT_DATE=$(date +%Y-%m-%d-%H-%M)

OLD_STRING=''
NEW_STRING="-${CURRENT_DATE}"

# Iterate over all YAML files in the folder
for file in "$FOLDER"/*.yaml; do
    if grep -q -- "${OLD_STRING}" "$file"; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/$OLD_STRING/$NEW_STRING/g" "$file"
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            sed -i "s/$OLD_STRING/$NEW_STRING/g" "$file"
        else
            echo "Unknown OS"
        fi
    fi
done

# Adapt chainsaw-test.yaml
if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "s/$OLD_STRING/$NEW_STRING/g" "providers/provider-btp/v1.0.3/chainsaw-test.yaml"
elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
    sed -i "s/$OLD_STRING/$NEW_STRING/g"  "providers/provider-btp/v1.0.3/chainsaw-test.yaml"
else
    echo "Unknown OS"
fi

TESTFILE="providers/provider-btp/v1.0.3/chainsaw-test.yaml"
if grep -q -- "${OLD_STRING}" "$TESTFILE"; then
    sed -i '' "s/$OLD_STRING/$NEW_STRING/g" "$TESTFILE"
fi

echo "All YAML files in the $FOLDER folder have been updated."