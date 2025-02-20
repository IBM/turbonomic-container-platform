#!/usr/bin/env sh

################## CMD ALIAS ##################
DEPENDENCY_LIST="grep cat sleep wc awk sed base64 mktemp curl jq"
KUBECTL=$(command -v oc)
KUBECTL=${KUBECTL:-$(command -v kubectl)}
if ! [ -x "${KUBECTL}" ]; then
    echo "ERROR: Command 'oc' and 'kubectl' are not found, please install either of them first!" >&2 && exit 1
fi

################## CONSTANT ##################
DEFAULT_PROMETURBO_DEPLOYMENT="prometurbo"
DEFAULT_CREDENTIAL_VOLUME_NAME="turbonomic-credentials-volume"
DEFAULT_TURBODIF_VOLUME_NAME="turbodif-config"
DEFAULT_TARGET_CRED_SECRET_NAME="turbonomic-credentials"
DEFAULT_TURBODIF_CNT_NAME="turbodif"
AUTH_APPROACH_BASIC="BASIC"
AUTH_APPROACH_OAUTH="OAUTH"
AUTH_APPROACH_TSC="TSC"

RETRY_INTERVAL=10 # in seconds
MAX_RETRY=10

################## DYNAMIC VARS ##################
DEPLOYMENT_LIST="<EMPTY>"
TARGET_DEPLOYMENT="<EMPTY>"
TARGET_DEPLOYMENT_NS="<EMPTY>"
AUTH_APPROACH="${AUTH_APPROACH_BASIC}"
TARGET_CRED_SECRET_NAME="<EMPTY>"
TARGET_TURBODIF_CONFIG_NAME="<EMPTY>"
TARGET_SERVER="<EMPTY>"
BASIC_USERNAME="<EMPTY>"
BASIC_PASSWORD="<EMPTY>"
OAUTH_CLIENT_ID="<EMPTY>"
OAUTH_SECRET="<EMPTY>"

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
            --kubeconfig) shift; KUBECONFIG="$1"; [ -n "${KUBECONFIG}" ] && shift;;
            -*) echo "ERROR: Unknown option $1" >&2; usage; exit 1;;
            *) shift;;
        esac
    done

    if [ -n "${KUBECONFIG}" ]; then
        KUBECTL="${KUBECTL} --kubeconfig=${KUBECONFIG}"
    fi
}

# Function to describe how to use this script
usage() {
   echo "This program helps to migrate Prometurbo to use OAuth connection method"
   echo "Syntax: ./$0 [flags] [args]"
   echo
   echo "args:"
   echo "<Prometurbo name>  Optional name fragment to scope down Prometurbo targets (default ${DEFAULT_PROMETURBO_DEPLOYMENT})"
   echo
   echo "flags:"
   echo "-h --help             Print out the usage message"
   echo "--kubeconfig <VAL>    Path to the kubeconfig file to use for kubectl requests"
   echo
}

# Main logic
main() {
    deployment_name=${1:-"${DEFAULT_PROMETURBO_DEPLOYMENT}"}

    # Get client's concent to work with the current cluster
    confirm_installation_cluster

    # Scan through the entire cluster for the prometurbo deployment type
    scan_pt_deployments "${deployment_name}"

    # List all existing Prometurbo deployments that need to migrate and ask for the target deployment
    choose_deployment "${DEPLOYMENT_LIST}"

    # Validate if the selected target is able to migrate
    validate_target "${TARGET_DEPLOYMENT_NS}" "${TARGET_DEPLOYMENT}"

    # Start to migrate the prometurbo deployment
    migrate_deployment

    # Migration completed
    echo "Migration is done. Prometurbo should be running with OAuth2 credentials."
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
    # exit if the current context is not set
    if ! current_context=$(${KUBECTL} config current-context); then
        echo "ERROR: Current context is not set in your cluster!"
        exit 1
    fi

    # get detail from the raw oject
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

    # exit if the current the cluster is not reachable
    if ! ${KUBECTL} get nodes > /dev/null 2>&1; then
        echo "ERROR: Context used by the current cluster is not reachable!"
        exit 1
    fi
}

# Function to scan through Prometurbo deployment in the deploy_ns
scan_pt_deployments() {
    deployment_name=${1:-${DEFAULT_PROMETURBO_DEPLOYMENT}}
    
    echo "Fetching deployment contains '${deployment_name}' in all namespaces..."
    DEPLOYMENT_LIST=$(${KUBECTL} get deploy -A --no-headers --ignore-not-found | grep "${deployment_name}" | awk '{print $1 "," $2}')
    
    # Exit if no deployment was found
    target_count=$(echo "${DEPLOYMENT_LIST}" | wc -l | awk '{print $1}')
    if [ -z "${DEPLOYMENT_LIST}" ] || [ -z "${target_count}" ] || [ "${target_count}" -lt 1 ]; then
        echo "No deployments found with name containing '${deployment_name}'." && exit 0
    fi
}

# Function to present a list of targets and ask user to choose the target one
choose_deployment() {
    deployment_list=${1-${DEPLOYMENT_LIST}}

    target_count=$(echo "${deployment_list}" | wc -l | awk '{print $1}')
    if [ -z "${deployment_list}" ] || [ -z "${target_count}" ] || [ "${target_count}" -lt 1 ]; then
        echo "No deployments found with name containing '${deployment_name}'." && exit 0
    fi

    PS3="Choose a Prometurbo deployment by number to update with the OAuth2 credentials OR type 'exit' to exit: "
    while true; do
        echo "Here are available options:"
        i=1; echo "${deployment_list}" | while IFS= read -r deploy; do
            ns=$(echo "${deploy}" | awk -F',' '{print $1}')
            dp=$(echo "${deploy}" | awk -F',' '{print $2}')
            echo "${i}) Deployment '${dp}' in '${ns}' namespace"
            i=$((i + 1))
        done
        echo "${PS3}" && read -r REPLY
        if validate_select_input "${target_count}" "${REPLY}"; then
            [ "${REPLY}" = 'exit' ] && exit 0
            deployment=$(echo "${deployment_list}" | awk "NR==$((REPLY))")
            break
        fi
    done

    TARGET_DEPLOYMENT_NS=$(echo "${deployment}" | awk -F',' '{print $1}')
    TARGET_DEPLOYMENT=$(echo "${deployment}" | awk -F',' '{print $2}')
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

# Function to verify if the select target is able to migrate
validate_target() {
    deploy_ns=${1:-${TARGET_DEPLOYMENT_NS}}
    deploy=${2:-${TARGET_DEPLOYMENT}}

    validate_deployment "${deploy_ns}" "${deploy}"
    validate_auth_settings "${deploy_ns}" "${deploy}"
}

# Function to validate if the deployment is ready to migrate 
validate_deployment() {
    echo "Validating deployment settings..."
    deploy_ns=${1:-${TARGET_DEPLOYMENT_NS}}
    deploy=${2:-${TARGET_DEPLOYMENT}}

    # check if the deployment is in a running state
    replicas=$(${KUBECTL} -n "${deploy_ns}" get deploy/"${deploy}" --ignore-not-found -o=jsonpath='{.spec.replicas}')
    if [ "${replicas}" -eq 0 ]; then
        echo "The selected Prometurbo target current has the replicas set to ${replicas}"
        echo "Please ensure the Prometurbo target is running before starting the migration"
        exit 1
    fi

    readyReplicas=$(${KUBECTL} -n "${deploy_ns}" get deploy/"${deploy}" --ignore-not-found -o=jsonpath='{.status.readyReplicas}')
    if [ "${readyReplicas}" -eq 0 ]; then
        echo "The selected Prometurbo target current has no available replicas at the moment"
        echo "Please ensure the Prometurbo target is running without errors before starting the migration"
        exit 1
    fi
}

# Function to validate if the current auth settings are valid to migrate or not 
validate_auth_settings() {
    echo "Validating authorization settings..."
    deploy_ns=${1:-${TARGET_DEPLOYMENT_NS}}
    deploy=${2:-${TARGET_DEPLOYMENT}}

    # Make decision based on the current authorization approach
    get_auth_method "${deploy_ns}" "${deploy}"
    if [ "${AUTH_APPROACH}" = "${AUTH_APPROACH_OAUTH}" ]; then
        echo "Migration to OAuth2 credentials already completed, nothing more to do."
        echo "Exiting the script..."
        exit 0
    elif [ "${AUTH_APPROACH}" = "${AUTH_APPROACH_TSC}" ]; then
        echo "The selected Prometurbo instance uses a TSC deployment approach!"
        echo "Please contact support at https://support.ibm.com for further assistance with the migration."
        echo "Abort the migration."
        exit 1
    elif  [ -z "${BASIC_USERNAME}" ] || [ -z "${BASIC_PASSWORD}" ]; then
        echo "The basic authorization approach for deployment ${deploy} is not complete!"
        echo "Please ensure that your turbodif configmap sets the opsManagerUserName and opsManagerPassword values!"
        echo "Abort the migration."
        exit 1
    elif [ -z "${TARGET_SERVER}" ]; then
        echo "Field 'turboServer' not found in ConfigMap '${TARGET_TURBODIF_CONFIG_NAME}'."
        exit 1
    fi
}

# Function to determine what kind of deployment approach the current Prometurbo is using
get_auth_method() {
    deploy_ns=${1:-${TARGET_DEPLOYMENT_NS}}
    deploy=${2:-${TARGET_DEPLOYMENT}}

    # Determine if the existing auth approach is OAuth2 or not
    get_turbo_secret_name_from_deployment "${deploy_ns}" "${deploy}"
    if [ -n "${TARGET_CRED_SECRET_NAME}" ]; then 
        oauth_client_id=$(${KUBECTL} -n "${deploy_ns}" get secret/"${TARGET_CRED_SECRET_NAME}" --ignore-not-found -o=jsonpath='{.data.clientid}')
        oauth_client_secret=$(${KUBECTL} -n "${deploy_ns}" get secret/"${TARGET_CRED_SECRET_NAME}" --ignore-not-found -o=jsonpath='{.data.clientsecret}')
        if [ -n "${oauth_client_id}" ] && [ -n "${oauth_client_secret}" ]; then
            AUTH_APPROACH="${AUTH_APPROACH_OAUTH}"
            return
        fi
    fi

    get_turbo_config_name_from_deployment "${deploy_ns}" "${deploy}"
    if [ -z "${TARGET_TURBODIF_CONFIG_NAME}" ]; then
        echo "ERROR: Configmap object for the turbodif-config volume is not found, please check your settings"
        echo "Abort the migration."
        exit 1
    fi
    
    # Determine if the existing auth approach is TSC or not
    TARGET_SERVER=$(${KUBECTL} -n "${deploy_ns}" get cm/"${TARGET_TURBODIF_CONFIG_NAME}" --ignore-not-found -o=jsonpath="{.data.turbodif-config\.json}" | jq -r ".communicationConfig.serverMeta.turboServer")
    if echo "$TARGET_SERVER" | grep -q ".*/topology-processor"; then
        AUTH_APPROACH="${AUTH_APPROACH_TSC}"
        return
    fi

    TARGET_NAME=$(${KUBECTL} -n "${deploy_ns}" get cm/"${TARGET_TURBODIF_CONFIG_NAME}" --ignore-not-found -o=jsonpath="{.data.turbodif-config\.json}" | jq -r ".targetConfig.targetName")
    BASIC_USERNAME=$(${KUBECTL} -n "${deploy_ns}" get cm/"${TARGET_TURBODIF_CONFIG_NAME}" --ignore-not-found -o=jsonpath="{.data.turbodif-config\.json}" | jq -r ".communicationConfig.restAPIConfig.opsManagerUserName")
    BASIC_PASSWORD=$(${KUBECTL} -n "${deploy_ns}" get cm/"${TARGET_TURBODIF_CONFIG_NAME}" --ignore-not-found -o=jsonpath="{.data.turbodif-config\.json}" | jq -r ".communicationConfig.restAPIConfig.opsManagerPassword")
    AUTH_APPROACH="${AUTH_APPROACH_BASIC}"
}

# Function to extract turbo secret that binds to the deployment
get_turbo_secret_name_from_deployment() {
    deploy_ns=${1:-${TARGET_DEPLOYMENT_NS}}
    deploy=${2:-${TARGET_DEPLOYMENT}}
    TARGET_CRED_SECRET_NAME=$(${KUBECTL} -n "${deploy_ns}" get deploy/"${deploy}" -o=jsonpath='{.spec.template.spec.volumes[?(@.name == "'"${DEFAULT_CREDENTIAL_VOLUME_NAME}"'")].secret.secretName}')
}

# Function to extract turbo config map that binds to the deployment
get_turbo_config_name_from_deployment() {
    deploy_ns=${1:-${TARGET_DEPLOYMENT_NS}}
    deploy=${2:-${TARGET_DEPLOYMENT}}
    TARGET_TURBODIF_CONFIG_NAME=$(${KUBECTL} -n "${deploy_ns}" get deploy/"${deploy}" -o=jsonpath='{.spec.template.spec.volumes[?(@.name == "'"${DEFAULT_TURBODIF_VOLUME_NAME}"'")].configMap.name}')
}

# Function to migrate a specific Prometurbo target
migrate_deployment() {
    # Register current target as new OAuth client and verify if the token works
    register_oauth2_client "${TARGET_SERVER}" "${BASIC_USERNAME}" "${BASIC_PASSWORD}"

    # Using the generated client id and secret to recreate secret turbonomic-credentials
    create_k8s_secret "${TARGET_DEPLOYMENT_NS}" "${OAUTH_CLIENT_ID}" "${OAUTH_SECRET}"

    # If the deployment is not patched with the secret then patch the volume
    patch_deployment_with_secret "${TARGET_DEPLOYMENT_NS}" "${TARGET_DEPLOYMENT}"

    # Wait until the pod is ready
    wait_for_deployment "${TARGET_DEPLOYMENT_NS}" "${TARGET_DEPLOYMENT}"
}

# Register current target as a oauth2 target
register_oauth2_client() {
    target_host=${1:-"${TARGET_SERVER}"}
    username=${2:-${BASIC_USERNAME}}
    password=${3:-${BASIC_PASSWORD}}
    target_name=${TARGET_NAME:-"Prometurbo"}

    echo "Registering new OAuth client..."
    auth_cookie_jar=$(mktemp -t xl.cookie)

    # Get the auth cookie for later API requests
    curl -ks -X 'POST' "${target_host}/api/v3/login?disable_hateoas=true" \
        --cookie-jar "${auth_cookie_jar}" \
        -H "accept: application/json" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "username=${username}&password=${password}" > /dev/null

    client_request_data=$(echo \
        '{
            "clientName": "<CLIENT_NAME>",
            "grantTypes": ["client_credentials"],
            "clientAuthenticationMethods": ["client_secret_post"],
            "scopes": ["role:PROBE_ADMIN"],
            "tokenSettings": {"accessToken": {"ttlSeconds": 600}}
        }' | sed -e "s/<CLIENT_NAME>/${client-${target_name}}/g"
    )

    oauth_post_response=$(curl -ks -w "%{http_code}" -X 'POST' "${target_host}/vmturbo/rest/authorization/oauth2/clients" \
        -b "${auth_cookie_jar}" \
        -H 'accept: application/json' \
        -H 'Content-Type: application/json' \
        -d "${client_request_data}"
    )

    # Check if the request was successful
    status_code=$(printf "%s" "${oauth_post_response}" | tail -c 3)
    if [ "${status_code}" -ne 200 ]; then
        echo "ERROR: Failed to create the OAuth2 client: ${oauth_post_response}"
        echo "Please check if your oauth2 setting is turned on."
        exit 1
    fi

    oauth_post_response=$(printf "%s" "${oauth_post_response}" | cut -c1-$((${#oauth_post_response}-3)))
    OAUTH_CLIENT_ID=$(echo "${oauth_post_response}" | jq -r '.clientId')
    OAUTH_SECRET=$(echo "${oauth_post_response}" | jq -r '.clientSecret')

    rm "${auth_cookie_jar}"

    request_token_with_client_info "${target_host}" "${OAUTH_CLIENT_ID}" "${OAUTH_SECRET}"
}

# Function to test if the oauth secret and id works or not
request_token_with_client_info() {
    echo "Verifying connection to the new OAuth client..."
    target_host=${1:-"${TARGET_SERVER}"}
    client_id=${2:-${OAUTH_CLIENT_ID}}
    client_secret=${3:-${OAUTH_SECRET}}

    # if id and secret are invalid, exit the program
    if [ -z "${client_id}" ] || [ -z "${client_secret}" ]; then
        echo "ERROR: Failed to request token with the client secret and id" >&2 && exit 1
    fi

    oauth_client_uri="${target_host}/oauth2/token"
    general_request_data="grant_type=client_credentials&scope=role:PROBE_ADMIN&audience=turbonomic"

    response=$(curl -X POST -ks "${oauth_client_uri}" \
        -d "client_id=${client_id}&client_secret=${client_secret}&${general_request_data}")

    OAUTH_TOKEN=$(echo "${response}" | jq -r ".access_token")
    if [ -z "${OAUTH_TOKEN}" ]; then
        echo "ERROR: Failed to request token with the client secret and id" >&2 && exit 1
    fi
}

# Function to create turbonomic-credentials secret with client id/secret
create_k8s_secret() {
    namespace=${1:-"${TARGET_DEPLOYMENT_NS}"}
    client_id=${2:-"${OAUTH_CLIENT_ID}"}
    client_secret=${3:-"${OAUTH_SECRET}"}
    secret_name=${TARGET_CRED_SECRET_NAME:-"${DEFAULT_TARGET_CRED_SECRET_NAME}"}

    # Delete the existing turbo secret
    if [ -n "${secret_name}" ]; then
        echo "Delete old '${secret_name}' exists in namespace '${namespace}'"
        ${KUBECTL} -n "${namespace}" delete secret "${secret_name}" >/dev/null 2>&1
    fi

    # Create the secret using kubectl
    ${KUBECTL} create secret generic "${secret_name}" \
        --namespace="${namespace}" \
        --from-literal="clientid=${client_id}" \
        --from-literal="clientsecret=${client_secret}" >/dev/null 2>&1

    # Check if the secret was created successfully
    if ! ${KUBECTL} -n "${deploy_ns}" get secret/"${secret_name}" >/dev/null 2>&1; then
        echo "Failed to create the secret."
        exit 1
    fi

    echo "Secret '${secret_name}' created successfully in namespace '${namespace}'."
}

# Function to patch the Prometurbo deployment with the secret and mount the secret as a volume
patch_deployment_with_secret() {
    deploy_ns=${1:-${TARGET_DEPLOYMENT_NS}}
    deploy=${2:-${TARGET_DEPLOYMENT}}
    secret_name=${TARGET_CRED_SECRET_NAME:-"${DEFAULT_TARGET_CRED_SECRET_NAME}"}

    # Return if the turbo secret already mounted in the deployment
    if is_turbo_secret_mounted "${deploy_ns}" "${deploy}"; then
        restart_deployment "${deploy_ns}" "${deploy}"
        return
    fi

    # Get turbodif container index
    turbodif_cnt_index=$(${KUBECTL} -n "${deploy_ns}" get deployment/"${deploy}" -o=jsonpath='{.spec.template.spec.containers}' | jq -r '. | map(.name == "'${DEFAULT_TURBODIF_CNT_NAME}'") | index(true)')
    if [ -z "${turbodif_cnt_index}" ] || [ "${turbodif_cnt_index}" = "null" ]; then
        echo "ERROR: ${DEFAULT_TURBODIF_CNT_NAME} container is missing in your '${deploy}' deployment"
        echo "Please make sure the '${deploy}' deployment is configured correctly before proceed to migration"
        exit 1
    fi


    # Patch the deployment with the secret volume mounts
    echo "Patching secret '${secret_name}'to the deployment '${deploy}'"
    if [ -z "${TARGET_CRED_SECRET_NAME}" ]; then
        # Patch both Volume and volume mount
		cat <<-EOF | ${KUBECTL} patch deployment "${deploy}" -n "${deploy_ns}" --type=json --patch "$(cat)" >/dev/null 2>&1
		[
		    {
		        "op": "add",
		        "path": "/spec/template/spec/volumes/-",
		        "value": {
		            "name": "${DEFAULT_CREDENTIAL_VOLUME_NAME}",
		            "secret": {
		                "secretName": "${secret_name}",
		                "defaultMode": 420,
		                "optional": true
		            }
		        }
		    },
		    {
		        "op": "add",
		        "path": "/spec/template/spec/containers/${turbodif_cnt_index}/volumeMounts/-",
		        "value": {
		            "name": "${DEFAULT_CREDENTIAL_VOLUME_NAME}",
		            "mountPath": "/etc/turbonomic-credentials",
		            "readOnly": true
		        }
		    }
		]
		EOF
    else
        # Patch VolumeMount since the volume is already exists
        cat <<-EOF | ${KUBECTL} patch deployment "${deploy}" -n "${deploy_ns}" --type=json --patch "$(cat)"
		[
		    {
		        "op": "add",
		        "path": "/spec/template/spec/containers/${turbodif_cnt_index}/volumeMounts/-",
		        "value": {
		            "name": "${DEFAULT_CREDENTIAL_VOLUME_NAME}",
		            "mountPath": "/etc/turbonomic-credentials",
		            "readOnly": true
		        }
		    }
		]
		EOF
    fi
}

# Function to determine if the turbonomic-credentials is binding to the Prometurbo deployment
is_turbo_secret_mounted() {
    deploy_ns=${1:-${TARGET_DEPLOYMENT_NS}}
    deploy=${2:-${TARGET_DEPLOYMENT}}

    # No volume mounted in the container
    is_volume_mounted=$(${KUBECTL} -n "${deploy_ns}" get deployment/"${deploy}" -o=jsonpath='{.spec.template.spec.containers[?(@.name == "'"${DEFAULT_TURBODIF_CNT_NAME}"'")].volumeMounts[?(@.name == "'"${DEFAULT_CREDENTIAL_VOLUME_NAME}"'")]}')
    if [ -z "${is_volume_mounted}" ]; then return 1; fi

    # No volume for turbonomic-credentials
    if [ -z "${TARGET_CRED_SECRET_NAME}" ]; then return 1; fi
}

# Function to restart the deployment
restart_deployment() {
    deploy_ns=${1:-${TARGET_DEPLOYMENT_NS}}
    deploy=${2:-${TARGET_DEPLOYMENT}}
    
    echo "Restarting deployment '${deploy}' to pick up changes..."
    replicas=$(${KUBECTL} -n "${deploy_ns}" get deploy/"${deploy}" --ignore-not-found -o=jsonpath='{.spec.replicas}')
    ${KUBECTL} -n "${deploy_ns}" scale deploy/"${deploy}" --replicas=0 >/dev/null 2>&1
    ${KUBECTL} -n "${deploy_ns}" scale deploy/"${deploy}" --replicas="${replicas}" >/dev/null 2>&1
}

# Function to wait for the deployment to become ready
wait_for_deployment() {
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

################## MAIN ##################
dependencies_check && validate_args "${@}" && main "${@}"
