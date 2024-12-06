# Turbonomic Container Platform

A helm repo for installation of Turbonomic agents kubeturbo and prometurbo in customer owned kubernetes clusters.

## Usage

[Helm](https://helm.sh) must be installed to use the charts.  Please refer to
Helm's [documentation](https://helm.sh/docs) to get started.

Once Helm has been set up, add the repo as follows:
```bash
    helm repo add turbonomic https://ibm.github.io/turbonomic-container-platform/
```

To retrieve the latest versions of the packages:
```bash
    helm repo update
```


To see the available charts and their version numbers: 
```
    helm search repo turbonomic
```


## Example Installation

To install the latest kubeturbo chart:

    helm install my-kubeturbo turbonomic/kubeturbo --namespace {KUBETURBO_NAMESPACE} --create-namespace --set serverMeta.turboServer={TURBOSERVER_URL} --set targetConfig.targetName={CLUSTER_DISPLAY_NAME}

For more settings see the documentation.  
Values for the settings can be set through a `values.yaml` file instead of the command line.

To uninstall the chart:

    helm delete my-kubeturbo
