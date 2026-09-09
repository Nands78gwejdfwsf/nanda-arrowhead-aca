# Arrowhead ACA CI/CD POC

This repository contains the Arrowhead Pharmaceuticals Azure Container Apps POC platform IaC, reusable GitHub Actions CI/CD, rollback workflow, and two dummy reference applications (PureOTA and HelixBridge).

## Repository structure

- `infrastructure/` — Azure platform Bicep modules and deployment script.
- `apps/` — reference application source and application configuration.
- `.github/workflows/` — reusable CI/CD and rollback workflows.
- `platform.json` — shared platform identifiers used by GitHub Actions.

## Platform deployment

Run the foundation/runtime deployment script from `infrastructure/` after authenticating with Azure CLI:

```powershell
cd infrastructure
.\deploy-lab.ps1
```

The script performs Bicep compilation before any Azure deployment. PostgreSQL administrator passwords are supplied as secure runtime input and are not stored in Git.

## GitHub Actions

Required repository secrets:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

Authentication uses GitHub OIDC; no Azure client secret is stored in GitHub.

Create a GitHub Environment named `production` with the required reviewer approval rule. The deployment workflow builds immutable images using the full Git commit SHA, deploys a new ACA revision, validates its health, optionally runs the PureOTA ACA Job, waits for production approval, and then promotes the validated revision.

ACA ingress is kept **internal** by the deployment workflow to match the POC network requirement.

## Rollback

Use `ACA Rollback` with the application and full Git commit SHA. The workflow verifies that the image and corresponding ACA revision exist and are healthy before assigning 100% traffic to that revision.

## Security

Do not commit passwords, client secrets, access tokens, generated deployment outputs, or local environment files. Runtime application secrets are intended to be sourced from Azure Key Vault.
