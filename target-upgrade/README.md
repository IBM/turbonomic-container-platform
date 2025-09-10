# Target Upgrade

The script `upgradeTurboTargets.sh` uses Turbonomic's REST API to upgrade the targets.

This requires that the kubeturbo, prometurbo probes are at least at version 8.17.1 to accept the upgrade request.

Edit this script to provide:

1. The Turbonomic server address.
2. The Turbonomic server administrator credentials.

Please note that this script will not update the operator image if the kubeturbo operator was used to install kubeturbo.
