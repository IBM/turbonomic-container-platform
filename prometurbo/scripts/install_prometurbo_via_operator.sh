#!/usr/bin/env sh

################## PRE-CONFIGURATION ##################
## Place your hardcoded ARGS variable assignments here ##
# TARGET_HOST=""
# OAUTH_CLIENT_ID=""
# OAUTH_CLIENT_SECRET=""
# TSC_TOKEN=""

################## CMD ALIAS ##################
DEPENDENCY_LIST="grep cat sleep wc awk sed base64 mktemp curl"
KUBECTL=$(command -v oc)
KUBECTL=${KUBECTL:-$(command -v kubectl)}
if ! [ -x "${KUBECTL}" ]; then
    echo "ERROR: Command 'oc' and 'kubectl' are not found, please install either of them first!" >&2 && exit 1
fi

################## CONSTANT ##################
export KUBECTL_WARNINGS="false"

K8S_TYPE="Kubernetes"
OCP_TYPE="RedHatOpenShift"

# ENUM values for the approach to connect to the Prometheus server
NONE_APPROACH="none"
TOKEN_APPROACH="token"
SERVICEACCOUNT_APPROACH="service account"
CUSTOMSECRET_APPROACH="custom secret"
MANUALTOKEN_APPROACH="manual token"

CATALOG_SOURCE="certified-operators"
CATALOG_SOURCE_NS="openshift-marketplace"

TSC_TOKEN_FILE=""
DEFAULT_RELEASE="stable"
DEFAULT_NS="turbonomic"
DEFAULT_TARGET_NAME="Customer-cluster"
DEFAULT_PROMETHEUS_ADDRESS="http://127.0.0.1:8081/metrics"
DEFAULT_ROLE="cluster-admin"
DEFAULT_ENABLE_TSC="optional"
DEFAULT_PROMETURBO_NAME="prometurbo-release"
DEFAULT_PROMETURBO_VERSION="8.14.3"
DEFAULT_PROMETURBO_REGISTRY="icr.io/cpopen/turbonomic/prometurbo"
DEFAULT_TURBODIF_REGISTRY="icr.io/cpopen/turbonomic/turbodif"
DEFAULT_REGISTRY_PREFIX="icr.io/cpopen"
DEFAULT_PROMETURBO_IMG_REPO="turbonomic/prometurbo"
DEFAULT_TURBODIF_IMG_REPO="turbonomic/turbodif"
DEFAULT_PRIVATE_REGISTRY_SECRET_NAME="private-docker-registry-secret-prometurbo"
DEFAULT_LOGGING_LEVEL=0
DEFAULT_KUBESTATE_VERSION="v2.14.0"
DEFAULT_PROXY_SERVER=""
DEFAULT_PSC_NAME="prometheus-server-config"
DEFAULT_PROMETHEUS_SERVER_SECRET_NAME="prometheus-server-authorization-secret"

RETRY_INTERVAL=10 # in seconds
MAX_RETRY=10

################## ARGS ##################
OSTYPE=${OSTYPE:-""}
KUBECONFIG=${KUBECONFIG:-""}

ACTION=${ACTION:-"apply"}
PT_TARGET_RELEASE=${PT_TARGET_RELEASE:-${DEFAULT_RELEASE}}
TSC_TARGET_RELEASE=${TSC_TARGET_RELEASE:-${DEFAULT_RELEASE}}
PWD_SECRET_ENCODED=${PWD_SECRET_ENCODED:-"true"}

TARGET_HOST=${TARGET_HOST:-""}
OAUTH_CLIENT_ID=${OAUTH_CLIENT_ID:-""}
OAUTH_CLIENT_SECRET=${OAUTH_CLIENT_SECRET:-""}
TSC_TOKEN=${TSC_TOKEN:-""}

OPERATOR_NS=${OPERATOR_NS:-${DEFAULT_NS}}
TARGET_NAME=${TARGET_NAME:-${DEFAULT_TARGET_NAME}}
TARGET_ADDRESS=${TARGET_ADDRESS:-${DEFAULT_PROMETHEUS_ADDRESS}}
PROMETURBO_ROLE=${PROMETURBO_ROLE:-${DEFAULT_ROLE}}
ENABLE_TSC=${ENABLE_TSC:-${DEFAULT_ENABLE_TSC}}
PROMETURBO_NAME=${PROMETURBO_NAME:-${DEFAULT_PROMETURBO_NAME}}
PROMETURBO_OP_VERSION=${PROMETURBO_OP_VERSION:-""}
PROMETURBO_VERSION=${PROMETURBO_VERSION:-${DEFAULT_PROMETURBO_VERSION}}
PROMETURBO_REGISTRY=${PROMETURBO_REGISTRY:-${DEFAULT_PROMETURBO_REGISTRY}}
TURBODIF_REGISTRY=${TURBODIF_REGISTRY:-${DEFAULT_TURBODIF_REGISTRY}}
PRIVATE_REGISTRY_PREFIX=${PRIVATE_REGISTRY_PREFIX:-""}
PRIVATE_REGISTRY_USRNAME=${PRIVATE_REGISTRY_USRNAME:-""}
PRIVATE_REGISTRY_PASSWRD=${PRIVATE_REGISTRY_PASSWRD:-""}
TARGET_SUBTYPE=${TARGET_SUBTYPE:-""}
PROXY_SERVER=${PROXY_SERVER:-${DEFAULT_PROXY_SERVER}}

PSC_NAME="${PSC_NAME:-${DEFAULT_PSC_NAME}}"
PROMETHEUS_SERVER_URL="${PROMETHEUS_SERVER_URL:-""}"
PROMETHEUS_SERVER_SECRET_NAME="${PROMETHEUS_SERVER_SECRET_NAME:-${DEFAULT_PROMETHEUS_SERVER_SECRET_NAME}}"
PROMETHEUS_QUERY_MAPPING_CR="${PROMETHEUS_QUERY_MAPPING_CR:-""}"
PROMETHEUS_ACCESS_TOKEN=${PROMETHEUS_ACCESS_TOKEN:-""}
PROMETHEUS_SERVERACCOUNT_NS=${PROMETHEUS_SERVERACCOUNT_NS:-""}
PROMETHEUS_SERVERACCOUNT_NAME=${PROMETHEUS_SERVERACCOUNT_NAME:-""}

LOGGING_LEVEL=${LOGGING_LEVEL:-${DEFAULT_LOGGING_LEVEL}}

################## DYNAMIC VARS ##################
CERT_OP_NAME="<EMPTY>"
CERT_OP_RELEASE="<EMPTY>"
CERT_OP_VERSION="<EMPTY>"
CERT_PROMETURBO_OP_NAME="<EMPTY>"
CERT_PROMETURBO_OP_RELEASE="<EMPTY>"
CERT_PROMETURBO_OP_VERSION="<EMPTY>"
CERT_TSC_OP_NAME="<EMPTY>"
CERT_TSC_OP_RELEASE="<EMPTY>"
CERT_TSC_OP_VERSION="<EMPTY>"
K8S_CLUSTER_KINDS="<EMPTY>"
PRIVATE_REGISTRY_ENABLED="false"
PRIVATE_REGISTRY_SECRET_NAME=""
ACCEPT_FALLBACK=""
PROMETHEUS_SERVER_CONNECTION_APPROACH=""

PROMETHEUS_NS=""
PROMETHEUS_PORT=""
PROMETHEUS_SERVICES_NAME=""
INTERNAL_URL_MAPPING_SOURCE=""

PORT_FORWARD_PID=""
PORT_FORWARD_URL=""
PORT_FORWARD_PORT=""

################## FUNCTIONS ##################
# Function to check if the current system supports all the commands needed to run the script
dependencies_check() {
    echo "Validating necessary tools on the machine..."
    missing_dependencies=""
    for dependency in ${DEPENDENCY_LIST}; do
        dependency_path=$(command -v "${dependency}")
        if ! [ -x "${dependency_path}" ]; then
            if [ -z "${missing_dependencies}" ]; then
                missing_dependencies="${dependency}"
            else
                missing_dependencies="${missing_dependencies} ${dependency}"
            fi
        fi
    done

    if [ -n "${missing_dependencies}" ]; then
        missing_dependencies_str=$(echo "$missing_dependencies" | sed 's/ /, /g')
        echo "ERROR: Missing the required command: ${missing_dependencies_str}"
        echo "Please refer to the official documentation or use your package manager to install them."
        exit 1
    fi
}

# Function to process args to this script
validate_args() {
    while [ $# -gt 0 ]; do
        case $1 in
            -h|--help) shift; usage; exit 0;;
            --host) shift; TARGET_HOST="$1"; [ -n "${TARGET_HOST}" ] && shift;;
            --kubeconfig) shift; KUBECONFIG="$1"; [ -n "${KUBECONFIG}" ] && shift;;
            -*) echo "ERROR: Unknown option $1" >&2; usage; exit 1;;
            *) shift;;
        esac
    done

    if [ -z "${TARGET_HOST}" ]; then
        echo "ERROR: Missing target host" >&2; usage; exit 1
    fi

    # Prioritize the TSC deployment approach once the value is set
    if [ "${ENABLE_TSC}" = "optional" ]; then
        if [ -n "${TSC_TOKEN}" ] || [ -n "${TSC_TOKEN_FILE}" ]; then ENABLE_TSC="true"; fi
    fi

    # Pre-process the encoded secrets and passwords
    if [ "${PWD_SECRET_ENCODED}" = "true" ]; then
        PRIVATE_REGISTRY_PASSWRD=$(password_secret_handler "${PRIVATE_REGISTRY_PASSWRD}")
        OAUTH_CLIENT_ID=$(password_secret_handler "${OAUTH_CLIENT_ID}")
        OAUTH_CLIENT_SECRET=$(password_secret_handler "${OAUTH_CLIENT_SECRET}")
        PROXY_SERVER=$(password_secret_handler "${PROXY_SERVER}")
        PROMETHEUS_ACCESS_TOKEN=$(password_secret_handler "${PROMETHEUS_ACCESS_TOKEN}")
        PROMETHEUS_QUERY_MAPPING_CR=$(password_secret_handler "${PROMETHEUS_QUERY_MAPPING_CR}")
    fi

    # If the target subtype is not set, auto-detect the current cluster
    if [ -z "${TARGET_SUBTYPE}" ]; then
        TARGET_SUBTYPE=$(auto_detect_cluster_type)
    fi

    # Extract registry prefix from prometurbo registry if the private registry is not provided
    if [ "${PRIVATE_REGISTRY_PREFIX}" = "" ]; then
        PRIVATE_REGISTRY_PREFIX=$(echo "${PROMETURBO_REGISTRY}" | sed "s|\/${DEFAULT_PROMETURBO_IMG_REPO}$||g")
    fi

    # Determine if the private registry is applied or not
    if [ "${PRIVATE_REGISTRY_PREFIX}" != "${DEFAULT_REGISTRY_PREFIX}" ]; then
        PRIVATE_REGISTRY_ENABLED="true"
    else
        PRIVATE_REGISTRY_ENABLED="false"
    fi

    # determine which approach is used to connect to the Prometheus server based on the args provided by the user
    determine_prometheus_connection_approach
}

# Wraps up kubectl cmd to ensure spaces in path can be handle safely
run_kubectl() {
    if [ -n "${KUBECONFIG:-}" ]; then
        "${KUBECTL}" --kubeconfig="${KUBECONFIG}" "$@"
    else
        "${KUBECTL}" "$@"
    fi
}


# Function to detect the cluster type
auto_detect_cluster_type() {
    is_current_oc_cluster=$(run_kubectl api-resources --api-group=route.openshift.io -o name)
    normalize_target_cluster_type "$([ -n "${is_current_oc_cluster}" ] && echo "${OCP_TYPE}")"
}

# Function to normalize cluster type to either Openshift or Kubernetes
normalize_target_cluster_type() {
    cluster_type=$1
    is_target_oc_cluster=$(echo "${cluster_type}" | grep -i "${OCP_TYPE}")
    [ -n "${is_target_oc_cluster}" ] && echo "${OCP_TYPE}" || echo "${K8S_TYPE}"
}

# Function to handle base64 encoded secret
password_secret_handler() {
    if [ "${PWD_SECRET_ENCODED}" = "true" ]; then
        echo "$1" | base64 -d
    else
        echo "$1"
    fi
}

# Function to describe how to use this script
usage() {
   echo "This program helps to install Prometurbo to to the Kubernetes cluster"
   echo "Syntax: ./$0 [flags] [args]"
   echo
   echo "args:"
   echo "<Prometurbo name>  Optional name fragment to scope down Prometurbo targets (default ${DEFAULT_PROMETURBO_DEPLOYMENT})"
   echo
   echo "flags:"
   echo "-h --help             Print out the usage message"
   echo "--host       <VAL>    host of the Turbonomic instance (required)"
   echo "--kubeconfig <VAL>    Path to the kubeconfig file to use for kubectl requests"
   echo
}

confirmations() {
    confirm_installation
    confirm_installation_cluster
    cluster_type_check
}

# Function to confirm args that are passed into the script and get user's consent
confirm_installation() {
    proxy_server_enabled=$([ -n "${PROXY_SERVER}" ] && echo 'true' || echo 'false')
    echo "Here is the summary for the current installation:"
    echo ""
    printf "%-20s %-20s\n" "---------" "---------"
    printf "%-20s %-20s\n" "Parameter" "Value"
    printf "%-20s %-20s\n" "---------" "---------"
    printf "%-20s %-20s\n" "Mode" "$([ "${ACTION}" = 'delete' ] && echo 'Delete' || echo 'Create/Update')"
    printf "%-20s %-20s\n" "Kubeconfig" "${KUBECONFIG:-default}"
    printf "%-20s %-20s\n" "Host" "${TARGET_HOST}"
    printf "%-20s %-20s\n" "Namespace" "${OPERATOR_NS}"
    printf "%-20s %-20s\n" "Target Name" "${TARGET_NAME}"
    printf "%-20s %-20s\n" "Target Subtype" "${TARGET_SUBTYPE}"
    printf "%-20s %-20s\n" "Role" "${PROMETURBO_ROLE}"
    printf "%-20s %-20s\n" "Version" "${PROMETURBO_VERSION}"
    printf "%-20s %-20s\n" "Auto-Update" "${ENABLE_TSC}"
    printf "%-20s %-20s\n" "Auto-Logging" "${ENABLE_TSC}"
    printf "%-20s %-20s\n" "Private Registry" "${PRIVATE_REGISTRY_ENABLED}"
    printf "%-20s %-20s\n" "Registry" "${PRIVATE_REGISTRY_PREFIX}"
    printf "%-20s %-20s\n" "Proxy Server" "${proxy_server_enabled}"
    printf "%-20s %-20s\n" "Prometheus URL" "${PROMETHEUS_SERVER_URL:-"Not Set"}"
    printf "%-20s %-20s\n" "Prometheus Connection" "${PROMETHEUS_SERVER_CONNECTION_APPROACH}"
    echo ""
    echo "Please confirm the above settings [Y/n]: " && read -r  continueInstallation
    [ "${continueInstallation}" = "n" ] || [ "${continueInstallation}" = "N" ] && echo "Please retry the script with correct settings!" && exit 1
}

# Function to determine which approach used to connect to the Prometheus server
determine_prometheus_connection_approach() {
    if [ -z "${PROMETHEUS_SERVER_URL}" ]; then
        PROMETHEUS_SERVER_CONNECTION_APPROACH="${NONE_APPROACH}"
    elif [ "${PROMETHEUS_SERVER_SECRET_NAME}" != "${DEFAULT_PROMETHEUS_SERVER_SECRET_NAME}" ]; then
        PROMETHEUS_SERVER_CONNECTION_APPROACH="${CUSTOMSECRET_APPROACH}"
    elif [ -n "${PROMETHEUS_ACCESS_TOKEN}" ]; then
        PROMETHEUS_SERVER_CONNECTION_APPROACH="${TOKEN_APPROACH}"
    elif [ -n "${PROMETHEUS_SERVERACCOUNT_NAME}" ] || [ -n "${PROMETHEUS_SERVERACCOUNT_NS}" ]; then
        PROMETHEUS_SERVER_CONNECTION_APPROACH="${SERVICEACCOUNT_APPROACH}"
    else
        PROMETHEUS_SERVER_CONNECTION_APPROACH="${MANUALTOKEN_APPROACH}"
    fi
}

# Function to get client's consent to work with the current cluster
confirm_installation_cluster() {
    echo "Info: Your current Kubernetes context is set to the following:"
    show_current_kube_context
    echo "Please confirm if the script should work in the above cluster [Y/n]: " && read -r continueInstallation
    [ "${continueInstallation}" = "n" ] || [ "${continueInstallation}" = "N" ] && echo "Please double check your current Kubernetes context before the other try!" && exit 1
}

# Function to display the current kubeconfig context in a table format
show_current_kube_context() {
    # Exit if the current context is not set
    if ! current_context=$(run_kubectl config current-context); then
        echo "ERROR: Current context is not set in your cluster!"
        exit 1
    fi

    # Get detail from the raw object
    cluster=$(run_kubectl config view -o jsonpath='{.contexts[?(@.name == "'"${current_context}"'")].context.cluster}')
    user=$(run_kubectl config view -o jsonpath='{.contexts[?(@.name == "'"${current_context}"'")].context.user}')
    namespace=$(run_kubectl config view -o jsonpath='{.contexts[?(@.name == "'"${current_context}"'")].context.namespace}')

    # print out in the table
    spacing=5
    name_width=$((${#current_context} + spacing))
    cluster_width=$((${#cluster} + spacing))
    user_width=$((${#user} + spacing))
    namespace_width=$((${#namespace} + spacing))

    # Construct the dynamic format string
    format="%-${name_width}s %-${cluster_width}s %-${user_width}s %-${namespace_width}s\n"

    # Use printf with the format string as an argument
    eval "printf '${format}' 'NAME' 'CLUSTER' 'AUTHINFO' 'NAMESPACE'"
    eval "printf '${format}' \"${current_context}\" \"${cluster}\" \"${user}\" \"${namespace}\""

    # Exit if the current the cluster is not reachable
    if ! run_kubectl get nodes > /dev/null 2>&1; then
        echo "ERROR: Context used by the current cluster is not reachable!"
        exit 1
    fi

    # Gather all cluster level resource kinds
    K8S_CLUSTER_KINDS=$(run_kubectl api-resources --namespaced=false --no-headers | awk '{print $NF}')
}

# Function to determine whether the current kubectl context is an Openshift cluster
cluster_type_check() {
    current_context=$(run_kubectl config current-context)
    current_oc_cluster_type=$(auto_detect_cluster_type)
    TARGET_SUBTYPE=$(normalize_target_cluster_type "${TARGET_SUBTYPE}")
    if [ "${current_oc_cluster_type}" != "${TARGET_SUBTYPE}" ]; then
        echo "Your current cluster type [${current_oc_cluster_type}] mismatches with the target type [${TARGET_SUBTYPE}] you specified from the UI!"
        echo "Do you want to continue the installation as the [${current_oc_cluster_type}] target? [y/N]: " && read -r allowMismatch
        if [ "${allowMismatch}" = "y" ] || [ "${allowMismatch}" = "Y" ]; then
            TARGET_SUBTYPE="${current_oc_cluster_type}"
        else
            echo "Please double check your current Kubernetes context before the other try!" && exit 1
        fi
    fi
}

# Main logic
main () {
    # Create target namespace if it's not existing
    createORupdate_namespace "${OPERATOR_NS}"

    # install the Prometurbo operator and cr
    setup_prometurbo

    # install TSC operator, cr and apply the Skupper connection
    setup_tsc

    echo "Done"
}

# Function to ensure the target namespace is created
createORupdate_namespace() {
    namespace=${1:-"${OPERATOR_NS}"}
    if ! run_kubectl get ns "${namespace}" -o name > /dev/null 2>&1; then
        echo "Creating ${namespace} namespace..."
        run_kubectl create ns "${namespace}" --dry-run=client -o yaml | run_kubectl apply -f -
    fi
}

# Function to create or update the operator group object needed by running the operator subscription
createORupdate_operatorgroup() {
    namespace=${1:-"${OPERATOR_NS}"}
    action="${ACTION}"

    # Ensure to only create or update on OCP clusters
    if [ "${TARGET_SUBTYPE}" != "${OCP_TYPE}" ]; then return; fi

    # There is a restriction on the operator that enforced single OperatorGroup per namespace
    # This function shall create one if it's not exists or reuse it if it's already existed
    op_gp_count=$(run_kubectl -n "${namespace}" get OperatorGroup -o name | wc -l)
    if [ "${action}" != "delete" ] && [ "${op_gp_count}" -eq 1 ]; then
        echo "Operator group already exists in the ${namespace} namespace, no need to create new one."
        return
    elif [ "${op_gp_count}" -gt 1 ]; then
        # Error needs to be addressed by the client
        echo "ERROR: Found multiple Operator Groups in the namespace ${namespace}" >&2 && exit 1
    fi

    # Construct command to safely delete the generated operator group created by the code
    unset config
    if [ "${action}" = "delete" ]; then
        config="--ignore-not-found"
    fi

    operatorgroup_name="${namespace}-opeartorgroup"
    cat <<-EOF | run_kubectl "${action}" -f - ${config}
	---
	apiVersion: operators.coreos.com/v1
	kind: OperatorGroup
	metadata:
	  name: "${operatorgroup_name}"
	  namespace: "${namespace}"
	spec:
	  targetNamespaces:
	  - "${namespace}"
	---
	EOF
}

# Function to install Prometurbo
setup_prometurbo() {
    if [ "${ENABLE_TSC}" != "true" ]; then
        createORupdate_oauth2_token
    fi

    if [ "${ACTION}" = "delete" ]; then
        createORupdate_prometurbo_cr
        apply_prometheus_metrics_collection_configs
        createORupdate_prometurbo_operator
        apply_private_registry_secret
    else
        apply_private_registry_secret
        createORupdate_prometurbo_operator
        apply_prometheus_metrics_collection_configs
        createORupdate_prometurbo_cr
    fi

    echo "Successfully ${ACTION} Prometurbo in ${OPERATOR_NS} namespace!"
    run_kubectl -n "${OPERATOR_NS}" get sa,pod,deploy,cm,pqm,psc
}

# Create or delete private registry secret
apply_private_registry_secret() {
    if [ -n "${PRIVATE_REGISTRY_USRNAME}" ] && [ -n "${PRIVATE_REGISTRY_PASSWRD}" ]; then
        action="${ACTION}"
        unset config
        if [ "${ACTION}" = "delete" ]; then
            action="${ACTION}"
            config="--ignore-not-found"
        fi

        # Extract registry (part before the first '/'), default to "docker.io"
        docker_server=$(echo "${PRIVATE_REGISTRY_PREFIX}" | awk -F'/' '{print ($1 ~ /\./ ? $1 : "docker.io")}')

        PRIVATE_REGISTRY_SECRET_NAME="${DEFAULT_PRIVATE_REGISTRY_SECRET_NAME}"
        run_kubectl create secret docker-registry "${PRIVATE_REGISTRY_SECRET_NAME}" \
            --docker-username="${PRIVATE_REGISTRY_USRNAME}" \
            --docker-password="${PRIVATE_REGISTRY_PASSWRD}" \
            --docker-server="${docker_server}" \
            --namespace="${OPERATOR_NS}" \
            --dry-run="client" -o yaml | run_kubectl "${action}" -f - ${config}
    fi
}

# Function to create turbonomic-credentials secret
createORupdate_oauth2_token() {
    if [ "${ACTION}" != "delete" ]; then
        if [ -z "${OAUTH_CLIENT_ID}" ] || [ -z "${OAUTH_CLIENT_SECRET}" ]; then
            echo "Missing OAuth2 client settings, please gather values following the instruction: "
            echo "https://www.ibm.com/docs/en/tarm/latest?topic=cookbook-authenticating-oauth-20-clients-api"
            echo "Enable enter your OAuth2 client id: " && read -r OAUTH_CLIENT_ID
            echo "Enable enter your OAuth2 client secret: " && read -r OAUTH_CLIENT_SECRET
            createORupdate_oauth2_token && return
        fi
    fi

    action="${ACTION}"
    unset config
    if [ "${action}" = "delete" ]; then
        config="--ignore-not-found"
    fi

    cat <<-EOF | run_kubectl "${action}" -f - ${config}
	apiVersion: v1
	kind: Secret
	metadata:
	  name: turbonomic-credentials
	  namespace: "${OPERATOR_NS}"
	type: Opaque
	data:
	  clientid: $(encode_inline "${OAUTH_CLIENT_ID}")
	  clientsecret: $(encode_inline "${OAUTH_CLIENT_SECRET}")
	---
	EOF
}

# Function to create or update the prometurbo CR
createORupdate_prometurbo_cr() {
    action="${ACTION}"
    unset config
    if [ "${action}" = "delete" ]; then
        config="--ignore-not-found"
    fi

    echo "${ACTION} Prometurbo CR ..."
    if [ "${action}" = "delete" ]; then
        # Skip deletion if the CRD is not found
        if ! run_kubectl api-resources | grep -qE "Prometurbo"; then
            echo "There is not Prometurbo object to delete"
            return
        fi
    fi

    # Notify client to mirror which images
    if [ "${PRIVATE_REGISTRY_ENABLED}" = "true" ] && [ "${ACTION}" != "delete" ]; then
        echo "Ensure following images get mirrored to your private registry (${PRIVATE_REGISTRY_PREFIX}):"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/${DEFAULT_PROMETURBO_IMG_REPO}:${PROMETURBO_VERSION}"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/${DEFAULT_TURBODIF_IMG_REPO}:${PROMETURBO_VERSION}"
        echo "Please press [Enter] to proceed: " && read -r _
    fi

    imagePullSecret=""
    if [ -n "${PRIVATE_REGISTRY_SECRET_NAME}" ]; then
        imagePullSecret="imagePullSecret: ${PRIVATE_REGISTRY_SECRET_NAME}"
    fi

    # Get user's consent to overwrite the current Prometurbo CR in the target namespace
    is_cr_exists=$(run_kubectl -n "${OPERATOR_NS}" get Prometurbo "${PROMETURBO_NAME}" -o name --ignore-not-found)
    if [ -n "${is_cr_exists}" ] && [ "${action}" != "delete" ]; then
        echo "Warning: Prometurbo CR (${PROMETURBO_NAME}) detected in the namespace(${OPERATOR_NS})!"
        echo "Please confirm to overwrite the current Prometurbo CR [Y/n]: " && read -r overwriteCR
        [ "${overwriteCR}" = "n" ] || [ "${overwriteCR}" = "N" ] && echo "Installation aborted..." && exit 1
    fi

    cat <<-EOF | run_kubectl "${action}" -f - ${config}
	---
	kind: Prometurbo
	apiVersion: charts.helm.k8s.io/v1
	metadata:
	  name: "${PROMETURBO_NAME}"
	  namespace: "${OPERATOR_NS}"
	spec:
	  serverMeta:
	    turboServer: "${TARGET_HOST}"
	    version: "${PROMETURBO_VERSION}"
	    proxy: "${PROXY_SERVER}"
	  image:
	    prometurboRepository: "${PRIVATE_REGISTRY_PREFIX}/${DEFAULT_PROMETURBO_IMG_REPO}"
	    prometurboTag: "${PROMETURBO_VERSION}"
	    turbodifRepository: "${PRIVATE_REGISTRY_PREFIX}/${DEFAULT_TURBODIF_IMG_REPO}"
	    turbodifTag: "${PROMETURBO_VERSION}"
	    ${imagePullSecret}
	  roleName: "${PROMETURBO_ROLE}"
	  targetName: "${TARGET_NAME}"
	  targetAddress: "${TARGET_ADDRESS}"
	---
	EOF
    wait_for_deployment "${OPERATOR_NS}" "${PROMETURBO_NAME}"
}

# Function to setup the Prometheus Metrics Collection Configs
apply_prometheus_metrics_collection_configs() {
    echo "Applying Prometheus metrics collection configs ..."

    # Valid if Prometheus is accessible and validate queries
    validate_prometheus_inputs

    # Create or update the secret for Prometheus server access token
    createORupdate_promethues_secret "${ACTION}"

    # Apply the PrometheusServerConfig CR to reference the server config
    createORupdate_psc_cr "${ACTION}"

    # Apply the PrometheusQueryMapping CR which defines how to map the metrics from Prometheus to Turbonomic
    createORupdate_pqm_cr "${ACTION}"
}

validate_prometheus_inputs() {
    if [ "${action}" = "delete" ]; then
        return
    fi

    # Get Prometheus token
    fetch_prometheus_token
    verify_prometheus_connection "${PROMETHEUS_SERVER_URL}" "${PROMETHEUS_ACCESS_TOKEN}"
    verify_promql_in_pqm "${PROMETHEUS_SERVER_URL}" "${PROMETHEUS_ACCESS_TOKEN}"
}

# Get Prometheus token
fetch_prometheus_token() {
    if [ "${PROMETHEUS_SERVER_CONNECTION_APPROACH}" = "${SERVICEACCOUNT_APPROACH}" ]; then
        if ! run_kubectl get ns "${PROMETHEUS_SERVERACCOUNT_NS}" > /dev/null 2>&1; then
            echo "ERROR: The specified Prometheus namespace '${PROMETHEUS_SERVERACCOUNT_NS}' does not exist. Please provide a valid namespace and re-run the installation script." >&2
            exit 1
        elif ! run_kubectl get sa "${PROMETHEUS_SERVERACCOUNT_NAME}" -n "${PROMETHEUS_SERVERACCOUNT_NS}" > /dev/null 2>&1; then
            echo "ERROR: The specified Prometheus service account '${PROMETHEUS_SERVERACCOUNT_NAME}' was not found in namespace '${PROMETHEUS_SERVERACCOUNT_NS}'. Verify that the service account name is correct and try again." >&2
            exit 1
        fi
        PROMETHEUS_ACCESS_TOKEN=$(run_kubectl -n "${PROMETHEUS_SERVERACCOUNT_NS}" create token "${PROMETHEUS_SERVERACCOUNT_NAME}" --duration=87600h)
    elif [ "${PROMETHEUS_SERVER_CONNECTION_APPROACH}" = "${MANUALTOKEN_APPROACH}" ]; then
        echo "ERROR: No Prometheus access token was provided. Please supply a valid token or using other approaches for Prometheus authorization." >&2
        exit 1
    elif [ "${PROMETHEUS_SERVER_CONNECTION_APPROACH}" = "${CUSTOMSECRET_APPROACH}" ]; then
        # Check if the secret exists
        if ! run_kubectl get secret "${PROMETHEUS_SERVER_SECRET_NAME}" -n "${OPERATOR_NS}" > /dev/null 2>&1; then
            echo "ERROR: The specified custom Prometheus secret '${PROMETHEUS_SERVER_SECRET_NAME}' does not exist in namespace '${OPERATOR_NS}'. Please create the secret before re-running the installation script." >&2
            exit 1
        fi
        PROMETHEUS_ACCESS_TOKEN=$(run_kubectl get secret "${PROMETHEUS_SERVER_SECRET_NAME}" -n "${OPERATOR_NS}" -o jsonpath='{.data.authorizationToken}' | base64 -d)
        if [ -z "${PROMETHEUS_ACCESS_TOKEN}" ]; then
            echo "ERROR: The custom Prometheus secret '${PROMETHEUS_SERVER_SECRET_NAME}' in namespace '${OPERATOR_NS}' does not contain a valid 'authorizationToken' field. Please ensure the secret is correctly formatted and includes the required token." >&2
            exit 1
        fi
    fi
}

# Check if URL is in Kubernetes service format
is_cluster_service() {
    prom_url="$1"

    # Return success if URL has already been classified as a cluster service
    if [ -n "${INTERNAL_URL_MAPPING_SOURCE}" ]; then
        return 0
    fi

    # Check if URL is in Kubernetes service format
    if echo "${prom_url}" | grep -qE '^[a-z0-9-]+/[a-z0-9-]+(:[0-9]+)?$'; then
        # Custom namespace/service format
        # Format 1: namespace/service:port (e.g., monitoring/prometheus-k8s:9090)
        INTERNAL_URL_MAPPING_SOURCE="SERVICE"
        return 0
    elif echo "${prom_url}" | grep -qE '\.(svc|svc\.cluster\.local)(:[0-9]+)?(/|$)'; then
        # Standard Kubernetes service DNS format
        # Format 2: service.namespace.svc:port (e.g., prometheus-k8s.monitoring.svc:9090)
        # Format 3: service.namespace.svc.cluster.local:port
        INTERNAL_URL_MAPPING_SOURCE="SERVICE_DNS"
        return 0
    fi

    # Format 4: ip:port (e.g., 10.10.10.10:9090) as internally accessible
    host_ip=$(echo "${prom_url}" | sed -E 's|^(https?://)?([^/:]+).*|\2|')
    if [ -n "${host_ip}" ]; then
        if run_kubectl get svc -A -o wide | grep "${host_ip}" > /dev/null 2>&1; then
            INTERNAL_URL_MAPPING_SOURCE="SERVICE_IP"
            return 0
        elif run_kubectl get endpointslice -A -o wide | grep "${host_ip}" > /dev/null 2>&1; then
            INTERNAL_URL_MAPPING_SOURCE="ENDPOINTS_IP"
            return 0
        elif run_kubectl get pods -A -o wide | grep "${host_ip}" > /dev/null 2>&1; then
            INTERNAL_URL_MAPPING_SOURCE="POD_IP"
            return 0
        fi
    fi

    return 1
}

# Parse namespace, service name and port from the Kubernetes service format url
parse_in_cluster_prometheus_services_url() {
    prom_url="$1"
    if ! is_cluster_service "${prom_url}"; then
        return 1
    fi

    if [ "${INTERNAL_URL_MAPPING_SOURCE}" = "SERVICE" ]; then
        echo "Parsing namespace, service name and port from the Kubernetes service format url: ${prom_url}"
        # Format 1: namespace/service:port (e.g., monitoring/prometheus-k8s:9090)
        namespace=$(echo "${prom_url}" | cut -d'/' -f1)
        service=$(echo "${prom_url}" | cut -d'/' -f2 | cut -d':' -f1)
        port=$(echo "${prom_url}" | grep -oE ':[0-9]+$' | tr -d ':')
    elif [ "${INTERNAL_URL_MAPPING_SOURCE}" = "SERVICE_DNS" ]; then
        echo "Parsing namespace, service name and port from the Kubernetes service format url: ${prom_url}"
        # Format 2: service.namespace.svc:port (e.g., prometheus-k8s.monitoring.svc:9090)
        # Format 3: service.namespace.svc.cluster.local:port

        # Remove protocol if present
        url_no_proto="${prom_url#http://}"
        url_no_proto="${url_no_proto#https://}"

        # Extract hostname (before any / or ?)
        hostname=$(echo "${url_no_proto}" | cut -d'/' -f1 | cut -d'?' -f1)

        # Extract service name (first part before first dot)
        service=$(echo "${hostname}" | cut -d'.' -f1)

        # Extract namespace (second part)
        namespace=$(echo "${hostname}" | cut -d'.' -f2)

        # Extract port if present in hostname
        if echo "${hostname}" | grep -q ':'; then
            port=$(echo "${hostname}" | grep -oE ':[0-9]+' | tr -d ':')
            # Remove port from service name if it was included
            service=$(echo "${service}" | cut -d':' -f1)
        fi
    elif [ "${INTERNAL_URL_MAPPING_SOURCE}" = "SERVICE_IP" ]; then
        # There must be a fetch since we check that the service IP is in the list
        host_ip=$(echo "${prom_url}" | sed -E 's|^(https?://)?([^/:]+).*|\2|')

        echo "Fetching namespace, service name and port from the Kubernetes service ip: ${host_ip}"
        match=$(run_kubectl get svc -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{" "}{.spec.clusterIP}{"\n"}{end}' | grep "${host_ip}" | head -n1)

        namespace=$(echo "${match}" | awk '{print $1}')
        service=$(echo "${match}" | awk '{print $2}')
        port=$(echo "${prom_url}" | grep -oE ':[0-9]+$' | tr -d ':')
    elif [ "${INTERNAL_URL_MAPPING_SOURCE}" = "ENDPOINTS_IP" ]; then
        # There must be a fetch since we check that the endpoint IP is in the list
        host_ip=$(echo "${prom_url}" | sed -E 's|^(https?://)?([^/:]+).*|\2|')

        echo "Fetching namespace, service name and port from the Kubernetes EndpointSlice ip: ${host_ip}"
        match=$(run_kubectl get endpointslice -A -o wide | grep "${host_ip}" | head -n1)

        namespace=$(echo "${match}" | awk '{print $1}')
        endpointslice_name=$(echo "${match}" | awk '{print $2}')

        # Use the endpointslice name to get the upstream service name
        service=$(run_kubectl -n "${namespace}" get endpointslice "${endpointslice_name}" -o=jsonpath='{.metadata.labels.kubernetes\.io/service-name}')
        port=$(echo "${prom_url}" | grep -oE ':[0-9]+$' | tr -d ':')
    elif [ "${INTERNAL_URL_MAPPING_SOURCE}" = "POD_IP" ]; then
        # There must be a fetch since we check that the pod IP is in the list
        host_ip=$(echo "${prom_url}" | sed -E 's|^(https?://)?([^/:]+).*|\2|')

        echo "Fetching namespace, pod name and port from the Kubernetes Pod ip: ${host_ip}"
        match=$(run_kubectl get pod -A -o wide | grep "${host_ip}" | head -n1)

        namespace=$(echo "${match}" | awk '{print $1}')
        service=$(echo "${match}" | awk '{print $2}')
        port=$(echo "${prom_url}" | grep -oE ':[0-9]+$' | tr -d ':')
    fi

    # Set default port if not specified
    if [ -z "${port}" ]; then
        if echo "${prom_url}" | grep -q "^https://"; then
            port="443"
        else
            port="9090"  # Default Prometheus port
        fi
    fi

    # Fail if the root service cannot be found
    if [ -z "${service}" ]; then
        echo "ERROR: Unable to extract service/pod name from URL: ${prom_url}" >&2
        exit 1
    fi

    PROMETHEUS_NS="${namespace}"
    PROMETHEUS_PORT="${port}"
    PROMETHEUS_SERVICES_NAME="${service}"
}

# Port-forward the Prometheus service if not open
port_forward_prometheus_svc() {
    service_namespace="$1"
    service_name="$2"
    target_port="$3"

    # Prometheus port-forward already open
    if [ -n "${PORT_FORWARD_PID}" ]; then
        return
    fi

    target_name="service/${service_name}"
    if [ "${INTERNAL_URL_MAPPING_SOURCE}" = "POD_IP" ]; then
        target_name="pod/${service_name}"
    fi

    # Valid if parsed service exists
    if ! run_kubectl get ns "${service_namespace}" > /dev/null 2>&1; then
        echo "ERROR: The namespace '${service_namespace}' extracted from the provided cluster URL does not exist. Please verify the URL format and ensure the namespace is valid before re-running the script." >&2
        exit 1
    elif ! run_kubectl get "${target_name}" -n "${service_namespace}" > /dev/null 2>&1; then
        echo "ERROR: The '${target_name}' extracted from the provided cluster URL does not exist in namespace '${service_namespace}'. Please confirm that the target and namespace in the URL are correct and try again." >&2
        exit 1
    fi

    # Valid if parsed port exists on the service type
    if [ "${INTERNAL_URL_MAPPING_SOURCE}" != "POD_IP" ]; then
        if ! run_kubectl -n "${service_namespace}" get "${target_name}" \
            -o jsonpath='{.spec.ports[?(@.port=='"${target_port}"')].port}' \
            | grep "${target_port}"  > /dev/null 2>&1; then
            echo "ERROR: The port '${target_port}' extracted from the provided cluster URL is not defined in the '${target_name}' within namespace '${service_namespace}'. Please verify that the URL includes a valid service port and ensure the service is configured with this port before re-running the script." >&2
            exit 1
        fi
    fi

    # Port-forward the Prometheus service
    tmpfile=$(mktemp)
    run_kubectl port-forward -n "${service_namespace}" "${target_name}" :"${target_port}" >"${tmpfile}" 2>&1 &

    # Wait for port-forward to be ready (max 5 seconds)
    i=1
    while [ "$i" -le 10 ]; do
        if grep -q "Forwarding from" "${tmpfile}" 2>/dev/null; then
            break
        fi
        sleep 0.5
        i=$((i + 1))
    done

    PORT_FORWARD_PID=$(pgrep -f "port-forward -n ${service_namespace} ${target_name} :${target_port}" | head -n1)
    PORT_FORWARD_PORT=$(sed -n 's/.*127\.0\.0\.1:\([0-9]*\).*/\1/p' "$tmpfile")
    rm "${tmpfile}"

    # Validate the port-forward port
    if [ -z "${PORT_FORWARD_PORT}" ]; then
        echo "ERROR: Failed to extract port-forward port from running process" >&2
        kill_prometheus_svc_process
        exit 1
    fi

    echo "Prometheus port-forward process pid: ${PORT_FORWARD_PID}"
    echo "Prometheus port-forward port: ${PORT_FORWARD_PORT}"
}

# Kill port-forward process if it is running
kill_prometheus_svc_process() {
    # Stop skill port-forward if it is not running
    if [ -z "${PORT_FORWARD_PID}" ]; then
        return
    fi

    echo "Killing Prometheus server port-forward process: ${PORT_FORWARD_PID}..."
    kill "${PORT_FORWARD_PID}" 2>/dev/null
    wait "${PORT_FORWARD_PID}" 2>/dev/null
    unset PORT_FORWARD_PID
}

# Check if should skip Prometheus connection check
should_skip_prometheus_check() {
    prom_url="$1"
    prom_token="$2"
    if [ -z "${prom_url}" ] || [ -z "${prom_token}" ]; then
        echo "ERROR: No cluster URL was provided and a Prometheus access token could not be retrieved from any available method. Please supply a valid cluster URL or provide a Prometheus access token before running the script." >&2
        exit 1
    fi
}

# Verify Prometheus token is valid and test the provided Promql query
verify_prometheus_query_and_connection() {
    prom_url="$1"
    prom_token="$2"
    query="$3"

    should_skip_prometheus_check "${prom_url}" "${prom_token}"

    # Verify Prometheus query is provided
    response_body=$(mktemp)
    if [ -z "${query}" ]; then
        http_status=$(curl -sS -k "${prom_url}/api/v1/status/runtimeinfo" \
            --header "Authorization: Bearer ${prom_token}" \
            -o "${response_body}" \
            -w "%{http_code}" \
            --connect-timeout 5 --max-time 10)
    else
        http_status=$(curl -sS -k "${prom_url}/api/v1/query" \
            --header "Authorization: Bearer ${prom_token}" \
            -G --data-urlencode "query=${query}" \
            -o "${response_body}" \
            -w "%{http_code}" \
            --connect-timeout 5 --max-time 10)
    fi

    # Extract Prometheus response status and errors
    rc=$?
    body=$(cat "${response_body}")
    error_type=$(printf "%s" "$body" | sed -n 's/.*"errorType":"\([^"]*\)".*/\1/p')
    error_msg=$(printf "%s" "$body" | sed -n 's/.*"error":"\([^"]*\)".*/\1/p')
    rm -f "${response_body}"

    # Verify Prometheus request succeed or not
    if [ ${rc} -ne 0 ]; then
        echo "ERROR: Failed to connect to the Prometheus endpoint due to a network or connection error." >&2
        return 1
    elif [ "${http_status}" = "000" ]; then
        echo "The Prometheus server returned no data. Please verify that the server is reachable and responding correctly." >&2
        return 1
    elif [ "${http_status}" = "401" ]; then
        echo "ERROR(${http_status}): Unauthorized access to the Prometheus server as the access token is invalid or expired. The access token obtained from the user-provided input or custom secret is invalid or does not grant sufficient permissions." >&2
        return 1
    elif [ "${http_status}" != "200" ]; then
        echo "WARNING: The Prometheus request failed."
        echo "  Status Code: ${http_status}"
        echo "  Error type: ${error_type}"
        echo "  Message: ${error_msg:-"${body}"}"
        if [ -n "${query}" ]; then
            echo "  PromQL query: ${query}"
        fi
        echo ""
        return 1
    fi

    return 0
}

# Function to get context-aware authentication error messages based on connection approach
get_prometheus_auth_error_message() {
    message_type="$1"
    auth_cause=""
    auth_next_step=""
    
    case "${PROMETHEUS_SERVER_CONNECTION_APPROACH}" in
        "${TOKEN_APPROACH}"|"${MANUALTOKEN_APPROACH}")
            auth_cause="The provided access token is invalid, expired, or lacks permissions to access Prometheus."
            auth_next_step="Verify the token was copied correctly and has proper permissions."
            ;;
        "${SERVICEACCOUNT_APPROACH}")
            auth_cause="The service account lacks sufficient RBAC permissions to access Prometheus."
            auth_next_step="Verify the service account configuration and RBAC permissions."
            ;;
        "${CUSTOMSECRET_APPROACH}")
            auth_cause="The token in the custom secret is invalid, expired, or lacks permissions to access Prometheus."
            auth_next_step="Verify the token value in the secret and its permissions."
            ;;
        *)
            # Fallback for undefined or empty approach
            auth_cause="The provided access token is invalid, expired, or lacks permissions to access Prometheus."
            auth_next_step="Verify the token was copied correctly and has proper permissions."
            ;;
    esac
    
    if [ "${message_type}" = "cause" ]; then
        printf "%s\n" "${auth_cause}"
    elif [ "${message_type}" = "next_step" ]; then
        printf "%s\n" "${auth_next_step}"
    fi
}

# Test Prometheus server connection
verify_prometheus_connection() {
    url="$1"
    token="$2"

    should_skip_prometheus_check "${url}" "${token}"

    echo "Verifying Prometheus server connection to ${url}..."
    if is_cluster_service "${url}"; then
        # Parse cluster service URL to extract namespace, service, and port
        parse_in_cluster_prometheus_services_url "${url}"

        # Open port-forward to Prometheus service and handle the port-forward process after execution
        if port_forward_prometheus_svc "${PROMETHEUS_NS}" "${PROMETHEUS_SERVICES_NAME}" "${PROMETHEUS_PORT}"; then
            # Set the port-forward URL
            PORT_FORWARD_URL="http://localhost:${PORT_FORWARD_PORT}"
            if echo "${url}" | grep -E "^https://" > /dev/null 2>&1; then
                PORT_FORWARD_URL="https://localhost:${PORT_FORWARD_PORT}"
            fi
            trap 'kill_prometheus_svc_process '"${PORT_FORWARD_PID}"'' EXIT
        fi
    else
        echo "Prometheus server URL is in public URL format, verifying connection using curl directly..."
    fi

    # Verify Prometheus server connection using curl
    if verify_prometheus_query_and_connection "${PORT_FORWARD_URL:-${url}}" "${token}"; then
        echo "SUCCESS: Successfully connected to the Prometheus server at '${url}'."
    else
        echo "Unable to reach the Prometheus server at '${url}'."
        echo ""
        echo "Possible Causes:"
        echo "  - The provided URL is incorrect."
        echo "  - The Prometheus service is not running or not reachable."
        echo "  - A network or curl-related issue occurred (see details above)."
        echo "  - $(get_prometheus_auth_error_message 'cause')"
        echo ""
        echo "Next Steps:"
        echo "  - Verify that the URL is correct and reachable."
        echo "  - Confirm that the Prometheus service is running and accessible."
        echo "  - Check the error details above for curl or network-related issues."
        echo "  - $(get_prometheus_auth_error_message 'next_step')"
        echo "  - Review the IBM documentation https://www.ibm.com/docs/en/tarm/latest?topic=prometheus-enabling-metrics-collection-prometurbo for additional guidance."
        echo ""
        exit 1
    fi
}

# Function to verify if the Promql defined in PQM object is valid or not
verify_promql_in_pqm() {
    prom_url="$1"
    prom_token="$2"

    should_skip_prometheus_check "${prom_url}" "${prom_token}"

    if [ -z "${PROMETHEUS_QUERY_MAPPING_CR}" ]; then
        echo "WARNING: PQM CR is not provided. Skip PromQL queries verifications."
        return 1
    fi

    # Verify PQM CR Promql queries
    echo "Verifying PQM CR Promql queries..."
    tmpfile=$(mktemp)
    printf "%s" "${PROMETHEUS_QUERY_MAPPING_CR}" | run_kubectl apply -f - --dry-run=client -ojsonpath='{range .spec.entities[*]}{range .metrics[*]}{range .queries[*]}{.promql}{"\n"}{end}{end}{end}' > "${tmpfile}"

    error_count=0
    while IFS= read -r query; do
        if [ -z "${query}" ]; then
            continue
        elif ! verify_prometheus_query_and_connection "${PORT_FORWARD_URL:-${prom_url}}" "${prom_token}" "${query}"; then
            error_count=$((error_count + 1))
        fi
    done < "${tmpfile}"
    rm -rf "${tmpfile}"

    if [ "${error_count}" -gt 0 ]; then
        echo "ACTION REQUIRED: One or more PromQL queries are invalid or failed during validation."
        echo ""
        echo "Please return to the UI page, update your PromQL queries, regenerate the installation script,"
        echo "and re-run the script to continue the setup process."
        echo ""
        exit 1
    fi
}

# Function to create or update the PrometheusServerConfig CR
createORupdate_psc_cr() {
    action="${ACTION}"
    if [ "${action}" = "delete" ]; then
        echo "${ACTION} PrometheusServerConfig CR ..."
        if ! run_kubectl api-resources | grep -qE "PrometheusServerConfig"; then
            # Skip deletion if the CRD is not found
            echo "There is not PrometheusServerConfig object to delete"
        else
            run_kubectl delete PrometheusServerConfig "${PSC_NAME}" --namespace="${OPERATOR_NS}" --ignore-not-found
        fi
        return
    fi

    echo "${ACTION} PrometheusServerConfig CR ..."

    # Fetch identifier ID from the default kubernetes service
    identifier_ID="$(run_kubectl -n default get svc kubernetes -o jsonpath='{.metadata.uid}')"

    if [ -z "${identifier_ID}" ]; then
        echo "Error: Unable to fetch uid from the default kubernetes service" && exit 1
    fi

    cat <<-EOF | run_kubectl "${action}" -f - ${config}
	---
	apiVersion: metrics.turbonomic.io/v1alpha1
	kind: PrometheusServerConfig
	metadata:
	  name: "${PSC_NAME}"
	  namespace: "${OPERATOR_NS}"
	spec:
	  address: "${PROMETHEUS_SERVER_URL}"
	  bearerToken:
	    secretKeyRef:
	      key: authorizationToken
	      name: "${PROMETHEUS_SERVER_SECRET_NAME}"
	  clusters:
	  - identifier:
	      id: "${identifier_ID}"
	---
	EOF
}

# Function to create or update the secret for Prometheus server access token which is referenced by the PrometheusServerConfig CR
createORupdate_promethues_secret() {
    action="${ACTION}"
    if [ "${action}" = "delete" ]; then
        # Only delete the default secret created by the script to avoid accidental deletion.
        if [ "${PROMETHEUS_SERVER_SECRET_NAME}" = "${DEFAULT_PROMETHEUS_SERVER_SECRET_NAME}" ]; then
            echo "Delete Prometheus server secret ${PROMETHEUS_SERVER_SECRET_NAME} ..."
            run_kubectl delete secret "${PROMETHEUS_SERVER_SECRET_NAME}" --namespace="${OPERATOR_NS}" --ignore-not-found
        fi
        return
    fi

    if [ -z "${PROMETHEUS_ACCESS_TOKEN}" ]; then
        echo "No Prometheus access token provided, skipping the creation of Prometheus server secret"
        return
    fi

    # Create or update the secret with the provided Prometheus access token
    run_kubectl create secret generic "${PROMETHEUS_SERVER_SECRET_NAME}" \
        --from-literal=authorizationToken="${PROMETHEUS_ACCESS_TOKEN}" \
        --namespace="${OPERATOR_NS}" \
        --dry-run="client" -o yaml | run_kubectl "${action}" -f -
}

# Function to create or update the PrometheusQueryMapping CR
createORupdate_pqm_cr() {
    if [ -z "${PROMETHEUS_QUERY_MAPPING_CR}" ]; then
        echo "No PrometheusQueryMapping CR provided, skipping the creation of PrometheusQueryMapping CR"
        return
    fi

    action="${ACTION}"
    unset config
    if [ "${action}" = "delete" ]; then
        config="--ignore-not-found"
    fi

    echo "${ACTION} PrometheusQueryMapping CR ..."
    if [ "${action}" = "delete" ]; then
        # Skip deletion if the CRD is not found
        if ! run_kubectl api-resources | grep -qE "PrometheusQueryMapping"; then
            echo "There is not PrometheusQueryMapping object to delete"
            return
        fi
    fi

    # Create or update the PrometheusQueryMapping CR
    printf "%s" "${PROMETHEUS_QUERY_MAPPING_CR}" | run_kubectl "${action}" -f - ${config} -n "${OPERATOR_NS}"
}

# Function to create or update the prometurbo operator in the namespace
createORupdate_prometurbo_operator() {
    if [ "${TARGET_SUBTYPE}" = "${OCP_TYPE}" ]; then
        createORupdate_prometurbo_subscription
    else
        createORupdate_prometurbo_operator_via_yaml
    fi
}

# Function to create or update the prometurbo subscription
createORupdate_prometurbo_subscription() {
    if ! handle_private_registry_fallback; then
        createORupdate_prometurbo_operator_via_yaml
        return
    fi

    # To ensure the operator is installed
    createORupdate_operatorgroup "${OPERATOR_NS}"

    select_cert_op_from_operatorhub "prometurbo"
    CERT_PROMETURBO_OP_NAME="${CERT_OP_NAME}"

    select_cert_op_channel_from_operatorhub "${CERT_PROMETURBO_OP_NAME}" "${PT_TARGET_RELEASE}"
    CERT_PROMETURBO_OP_RELEASE="${CERT_OP_RELEASE}"
    CERT_PROMETURBO_OP_VERSION="${CERT_OP_VERSION}"

    action="${ACTION}"
    unset config
    if [ "${action}" = "delete" ]; then
        config="--ignore-not-found"
    fi

    echo "${ACTION} Certified Prometurbo operator subscription ..."
    if [ "${ACTION}" = "delete" ]; then
        run_kubectl -n "${OPERATOR_NS}" "${action}" Subscription "${CERT_PROMETURBO_OP_NAME}" ${config}
        run_kubectl -n "${OPERATOR_NS}" "${action}" csv "${CERT_PROMETURBO_OP_VERSION}" ${config}
        return
    fi
    cat <<-EOF | run_kubectl "${action}" -f - ${config}
	---
	apiVersion: operators.coreos.com/v1alpha1
	kind: Subscription
	metadata:
	  name: "${CERT_PROMETURBO_OP_NAME}"
	  namespace: "${OPERATOR_NS}"
	spec:
	  channel: "${CERT_PROMETURBO_OP_RELEASE}"
	  installPlanApproval: "Automatic"
	  name: "${CERT_PROMETURBO_OP_NAME}"
	  source: "${CATALOG_SOURCE}"
	  sourceNamespace: "${CATALOG_SOURCE_NS}"
	  startingCSV: "${CERT_PROMETURBO_OP_VERSION}"
	---
	EOF
    wait_for_deployment "${OPERATOR_NS}" "prometurbo-operator"
}

# Function to fallback OCP installation with private image repo to yaml installation
handle_private_registry_fallback() {
    if [ "${PRIVATE_REGISTRY_ENABLED}" != "true" ]; then
        return 0
    fi

    if [ -n "${ACCEPT_FALLBACK}" ]; then
        return "${ACCEPT_FALLBACK}"
    fi

    echo "OpenShift clusters do not natively support installing OperatorHub operators with private registries."
    echo "Would you like to proceed with the YAML approach (manual, no auto-updates)? [Y/n]: " && read -r choice

    ACCEPT_FALLBACK=0
    if [ "${choice}" = "n" ] || [ "${choice}" = "N" ]; then
        echo "Please proceed to mirror the OCP catalog for OperatorHub: https://www.ibm.com/docs/en/tarm/8.16.x?topic=requirements-prometurbo-image-repository"
        echo "Press [Enter] to continue: " && read -r _
    else
        echo "Using YAML approach with private registry."
        ACCEPT_FALLBACK=1
    fi
    return "${ACCEPT_FALLBACK}"
}

# Function to install Prometurbo operator via yaml bundle
createORupdate_prometurbo_operator_via_yaml() {
    operator_deploy_name="prometurbo-operator"
    operator_service_account="prometurbo-operator"
    source_github_repo="https://raw.githubusercontent.com/IBM/turbonomic-container-platform"
    prometurbo_operator_release=$(match_github_release "IBM/turbonomic-container-platform" "${PROMETURBO_VERSION}")

    operator_crd_path="prometurbo/operator/charts.helm.k8s.io_prometurbos_crd.yaml"
    operator_yaml_path="prometurbo/operator/prometurbo_operator_full.yaml"
    pqm_crd_path="turbo-metrics/crd/metrics.turbonomic.io_prometheusquerymappings.yaml"
    psc_crd_path="turbo-metrics/crd/metrics.turbonomic.io_prometheusserverconfigs.yaml"

    operator_crd=$(curl "${source_github_repo}/${prometurbo_operator_release}/${operator_crd_path}" )
    # The default namespace in previous bundle yaml was turbo but got replace to turbonomic recently, we need to support both in case user specified an older version for installation
    operator_full=$(curl "${source_github_repo}/${prometurbo_operator_release}/${operator_yaml_path}" | sed "s/: turbo$/: ${OPERATOR_NS}/g" | sed "s/: turbonomic$/: ${OPERATOR_NS}/g" | sed '/^\s*#/d')
    pqm_crd=$(curl "${source_github_repo}/${prometurbo_operator_release}/${pqm_crd_path}" )
    psc_crd=$(curl "${source_github_repo}/${prometurbo_operator_release}/${psc_crd_path}" )

    operator_yaml_bundle=$(cat <<-EOF | run_kubectl create -f - -n "${OPERATOR_NS}" --dry-run=client -o yaml
	${operator_crd}
	---
	${pqm_crd}
	---
	${psc_crd}
	---
	${operator_full}
	EOF
    )

     # Only apply operator version once user specified
    if [ -n "${PROMETURBO_OP_VERSION}" ]; then
        echo "Using the customized image tag for operator: ${PROMETURBO_OP_VERSION}"
        current_image=$(echo "${operator_yaml_bundle}" | grep "image: " | awk '{print $2}')
        target_image=$(echo "${operator_yaml_bundle}" | grep "image: " | awk '{print $2}' | sed 's|:.*|:'"${PROMETURBO_OP_VERSION}"'|g')
        operator_yaml_bundle=$(echo "${operator_yaml_bundle}" | sed 's|'"${current_image}"'|'"${target_image}"'|g')
    fi

    # Notify client to mirror which images
    if [ "${PRIVATE_REGISTRY_ENABLED}" = "true" ] && [ "${ACTION}" != "delete" ]; then
        echo "Ensure following image gets mirrored to your private registry (${PRIVATE_REGISTRY_PREFIX}):"
        echo "- $(echo "${operator_yaml_bundle}" | grep "image: " | awk '{print $2}')"
        echo "Please press [Enter] to proceed: " && read -r _

        # Swap to use private registry if necessary
        operator_yaml_bundle=$(echo "${operator_yaml_bundle}" | sed 's|image: '"${DEFAULT_REGISTRY_PREFIX}"'|image: '"${PRIVATE_REGISTRY_PREFIX}"'|g')
    fi

    apply_operator_bundle "${operator_service_account}" "${operator_deploy_name}" "${operator_yaml_bundle}"
}

# Function to fetch target version wrt the released branch, if not fetched will return the default branch
match_github_release() {
    owner_repo=$1
    target_version=$2

    # if a version is specified then try to fetch the version from the release tags
    fetched_version=""
    if [ -n "${target_version}" ]; then
        released_versions=$(curl -s "https://api.github.com/repos/${owner_repo}/tags" | grep '"name":' | cut -d '"' -f 4)
        for rv in ${released_versions}; do
            if [ "${target_version}" = "${rv}" ]; then
                fetched_version="${rv}"
                break
            fi
        done
    fi

    # if the target version is not matching with any existed release tag then use the default branch for instead
    if [ -z "${fetched_version}" ]; then
        echo "Warning: Unable to fetch '${target_version}' from released versions, using the latest default branch for instead" >&2
        fetched_version=$(curl -s "https://api.github.com/repos/${owner_repo}" | grep '"default_branch":' | cut -d '"' -f 4 | head -n1)
    fi

    echo "${fetched_version}"
}

# Function to apply k8s object in a bundled yaml file
apply_operator_bundle() {
    sa_name="$1"
    deploy_name="$2"
    operator_yaml_str="$3"

    tmp_dir=$(mktemp -d)
    # split out yaml from the yaml bundle
    echo "${operator_yaml_str}" | awk '/^---/{i++} {file = "'"${tmp_dir}"'/yaml_part_" i ".yaml"; print > file}'
    for yaml_part in "${tmp_dir}"/*.yaml; do
        yaml_abs_path="${yaml_part}"
        kind_name_str=$(run_kubectl create -f "${yaml_abs_path}" --dry-run=client -o=jsonpath="{.kind} {.metadata.name}")
        obj_kind=$(echo "${kind_name_str}" | awk '{print $1}')
        obj_name=$(echo "${kind_name_str}" | awk '{print $2}')

        is_object_exists=$(run_kubectl -n "${OPERATOR_NS}" get "${obj_kind}" --field-selector=metadata.name"=${obj_name}" -o name)
        if [ "${ACTION}" = "delete" ]; then
            # delete k8s resources if exists (avoid cluster resources)
            skip_target=$(should_skip_delete_k8s_object "${obj_kind}")
            [ -n "${is_object_exists}" ] && [ "${skip_target}" = "false" ] && run_kubectl "${ACTION}" -f "${yaml_abs_path}"
        elif [ -n "${is_object_exists}" ] && [ "${obj_kind}" = "ClusterRoleBinding" ]; then
            # if cluster role binding exists, patch it with target services account
            isClusterRoleBinded=$(run_kubectl get "${obj_kind}" "${obj_name}" -o=jsonpath='{range .subjects[*]}{.namespace}{"\n"}{end}' | grep -E "^${OPERATOR_NS}$")
            if [ -z "${isClusterRoleBinded}" ]; then
                run_kubectl patch "${obj_kind}" "${obj_name}" --type='json' -p='[{"op": "add", "path": "/subjects/-", "value": {"kind": "ServiceAccount", "name": "'"${sa_name}"'", "namespace": "'"${OPERATOR_NS}"'"}}]'
            else
                echo "Skip patching ${obj_kind} ${obj_name} as the clusterRole has bound to the operator service account already."
            fi
        elif [ -z "${is_object_exists}" ]; then
            # create the k8s object if not exists
            run_kubectl "create" -f "${yaml_abs_path}" --save-config
        else
            # update the k8s object if exists
            run_kubectl apply -f "${yaml_abs_path}"
        fi

        # patch operator services account with private registry pull secret
        if [ "${obj_kind}" = "ServiceAccount" ] && [ -n "${PRIVATE_REGISTRY_SECRET_NAME}" ]; then
            run_kubectl -n "${OPERATOR_NS}" patch "${obj_kind}" "${obj_name}" --type='json' -p='[{"op": "add", "path": "/imagePullSecrets", "value": [{"name": '"${PRIVATE_REGISTRY_SECRET_NAME}"'}]}]'
        fi
    done
    rm -rf "${tmp_dir}"

    # check if the operator is ready
    [ "${ACTION}" != "delete" ] && wait_for_deployment "${OPERATOR_NS}" "${deploy_name}"
}

# Function to avoid deleting cluster level k8s objects
should_skip_delete_k8s_object() {
    k8s_kind=$1
    [ "${k8s_kind}" = "Namespace" ] && echo "true" && return
    for it in ${K8S_CLUSTER_KINDS}; do
        [ "${it}" = "${k8s_kind}" ] && echo "true" && return
    done
    echo "false"
}

# Function to select certified operators from the operatorhub contains the given name
select_cert_op_from_operatorhub() {
    target=$1
    echo "Fetching Openshift certified ${target} operator from OperatorHub ..."
    cert_ops=$(run_kubectl get packagemanifests -o jsonpath="{range .items[*]}{.metadata.name} {.status.catalogSource} {.status.catalogSourceNamespace}{'\n'}{end}" | grep -e "${target}" | grep -e "${CATALOG_SOURCE}.*${CATALOG_SOURCE_NS}" | awk '{print $1}')
    cert_ops_count=$(echo "${cert_ops}" | wc -l | awk '{print $1}')
    if [ -z "${cert_ops}" ] || [ "${cert_ops_count}" -lt 1 ]; then
        echo "There aren't any certified ${target} operator in the Operatorhub, please contact administrator for more information!" && exit 1
    elif [ "${cert_ops_count}" -gt 1 ]; then
        PS3="Fetched multiple certified ${target} operators in the Operatorhub, please select a number to proceed OR type 'exit' to exit: "
        while true; do
            echo "Available options:"
            i=1; echo "${cert_ops}" | while IFS= read -r cert_op; do
                echo "$i) $cert_op"
                i=$((i + 1))
            done
            echo "${PS3}" && read -r REPLY
            if validate_select_input "${cert_ops_count}" "${REPLY}"; then
                [ "${REPLY}" = 'exit' ] && exit 0
                cert_ops=$(echo "$cert_ops" | awk "NR==$((REPLY))")
                break
            fi
        done
    fi
    CERT_OP_NAME=${cert_ops}
    echo "Using Openshift certified ${target} operator: ${CERT_OP_NAME}"
}

# Function to select channel from a certified operator
select_cert_op_channel_from_operatorhub() {
    cert_op_name=${1-${CERT_OP_NAME}}
    target_release=${2-${DEFAULT_RELEASE}}
    echo "Fetching Openshift ${cert_op_name} channels from OperatorHub ..."
    channels=$(run_kubectl get packagemanifests "${cert_op_name}" -o jsonpath="{range .status.channels[*]}{.name}:{.currentCSV}{'\n'}{end}" | grep "${target_release}")
    channel_count=$(echo "${channels}" | wc -l | awk '{print $1}')
    if [ -z "${channels}" ] || [ "${channel_count}" -lt 1 ]; then
        echo "There aren't any channel created for ${cert_op_name}, please contact administrator for more information!" && exit 1
    elif [ "${channel_count}" -gt 1 ]; then
        PS3="Fetched multiple releases, please select a number to proceed OR type 'exit' to exit: "
        while true; do
            echo "Available options:"
            i=1; echo "${channels}" | while IFS= read -r channel; do
                echo "$i) $channel"
                i=$((i + 1))
            done
            echo "${PS3}" && read -r REPLY
            if validate_select_input "${channel_count}" "${REPLY}"; then
                [ "${REPLY}" = 'exit' ] && exit 0
                channels=$(echo "$channels" | awk "NR==$((REPLY))")
                break
            fi
        done
    fi
    CERT_OP_RELEASE=$(echo "${channels}" | awk -F':' '{print $1}')
    CERT_OP_VERSION=$(echo "${channels}" | awk -F':' '{print $2}')
    echo "Using Openshift certified ${cert_op_name} ${CERT_OP_RELEASE} channel, version ${CERT_OP_VERSION}"
}

# Function to examine if a given number input is within the range
validate_select_input() {
    opts_count=$1 && opt=$2
    if [ "${opt}" = "exit" ]; then
        echo "Exiting the program ..." >&2 && exit 0
    elif ! echo "${opt}" | grep -qE '^[1-9][0-9]*$'; then
        echo "ERROR: Input not a number: ${opt}" >&2 && exit 1
    elif [ "${opt}" -le 0 ] || [ "${opt}" -gt "${opts_count}" ]; then
        echo "ERROR: Input out of range [1 - ${opts_count}]: ${opt}" >&2 && exit 1
    fi
}

# Function to wait for the deployment to become ready
wait_for_deployment() {
    if [ "${ACTION}" = "delete" ]; then return; fi

    deploy_ns=${1:-${TARGET_DEPLOYMENT_NS}}
    deploy=${2:-${TARGET_DEPLOYMENT}}

    echo "Waiting for deployment '${deploy}' to start..."
    retry_count=0
    while true; do
        full_deploy=$(run_kubectl -n "${deploy_ns}" get deploy -o name | grep -E "^deployment.apps/${deploy}$")
        if [ -n "${full_deploy}" ]; then
            deploy_status=$(run_kubectl -n "${deploy_ns}" rollout status "${full_deploy}" --timeout=5s 2>&1 | grep "successfully")
            if [ -n "${deploy_status}" ]; then
                break
            fi
        fi
        retry_count=$((retry_count + 1))
        if message=$(retry "${retry_count}"); then
            echo "${message}"
        else
            echo "Please check following events for more information:"
            run_kubectl -n "${deploy_ns}" get events --sort-by='.lastTimestamp' | grep "${deploy}"
            exit 1
        fi
    done
}

# Function to determine if reaches the timeout limit for retries
retry() {
    attempts=${1:--999}
    if [ "${attempts}" -ge ${MAX_RETRY} ]; then
        echo "ERROR: Resource is not ready in ${MAX_RETRY} attempts." >&2 && exit 1
    else
        attempt_str=$([ "${attempts}" -ge 0 ] && echo " (${attempts}/${MAX_RETRY})")
        echo "Resource is not ready, re-attempt after ${RETRY_INTERVAL}s ...${attempt_str}"
        sleep ${RETRY_INTERVAL}
    fi
}

# Function to encode string into base64 format
encode_inline() {
    input=$1
    case "${OSTYPE}" in
        darwin*)
            echo "${input}" | base64 -b 0
            ;;
        *)
            echo "${input}" | base64 -w 0
            ;;
    esac
}

# Function to install TSC via the TSC operator
setup_tsc () {
    if [ "${ACTION}" = "delete" ]; then
        createORupdate_skupper_tunnel
        createORupdate_tsc_cr
        createORupdate_tsc_operator
    else
        if [ "${ENABLE_TSC}" != "true" ]; then return; fi
        run_kubectl -n "${OPERATOR_NS}" delete secret turbonomic-credentials --ignore-not-found
        createORupdate_tsc_operator
        createORupdate_tsc_cr
        createORupdate_skupper_tunnel
        wait_for_tsc_sync_up
    fi
    echo "Successfully ${ACTION} TSC operator in the ${OPERATOR_NS} namespace!"
    run_kubectl -n "${OPERATOR_NS}" get role,rolebinding,sa,pod,deploy -l 'app.kubernetes.io/created-by in (t8c-client-operator, turbonomic-t8c-client-operator)'
}

# Function to create or update the prometurbo operator in the namespace
createORupdate_tsc_operator() {
    if [ "${TARGET_SUBTYPE}" = "${OCP_TYPE}" ]; then
        createORupdate_tsc_subscription
    else
        createORupdate_tsc_operator_via_yaml
    fi
}

# Function to create or update the tsc subscription
createORupdate_tsc_subscription() {
    if ! handle_private_registry_fallback; then
        createORupdate_tsc_operator_via_yaml
        return
    fi

    select_cert_op_from_operatorhub "t8c-tsc"
    CERT_TSC_OP_NAME="${CERT_OP_NAME}"

    select_cert_op_channel_from_operatorhub "${CERT_TSC_OP_NAME}" "${TSC_TARGET_RELEASE}"
    CERT_TSC_OP_RELEASE="${CERT_OP_RELEASE}"
    CERT_TSC_OP_VERSION="${CERT_OP_VERSION}"

    action="${ACTION}"
    unset config
    if [ "${action}" = "delete" ]; then
        config="--ignore-not-found"
    fi

    echo "${action} Certified t8c-tsc operator subscription ..."
    if [ "${action}" = "delete" ]; then
        run_kubectl -n "${OPERATOR_NS}" "${action}" Subscription "${CERT_TSC_OP_NAME}" ${config}
        run_kubectl -n "${OPERATOR_NS}" "${action}" csv "${CERT_TSC_OP_VERSION}" ${config}
        return
    fi
    cat <<-EOF | run_kubectl "${action}" -f - ${config}
	---
	apiVersion: operators.coreos.com/v1alpha1
	kind: Subscription
	metadata:
	  name: "${CERT_TSC_OP_NAME}"
	  namespace: "${OPERATOR_NS}"
	spec:
	  channel: "${CERT_TSC_OP_RELEASE}"
	  installPlanApproval: Automatic
	  name: "${CERT_TSC_OP_NAME}"
	  source: "${CATALOG_SOURCE}"
	  sourceNamespace: "${CATALOG_SOURCE_NS}"
	  startingCSV: "${CERT_TSC_OP_VERSION}"
	---
	EOF
    wait_for_deployment "${OPERATOR_NS}" "t8c-client-operator-controller-manager"
}

# Function to install TSC operator via yaml bundle (future work)
createORupdate_tsc_operator_via_yaml() {
    operator_deploy_name="t8c-client-operator-controller-manager"
    operator_service_account="t8c-client-operator-controller-manager"

    source_github_repo="https://raw.githubusercontent.com/IBM/t8c-client-operator"
    operator_yaml_path="deploy/operator_bundle.yaml"
    tsc_operator_release=$(match_github_release "IBM/t8c-client-operator" "${PROMETURBO_VERSION}")
    operator_yaml_bundle=$(curl "${source_github_repo}/${tsc_operator_release}/${operator_yaml_path}" | sed "s/: __NAMESPACE__$/: ${OPERATOR_NS}/g" | sed '/^\s*#/d')

    # Notify client to mirror which images
    if [ "${PRIVATE_REGISTRY_ENABLED}" = "true" ] && [ "${ACTION}" != "delete" ]; then
        echo "Ensure following image gets mirrored to your private registry (${PRIVATE_REGISTRY_PREFIX}):"
        echo "- $(echo "${operator_yaml_bundle}" | grep "image: " | awk '{print $2}')"
        echo "Please press [Enter] to proceed: " && read -r _

        # Swap to use private registry if necessary
        operator_yaml_bundle=$(echo "${operator_yaml_bundle}" | sed 's|image: '"${DEFAULT_REGISTRY_PREFIX}"'|image: '"${PRIVATE_REGISTRY_PREFIX}"'|g')
    fi

    apply_operator_bundle "${operator_service_account}" "${operator_deploy_name}" "${operator_yaml_bundle}"
}

# Function to create or update the prometurbo operator in the namespace
createORupdate_tsc_cr() {
    action="${ACTION}"
    unset config
    if [ "${action}" = "delete" ]; then
        config="--ignore-not-found"
    fi

    registry=""
    if [ "${PRIVATE_REGISTRY_ENABLED}" = "true" ]; then
        registry="registry: ${PRIVATE_REGISTRY_PREFIX}"
    fi

    imagePullSecrets=""
    if [ -n "${PRIVATE_REGISTRY_SECRET_NAME}" ]; then
        imagePullSecrets=$(cat <<-EOF
		imagePullSecrets:
	    - name: "${PRIVATE_REGISTRY_SECRET_NAME}"
		EOF
        )
    fi

    echo "${action} TSC CR ..."
    if [ "${action}" = "delete" ]; then
        # skip deletion if the CRD is not found
        if ! run_kubectl api-resources | grep -qE "TurbonomicClient|VersionManager"; then
            return
        fi
    fi

    # Notify client to mirror which images
    if [ "${PRIVATE_REGISTRY_ENABLED}" = "true" ] && [ "${ACTION}" != "delete" ]; then
        echo "Ensure following images get mirrored to your private registry. (${PRIVATE_REGISTRY_PREFIX}):"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/turbonomic/kube-state-metrics:${DEFAULT_KUBESTATE_VERSION}"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/turbonomic/skupper-router:${PROMETURBO_VERSION}"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/turbonomic/skupper-config-sync:${PROMETURBO_VERSION}"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/turbonomic/rsyslog-courier:${PROMETURBO_VERSION}"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/turbonomic/skupper-service-controller:${PROMETURBO_VERSION}"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/turbonomic/skupper-site-controller:${PROMETURBO_VERSION}"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/turbonomic/tsc-site-resources:${PROMETURBO_VERSION}"
        echo "Please press [Enter] to proceed: " && read -r _
    fi

    tsc_client_name="turbonomicclient-release"
    cat <<-EOF | run_kubectl "${action}" -f - ${config}
	---
	kind: TurbonomicClient
	apiVersion: clients.turbonomic.ibm.com/v1alpha1
	metadata:
	  name: "${tsc_client_name}"
	  namespace: "${OPERATOR_NS}"
	spec:
	  kubeStateMetrics:
	    image:
	      tag: ${DEFAULT_KUBESTATE_VERSION}
	  global:
	    version: "${PROMETURBO_VERSION}"
	    ${registry}
	    ${imagePullSecrets}
	---
	apiVersion: clients.turbonomic.ibm.com/v1alpha1
	kind: VersionManager
	metadata:
	  name: versionmanager-release
	  namespace: "${OPERATOR_NS}"
	spec:
	  url: 'http://remote-nginx-tunnel:9080/cluster-manager/clusterConfiguration'
	---
	EOF
    if [ "${ACTION}" != "delete" ]; then
        echo "Waiting for TSC client to be ready ..."
        wait_for_deployment "${OPERATOR_NS}" "tsc-site-resources"
        sleep 20 && run_kubectl wait pod \
            -n "${OPERATOR_NS}" \
            -l "app.kubernetes.io/part-of=${tsc_client_name}" \
            --for=condition=Ready \
            --timeout=60s
    fi
}

# Function to create or update the secret for tsc client to connect to the remote XL instance
createORupdate_skupper_tunnel() {
    action="${ACTION}"
    unset config
    if [ "${ACTION}" = "delete" ]; then
        config="--ignore-not-found"
    fi

    if [ "${action}" = "delete" ]; then
        echo "${action} secrets for TSC connection ..."
        for it in $(run_kubectl get secret -n "${OPERATOR_NS}" -l "skupper.io/type" -o name); do
            run_kubectl "${action}" -n "${OPERATOR_NS}" "${it}" ${config}
        done
        return
    fi

    if [ -z "${TSC_TOKEN}" ]; then
        if [  -f "${TSC_TOKEN_FILE}" ]; then
            TSC_TOKEN=$(getJsonField "$(cat "${TSC_TOKEN_FILE}")" "tokenData")
        else
            echo "Please follow the wiki to get the TSC token file: "
            echo "https://www.ibm.com/docs/en/tarm/latest?topic=client-secure-deployment-red-hat-openshift-operatorhub#SaaS_OpenShift__OVA_connect__title__1"
            echo "Warning: cannot find TSC token file under: ${TSC_TOKEN_FILE}"
            echo "Please enter the absolute path for your TSC token: " && read -r TSC_TOKEN_FILE
        fi
        createORupdate_skupper_tunnel && return
    fi

    skupper_connection_secret=$(echo "${TSC_TOKEN}" | base64 -d)
    echo "${skupper_connection_secret}" | run_kubectl "${action}" -n "${OPERATOR_NS}" -f - ${config}

    echo "Waiting for setting up TSC connection..."
    retry_count=0
    while true; do
        tunnel_svc=$(run_kubectl -n "${OPERATOR_NS}" get service --field-selector=metadata.name=remote-nginx-tunnel -o name)
        if [ -n "${tunnel_svc}" ];then break; fi
        retry_count=$((retry_count + 1))
        if message=$(retry "${retry_count}"); then
            echo "${message}"
        else
            echo "Failed to setup the TSC connection, please request another one from the endpoint or regenerate the script from the UI!"
            exit 1
        fi
    done
    echo "Skupper connection established!"
}

# Function to apply skupper tunnel to the Prometurbo CR and wait for the pod to become ready
wait_for_tsc_sync_up() {
    # Prometurbo is not an available target for TSC operator to auto-patch the server address
    # So, we need to manually patch the tunnel to Prometurbo's CR for now
    run_kubectl -n "${OPERATOR_NS}" patch prometurbo/"${PROMETURBO_NAME}" --type=json -p='[{"op": "replace", "path": "/spec/serverMeta/turboServer", "value": "http://remote-nginx-tunnel:9080/topology-processor"}]'

    # Manually restart the Prometurbo deployment to be compatible with the old prometurbo operator implementation.
    run_kubectl -n "${OPERATOR_NS}" scale deploy/"${PROMETURBO_NAME}" --replicas=0
    wait_for_deployment "${OPERATOR_NS}" "${PROMETURBO_NAME}"
}

################## MAIN ##################
dependencies_check && validate_args "${@}" && confirmations && main
