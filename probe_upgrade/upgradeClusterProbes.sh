#!/usr/bin/env bash

set -o nounset

##########################################################################################
# VERSION is the version to update to
VERSION=8.17.2
# folder where cluster configurations with admin privileges can be found
clusterConfigsFolder=~/.kube

# Namespace where kubeturbo is deployed
NAMESPACE=kubeturbo-namespace

# Name of kubeturbo deployment
DEPLOYMENT=kubeturbo-release

UPGRADE_CMD=./darwin/arm64/upgradeProbe
##########################################################################################

for clusterConfig in ${clusterConfigsFolder}/*; do
    if [ -f "${clusterConfig}" ]; then
        printf "Using cluster config '${clusterConfig}'\n"
        ${UPGRADE_CMD} -k8s-kubeconfig ${clusterConfig} -namespace ${NAMESPACE} -deployment ${DEPLOYMENT} -tag ${VERSION}
        echo
    fi
done
