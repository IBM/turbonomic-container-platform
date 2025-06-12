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

CARALOG_SOURCE="certified-operators"
CARALOG_SOURCE_NS="openshift-marketplace"

TSC_TOKEN_FILE=""
DEFAULT_RELEASE="stable"
DEFAULT_NS="turbo"
DEFAULT_TARGET_NAME="Customer-cluster"
DEFAULT_PROMETHEUS_ADDRESS="http://127.0.0.1:8081/metrics"
DEFAULT_ROLE="cluster-admin"
DEFAULT_ENABLE_TSC="optional"
DEFAULT_PROMETURBO_NAME="prometurbo-release"
DEFAULT_PROMETURBO_VERSION="8.14.3"
DEFAULT_PROMETURBO_REGISTRY="icr.io/cpopen/turbonomic/prometurbo"
DEFAULT_TURBODIF_REGISTRY="icr.io/cpopen/turbonomic/turbodif"
DEFAULT_LOGGING_LEVEL=0

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
PROMETURBO_VERSION=${PROMETURBO_VERSION:-${DEFAULT_PROMETURBO_VERSION}}
PROMETURBO_REGISTRY=${PROMETURBO_REGISTRY:-${DEFAULT_PROMETURBO_REGISTRY}}
TURBODIF_REGISTRY=${TURBODIF_REGISTRY:-${DEFAULT_TURBODIF_REGISTRY}}
TARGET_SUBTYPE=${TARGET_SUBTYPE:-""}

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

    if [ -n "${KUBECONFIG}" ]; then
        KUBECTL="${KUBECTL} --kubeconfig=${KUBECONFIG}"
    fi

    if [ -z "${TARGET_HOST}" ]; then
        echo "ERROR: Missing target host" >&2; usage; exit 1
    fi

    # Prioritize the TSC deployment approach once the value is set
    if [ "${ENABLE_TSC}" = "optional" ]; then
        if [ -n "${TSC_TOKEN}" ] || [ -n "${TSC_TOKEN_FILE}" ]; then ENABLE_TSC="true"; fi
    fi

    # Pre-process the encoded secrets and passwords
    if [ "${PWD_SECRET_ENCODED}" = "true" ]; then
        OAUTH_CLIENT_ID=$(password_secret_handler "${OAUTH_CLIENT_ID}")
        OAUTH_CLIENT_SECRET=$(password_secret_handler "${OAUTH_CLIENT_SECRET}")
    fi

    # If the target subtype is not set, auto-detect the current cluster
    if [ -z "${TARGET_SUBTYPE}" ]; then
        TARGET_SUBTYPE=$(auto_detect_cluster_type)
    fi
}

# Function to detect the cluster type
auto_detect_cluster_type() {
    is_current_oc_cluster=$(${KUBECTL} api-resources --api-group=route.openshift.io -o name)
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
    echo ""
    echo "Please confirm the above settings [Y/n]: " && read -r  continueInstallation
    [ "${continueInstallation}" = "n" ] || [ "${continueInstallation}" = "N" ] && echo "Please retry the script with correct settings!" && exit 1
}

# Function to get client's concent to work with the current cluster
confirm_installation_cluster() {
    echo "Info: Your current Kubernetes context is set to the following:"
    show_current_kube_context
    echo "Please confirm if the script should work in the above cluster [Y/n]: " && read -r continueInstallation
    [ "${continueInstallation}" = "n" ] || [ "${continueInstallation}" = "N" ] && echo "Please double check your current Kubernetes context before the other try!" && exit 1
}

# Function to display the current kubeconfig context in a table format
show_current_kube_context() {
    # Exit if the current context is not set
    if ! current_context=$(${KUBECTL} config current-context); then
        echo "ERROR: Current context is not set in your cluster!"
        exit 1
    fi

    # Get detail from the raw object
    cluster=$(${KUBECTL} config view -o jsonpath='{.contexts[?(@.name == "'"${current_context}"'")].context.cluster}')
    user=$(${KUBECTL} config view -o jsonpath='{.contexts[?(@.name == "'"${current_context}"'")].context.user}')
    namespace=$(${KUBECTL} config view -o jsonpath='{.contexts[?(@.name == "'"${current_context}"'")].context.namespace}')

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
    if ! ${KUBECTL} get nodes > /dev/null 2>&1; then
        echo "ERROR: Context used by the current cluster is not reachable!"
        exit 1
    fi

    # Gather all cluster level resource kinds
    K8S_CLUSTER_KINDS=$(${KUBECTL} api-resources --namespaced=false --no-headers | awk '{print $NF}')
}

# Function to determine whether the current kubectl context is an Openshift cluster
cluster_type_check() {
    current_context=$(${KUBECTL} config current-context)
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
    if ! ${KUBECTL} get ns "${namespace}" -o name > /dev/null 2>&1; then
        echo "Creating ${namespace} namespace..."
        ${KUBECTL} create ns "${namespace}" --dry-run=client -o yaml | ${KUBECTL} apply -f - 
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
    op_gp_count=$(${KUBECTL} -n "${namespace}" get OperatorGroup -o name | wc -l)
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
    cat <<-EOF | ${KUBECTL} "${action}" -f - ${config}
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
        createORupdate_prometurbo_operator
    else
        createORupdate_prometurbo_operator
        createORupdate_prometurbo_cr
    fi

    echo "Successfully ${ACTION} Prometurbo in ${OPERATOR_NS} namespace!"
    ${KUBECTL} -n "${OPERATOR_NS}" get sa,pod,deploy,cm
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

    cat <<-EOF | ${KUBECTL} "${action}" -f - ${config}
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
        if ! ${KUBECTL} api-resources | grep -qE "Prometurbo"; then
            echo "There is not Prometurbo object to delete"
            return
        fi
    fi

    # Get user's consent to overwrite the current Prometurbo CR in the target namespace
    is_cr_exists=$(${KUBECTL} -n "${OPERATOR_NS}" get Prometurbo "${PROMETURBO_NAME}" -o name --ignore-not-found)
    if [ -n "${is_cr_exists}" ] && [ "${action}" != "delete" ]; then
        echo "Warning: Prometurbo CR (${PROMETURBO_NAME}) detected in the namespace(${OPERATOR_NS})!"
        echo "Please confirm to overwrite the current Prometurbo CR [Y/n]: " && read -r overwriteCR
        [ "${overwriteCR}" = "n" ] || [ "${overwriteCR}" = "N" ] && echo "Installation aborted..." && exit 1
    fi

    cat <<-EOF | ${KUBECTL} "${action}" -f - ${config}
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
	  image:
	    prometurboRepository: "${PROMETURBO_REGISTRY}"
	    prometurboTag: "${PROMETURBO_VERSION}"
	    turbodifRepository: "${TURBODIF_REGISTRY}"
	    turbodifTag: "${PROMETURBO_VERSION}"
	  roleName: "${PROMETURBO_ROLE}"
	  targetName: "${TARGET_NAME}"
	  targetAddress: "${TARGET_ADDRESS}"
	---
	EOF
    wait_for_deployment "${OPERATOR_NS}" "${PROMETURBO_NAME}"
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
        ${KUBECTL} -n "${OPERATOR_NS}" "${action}" Subscription "${CERT_PROMETURBO_OP_NAME}" ${config}
        ${KUBECTL} -n "${OPERATOR_NS}" "${action}" csv "${CERT_PROMETURBO_OP_VERSION}" ${config}
        return
    fi
    cat <<-EOF | ${KUBECTL} "${action}" -f - ${config}
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
	  source: "${CARALOG_SOURCE}"
	  sourceNamespace: "${CARALOG_SOURCE_NS}"
	  startingCSV: "${CERT_PROMETURBO_OP_VERSION}"
	---
	EOF
    wait_for_deployment "${OPERATOR_NS}" "prometurbo-operator"
}

# Function to install Prometurbo operator via yaml bundle
createORupdate_prometurbo_operator_via_yaml() {
    operator_deploy_name="prometurbo-operator"
    operator_service_account="prometurbo-operator"
    source_github_repo="https://raw.githubusercontent.com/IBM/turbonomic-container-platform"
    prometurbo_operator_release=$(match_github_release "IBM/turbonomic-container-platform" "${PROMETURBO_VERSION}")

    operator_crd_path="prometurbo/operator/charts.helm.k8s.io_prometurbos_crd.yaml"
    operator_crd=$(curl "${source_github_repo}/${prometurbo_operator_release}/${operator_crd_path}" )

    operator_yaml_path="prometurbo/operator/prometurbo_operator_full.yaml"
    operator_full=$(curl "${source_github_repo}/${prometurbo_operator_release}/${operator_yaml_path}" | sed "s/: turbo$/: ${OPERATOR_NS}/g" | sed '/^\s*#/d')

    operator_yaml_bundle=$(cat <<-EOF | ${KUBECTL} create -f - -n "${OPERATOR_NS}" --dry-run=client -o yaml
	${operator_crd}
	---
	${operator_full}
	EOF
    )
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
        kind_name_str=$(${KUBECTL} create -f "${yaml_abs_path}" --dry-run=client -o=jsonpath="{.kind} {.metadata.name}")
        obj_kind=$(echo "${kind_name_str}" | awk '{print $1}')
        obj_name=$(echo "${kind_name_str}" | awk '{print $2}')

        is_object_exists=$(${KUBECTL} -n "${OPERATOR_NS}" get "${obj_kind}" --field-selector=metadata.name"=${obj_name}" -o name)
        if [ "${ACTION}" = "delete" ]; then
            # delete k8s resources if exists (avoid cluster resources)
            skip_target=$(should_skip_delete_k8s_object "${obj_kind}")
            [ -n "${is_object_exists}" ] && [ "${skip_target}" = "false" ] && ${KUBECTL} "${ACTION}" -f "${yaml_abs_path}"
        elif [ -n "${is_object_exists}" ] && [ "${obj_kind}" = "ClusterRoleBinding" ]; then
            # if cluster role binding exists, patch it with target services account
            isClusterRoleBinded=$(${KUBECTL} get "${obj_kind}" "${obj_name}" -o=jsonpath='{range .subjects[*]}{.namespace}{"\n"}{end}' | grep -E "^${OPERATOR_NS}$")
            if [ -z "${isClusterRoleBinded}" ]; then 
                ${KUBECTL} patch "${obj_kind}" "${obj_name}" --type='json' -p='[{"op": "add", "path": "/subjects/-", "value": {"kind": "ServiceAccount", "name": "'"${sa_name}"'", "namespace": "'"${OPERATOR_NS}"'"}}]'
            else
                echo "Skip patching ${obj_kind} ${obj_name} as the clusterRole has bound to the operator service account already."
            fi
        elif [ -z "${is_object_exists}" ]; then
            # create the k8s object if not exists
            ${KUBECTL} "create" -f "${yaml_abs_path}" --save-config
        else
            # update the k8s object if exists
            ${KUBECTL} apply -f "${yaml_abs_path}"
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
    cert_ops=$(${KUBECTL} get packagemanifests -o jsonpath="{range .items[*]}{.metadata.name} {.status.catalogSource} {.status.catalogSourceNamespace}{'\n'}{end}" | grep -e "${target}" | grep -e "${CARALOG_SOURCE}.*${CARALOG_SOURCE_NS}" | awk '{print $1}')
    cert_ops_count=$(echo "${cert_ops}" | wc -l | awk '{print $1}')
    if [ -z "${cert_ops}" ] || [ "${cert_ops_count}" -lt 1 ]; then
        echo "There aren't any certified ${target} operator in the Operatorhub, please contact administrator for more information!" && exit 1
    elif [ "${cert_ops_count}" -gt 1 ]; then
        PS3="Fetched mutiple certified ${target} operators in the Operatorhub, please select a number to proceed OR type 'exit' to exit: "
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
    channels=$(${KUBECTL} get packagemanifests "${cert_op_name}" -o jsonpath="{range .status.channels[*]}{.name}:{.currentCSV}{'\n'}{end}" | grep "${target_release}")
    channel_count=$(echo "${channels}" | wc -l | awk '{print $1}')
    if [ -z "${channels}" ] || [ "${channel_count}" -lt 1 ]; then
        echo "There aren't any channel created for ${cert_op_name}, please contact administrator for more information!" && exit 1
    elif [ "${channel_count}" -gt 1 ]; then
        PS3="Fetched mutiple releases, please select a number to proceed OR type 'exit' to exit: "
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
        full_deploy=$(${KUBECTL} -n "${deploy_ns}" get deploy -o name | grep -E "^deployment.apps/${deploy}$")
        if [ -n "${full_deploy}" ]; then
            deploy_status=$(${KUBECTL} -n "${deploy_ns}" rollout status "${full_deploy}" --timeout=5s 2>&1 | grep "successfully")
            if [ -n "${deploy_status}" ]; then
                break
            fi
        fi
        retry_count=$((retry_count + 1))
        if message=$(retry "${retry_count}"); then
            echo "${message}"
        else
            echo "Please check following events for more information:"
            ${KUBECTL} -n "${deploy_ns}" get events --sort-by='.lastTimestamp' | grep "${deploy}"
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
        ${KUBECTL} -n "${OPERATOR_NS}" delete secret turbonomic-credentials --ignore-not-found
        createORupdate_tsc_operator
        createORupdate_tsc_cr
        createORupdate_skupper_tunnel
        wait_for_tsc_sync_up
    fi
    echo "Successfully ${ACTION} TSC operator in the ${OPERATOR_NS} namespace!"
    ${KUBECTL} -n "${OPERATOR_NS}" get role,rolebinding,sa,pod,deploy -l 'app.kubernetes.io/created-by in (t8c-client-operator, turbonomic-t8c-client-operator)'
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
        ${KUBECTL} -n "${OPERATOR_NS}" "${action}" Subscription "${CERT_TSC_OP_NAME}" ${config}
        ${KUBECTL} -n "${OPERATOR_NS}" "${action}" csv "${CERT_TSC_OP_VERSION}" ${config}
        return
    fi
    cat <<-EOF | ${KUBECTL} "${action}" -f - ${config}
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
	  source: "${CARALOG_SOURCE}"
	  sourceNamespace: "${CARALOG_SOURCE_NS}"
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

    apply_operator_bundle "${operator_service_account}" "${operator_deploy_name}" "${operator_yaml_bundle}"
}

# Function to create or update the prometurbo operator in the namespace
createORupdate_tsc_cr() {
    action="${ACTION}"
    unset config
    if [ "${action}" = "delete" ]; then
        config="--ignore-not-found"
    fi

    echo "${action} TSC CR ..."
    if [ "${action}" = "delete" ]; then
        # skip deletion if the CRD is not found
        if ! ${KUBECTL} api-resources | grep -qE "TurbonomicClient|VersionManager"; then
            return
        fi
    fi

    tsc_client_name="turbonomicclient-release"
    cat <<-EOF | ${KUBECTL} "${action}" -f - ${config}
	---
	kind: TurbonomicClient
	apiVersion: clients.turbonomic.ibm.com/v1alpha1
	metadata:
	  name: "${tsc_client_name}"
	  namespace: "${OPERATOR_NS}"
	spec:
	  global:
	    version: "${PROMETURBO_VERSION}"
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
        sleep 20 && ${KUBECTL} wait pod \
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
        for it in $(${KUBECTL} get secret -n "${OPERATOR_NS}" -l "skupper.io/type" -o name); do
            ${KUBECTL} "${action}" -n "${OPERATOR_NS}" "${it}" ${config}
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
    echo "${skupper_connection_secret}" | ${KUBECTL} "${action}" -n "${OPERATOR_NS}" -f - ${config}

    echo "Waiting for setting up TSC connection..."
    retry_count=0
    while true; do
        tunnel_svc=$(${KUBECTL} -n "${OPERATOR_NS}" get service --field-selector=metadata.name=remote-nginx-tunnel -o name)
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
    # Prombeturbo is not an available target for TSC operator to auto-patch the server address
    # So, we need to manually patch the tunnel to Prometurbo's CR for now
    ${KUBECTL} -n "${OPERATOR_NS}" patch prometurbo/"${PROMETURBO_NAME}" --type=json -p='[{"op": "replace", "path": "/spec/serverMeta/turboServer", "value": "http://remote-nginx-tunnel:9080/topology-processor"}]'

    # Manually restart the Prometurbo deployment to be compatiable with the old prometurbo operator impletation.
    ${KUBECTL} -n "${OPERATOR_NS}" scale deploy/"${PROMETURBO_NAME}" --replicas=0
    wait_for_deployment "${OPERATOR_NS}" "${PROMETURBO_NAME}"
}

################## MAIN ##################
dependencies_check && validate_args "${@}" && confirmations && main
