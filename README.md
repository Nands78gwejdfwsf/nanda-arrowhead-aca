# Arrowhead ACA CI/CD POC

This repository contains the Arrowhead Pharmaceuticals Azure Container Apps POC platform IaC, GitHub Actions CI/CD, rollback workflow, two dummy reference applications (PureOTA and HelixBridge), and clean-redeployment tooling.

## Repository structure

- `infrastructure/` — Azure Bicep modules, deployment, validation and cleanup scripts.
- `apps/` — dummy reference application source and application configuration.
- `.github/workflows/` — CI/CD and rollback workflows.
- `platform.json` — shared platform identifiers used by GitHub Actions.

## Clean deployment lifecycle

### 1. One-time local prerequisites

- Azure CLI + Bicep
- Windows PowerShell
- Azure login: `az login`

Using the authenticated GitHub CLI, the deployment script derives the immutable GitHub OIDC repository subject from GitHub repository metadata. Repository owner/repository numeric IDs are therefore not hard-coded in the IaC.

### 2. Deploy

```powershell
cd infrastructure
.\deploy-lab.ps1
```

The script:

1. Validates Azure CLI/Bicep.
2. Creates the resource group if it is needed for recovery.
3. Recovers `NANDA-kv-aca-test19` if it is soft-deleted.
4. Resolves the GitHub immutable OIDC subject.
5. Deploys the foundation from Bicep, including PostgreSQL creation, private endpoints/DNS, ACA, Azure Files, identities, Key Vault, monitoring and GitHub OIDC.
6. Bootstraps Key Vault and Microsoft Entra configuration.
7. Deploys the runtime resources.
9. Automatically updates the GitHub Actions secrets `AZURE_CLIENT_ID`, `AZURE_TENANT_ID` and `AZURE_SUBSCRIPTION_ID`.
11. Reports success only if validation passes.

The PostgreSQL server is a real Bicep resource; it is not an `existing` reference. This is required for clean-room deployment.

### 3. Validate independently

```powershell
.\validate-deployment.ps1
```

The validation is read-only and checks the major acceptance prerequisites: internal ACA environment, ACR security, Key Vault security, PostgreSQL readiness/private access, Azure Files, ACA apps/jobs/storage binding, GitHub OIDC, Key Vault bootstrap secrets and persistent Azure Files storage.

### 4. Cleanly delete the lab

## GitHub Actions

Required repository secrets:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

`deploy-lab.ps1` updates these automatically after a clean rebuild.

Authentication uses GitHub OIDC; no Azure client secret is stored in GitHub.

Create a GitHub Environment named `production` with the required reviewer approval rule.

The deployment workflow:

1. Builds immutable full-SHA images.
2. Pushes them to ACR.
3. Creates a new ACA revision.
4. Keeps the current revision serving while the new revision is health-gated.
5. Requests production approval.
6. Runs the PureOTA ACA Job when configured.
7. Promotes the validated revision to 100%.
8. Rolls back automatically if deployment health validation fails.

ACA uses an internal VNet-integrated environment. Container App ingress is enabled inside that internal environment so VNet/corporate clients can reach the applications.

## Rollback

Use `ACA Rollback` with the application and full Git commit SHA. The workflow verifies that the target image and corresponding ACA revision exist and are healthy before assigning 100% traffic to that revision.

## Security

Do not commit passwords, client secrets, access tokens, generated deployment outputs, or local environment files. Runtime application secrets are sourced from Azure Key Vault.

The dummy applications are platform bootstrap applications only. Real PureOTA database schema/migrations, workload sizing, concurrent-write validation, PITR restore testing, file restore testing, secret rotation testing and third-application onboarding remain acceptance activities when the real application and customer inputs are available.
