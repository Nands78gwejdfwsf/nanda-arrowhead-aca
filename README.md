# Arrowhead ACA CI/CD POC

This repository contains the reproducible Arrowhead Azure Container Apps POC platform: Azure Bicep infrastructure, GitHub Actions CI/CD, rollback, PureOTA/HelixBridge reference applications, managed PostgreSQL connectivity, Azure Files persistence, Key Vault and Entra authentication.

## Authentication model

- Local deployment authentication: **Azure CLI `az login` only**.
- GitHub Actions authentication: **OIDC** using `NANDA-id-github-actions`.
- No GitHub CLI is required.
- No long-lived Azure client secret is required.

## Clean deployment

From the repository root:

```powershell
az login
cd infrastructure
.\deploy-lab.ps1
```

The deployment is intentionally split into two Bicep deployments:

1. **Foundation** — resource group, VNet/subnets, Private DNS, Log Analytics, ACR, Key Vault, PostgreSQL, PostgreSQL private endpoint, Azure Files, storage private endpoint, ACA environment, managed identities, GitHub OIDC identity, Defender and budget.
2. **Runtime** — PureOTA, HelixBridge, PureOTA ACA Job, Easy Auth, scoped Key Vault RBAC and Azure Monitor alerts.

The script also:

- validates both Bicep files before deployment;
- waits for PostgreSQL to become `Ready`;
- creates/reuses the Entra groups and app registrations idempotently;
- grants the GitHub Actions identity **Reader**, **Container Apps Contributor** and **Container Apps Jobs Contributor** at resource-group scope through Bicep;
- bootstraps PostgreSQL Entra roles for the PureOTA and HelixBridge managed identities from inside the VNet-integrated ACA environment;
- creates the shared `arrowhead` database and application schemas;
- removes the temporary PostgreSQL bootstrap Job after successful configuration;
- prints explicit phase/progress messages so a clean rebuild is understandable.

The PostgreSQL bootstrap uses a short-lived Microsoft Entra access token from the signed-in operator. The token is placed only in a temporary ACA Job secret, is not written to source, and the Job is deleted after bootstrap.

## Database connectivity

The ACR does **not** connect to PostgreSQL. ACR stores container images and is accessed by ACA using the application/job managed identities.

The database path is:

```text
PureOTA ACA App
   -> NANDA-id-pureota
   -> Microsoft Entra token
   -> Private PostgreSQL endpoint
   -> arrowhead database / pureota schema

HelixBridge ACA App
   -> NANDA-id-helixbridge
   -> Microsoft Entra token
   -> Private PostgreSQL endpoint
   -> arrowhead database / helixbridge schema

PureOTA ACA Job
   -> NANDA-id-pureota
   -> Microsoft Entra token
   -> Private PostgreSQL endpoint
   -> arrowhead database / pureota schema
```

Both application images perform a real PostgreSQL `SELECT 1` connection check using their user-assigned managed identity before nginx starts. The PureOTA CI/CD Job performs the same check before its normal job validation.

No PostgreSQL password is placed in application environment variables or container images.

## GitHub Actions

Required repository secrets:

- `AZURE_CLIENT_ID`
- `AZURE_TENANT_ID`
- `AZURE_SUBSCRIPTION_ID`

The deployment script prints the GitHub Actions client ID after a clean rebuild so the repository secrets can be updated manually.

The CI/CD flow is:

```text
Git push to main
  -> changed-application detection
  -> build full-SHA image
  -> push to ACR
  -> deploy new ACA revision
  -> keep old revision serving
  -> health gate
  -> production approval
  -> PureOTA Job validation
  -> promote validated revision
```

A manual **Run workflow** is an explicit deployment request and therefore creates a new immutable SHA image/revision for the selected application. A normal push only selects applications whose configured source path changed.

## Rollback

Use `.github/workflows/rollback.yml` to select a previously deployed full Git SHA. The workflow verifies the image/revision and health before assigning 100% traffic to the target revision.

## Security

- ACR admin access is disabled.
- ACA applications/jobs use user-assigned managed identities for ACR pulls.
- GitHub Actions uses OIDC and ACR push permissions.
- Key Vault uses RBAC, soft delete and purge protection.
- PostgreSQL uses private access and Microsoft Entra authentication.
- PostgreSQL application identities are non-admin database roles.
- Application secrets are not committed to source or baked into images.
- The PostgreSQL access token is obtained at runtime from the ACA managed identity endpoint and used only as the transient `psql` password.

## Repository structure

- `infrastructure/` — Bicep modules and clean deployment/cleanup tooling.
- `apps/` — PureOTA and HelixBridge reference applications.
- `.github/workflows/aca-ci-cd.yml` — multi-app CI/CD.
- `.github/workflows/rollback.yml` — controlled rollback.
- `apps/apps.json` — application build/deployment configuration.
- `platform.json` — shared Azure platform identifiers.

## Customer-specific/deferred work

The real PureOTA application, real schema migrations, production workload sizing, PITR restore demonstration, file restore demonstration, secret rotation demonstration, third-app onboarding and final corporate DNS/Cato/SANDC01 integration remain customer acceptance activities when the corresponding production inputs are available.
