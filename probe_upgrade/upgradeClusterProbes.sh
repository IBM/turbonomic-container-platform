#!/usr/bin/env bash

set -o nounset

##########################################################################################
# VERSION is the version to update to
VERSION=8.17.2
# folder where cluster configurations with admin privileges can be found
CLUSTER_CONFIGS=~/.kube

# Namespace where kubeturbo is deployed
NAMESPACE=turbonomic

# Name of kubeturbo deployment
DEPLOYMENTS=(kubeturbo-release prometurbo-release)

UPGRADE_CMD=./darwin/arm64/upgradeProbe
#UPGRADE_CMD=./linux/amd64/upgradeProbe
##########################################################################################

for clusterConfig in ${CLUSTER_CONFIGS}/*; do
    if [ -f "${clusterConfig}" ]; then
        printf "===> Using cluster config '${clusterConfig}'\n"
        for deployment in ${DEPLOYMENTS[@]}; do
            ${UPGRADE_CMD} -k8s-kubeconfig ${clusterConfig} -namespace ${NAMESPACE} -deployment ${deployment} -tag ${VERSION}
            echo
        done
    fi
done
