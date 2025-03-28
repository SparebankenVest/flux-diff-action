# Flux Diff Action

This GitHub Action compares the current state of your Kubernetes cluster with the desired state defined in your Git repository using Flux.

## Pre-requisite/Assumptions:
- Runner needs access to the cluster that the flux diff is performed against.
- Github flow branching strategy. Aka the Flux diff is done against the main branch in the git repo (`main`).
- Assumes that the gitops repo uses the `/tenant` and `/apps` structure.

## Usage

To use this action, create a workflow file in your repository (e.g., `.github/workflows/flux-diff.yml`):

```yaml
name: Flux Diff

on:
  pull_request:
    branches: [ "main" ]

jobs:
  flux-diff:
    runs-on: ubuntu-latest
    steps:
      - name: Flux Diff
        uses: SparebankenVest/flux-diff-action@main
        id: flux-diff
```
In order for `flux-diff-action` to understand what Flux kustomization it should diff against inside the cluster you need to add the following tags in the `kustomization.yaml` in the folder that the code changes appears. Example:
```
/tenant
/apps
└── /app1
  └── /dev
    ├── kustomization.yaml
    └── app1.yaml
```
E.g. in the given gitops repo structure: If there is a change to `/apps/app1/dev/app1.yaml` flux-diff action will look inside the `/apps/app1/dev/kustomization.yaml` after the header comments `# flux-tenant-name: app1-tenant` and `# flux-tenant-ns: app1-tenant-ns`. That is, the `/apps/app1/dev/kustomization.yaml` needs to look like the following:

```yaml
# flux-tenant-name: app1-tenant
# flux-tenant-ns: app1-tenant-ns
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - app1.yaml
```
If the comments are not provided the action will skip the diffing in this folder.

## Inputs

- **path-filter**: Comma separated string of paths that you want to do flux diff against. Supports glob patterns with wildcard characters (`*` and `**`). E.g. `/some/path/*` or `**/other-path/*` or `/some/path/*,**/other-path/*`. Defaults to `.`
- **autodetect-ingore-tenants**: Flag to enable autodetection of tenants to ignore. Either "true" or "false". Useful when new tenants are applied to the repo, and you dont want the action to fail. It will look for new sync.yaml files in /tenant folder and assumes the sync.yaml contains a `kind: Kustomization` object. The name of that object is used as tenant name.
- **additional-ignore-tenants**: Comma separated string of Flux tenants that you want to ignore. Useful if the tenant do not allready exist in the cluster and you do not want the action to fail.

## Outputs

- **diff-output**: multiline string with diff output

## Example (AZURE OIDC)

Here is an example of how to use this action in a workflow and comment the output back in the PR.
Notice that the workflow is triggered on pull request to `main` (required as flux diff do not handle other branches atm.).
The workflow also uses Azure OIDC authentication where the client ID belongs to a azure managed identity with
federated credentials tied to the repo running the workflow.

```yaml
name: Flux diff
on:
  pull_request:
    branches: [ "main" ]
jobs:
  flux-diff:
    runs-on:
      group: azure-private-runners
    permissions:
      id-token: write # Needed for OIDC
      contents: read  # Needed to read repo content
      pull-requests: write # Needed to write back to PR
    steps:
      - name: Checkout repo
        uses: actions/checkout@v2
        with:
          fetch-depth: 0 # Fetch all content and branches
      - name: Login Azure
        uses: azure/login@v2
        with:
          client-id: ${{ secrets.AZURE_CLIENT_ID }}
          tenant-id: ${{ secrets.AZURE_TENANT_ID }}
          subscription-id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
      - name: Setup kubelogin for non-interactive login
        uses: azure/use-kubelogin@v1
        with:
          kubelogin-version: 'v0.0.24'
      - name: Set AKS context
        uses: azure/aks-set-context@v4
        with:
          resource-group: '<azure-cluster-rg>'
          cluster-name: '<azure-cluster-name>'
          use-kubelogin: true
      - name: Flux diff
        uses: SparebankenVest/flux-diff-action@main
        with:
          path-filter: "some/path/*"
          autodetect-ignore-tenants: "true"
          additional-ignore-tenants: "some-tenant1,other-tenant"
        id: flux-diff
      - name: Show flux diff in PR
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v6
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
          script: |
            const diffOutput = `\`\`\`diff\n${{ steps.flux-diff.outputs.diff-output }}\n\`\`\``;
            await github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: `### Flux Diff\n${diffOutput}`
            });
```

## License

This project is licensed under the MIT License. See the [LICENSE](LICENSE) file for details.