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
            echo $SOURCE_VERSION
            if [[ -z "$SOURCE_VERSION" || "$SOURCE_VERSION" == "$SOURCE_REGISTRY" ]]; then
                SOURCE_VERSION="latest"
            fi
            shift 2
            ;;
        --source-dir)
            SOURCE_DIR="$2"
            shift 2
            ;;
        --source-docker-auth)
            SOURCE_NEED_AUTH=true
            shift
            ;;
        --target-docker-auth)
            TARGET_NEED_AUTH=true
            shift
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
        --initialize)
            INITIALIZE_SCRIPT="$2"
            shift 2
            ;;
        --cleanup)
            CLEANUP_SCRIPT="$2"
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
            ;;
        esac
    done

    date
    echo "----------------------------------------------------------------------------"
    echo "Value of --source: $SOURCE_REGISTRY"
    echo "Value of --target: $TARGET_REGISTRY"
    echo "Value of --source-dir: $SOURCE_DIR"
    echo "Value of --source-docker-auth: $SOURCE_NEED_AUTH"
    echo "Value of --target-docker-auth: $TARGET_NEED_AUTH"
    echo "Value of --provider: $PROVIDER_NAME"
    echo "Value of --wait-user-input: $WAIT_USER_INPUT"
    echo "Value of --use-cluster-context: $USE_CLUSTER_CONTEXT"
    echo "Value of --skip-crossplane-install: $INSTALL_CROSSPLANE"
    echo "----------------------------------------------------------------------------"

    exec_params_check

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
    
    
    if [ -d "./providers/${SOURCE_DIR}/setup" ]; then
        bash generate-yaml-rp-env.sh ./providers/${SOURCE_DIR}/setup
    fi
    
    if [ -z "$INITIALIZE_SCRIPT" ]; then
        print_color_message ${BLUE} "No initialize script provided, skipping initialization..."
    else
        print_color_message ${BLUE} "Running initialize script..."
        chmod +x $INITIALIZE_SCRIPT && bash $INITIALIZE_SCRIPT
    fi

    # todo: if the config doenst have a new line in the end there's no line of source:secret
    kubectl apply -f ./generated/temp-generated/
    chainsaw  test --test-dir ./providers/${SOURCE_DIR}/ --skip-delete 
    test_result=$?
    if [ $test_result -ne 0 ]; then
        print_color_message ${RED} "*****provider $PROVIDER_NAME CR resources can not be all applied at source version $SOURCE_VERSION, stop tests."
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
        exit 1
    fi
    status_provider_upgrade="✔ True"

    print_color_message ${PURPLE} "-------4. Checking if CRs deployed from source version is still healthy..."

    chainsaw_test_file="providers/${SOURCE_DIR}/chainsaw-test.yaml"
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
