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
DEFAULT_ROLE="cluster-admin"
DEFAULT_ENABLE_TSC="optional"
DEFAULT_PROXY_SERVER=""
DEFAULT_KUBETURBO_NAME="kubeturbo-release"
DEFAULT_KUBETURBO_VERSION="8.13.1"
DEFAULT_KUBETURBO_REGISTRY="icr.io/cpopen/turbonomic/kubeturbo"
DEFAULT_REGISTRY_PREFIX="icr.io/cpopen"
DEFAULT_KUBETURBO_IMG_REPO="turbonomic/kubeturbo"
DEFAULT_PRIVATE_REGISTRY_SECRET_NAME="private-docker-registry-secret"
DEFAULT_LOGGING_LEVEL=0
DEFAULT_KUBESTATE_VERSION="v2.14.0"

RETRY_INTERVAL=10 # in seconds
MAX_RETRY=10

################## ARGS ##################
OSTYPE=${OSTYPE:-""}
KUBECONFIG=${KUBECONFIG:-""}

ACTION=${ACTION:-"apply"}
KT_TARGET_RELEASE=${KT_TARGET_RELEASE:-${DEFAULT_RELEASE}}
TSC_TARGET_RELEASE=${TSC_TARGET_RELEASE:-${DEFAULT_RELEASE}}
PWD_SECRET_ENCODED=${PWD_SECRET_ENCODED:-"true"}

TARGET_HOST=${TARGET_HOST:-""}
OAUTH_CLIENT_ID=${OAUTH_CLIENT_ID:-""}
OAUTH_CLIENT_SECRET=${OAUTH_CLIENT_SECRET:-""}
TSC_TOKEN=${TSC_TOKEN:-""}

OPERATOR_NS=${OPERATOR_NS:-${DEFAULT_NS}}
TARGET_NAME=${TARGET_NAME:-${DEFAULT_TARGET_NAME}}
KUBETURBO_ROLE=${KUBETURBO_ROLE:-${DEFAULT_ROLE}}
ENABLE_TSC=${ENABLE_TSC:-${DEFAULT_ENABLE_TSC}}
PROXY_SERVER=${PROXY_SERVER:-${DEFAULT_PROXY_SERVER}}
KUBETURBO_NAME=${KUBETURBO_NAME:-${DEFAULT_KUBETURBO_NAME}}
KUBETURBO_VERSION=${KUBETURBO_VERSION:-${DEFAULT_KUBETURBO_VERSION}}
KUBETURBO_OP_VERSION=${KUBETURBO_OP_VERSION:-""}
KUBETURBO_IMG_REPO=${KUBETURBO_IMG_REPO:-${DEFAULT_KUBETURBO_IMG_REPO}}
KUBETURBO_REGISTRY=${KUBETURBO_REGISTRY:-${DEFAULT_KUBETURBO_REGISTRY}}
KUBETURBO_REGISTRY_USRNAME=${KUBETURBO_REGISTRY_USRNAME:-""}
KUBETURBO_REGISTRY_PASSWRD=${KUBETURBO_REGISTRY_PASSWRD:-""}
TARGET_SUBTYPE=${TARGET_SUBTYPE:-""}

LOGGING_LEVEL=${LOGGING_LEVEL:-${DEFAULT_LOGGING_LEVEL}}

################## DYNAMIC VARS ##################
CERT_OP_NAME="<EMPTY>"
CERT_OP_RELEASE="<EMPTY>"
CERT_OP_VERSION="<EMPTY>"
CERT_KUBETURBO_OP_NAME="<EMPTY>"
CERT_KUBETURBO_OP_RELEASE="<EMPTY>"
CERT_KUBETURBO_OP_VERSION="<EMPTY>"
CERT_TSC_OP_NAME="<EMPTY>"
CERT_TSC_OP_RELEASE="<EMPTY>"
CERT_TSC_OP_VERSION="<EMPTY>"
K8S_CLUSTER_KINDS="<EMPTY>"
PRIVATE_REGISTRY_ENABLED="false"
PRIVATE_REGISTRY_PREFIX=""
PRIVATE_REGISTRY_SECRET_NAME=""
ACCEPT_FALLBACK=""

################## FUNCTIONS ##################
# check if the current system supports all the commands needed to run the script
dependencies_check() {
    missing_dependencies=""
    for dependency in ${DEPENDENCY_LIST}; do 
        dependency_path=$(command -v "${dependency}")
        if ! [ -x "${dependency_path}" ]; then
            missing_dependencies="${missing_dependencies} ${dependency}"
        fi
    done

    if [ -n "${missing_dependencies}" ]; then 
        echo "ERROR: Missing the required command: $(echo "${missing_dependencies}" | sed 's/ /, /g')"
        echo "Please refer to the official documentation or use your package manager to install to continue."
        exit 1
    fi
}

validate_args() {
    while [ $# -gt 0 ]; do
        case $1 in
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
        KUBETURBO_REGISTRY_PASSWRD=$(password_secret_handler "${KUBETURBO_REGISTRY_PASSWRD}")
        OAUTH_CLIENT_ID=$(password_secret_handler "${OAUTH_CLIENT_ID}")
        OAUTH_CLIENT_SECRET=$(password_secret_handler "${OAUTH_CLIENT_SECRET}")
        PROXY_SERVER=$(password_secret_handler "${PROXY_SERVER}")
    fi

    # If cluster subtype is not provide then auto detect the current subtype
    if [ -z "${TARGET_SUBTYPE}" ]; then
        TARGET_SUBTYPE=$(auto_detect_cluster_type)
    fi

    # Extract registry prefix from given the Kubeturbo registry
    PRIVATE_REGISTRY_PREFIX=$(echo "${KUBETURBO_REGISTRY}" | sed "s|\/${KUBETURBO_IMG_REPO}$||g")
    
    # Determine if the private registry is applied or not
    if [ "${PRIVATE_REGISTRY_PREFIX}" != "${DEFAULT_REGISTRY_PREFIX}" ]; then
        PRIVATE_REGISTRY_ENABLED="true"
    else
        PRIVATE_REGISTRY_ENABLED="false"
    fi
}

usage() {
   echo "This program helps to install Kubeturbo to the Kubernetes cluster"
   echo "Syntax: ./$0 --host <IP> --kubeconfig <PATH>"
   echo
   echo "options:"
   echo "--host         <VAL>    host of the Turbonomic instance (required)"
   echo "--kubeconfig   <VAL>    Path to the kubeconfig file to use for CLI requests"
   echo
}

# wraps up kubectl cmd to ensure spaces in path can be handle safely
run_kubectl() {
    if [ -n "${KUBECONFIG:-}" ]; then
        "${KUBECTL}" --kubeconfig="${KUBECONFIG}" "$@"
    else
        "${KUBECTL}" "$@"
    fi
}

# confirm args that are passed into the script and get user's consent
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
    printf "%-20s %-20s\n" "Role" "${KUBETURBO_ROLE}"
    printf "%-20s %-20s\n" "Version" "${KUBETURBO_VERSION}"
    printf "%-20s %-20s\n" "Auto-Update" "${ENABLE_TSC}"
    printf "%-20s %-20s\n" "Auto-Logging" "${ENABLE_TSC}"
    printf "%-20s %-20s\n" "Proxy Server" "${proxy_server_enabled}"
    printf "%-20s %-20s\n" "Private Registry" "${PRIVATE_REGISTRY_ENABLED}"
    printf "%-20s %-20s\n" "Registry" "${PRIVATE_REGISTRY_PREFIX}"
    echo ""
    echo "Please confirm the above settings [Y/n]: " && read -r  continueInstallation
    [ "${continueInstallation}" = "n" ] || [ "${continueInstallation}" = "N" ] && echo "Please retry the script with correct settings!" && exit 1
    cluster_type_check
}

# To determine whether the current kubectl context is an Openshift cluster
cluster_type_check() {
    confirm_installation_cluster

    if [ -z "${TARGET_SUBTYPE}" ]; then
        TARGET_SUBTYPE=$(auto_detect_cluster_type)
        return
    fi
    
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

# get client's concent to install to the current cluster
confirm_installation_cluster() {
    echo "Info: Your current Kubernetes context is set to the following:"
    show_current_kube_context
    echo "Please confirm if the script should work in the above cluster [Y/n]: " && read -r continueInstallation
    [ "${continueInstallation}" = "n" ] || [ "${continueInstallation}" = "N" ] && echo "Please double check your current Kubernetes context before the other try!" && exit 1
}

# display current kubeconfig context in a table format
show_current_kube_context() {
    # exit if the current context is not set
    if ! current_context=$(run_kubectl config current-context); then
        echo "ERROR: Current context is not set in your cluster!"
        exit 1
    fi

    # get detail from the raw oject
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

    # exit if the current the cluster is not reachable
    if ! run_kubectl get nodes > /dev/null 2>&1; then
        echo "ERROR: Context used by the current cluster is not reachable!"
        exit 1
    fi
}

# detech the cluster type
auto_detect_cluster_type() {
    is_current_oc_cluster=$(run_kubectl api-resources --api-group=route.openshift.io -o name)
    normalize_target_cluster_type "$([ -n "${is_current_oc_cluster}" ] && echo "${OCP_TYPE}")"
}

# normalize cluster type to either Openshift or Kubernetes
normalize_target_cluster_type() {
    cluster_type=$1
    is_target_oc_cluster=$(echo "${cluster_type}" | grep -i "${OCP_TYPE}")
    [ -n "${is_target_oc_cluster}" ] && echo "${OCP_TYPE}" || echo "${K8S_TYPE}"
}

main() {
    # gather all cluster level resource kinds
    K8S_CLUSTER_KINDS=$(run_kubectl api-resources --namespaced=false --no-headers | awk '{print $NF}')

    NS_EXISTS=$(run_kubectl get ns --field-selector=metadata.name="${OPERATOR_NS}" -o name)
    if [ -z "${NS_EXISTS}" ]; then
        echo "Creating ${OPERATOR_NS} namespace to deploy Kubeturbo operator"
        run_kubectl create ns "${OPERATOR_NS}" --dry-run=client -o yaml | run_kubectl apply -f - 
    fi
    
    if [ "${ACTION}" != "delete" ] && [ "${ENABLE_TSC}" = "optional" ]; then
        echo "Do you want to install with the auto logging and auto version updates? [Y/n]: " && read -r enableTSC
        if [ "${enableTSC}" = "n" ] || [ "${enableTSC}" = "N" ]; then
            ENABLE_TSC="false"
        else
            ENABLE_TSC="true"
        fi
    fi
    
    apply_operator_group
    setup_kubeturbo

    # applicable scenario: user switch from tsc approach to oauth2 approach 
    is_tsc_launched=$(run_kubectl -n "${OPERATOR_NS}" get deploy --field-selector=metadata.name=t8c-client-operator-controller-manager -o name)
    if [ -n "${is_tsc_launched}" ] && [ "${ENABLE_TSC}" = "false" ]; then
        echo "Info: Dismounting Auto-logging & Auto-updating feature as no longer required ..."
        ACTION="delete"
    fi

    setup_tsc

    echo "Done!"
    exit 0
}

apply_operator_group() {
    if [ "${TARGET_SUBTYPE}" != "${OCP_TYPE}" ]; then return; fi
    op_gp_count=$(run_kubectl -n "${OPERATOR_NS}" get OperatorGroup -o name | wc -l)
    if [ "${op_gp_count}" -eq 1 ]; then 
        return
    elif [ "${op_gp_count}" -gt 1 ]; then 
        echo "ERROR: Found multiple Operator Groups in the namespace ${OPERATOR_NS}" >&2 && exit 1
    fi

    action="${ACTION}"
    unset config
    if [ "${ACTION}" = "delete" ]; then
        action="${ACTION}"
        config="--ignore-not-found"
    fi

    cat <<-EOF | run_kubectl "${action}" -f - ${config}
	---
	apiVersion: operators.coreos.com/v1
	kind: OperatorGroup
	metadata:
	  name: kubeturbo-opeartorgroup
	  namespace: "${OPERATOR_NS}"
	spec:
	  targetNamespaces:
	  - "${OPERATOR_NS}"
	---
	EOF
}

setup_kubeturbo() {
    if [ "${ENABLE_TSC}" != "true" ]; then
        apply_oauth2_token
    fi

    if [ "${ACTION}" = "delete" ]; then
        apply_kubeturbo_cr
        apply_kubeturbo_op
        apply_private_registry_secret
    else
        apply_private_registry_secret
        apply_kubeturbo_op
        apply_kubeturbo_cr
    fi

    echo "Successfully ${ACTION} Kubeturbo in ${OPERATOR_NS} namespace!"
    run_kubectl -n "${OPERATOR_NS}" get role,rolebinding,sa,pod,deploy,cm -l 'app.kubernetes.io/created-by in (kubeturbo-deploy, kubeturbo-operator)'
}

# Create or delete private registry secret
apply_private_registry_secret() {
    if [ -n "${KUBETURBO_REGISTRY_USRNAME}" ] && [ -n "${KUBETURBO_REGISTRY_PASSWRD}" ]; then
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
            --docker-username="${KUBETURBO_REGISTRY_USRNAME}" \
            --docker-password="${KUBETURBO_REGISTRY_PASSWRD}" \
            --docker-server="${docker_server}" \
            --namespace="${OPERATOR_NS}" \
            --dry-run="client" -o yaml | run_kubectl "${action}" -f - ${config}
        
        if [ "${ACTION}" != "delete" ]; then
            run_kubectl -n "${OPERATOR_NS}" patch sa default --type='json' -p='[{"op": "add", "path": "/imagePullSecrets", "value": [{"name": '"${PRIVATE_REGISTRY_SECRET_NAME}"'}]}]'
        fi
    fi
}

apply_kubeturbo_op() {
    if [ "${TARGET_SUBTYPE}" = "${OCP_TYPE}" ]; then
        apply_kubeturbo_op_subscription
    else
        apply_kubeturbo_op_yaml
    fi
}

apply_kubeturbo_op_subscription() {
    if ! handle_private_registry_fallback; then
        apply_kubeturbo_op_yaml
        return
    fi

    select_cert_op_from_operatorhub "kubeturbo"
    CERT_KUBETURBO_OP_NAME="${CERT_OP_NAME}"

    select_cert_op_channel_from_operatorhub "${CERT_KUBETURBO_OP_NAME}" "${KT_TARGET_RELEASE}"
    CERT_KUBETURBO_OP_RELEASE="${CERT_OP_RELEASE}"
    CERT_KUBETURBO_OP_VERSION="${CERT_OP_VERSION}"

    action="${ACTION}"
    unset config
    if [ "${ACTION}" = "delete" ]; then
        action="${ACTION}"
        config="--ignore-not-found"
    fi

    echo "${ACTION} Certified Kubeturbo operator subscription ..."
    if [ "${ACTION}" = "delete" ]; then
        run_kubectl -n "${OPERATOR_NS}" "${action}" Subscription "${CERT_KUBETURBO_OP_NAME}" ${config}
        run_kubectl -n "${OPERATOR_NS}" "${action}" csv "${CERT_KUBETURBO_OP_VERSION}" ${config}
        return
    fi
    cat <<-EOF | run_kubectl "${action}" -f - ${config}
	---
	apiVersion: operators.coreos.com/v1alpha1
	kind: Subscription
	metadata:
	  name: "${CERT_KUBETURBO_OP_NAME}"
	  namespace: "${OPERATOR_NS}"
	spec:
	  channel: "${CERT_KUBETURBO_OP_RELEASE}"
	  installPlanApproval: "Automatic"
	  name: "${CERT_KUBETURBO_OP_NAME}"
	  source: "${CARALOG_SOURCE}"
	  sourceNamespace: "${CARALOG_SOURCE_NS}"
	  startingCSV: "${CERT_KUBETURBO_OP_VERSION}"
	---
	EOF
    wait_for_deployment "${OPERATOR_NS}" "kubeturbo-operator"
}

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
        echo "Please proceed to mirror the OCP catalog for OperatorHub: https://www.ibm.com/docs/en/tarm/8.16.x?topic=requirements-container-image-repository"
        echo "Press [Enter] to continue: " && read -r _
    else
        echo "Using YAML approach with private registry."
        ACCEPT_FALLBACK=1
    fi
    return "${ACCEPT_FALLBACK}"
}

apply_kubeturbo_op_yaml() {
    operator_deploy_name="kubeturbo-operator"
    operator_service_account="kubeturbo-operator"
    
    source_github_repo="https://raw.githubusercontent.com/IBM/turbonomic-container-platform"
    operator_yaml_path="kubeturbo/operator/operator-bundle.yaml"
    kubeturbo_operator_release=$(match_github_release "IBM/turbonomic-container-platform" "${KUBETURBO_VERSION}")
    operator_yaml_bundle=$(curl "${source_github_repo}/${kubeturbo_operator_release}/${operator_yaml_path}" | sed "s/: turbo$/: ${OPERATOR_NS}/g" | sed '/^\s*#/d')
    
    # Only apply operator version once user specified
    if [ -n "${KUBETURBO_OP_VERSION}" ]; then
        echo "Using the customized image tag for operator: ${KUBETURBO_OP_VERSION}"
        current_image=$(echo "${operator_yaml_bundle}" | grep "image: " | awk '{print $2}')
        target_image=$(echo "${operator_yaml_bundle}" | grep "image: " | awk '{print $2}' | sed 's|:.*|:'"${KUBETURBO_OP_VERSION}"'|g')
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

apply_kubeturbo_cr() {
    action="${ACTION}"
    unset config
    if [ "${ACTION}" = "delete" ]; then
        action="${ACTION}"
        config="--ignore-not-found"
    fi

    echo "${ACTION} Kubeturbo CR ..."
    if [ "${ACTION}" = "delete" ]; then
        # skip deletion if the CRD is not found
        if ! run_kubectl api-resources | grep -qE "Kubeturbo"; then
            return
        fi
    fi

    # get user's consent to overwrite the current Kubeturbo CR in the target namespace
    is_cr_exists=$(run_kubectl -n "${OPERATOR_NS}" get Kubeturbo --field-selector=metadata.name="${KUBETURBO_NAME}" -o name)
    if [ -n "${is_cr_exists}" ] && [ "${ACTION}" != "delete" ]; then
        echo "Warning: Kubeturbo CR(${KUBETURBO_NAME}) detected in the namespace(${OPERATOR_NS})!"
        echo "Please confirm to overwrite the current Kubeturbo CR [Y/n]: " && read -r overwriteCR
        [ "${overwriteCR}" = "n" ] || [ "${overwriteCR}" = "N" ] && echo "Installation aborted..." && exit 1
    fi

    # Tag of the cpufreqgetter image starts to align with turbo version since 8.16.5,
    # so we need to check if the image tag exist before print to the client.
    # Will use the previous default tag (latest) if the current tag version is not found.
    cpuFreqgetterTag=$(curl -s "https://icr.io/v2/cpopen/turbonomic/cpufreqgetter/tags/list" 2>/dev/null | grep -q -w "\"${KUBETURBO_VERSION}\"" && echo "${KUBETURBO_VERSION}" || echo "latest")

    # Notify client to mirror which images 
    if [ "${PRIVATE_REGISTRY_ENABLED}" = "true" ] && [ "${ACTION}" != "delete" ]; then
        echo "Ensure following images get mirrored to your private registry (${PRIVATE_REGISTRY_PREFIX}):"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/${DEFAULT_KUBETURBO_IMG_REPO}:${KUBETURBO_VERSION}"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/turbonomic/cpufreqgetter:${cpuFreqgetterTag}"
        echo "Please press [Enter] to proceed: " && read -r _
    fi

    imagePullSecret=""
    if [ -n "${PRIVATE_REGISTRY_SECRET_NAME}" ]; then
        imagePullSecret="imagePullSecret: ${PRIVATE_REGISTRY_SECRET_NAME}"
    fi

    cat <<-EOF | run_kubectl "${action}" -f - ${config}
	---
	kind: Kubeturbo
	apiVersion: charts.helm.k8s.io/v1
	metadata:
	  name: "${KUBETURBO_NAME}"
	  namespace: "${OPERATOR_NS}"
	spec:
	  serverMeta:
	    turboServer: "${TARGET_HOST}"
	    version: "${KUBETURBO_VERSION}"
	    proxy: "${PROXY_SERVER}"
	  targetConfig:
	    targetName: "${TARGET_NAME}"
	  image:
	    repository: "${PRIVATE_REGISTRY_PREFIX}/${KUBETURBO_IMG_REPO}" 
	    tag: "${KUBETURBO_VERSION}"
	    ${imagePullSecret}
	    cpufreqgetterRepository: "${PRIVATE_REGISTRY_PREFIX}/turbonomic/cpufreqgetter" 
	  roleName: "${KUBETURBO_ROLE}"
	---
	EOF
    wait_for_deployment "${OPERATOR_NS}" "${KUBETURBO_NAME}"
}

apply_oauth2_token() {
    if [ "${ACTION}" != "delete" ]; then 
        if [ -z "${OAUTH_CLIENT_ID}" ] || [ -z "${OAUTH_CLIENT_SECRET}" ]; then
            echo "Missing OAuth2 client settings, please gather values following the instruction: "
            echo "https://www.ibm.com/docs/en/tarm/latest?topic=cookbook-authenticating-oauth-20-clients-api"
            echo "Enable enter your OAuth2 client id: " && read -r OAUTH_CLIENT_ID
            echo "Enable enter your OAuth2 client secret: " && read -r OAUTH_CLIENT_SECRET
            apply_oauth2_token && return
        fi
    fi

    action="${ACTION}"
    unset config
    if [ "${ACTION}" = "delete" ]; then
        action="${ACTION}"
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

setup_tsc() {
    if [ "${ACTION}" = "delete" ]; then
        apply_skupper_tunnel
        apply_tsc_cr
        apply_tsc_op
    else
        if [ "${ENABLE_TSC}" != "true" ]; then return; fi
        run_kubectl -n "${OPERATOR_NS}" delete secret turbonomic-credentials --ignore-not-found
        apply_tsc_op
        apply_tsc_cr
        apply_skupper_tunnel
        wait_for_tsc_sync_up
    fi
    echo "Successfully ${ACTION} TSC operator in the ${OPERATOR_NS} namespace!"
    run_kubectl -n "${OPERATOR_NS}" get role,rolebinding,sa,pod,deploy -l 'app.kubernetes.io/created-by in (t8c-client-operator, turbonomic-t8c-client-operator)'
}

apply_tsc_op() {
    if [ "${TARGET_SUBTYPE}" = "${OCP_TYPE}" ]; then
        apply_tsc_op_subscription
    else
        apply_tsc_op_yaml
    fi
}

apply_tsc_op_subscription() {
    if ! handle_private_registry_fallback; then
        apply_tsc_op_yaml
        return
    fi

    select_cert_op_from_operatorhub "t8c-tsc"
    CERT_TSC_OP_NAME="${CERT_OP_NAME}"

    select_cert_op_channel_from_operatorhub "${CERT_TSC_OP_NAME}" "${TSC_TARGET_RELEASE}"
    CERT_TSC_OP_RELEASE="${CERT_OP_RELEASE}"
    CERT_TSC_OP_VERSION="${CERT_OP_VERSION}"

    action="${ACTION}"
    unset config
    if [ "${ACTION}" = "delete" ]; then
        action="${ACTION}"
        config="--ignore-not-found"
    fi

    echo "${ACTION} Certified t8c-tsc operator subscription ..."
    if [ "${ACTION}" = "delete" ]; then
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
	  source: "${CARALOG_SOURCE}"
	  sourceNamespace: "${CARALOG_SOURCE_NS}"
	  startingCSV: "${CERT_TSC_OP_VERSION}"
	---
	EOF
    wait_for_deployment "${OPERATOR_NS}" "t8c-client-operator-controller-manager"
}

apply_tsc_op_yaml() {
    operator_deploy_name="t8c-client-operator-controller-manager"
    operator_service_account="t8c-client-operator-controller-manager"
    
    source_github_repo="https://raw.githubusercontent.com/IBM/t8c-client-operator"
    operator_yaml_path="deploy/operator_bundle.yaml"
    tsc_operator_release=$(match_github_release "IBM/t8c-client-operator" "${KUBETURBO_VERSION}")
    operator_yaml_bundle=$(curl "${source_github_repo}/${tsc_operator_release}/${operator_yaml_path}" | sed "s/: __NAMESPACE__$/: ${OPERATOR_NS}/g" | sed '/^\s*#/d')

    # Notify client to mirror which images 
    if [ "${PRIVATE_REGISTRY_ENABLED}" = "true" ] && [ "${ACTION}" != "delete" ]; then
        echo "Ensure following image gets mirrored to your private registry. (${PRIVATE_REGISTRY_PREFIX}):"
        echo "- $(echo "${operator_yaml_bundle}" | grep "image: " | awk '{print $2}')"
        echo "Please press [Enter] to proceed: " && read -r _
   
        # Swap to private registry
        operator_yaml_bundle=$(echo "${operator_yaml_bundle}" | sed 's|image: '"${DEFAULT_REGISTRY_PREFIX}"'|image: '"${PRIVATE_REGISTRY_PREFIX}"'|g')
    fi


    apply_operator_bundle "${operator_service_account}" "${operator_deploy_name}" "${operator_yaml_bundle}"
}

apply_tsc_cr() {
    action="${ACTION}"
    unset config
    if [ "${ACTION}" = "delete" ]; then
        action="${ACTION}"
        config="--ignore-not-found"
    fi

    echo "${ACTION} TSC CR ..."
    if [ "${ACTION}" = "delete" ]; then
        # skip deletion if the CRD is not found
        if ! run_kubectl api-resources | grep -qE "TurbonomicClient|VersionManager"; then
            return
        fi
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

     # Notify client to mirror which images 
    if [ "${PRIVATE_REGISTRY_ENABLED}" = "true" ] && [ "${ACTION}" != "delete" ]; then
        echo "Ensure following images get mirrored to your private registry. (${PRIVATE_REGISTRY_PREFIX}):"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/turbonomic/kube-state-metrics:${DEFAULT_KUBESTATE_VERSION}"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/turbonomic/skupper-router:${KUBETURBO_VERSION}"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/turbonomic/skupper-config-sync:${KUBETURBO_VERSION}"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/turbonomic/rsyslog-courier:${KUBETURBO_VERSION}"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/turbonomic/skupper-service-controller:${KUBETURBO_VERSION}"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/turbonomic/skupper-site-controller:${KUBETURBO_VERSION}"
        echo "- ${DEFAULT_REGISTRY_PREFIX}/turbonomic/tsc-site-resources:${KUBETURBO_VERSION}"
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
	    version: "${KUBETURBO_VERSION}"
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

apply_skupper_tunnel() {
    action="${ACTION}"
    unset config
    if [ "${ACTION}" = "delete" ]; then
        action="${ACTION}"
        config="--ignore-not-found"
    fi

    if [ "${ACTION}" = "delete" ]; then 
        echo "${ACTION} secrets for TSC connection ..."
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
        apply_skupper_tunnel && return
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

wait_for_tsc_sync_up() {
    # Wait for CR updates (watch on target server url updates)
    echo "Waiting for Kubeturbo CR updates..."
    retry_count=0
    while true; do
        turbo_server=$(run_kubectl -n "${OPERATOR_NS}" get Kubeturbos "${KUBETURBO_NAME}" -o=jsonpath='{.spec.serverMeta.turboServer}' | grep remote-nginx-tunnel)
        if [ -n "${turbo_server}" ];then break; fi
        retry_count=$((retry_count + 1))
        if message=$(retry "${retry_count}"); then
            echo "${message}"
        else
            echo "There's no updates from the TSC client, please double-check if the Turbo server can reach out your current cluster!" 
            exit 1
        fi
    done

    # Restart the kubeturbo pod to secure the updates if the operator hasn't restart the pod yet
    kubeturbo_pod=$(run_kubectl -n "${OPERATOR_NS}" get pods --field-selector=status.phase=Running -o name | grep "${KUBETURBO_NAME}")
    if [ -n "${kubeturbo_pod}" ]; then
        run_kubectl -n "${OPERATOR_NS}" delete "${kubeturbo_pod}" --ignore-not-found
        wait_for_deployment "${OPERATOR_NS}" "${KUBETURBO_NAME}"
    fi
}

select_cert_op_from_operatorhub() {
    target=$1
    echo "Fetching Openshift certified ${target} operator from OperatorHub ..."
    cert_ops=$(run_kubectl get packagemanifests -o jsonpath="{range .items[*]}{.metadata.name} {.status.catalogSource} {.status.catalogSourceNamespace}{'\n'}{end}" | grep -e "${target}" | grep -e "${CARALOG_SOURCE}.*${CARALOG_SOURCE_NS}" | awk '{print $1}')
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

select_cert_op_channel_from_operatorhub() {
    cert_op_name=${1-${CERT_OP_NAME}}
    target_release=${2-${DEFAULT_RELEASE}}
    echo "Fetching Openshift ${cert_op_name} channels from OperatorHub ..."
    channels=$(run_kubectl get packagemanifests "${cert_op_name}" -o jsonpath="{range .status.channels[*]}{.name}:{.currentCSV}{'\n'}{end}" | grep "${target_release}")
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

getJsonField() {
    jsonData=$1 && field=$2
    if ! echo "${jsonData}" | grep -q "${field}"; then
        echo "Unable to get field ${field} due to:"
        echo "${jsonData}"
        exit 1
    fi
    echo "${jsonData}" | sed -e "s/^{//g" -e "s/}$//g" -e "s/,/\n/g" -e "s/\"//g" | grep "${field}" | sed -e "s/[\" ]//g" | awk -F ':' '{print $2}'
}

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

wait_for_deployment() {
    if [ "${ACTION}" = "delete" ]; then return; fi
    namespace=$1 && deploy_name=$2
    
    echo "Waiting for deployment '${deploy_name}' to start..."
    retry_count=0
    while true; do
        full_deploy_name=$(run_kubectl -n "${namespace}" get deploy -o name | grep -E "^deployment.apps/${deploy_name}$")
        if [ -n "${full_deploy_name}" ]; then
            deploy_status=$(run_kubectl -n "${namespace}" rollout status "${full_deploy_name}" --timeout=5s 2>&1 | grep "successfully")
            if [ -n "${deploy_status}" ]; then
                deploy_name=$(echo "${full_deploy_name}" | awk -F '/' '{print $2}')
                for pod in $(run_kubectl -n "${namespace}" get pods -o name | grep "${deploy_name}"); do
                    run_kubectl -n "${namespace}" wait --for=condition=Ready "${pod}"
                done
                break
            fi
        fi
        retry_count=$((retry_count + 1))
        if message=$(retry "${retry_count}"); then
            echo "${message}"
        else
            echo "Please check following events for more information:"
            run_kubectl -n "${namespace}" get events --sort-by='.lastTimestamp' | grep "${deploy_name}"
            exit 1
        fi
    done
}

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

password_secret_handler() {
    if [ "${PWD_SECRET_ENCODED}" = "true" ]; then 
        echo "$1" | base64 -d
    else
        echo "$1"
    fi
}

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

should_skip_delete_k8s_object() {
    k8s_kind=$1
    [ "${k8s_kind}" = "Namespace" ] && echo "true" && return
    for it in ${K8S_CLUSTER_KINDS}; do
        [ "${it}" = "${k8s_kind}" ] && echo "true" && return
    done
    echo "false"
}

################## MAIN ##################
dependencies_check && validate_args "$@" && confirm_installation && main
