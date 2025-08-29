#!/usr/bin/env bash

set -o nounset

##########################################################################################
# VERSION is the version to update to
VERSION=8.17.2
# list of cluster configurations which have administrator permissions
clusterConfigs=(~/.kube/CLUSTER1.config ~/.kube/CLUSTER2.config ~/.kube/CLUSTER3.config)

# Namespace where kubeturbo is deployed
NAMESPACE=kubeturbo-namespace

# Name of kubeturbo deployment
DEPLOYMENT=kubeturbo-release

UPGRADE_CMD=./darwin/arm64/upgradeProbe
##########################################################################################

for clusterConfig in "${clusterConfigs[@]}"; do
    printf "Using cluster config '${clusterConfig}'\n"
    ${UPGRADE_CMD} -k8s-kubeconfig ${clusterConfig} -namespace ${NAMESPACE} -deployment ${DEPLOYMENT} -tag ${VERSION}
    echo
done
