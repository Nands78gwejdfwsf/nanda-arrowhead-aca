Configuration-driven Phase 3

Source of truth:
  apps/apps.json

Application provisioning:
  - managed identity
  - ACR pull RBAC
  - Entra group/application metadata (Entra itself is reconciled by PowerShell)
  - Key Vault secret access
  - PostgreSQL schema/principal bootstrap
  - Container App
  - Easy Auth
  - Azure Files/private endpoint/DNS/backup when storage.enabled=true
  - ACA Job when job.enabled=true

The existing Modules directory is intentionally preserved. Only modules whose parameter surface had to become configuration-driven were updated:
  acr.bicep
  containerApp.bicep
  containerAppAuth.bicep
  containerAppJob.bicep
  monitoring.bicep

Do not deploy until these pass:
  .\infrastructure\validate-app-config.ps1
  az bicep build --file .\infrastructure\main.bicep --stdout > $null
  az bicep build --file .\infrastructure\runtime.bicep --stdout > $null
  PowerShell parser validation for deploy-lab-fixed-postgres-admin-final.ps1
