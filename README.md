# Flux Diff Action

This GitHub Action compares the current state of your Kubernetes cluster with the desired state defined in your Git repository using Flux.

## Pre-requisite:
- Kubeconfig
- Runner needs access to the cluster that the flux diff is performed against.

## Usage

To use this action, create a workflow file in your repository (e.g., `.github/workflows/flux-diff.yml`):

```yaml
name: Flux Diff

on:
  push:
    branches:
      - main

jobs:
  flux-diff:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v2
        with:
          fetch-depth: 0
      - uses: azure/k8s-set-context@v4
        with:
          method: kubeconfig
          kubeconfig: <your kubeconfig>
          context: <context name>
      - name: Run Flux Diff
        uses: your-username/flux-diff-action@v1
```

## Inputs

None

## Outputs

None

## Example (AZURE OIDC)

Here is an example of how to use this action in a workflow:

```yaml
name: Flux Diff Example

on:
  push:
    branches:
      - main

jobs:
  flux-diff:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout repository
        uses: actions/checkout@v2
      - uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - uses: azure/aks-set-context@v4
        with:
          resource-group: '<resource group name>'
          cluster-name: '<cluster name>'
      - name: Run Flux Diff
        uses: your-username/flux-diff-action@v1
```

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.