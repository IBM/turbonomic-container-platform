# Probe Upgrade

These scripts are a starting point to upgrade kubeturbo and prometurbo probes in the customer owned clusters.

The first script `upgradeProbe.sh` can be used directly to target the clusters and upgrade the probes.
The requirement is that the cluster config file provides admin privileges.

Edit this script to provide:

1. The location of the cluster config files.
2. The version to update to.
3. The namespace where kubeturbo deployment is installed.


The second script `upgradeTurboTargets.sh` uses Turbonomic's REST API and requires that the probes are at least at version 8.17.1 to accept the upgrade request.
Edit this script to provide:

1. The server address.
2. The server adminisitrator credentials.
