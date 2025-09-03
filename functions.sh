#!/usr/bin/env bash

# Define color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
NC='\033[0m' # No Color (reset)


check_resource_status() {
  local api_version=$1
  local kind=$2
  local name=$3
  local namespace=$4

  # Query the resource using kubectl and check status conditions
  resource_status=$(kubectl get "$kind" "$name" --namespace="$namespace" -o json)

  # Debug: Print the actual resource status
  echo "Debug: Resource $kind/$name status:"
  echo "$resource_status" | jq '.status' || echo "No status field found"

  ready_status=$(echo "$resource_status" | jq -r '.status.conditions[] | select(.type == "Ready") | .status')
  synced_status=$(echo "$resource_status" | jq -r '.status.conditions[] | select(.type == "Synced") | .status')

  echo "Debug: Ready status: '$ready_status', Synced status: '$synced_status'"

  if [ "$ready_status" != "True" ]; then
    echo "Resource $kind/$name is not Ready!! Ready status: $ready_status"
    return 1
  fi
  if [ "$synced_status" != "True" ]; then
    echo "Resource $kind/$name is not Synced!! Synced status: $synced_status"
    return 1
  fi

  echo "Resource $kind/$name is Healthy"
  return 0
}

check_crossplane_installation() {
    # Timeout in seconds
    timeout=180
    interval=20
    elapsed=0

    echo "Checking if Crossplane pods are running and CRDs are applied (timeout: 3 minutes)..."

    while [[ $elapsed -lt $timeout ]]; do
        # Check if all Crossplane pods are running
        all_pods_running=true
        kubectl get pods -n crossplane-system | grep crossplane | while read -r line; do
            pod_status=$(echo "$line" | awk '{print $3}')
            if [[ "$pod_status" != "Running" ]]; then
                echo "Pod $(echo "$line" | awk '{print $1}') is not running. Status: $pod_status"
                all_pods_running=false
            fi
        done

        # Check if Crossplane CRDs are installed
        crds=$(kubectl get crds | grep crossplane | wc -l)

        if [[ "$all_pods_running" == true && "$crds" -ge 1 ]]; then
            echo "All Crossplane pods are running and CRDs are installed."
            return 0
        fi

        echo "Waiting for Crossplane pods to be running and CRDs to be applied..."
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    echo "Error: Crossplane pods are not running or CRDs are not applied within the timeout period."
    exit 1
}

parse_assertions() {
  local chainsaw_test_file=$1
   yq e -o=json ${chainsaw_test_file} | jq -r '
    .spec.steps[] |
    select(has("try")) |
    .try[] |
    select(has("assert")) |
    .assert.resource |
    "\(.apiVersion) \(.kind) \(.metadata.name)"
  ' 
} 

test() {
    jq --version
    yq --version
}

create_kind_cluster() {
    test_cluster_name=local-upgrade-test-$(date '+%Y-%m-%d-%H-%M-%S')
    echo "Creating kind cluster: ${test_cluster_name}..."
    kind create cluster --name ${test_cluster_name} --quiet
    kubectl wait --for=condition=Ready nodes --all --timeout=120s > /dev/null 2>&1
    kubectl config use-context kind-${test_cluster_name} > /dev/null 2>&1
    echo "✓ Cluster ${test_cluster_name} ready"
    
    # Only show essential cluster info
    kubectl cluster-info --context kind-${test_cluster_name} | head -2
}

check_required_command_exists() {
    if ! command -v chainsaw &> /dev/null; then
        if command -v go &> /dev/null; then
            echo -e "chainsaw not installed, attempting to install chainsaw..."
            if go install github.com/kyverno/chainsaw@latest; then
                echo "chainsaw successfully installed."
            else
                echo -e "Failed to install chainsaw using go."
            fi
        else
            echo -e "chainw not installed, go command not found. Cannot install chainsaw."
        fi
    fi
    command -v kind >/dev/null 2>&1 || { echo >&2 "kind is not installed. Aborting."; exit 1; }
    command -v kubectl >/dev/null 2>&1 || { echo >&2 "kubectl is not installed. Aborting."; exit 1; }
    command -v chainsaw >/dev/null 2>&1 || { echo >&2 "chainsaw is not installed. Aborting."; exit 1; }
    command -v sed >/dev/null 2>&1 || { echo >&2 "sed is not installed. Aborting."; exit 1; }
    command -v yq >/dev/null 2>&1 || { echo >&2 "yq is not installed. Aborting."; exit 1; }
    command -v jq >/dev/null 2>&1 || { echo >&2 "jq is not installed. Aborting."; exit 1; }

}

print_color_message() {
    local color=$1
    local message=$2

    echo -e "${color}${message}${NC}"
}

install_crossplane() {
    helm repo add crossplane-stable https://charts.crossplane.io/stable
    helm install crossplane  crossplane-stable/crossplane --version 1.20.0
}

wait_provider_healthy() {
    local provider_name=$1
    for i in {1..10}; do
        INSTALLED=$(kubectl get providers/${provider_name} -o jsonpath='{.status.conditions[?(@.type=="Installed")].status}')
        HEALTHY=$(kubectl get providers/${provider_name} -o jsonpath='{.status.conditions[?(@.type=="Healthy")].status}')        
        if [[ "$HEALTHY" == "True" ]] ; then
            echo "Provider is healthy."
            if [[ "$INSTALLED" == "True" ]]; then
                echo "Provider is installed."
                break
            else
                echo "Provider is not installed yet."
            fi
        fi
        echo "Provider is not ready yet. Retrying in 10 seconds..."
        if (( i % 3 == 0 )); then
            echo "*****current provider status details:"
            kubectl describe providers/${provider_name} | sed -n '/^Status:/,/^Events:/p' | sed '$d'
        fi
        sleep 10
    done
    
    if [[ "$HEALTHY" != "True" ]]; then
        print_color_message ${RED} "Error: Provider did not become healthy within the timeout period, stop the test."
        exit 1
    else 
       echo "Provider is healthy and installed."
    fi
}

wait_provider_upgrade_healthy() {
    local provider_always_healthy=true
    local provider_final_status
    func_check_provider_always_healthy $1
    if [[ "$provider_final_status" != "healthy" ]]; then
        print_color_message ${RED} "Error: failed to upgrade, provider did not become healthy within the timeout period."
        return -1
    else 
        print_color_message ${GREEN} "Provider is upgraded and in healthy status."
        return 0
    fi

}

check_provider_stay_healthy() {
    local provider_always_healthy=true
    local provider_final_status
    func_check_provider_always_healthy $1
    if [[ "$provider_always_healthy" == false ]]; then
        echo -e "${RED}Provider was not always healthy during the time period checking status.${NC}"
        return -1
    else 
        return 0
    fi
}

func_check_provider_always_healthy() {
    local check_times=${1:-60}
    for i in $(seq 1 "${check_times}"); do
        local provider_information=$(kubectl get providers/${PROVIDER_NAME} -o json)
        INSTALLED=$(echo $provider_information | jq -r '.status.conditions|.[] | select(.type == "Installed")|.status')
        HEALTHY=$(echo $provider_information | jq -r '.status.conditions|.[] | select(.type == "Healthy")|.status')
        if [[ "$HEALTHY" != "True" ]] || [[ "$INSTALLED" != "True" ]]; then
            print_color_message ${PURPLE} "Check no.${i}: Provider is not healthy or not installed. Checking again in 10 seconds..."
            provider_always_healthy=false
            provider_final_status="not healthy"
        else
            print_color_message ${GREEN} "Check no.${i}: Provider is healthy and installed. Checking again in 10 seconds..."
            provider_final_status="healthy"
        fi
        if (( i % 3 == 0 )); then
            echo "*****current provider status details:"
            kubectl describe providers/${PROVIDER_NAME} | sed -n '/^Status:/,/^Events:/p' | sed '$d'
        fi
        sleep 10
    done
    RESTART_COUNT=$(kubectl get providers/${PROVIDER_NAME} -o jsonpath='{.status.containerStatuses[*].restartCount}')
    print_color_message ${BLUE} "Checking provider pods restart times: ${RESTART_COUNT:-0}"
    if [[ "$RESTART_COUNT" -gt 0 ]]; then
        print_color_message ${PURPLE} "Provider pods have restarted ${RESTART_COUNT} times!!"
    else
        print_color_message ${BLUE} "Provider pods have not restarted."
    fi
}

install_crossplane_if_needed() {
    $INSTALL_CROSSPLANE && print_color_message ${BLUE} "Installing crossplane..."
    $INSTALL_CROSSPLANE && install_crossplane
    $INSTALL_CROSSPLANE && check_crossplane_installation
}

create_or_use_k8s_cluster() {
    if [ -z "$USE_CLUSTER_CONTEXT" ]; then
        print_color_message ${BLUE} "Creating a local kind cluster..."
        create_kind_cluster
    else
        print_color_message ${BLUE} "Using cluster context $USE_CLUSTER_CONTEXT..."
        test_cluster_name=$USE_CLUSTER_CONTEXT
        kubectl config use-context $test_cluster_name
    fi
}

exec_params_check() {
    if [ -z "$SOURCE_DIR" ]; then
        SOURCE_DIR="${PROVIDER_NAME}/${SOURCE_VERSION}"
    fi

    if [ -z "$SOURCE_REGISTRY" ] || [ -z "$TARGET_REGISTRY" ] || [ -z "$SOURCE_DIR" ] ; then
        print_color_message ${RED} "Error: --source, --target, --source-dir are required for upgrade-test."
        print_help
        exit 1
    fi 

    if [ ! -d "./providers/$SOURCE_DIR" ] || [ ! -f "./providers/$SOURCE_DIR/chainsaw-test.yaml" ]; then
        print_color_message ${RED} "Error: couldn't find test resource under source-dir: $SOURCE_DIR."
        exit 1
    fi
}

wait_user_input() {
    local is_wait_user_input=$1
    local message=$2
    if [[ -n "$is_wait_user_input" && $is_wait_user_input == "yes" ]]; then
        read -p "${message}" user_input
        if [[ "$user_input" != "y" && "$user_input" != "Y" ]]; then
            echo "Upgrade test process aborted by the user."
            exit 0
        fi
    fi
    
}

print_help ()
{
    printf '%s\n' "Provider Upgrade Test Script"
    printf 'Usage: %s upgrade-test [--source <arg>] [--target <arg>] [--source-dir <arg>] [--provider <arg>] [--use-cluster-context <arg>] [--wait-user-input] [--skip-crossplane-install] [-h|--help] \n' "$0"
    printf '\t%s\n' "--source: source version provider docker registry with tag (required)"
    printf '\t%s\n' "--target: target version provider docker registry with tag (required)"
    printf '\t%s\n' "--source-dir: source provider CR test directory relative to providers (required)"
    printf '\t%s\n' "--provider: which provider to test (default: provider-btp)"
    printf '\t%s\n' "--use-cluster-context: do not create k8s cluster, instead use existing cluster context"
    printf '\t%s\n' "--wait-user-input: prompt for user input within test steps"
    printf '\t%s\n' "--skip-crossplane-install: skip installing crossplane in k8s cluster"
    printf '\t%s\n' "-h,--help: Prints help"
    printf '\n%s\n' "Example:"
    printf '\t%s\n' "./provider-test.sh upgrade-test --source crossplane/provider-btp:v1.0.3 --target crossplane/provider-btp:v1.1.0 --source-dir provider-btp/v1.0.3"
}

print_test_steps_summary() {
    local deploy_source_provider_status=$1
    local apply_source_crs_status=$2
    local upgrade_provider_version_status=$3
    local verify_crs_healthy_status=$4
    local provider_stays_healthy_status=$5
    local table_name="Provider Upgrade Test Results"
    local steps=("1. Deploy source provider" \
        "2. Apply source CRs" \
        "3. provider upgraded successfully" \
        "4. CRs stay healthy after upgrade" \
        "5. Provider stays 10 mins healthy afterwards")
    local results=("$deploy_source_provider_status" "$apply_source_crs_status" "$upgrade_provider_version_status" "$verify_crs_healthy_status" "$provider_stays_healthy_status")

    # Print table name
    echo -e "\n$table_name\n"

    # Print table header
    printf "%-50s | %-10s\n" "Steps" "Result"
    printf "%-50s-+-%-10s\n" "$(printf -- '-%.0s' {1..50})" "$(printf -- '-%.0s' {1..10})"

    # Print table rows
    for i in "${!steps[@]}"; do
        printf "%-50s | %-10s\n" "${steps[$i]}" "${results[$i]}"
    done
    
}