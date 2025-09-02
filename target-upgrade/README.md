# Target Upgrade

The script `upgradeTurboTargets.sh` uses Turbonomic's REST API and requires that the probes are at least at version 8.17.1 to accept the upgrade request.
Edit this script to provide:

1. The server address.
2. The server administrator credentials.

Please note that this script will not update the operator image if the kubeturbo operator was used to install kubeturbo.
