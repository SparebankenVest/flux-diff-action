# Flux Diff Action

This GitHub Action compares the current state of your Kubernetes cluster with the desired state defined in your Git repository using Flux.

## Pre-requisite:
- yq
- flux

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

      - name: Run Flux Diff
        uses: your-username/flux-diff-action@v1
        with:
          kubeconfig: ${{ secrets.KUBECONFIG }}
          git-repo-url: ${{ secrets.GIT_REPO_URL }}
```

## Inputs

- `kubeconfig`: The kubeconfig file to access your Kubernetes cluster.
- `git-repo-url`: The URL of your Git repository containing the desired state.

## Outputs

This action does not produce any outputs.

## Example

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

      - name: Run Flux Diff
        uses: your-username/flux-diff-action@v1
        with:
          kubeconfig: ${{ secrets.KUBECONFIG }}
          git-repo-url: ${{ secrets.GIT_REPO_URL }}
```

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.