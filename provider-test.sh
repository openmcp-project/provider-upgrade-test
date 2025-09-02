#!/usr/bin/env bash

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color (reset)

source ./functions.sh
rm -rf generated/*

check_required_command_exists

# Built-in initialize function
initialize_yaml_files() {
    local source_dir="$1"
    print_color_message ${BLUE} "Initializing YAML files with timestamp..."
    
    local current_date=$(date +%Y-%m-%d-%H-%M)
    local old_string="PLACEHOLDER"
    local new_string="${current_date}"
    
    # Update CRs in the folder
    for file in "generated/${source_dir}/crs"/*.yaml; do
        if [ -f "$file" ] && grep -q -- "${old_string}" "$file"; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                sed -i '' "s/$old_string/$new_string/g" "$file"
            elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
                sed -i "s/$old_string/$new_string/g" "$file"
            fi
        fi
    done
    
    # Update chainsaw test file
    local chainsaw_file="generated/${source_dir}/chainsaw-test.yaml"
    if [ -f "$chainsaw_file" ] && grep -q -- "${old_string}" "$chainsaw_file"; then
        if [[ "$OSTYPE" == "darwin"* ]]; then
            sed -i '' "s/$old_string/$new_string/g" "$chainsaw_file"
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            sed -i "s/$old_string/$new_string/g" "$chainsaw_file"
        fi
    fi
    
    print_color_message ${BLUE} "YAML files updated with timestamp: $new_string"
}

# Built-in cleanup function
cleanup_resources() {
    local source_dir="$1"
    print_color_message ${BLUE} "Cleaning up test resources..."
    
    kubectl delete -f "generated/${source_dir}/crs/" --ignore-not-found=true
    
    print_color_message ${BLUE} "Checking deletion status of managed resources..."
    local timeout_duration=$((60 * 60))  # 1 hour
    local interval=30
    local start_time=$(date +%s)
    
    while true; do
        local current_time=$(date +%s)
        local elapsed_time=$((current_time - start_time))
        
        if [ "$elapsed_time" -ge "$timeout_duration" ]; then
            print_color_message ${YELLOW} "Timeout reached while waiting for resource cleanup."
            break
        fi
        
        local resources=$(kubectl get managed --no-headers 2>/dev/null)
        
        if [ -n "$resources" ]; then
            print_color_message ${BLUE} "Managed resources still exist, waiting..."
        else
            print_color_message ${GREEN} "No managed resources found. Cleanup complete."
            break
        fi
        
        sleep "$interval"
    done
}

COMMAND=$1
shift
case $COMMAND in
upgrade-test)
    SOURCE_VERSION=""
    TARGET_VERSION=""
    WAIT_USER_INPUT="no"
    PROVIDER_NAME="provider-btp"
    INSTALL_CROSSPLANE=true
    
    while [[ $# -gt 0 ]]; do
        case $1 in
        --source)
            SOURCE_REGISTRY="$2"
            SOURCE_VERSION="${SOURCE_REGISTRY##*:}"
            if [[ -z "$SOURCE_VERSION" || "$SOURCE_VERSION" == "$SOURCE_REGISTRY" ]]; then
                SOURCE_VERSION="latest"
            fi
            shift 2
            ;;
        --source-dir)
            SOURCE_DIR="$2"
            shift 2
            ;;
        --target)
            TARGET_REGISTRY="$2"
            TARGET_VERSION="${TARGET_REGISTRY##*:}"
            if [[ -z "$TARGET_VERSION" || "$TARGET_VERSION" == "$TARGET_REGISTRY" ]]; then
                TARGET_VERSION="latest"
            fi
            shift 2
            ;;
        --provider)
            PROVIDER_NAME="$2"
            shift 2
            ;;
        --wait-user-input)
            WAIT_USER_INPUT="yes"
            shift
            ;;
        --use-cluster-context)
            USE_CLUSTER_CONTEXT="$2"
            shift 2
            ;;
        --skip-crossplane-install)
            INSTALL_CROSSPLANE=false
            shift
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            print_help
            exit 1
            ;;
        esac
    done

    date
    echo "----------------------------------------------------------------------------"
    echo "Source registry: $SOURCE_REGISTRY"
    echo "Target registry: $TARGET_REGISTRY"
    echo "Source directory: $SOURCE_DIR"
    echo "Provider: $PROVIDER_NAME"
    echo "Wait for user input: $WAIT_USER_INPUT"
    echo "Cluster context: $USE_CLUSTER_CONTEXT"
    echo "Install Crossplane: $INSTALL_CROSSPLANE"
    echo "----------------------------------------------------------------------------"

    # Validate required parameters
    exec_params_check

    # Get the basename of SOURCE_DIR for the generated directory structure
    SOURCE_DIR_BASENAME=$(basename "$SOURCE_DIR")

    print_color_message ${PURPLE} "-------Running provider upgrade test from $SOURCE_VERSION to $TARGET_VERSION for $PROVIDER_NAME using CR tests located in providers/$SOURCE_DIR..."
    current_dir=$(pwd)
   
    create_or_use_k8s_cluster

    install_crossplane_if_needed

    mkdir generated
    print_color_message ${PURPLE} "------1. Deploying provider version $SOURCE_VERSION..."
    sed  -e  "s|DOCKER_REGISTRY_TAG|${SOURCE_REGISTRY}|g"  -e "s|PROVIDER_NAME|${PROVIDER_NAME}|g" resources/provider-cr-template.yaml > generated/${PROVIDER_NAME}-source.yaml

    if [ "$SOURCE_NEED_AUTH" == true ]; then
        print_color_message ${BLUE} "create docker secret for source provider image..."
        create_provider_image_secret $SOURCE_DOCKER_REGISTRY $SOURCE_DOCKER_USERNAME $SOURCE_DOCKER_PASSWORD $SOURCE_DOCKER_EMAIL
    fi

    echo -e "${BLUE}generated provider yaml:${NC}"
    cat generated/${PROVIDER_NAME}-source.yaml
    printf "\n\n" 
    wait_user_input ${WAIT_USER_INPUT} "Do you want to deploy the source version $SOURCE_VERSION provider? (y/n): "


    kubectl apply -f generated/${PROVIDER_NAME}-source.yaml
    print_color_message ${BLUE} "Waiting for provider to become healthy..."
    wait_provider_healthy ${PROVIDER_NAME}
    print_color_message ${PURPLE} "-------2. Applying CRS for source version..."
    
    
    if [ -d "./providers/${SOURCE_DIR}" ]; then
        bash generate-yaml-rp-env.sh ./providers/${SOURCE_DIR}
    fi
    
    initialize_yaml_files "${SOURCE_DIR_BASENAME}"
    # Apply the generated CRs from the new structure
    if [ -d "./generated/${SOURCE_DIR_BASENAME}/setup" ]; then
        kubectl apply -f ./generated/${SOURCE_DIR_BASENAME}/setup/
    fi
    if [ -d "./generated/${SOURCE_DIR_BASENAME}/crs" ]; then
        kubectl apply -f ./generated/${SOURCE_DIR_BASENAME}/crs/
    fi
    
    # Run chainsaw test from within the generated directory
    pushd "./generated/${SOURCE_DIR_BASENAME}" > /dev/null
    
    # Debug: Check what resources are actually created before running chainsaw
    echo "Debug: Checking applied resources:"
    kubectl get subaccount,entitlement,servicemanager,cloudmanagement --no-headers 2>/dev/null || echo "No managed resources found yet"
    
    echo "Debug: Checking provider status before chainsaw test:"
    kubectl get providers/${PROVIDER_NAME} -o json | jq '.status.conditions' || echo "Provider status not available"
    
    chainsaw test --skip-delete 
    test_result=$?
    popd > /dev/null
    
    if [ $test_result -ne 0 ]; then
        print_color_message ${RED} "*****provider $PROVIDER_NAME CR resources can not be all applied at source version $SOURCE_VERSION, stop tests."
        # Cleanup resources before exiting
        cleanup_resources "${SOURCE_DIR_BASENAME}"
        exit 1
    fi

    sed  -e  "s|DOCKER_REGISTRY_TAG|${TARGET_REGISTRY}|g" -e "s|PROVIDER_NAME|${PROVIDER_NAME}|g" resources/provider-cr-template.yaml > generated/${PROVIDER_NAME}-target.yaml
    if [ "$TARGET_NEED_AUTH" == true ]; then
        print_color_message ${BLUE} "create docker secret for source provider image..."
        create_provider_image_secret $TARGET_DOCKER_REGISTRY $SOURCE_DOCKER_USERNAME $SOURCE_DOCKER_PASSWORD $SOURCE_DOCKER_EMAIL
    fi
    print_color_message ${BLUE} "generated provider yaml:"
    cat generated/${PROVIDER_NAME}-target.yaml
    printf "\n\n"    
    wait_user_input ${WAIT_USER_INPUT} "Source version CRs applied, do you want to deploy the target version $TARGET_VERSION provider? (y/n): "
    print_color_message ${PURPLE} "-------3. Upgrading provider to version ${TARGET_VERSION}..."
    kubectl apply -f generated/${PROVIDER_NAME}-target.yaml

    sleep 10
    print_color_message ${BLUE} "Waiting for provider to become healthy and stay healthy for 2mins after verison upgrade..."
    wait_provider_upgrade_healthy 12
    provider_upgrade_result=$?
    if [ $provider_upgrade_result -ne 0 ]; then
        print_color_message ${RED} "*****Test results: provider $PROVIDER_NAME can not upgrade from $SOURCE_VERSION to $TARGET_VERSION."
        # Cleanup resources before exiting
        cleanup_resources "${SOURCE_DIR_BASENAME}"
        exit 1
    fi
    status_provider_upgrade="✔ True"

    print_color_message ${PURPLE} "-------4. Checking if CRs deployed from source version is still healthy..."

    chainsaw_test_file="generated/${SOURCE_DIR_BASENAME}/chainsaw-test.yaml"
    namespace="default"
    assertions=$(parse_assertions "$chainsaw_test_file")
    resources_healthy=true
    echo "$assertions" | while read -r api_version kind name; do
        check_resource_status "$api_version" "$kind" "$name" "$namespace"
        if [ $? -ne 0 ]; then
            resources_healthy=false
            echo -e "${RED}Health check failed for $kind/$name${NC}"
        fi
    done
    print_color_message "${NC}" "Source version resources check finished."
    if [ "$resources_healthy" = true ]; then
        status_resources_check_after_upgrade="✔ True"
    else
        status_resources_check_after_upgrade="✘ False"
    fi
    
    print_color_message ${BLUE} "to delete cluster: kind delete cluster --name ${test_cluster_name}"

    echo -e "${PURPLE}-------5. loop checking if provider will stay healthy for 10mins${NC}"
    check_provider_stay_healthy 60
    provider_stay_healthy_result=$?
    if [ $provider_stay_healthy_result -ne 0 ]; then
        status_provider_alwasy_healthy="✘ False"
    else 
        status_provider_alwasy_healthy="✔ True"
    fi
    
    print_color_message ${GREEN} "Finished upgrade test from $SOURCE_VERSION to $TARGET_VERSION for $PROVIDER_NAME."
    print_test_steps_summary "✔ True" "✔ True" "$status_provider_upgrade" "$status_resources_check_after_upgrade" "$status_provider_alwasy_healthy" 

    # Cleanup test resources from generated directory
    cleanup_resources "${SOURCE_DIR_BASENAME}"

    if [ -n "$CLEANUP_SCRIPT" ]; then
        print_color_message ${BLUE} "Running cleanup script..."
        chmod +x $CLEANUP_SCRIPT && bash $CLEANUP_SCRIPT
    fi
    if [ "$PRINT_POD_LOGS" == true ]; then
        print_color_message ${BLUE} "Printing pod logs to file "generated/${PROVIDER_NAME}-pod-logs.txt"..."
        kubectl logs providers/${PROVIDER_NAME} > generated/${PROVIDER_NAME}-pod-logs.txt
    fi
    ;;

*)
    print_help
    ;;
esac