<#
.SYNOPSIS
Fresh, reusable deployment for the Arrowhead Container Apps POC platform.

.DESCRIPTION
Application onboarding is configuration-driven through apps/apps.json.
The deployment is staged inside one reusable script:
  1. Foundation: shared Azure platform.
  2. Application prerequisites: managed identities, Entra groups/apps and Key Vault secrets/RBAC.
  3. PostgreSQL bootstrap: application managed identities and least-privilege schemas.
  4. Runtime: ACA apps, Easy Auth, Azure Files bindings, optional ACA Jobs and monitoring.

Azure authentication uses Azure CLI/OIDC. No GitHub CLI is required.
#>

[CmdletBinding()]
param(
    [string]$Location = 'westus',
    [string]$ResourceGroupName = 'NANDA-rg-arrowhead-aca-test11',
    [string]$GithubRepository = 'Nands78gwejdfwsf/nanda-arrowhead-aca',
    [string]$NotificationEmail = 'Nandan.NK@Stratogent.com',
    [string]$EntraOperatorObjectId,
    [SecureString]$PostgreSqlPassword,
    [switch]$FoundationOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$FoundationBicep = Join-Path $Root 'main.bicep'
$RuntimeBicep = Join-Path $Root 'runtime.bicep'
$AppsConfigPath = Join-Path $Root '..\apps\apps.json'

# ---------------------------------------------------------------------------
# PLATFORM CONFIGURATION
# These are shared platform resources. Application-specific values belong in
# apps/apps.json and must not be duplicated here.
# ---------------------------------------------------------------------------
$VnetName = 'NANDA-vnet-arrowhead-aca-test11'
$AcaSubnetName = 'NANDA-snet-aca'
$PrivateEndpointSubnetName = 'NANDA-snet-private-endpoint'
$LogAnalyticsWorkspaceName = 'NANDA-law-arrowhead-aca-test'
$AcrName = 'nandaacrarrowheadaca'
$KeyVaultName = 'NANDA-kv-aca-test38'
$PostgreSqlServerName = 'nanda-pg-aca-test'
$StorageAccountName = 'nandastarrowheadaca'
$StorageIdentityName = 'NANDA-id-aca-storage'
$EnvironmentName = 'NANDA-cae-arrowhead-aca-test11'
$GithubIdentityName = 'NANDA-id-github-actions'
$BudgetName = 'NANDA-budget-arrowhead-aca-test'
$AcrPrivateEndpointName = 'NANDA-pe-acr-arrowhead-aca'
$KeyVaultPrivateEndpointName = 'NANDA-pe-keyvault-aca'
$PostgresPrivateEndpointName = 'NANDA-pe-postgresql-aca'
$RecoveryServicesVaultName = 'NANDA-rsv-arrowhead-aca-files12'
$AzureFilesBackupPolicyName = 'NANDA-afs-daily-30d'
$MonitoringActionGroupName = 'NANDA-ag-aca-platform'
$MonthlyBudgetAmount = 100
$PostgresAdminGroupName = 'NANDA-PureOTA-PostgreSQL-Admins'

function Get-AppConfig {
    if (-not (Test-Path -LiteralPath $AppsConfigPath)) { throw "Application configuration not found: $AppsConfigPath" }
    try { $config = Get-Content -LiteralPath $AppsConfigPath -Raw | ConvertFrom-Json }
    catch { throw "apps.json is not valid JSON: $($_.Exception.Message)" }
    if ($null -eq $config.applications) { throw "apps.json must contain an 'applications' object." }

    $apps = @{}
    foreach ($property in $config.applications.PSObject.Properties) {
        $raw = $property.Value
        if (-not [bool]$raw.enabled) { continue }

        if ($null -eq $raw.PSObject.Properties['azure']) { throw "Enabled application '$($property.Name)' is missing the 'azure' object in apps.json." }
        if ([string]::IsNullOrWhiteSpace([string]$raw.azure.managedIdentityName)) { throw "Enabled application '$($property.Name)' has no managed identity name." }
        if ([string]::IsNullOrWhiteSpace([string]$raw.azure.containerAppName)) { throw "Enabled application '$($property.Name)' has no container app name." }
        if ([string]::IsNullOrWhiteSpace([string]$raw.azure.entraGroupName)) { throw "Enabled application '$($property.Name)' has no Entra group name." }
        if ([string]::IsNullOrWhiteSpace([string]$raw.azure.appRegistrationName)) { throw "Enabled application '$($property.Name)' has no Entra application registration name." }
        if ($null -eq $raw.PSObject.Properties['source']) { throw "Enabled application '$($property.Name)' is missing the 'source' object in apps.json." }
        if ($null -eq $raw.PSObject.Properties['runtime']) { throw "Enabled application '$($property.Name)' is missing the 'runtime' object in apps.json." }
        if ($null -eq $raw.PSObject.Properties['database']) { throw "Enabled application '$($property.Name)' is missing the 'database' object in apps.json." }
        if ($null -eq $raw.PSObject.Properties['keyVault']) { throw "Enabled application '$($property.Name)' is missing the 'keyVault' object in apps.json." }
        if ($null -eq $raw.PSObject.Properties['storage']) { throw "Enabled application '$($property.Name)' is missing the 'storage' object in apps.json." }
        if ($null -eq $raw.PSObject.Properties['job']) { throw "Enabled application '$($property.Name)' is missing the 'job' object in apps.json." }

        if ([bool]$raw.database.enabled -and [string]::IsNullOrWhiteSpace([string]$raw.database.databaseName)) {
            throw "Enabled application '$($property.Name)' has database.enabled=true but no databaseName."
        }
        if ([bool]$raw.database.enabled -and [string]::IsNullOrWhiteSpace([string]$raw.database.schemaName)) {
            throw "Enabled application '$($property.Name)' has database.enabled=true but no schemaName."
        }
        if ([bool]$raw.storage.enabled) {
            if ([string]::IsNullOrWhiteSpace([string]$raw.storage.accountName)) { throw "Enabled application '$($property.Name)' has storage enabled but no accountName." }
            if ([string]::IsNullOrWhiteSpace([string]$raw.storage.fileShareName)) { throw "Enabled application '$($property.Name)' has storage enabled but no fileShareName." }
            if ([string]::IsNullOrWhiteSpace([string]$raw.storage.mountPath)) { throw "Enabled application '$($property.Name)' has storage enabled but no mountPath." }
        }
        if ([bool]$raw.job.enabled -and [string]::IsNullOrWhiteSpace([string]$raw.job.jobName)) {
            throw "Enabled application '$($property.Name)' has job.enabled=true but no jobName."
        }

        # Normalize the current apps.json schema to the flat internal shape consumed
        # by the runtime Bicep/modules. This keeps apps.json clean and configuration-driven.
        $readAuthSecret = $true
        if ($null -ne $raw.keyVault.PSObject.Properties['readAuthSecret']) {
            $readAuthSecret = [bool]$raw.keyVault.readAuthSecret
        }
        $readStorageKeySecret = [bool]$raw.storage.enabled
        if ($null -ne $raw.keyVault.PSObject.Properties['readStorageKeySecret']) {
            $readStorageKeySecret = [bool]$raw.keyVault.readStorageKeySecret
        }

        $storageBindingName = ''
        if ([bool]$raw.storage.enabled) {
            $storageBindingName = [string]$raw.storage.fileShareName
            if ($null -ne $raw.storage.PSObject.Properties['bindingName'] -and -not [string]::IsNullOrWhiteSpace([string]$raw.storage.bindingName)) {
                $storageBindingName = [string]$raw.storage.bindingName
            }
        }

        $transport = 'auto'
        if ($null -ne $raw.runtime.PSObject.Properties['ingressTransport'] -and -not [string]::IsNullOrWhiteSpace([string]$raw.runtime.ingressTransport)) {
            $transport = [string]$raw.runtime.ingressTransport
        }

        $app = [ordered]@{
            enabled = $true
            displayName = [string]$raw.displayName
            identity = [ordered]@{ name = [string]$raw.azure.managedIdentityName }
            containerAppName = [string]$raw.azure.containerAppName
            imageName = [string]$raw.source.imageName
            buildContext = [string]$raw.source.buildContext
            dockerfile = [string]$raw.source.dockerfile
            targetPort = [int]$raw.runtime.targetPort
            healthPath = [string]$raw.runtime.healthPath
            minReplicas = [int]$raw.runtime.minReplicas
            maxReplicas = [int]$raw.runtime.maxReplicas
            ingress = [ordered]@{
                external = [bool]$raw.runtime.ingressExternal
                transport = $transport
            }
            entra = [ordered]@{
                groupName = [string]$raw.azure.entraGroupName
                applicationName = [string]$raw.azure.appRegistrationName
                redirectPath = '/.auth/login/aad/callback'
            }
            keyVault = [ordered]@{
                authSecretName = [string]$raw.keyVault.authSecretName
                storageKeySecretName = [string]$raw.keyVault.storageKeySecretName
                readAuthSecret = $readAuthSecret
                readStorageKeySecret = $readStorageKeySecret
            }
            postgres = [ordered]@{
                enabled = [bool]$raw.database.enabled
                databaseName = [string]$raw.database.databaseName
                schemaName = [string]$raw.database.schemaName
            }
            storage = [ordered]@{
                enabled = [bool]$raw.storage.enabled
                accountName = [string]$raw.storage.accountName
                fileShareName = [string]$raw.storage.fileShareName
                bindingName = $storageBindingName
                mountPath = [string]$raw.storage.mountPath
            }
            job = [ordered]@{
                enabled = [bool]$raw.job.enabled
                jobName = [string]$raw.job.jobName
                command = [string]$raw.job.command
            }
        }

        $apps[$property.Name] = [pscustomobject]$app
    }

    if ($apps.Count -eq 0) { throw 'apps.json contains no enabled applications.' }
    return $apps
}

if ($FoundationOnly) {
    $Apps = @{}
} else {
    $Apps = Get-AppConfig
}

if (-not $FoundationOnly) {
    $enabledApplications = @($Apps.GetEnumerator() | Where-Object { $_.Value.enabled } | ForEach-Object { [ordered]@{ key = $_.Key; value = $_.Value } })
    $storageApplications = @($Apps.GetEnumerator() | Where-Object { $_.Value.enabled -and $_.Value.storage.enabled } | ForEach-Object { [ordered]@{ key = $_.Key; value = $_.Value } })
    $jobApplications = @($Apps.GetEnumerator() | Where-Object { $_.Value.enabled -and $_.Value.job.enabled } | ForEach-Object { [ordered]@{ key = $_.Key; value = $_.Value } })
    $authApplications = @($Apps.GetEnumerator() | Where-Object { $_.Value.enabled -and $_.Value.keyVault.readAuthSecret } | ForEach-Object { [ordered]@{ key = $_.Key; value = $_.Value } })
    $storageApps = @($Apps.GetEnumerator() | Where-Object { $_.Value.enabled -and $_.Value.storage.enabled })
    $postgresApps = @($Apps.GetEnumerator() | Where-Object { $_.Value.enabled -and $_.Value.postgres.enabled })
}

$storageKey = $null
$plainPassword = $null
$PostgreSqlPassword = $null
$operatorId = $null
$githubRepositorySubjectPrefix = $null

function Write-Step([string]$Message) {
    Write-Host "`n============================================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Assert-AzCli {
    if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
        throw 'Azure CLI is not installed or is not in PATH.'
    }

    $bicepVersion = az bicep version 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Installing/updating the Azure CLI Bicep extension...' -ForegroundColor Yellow
        az bicep install --only-show-errors
        if ($LASTEXITCODE -ne 0) { throw 'Azure CLI Bicep installation failed.' }
    }
}

function Assert-BicepCompilation {
    Write-Step 'Validate Bicep before deployment'

    az bicep build --file $FoundationBicep --stdout --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Foundation Bicep compilation failed. No Azure resources were deployed.'
    }

    az bicep build --file $RuntimeBicep --stdout --only-show-errors | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw 'Runtime Bicep compilation failed. No Azure resources were deployed.'
    }
}

function Assert-AzureLogin {
    $account = az account show --only-show-errors --output json 2>$null
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure CLI is not logged in. Run az login first.'
    }
    return ($account | ConvertFrom-Json)
}


function Ensure-ResourceGroupForRecovery {
    $exists = az group exists --name $ResourceGroupName --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw 'Could not determine whether the resource group exists.'
    }

    if ($exists -ne 'true') {
        Write-Step 'Prepare Resource Group for recoverable resources'
        az group create `
            --name $ResourceGroupName `
            --location $Location `
            --only-show-errors `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create resource group '$ResourceGroupName'."
        }
    }
}


function Get-GitHubRepositorySubjectPrefix {
    Write-Step 'Set GitHub OIDC repository subject'

    # GitHub Actions currently presents the immutable repository subject in this form:
    # repo:OWNER@OWNER-ID/REPOSITORY@REPOSITORY-ID
    # Keep these values as deployment inputs; GitHub CLI is not required.
    $owner, $repository = $GithubRepository.Split('/', 2)

    if ($owner -ne 'Nands78gwejdfwsf' -or $repository -ne 'nanda-arrowhead-aca') {
        throw "This POC is configured for GitHub repository 'Nands78gwejdfwsf/nanda-arrowhead-aca'. Received '$GithubRepository'."
    }

    $prefix = 'Nands78gwejdfwsf@194785632/nanda-arrowhead-aca@1357384545'
    Write-Host "GitHub OIDC subject prefix: repo:$prefix" -ForegroundColor Green
    return $prefix
}

function Get-OperatorObjectId {
    if (-not [string]::IsNullOrWhiteSpace($EntraOperatorObjectId)) {
        return $EntraOperatorObjectId.Trim()
    }

    $id = az ad signed-in-user show --query id -o tsv --only-show-errors 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($id)) {
        return $id.Trim()
    }

    throw 'Could not determine the signed-in Entra user object ID. Re-run with -EntraOperatorObjectId <object-id>.'
}

function New-DeploymentParameterFile([hashtable]$Values) {
    $file = Join-Path $env:TEMP ("arrowhead-deployment-" + [guid]::NewGuid().ToString('N') + '.json')
    $parameterObject = @{ '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'; contentVersion = '1.0.0'; parameters = @{} }
    foreach ($key in $Values.Keys) { $parameterObject.parameters[$key] = @{ value = $Values[$key] } }
    $parameterObject | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $file -Encoding utf8
    return $file
}

function Invoke-FoundationDeployment([string]$Password) {
    Write-Step 'PHASE 1 - Deploy Foundation'
    Write-Host 'Deploying shared platform only: network, logging, ACR, Key Vault, PostgreSQL, private connectivity, ACA environment, GitHub OIDC and platform monitoring dependencies...' -ForegroundColor Yellow

    $parameterFile = New-DeploymentParameterFile -Values @{}
    try {
        az deployment sub create `
            --location $Location `
            --template-file $FoundationBicep `
            --parameters "@$parameterFile" `
            --parameters `
                resourceGroupName=$ResourceGroupName `
                githubRepositorySubjectPrefix=$githubRepositorySubjectPrefix `
                postgresqlAdministratorLoginPassword=$Password `
                notificationEmail=$NotificationEmail `
                monthlyBudgetAmount=$MonthlyBudgetAmount `
                budgetStartDate=$budgetStartDate `
                vnetName=$VnetName `
                acaSubnetName=$AcaSubnetName `
                privateEndpointSubnetName=$PrivateEndpointSubnetName `
                logAnalyticsWorkspaceName=$LogAnalyticsWorkspaceName `
                acrName=$AcrName `
                keyVaultName=$KeyVaultName `
                postgresqlServerName=$PostgreSqlServerName `
                storageAccountName=$StorageAccountName `
                containerAppsEnvironmentName=$EnvironmentName `
                githubIdentityName=$GithubIdentityName `
                storageIdentityName=$StorageIdentityName `
                budgetName=$BudgetName `
acrPrivateEndpointName=$AcrPrivateEndpointName `
keyVaultPrivateEndpointName=$KeyVaultPrivateEndpointName `
postgresPrivateEndpointName=$PostgresPrivateEndpointName `
            --only-show-errors `
            --output none
        if ($LASTEXITCODE -ne 0) { throw 'Foundation Bicep deployment failed.' }
    }
    finally {
        Remove-Item -LiteralPath $parameterFile -Force -ErrorAction SilentlyContinue
    }

    for ($attempt = 1; $attempt -le 36; $attempt++) {
        $state = az postgres flexible-server show --resource-group $ResourceGroupName --name $PostgreSqlServerName --query state -o tsv --only-show-errors 2>$null
        if ($LASTEXITCODE -eq 0 -and $state -eq 'Ready') { Write-Host 'PostgreSQL is Ready.' -ForegroundColor Green; return }
        Write-Host "Waiting for PostgreSQL to become Ready... attempt $attempt/36 (state=$state)" -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    }
    throw 'PostgreSQL did not reach Ready state after foundation deployment.'
}

function Invoke-RuntimeDeployment(
    [string]$PostgresAdminGroupId,
    [hashtable]$EntraMetadata
) {
    Write-Step 'PHASE 4 - Deploy Application Runtime'
    Write-Host 'Deploying configured ACA applications, Easy Auth, Azure Files bindings, optional ACA Jobs and monitoring...' -ForegroundColor Yellow

    $parameterFile = New-DeploymentParameterFile -Values @{
        enabledApplications = $enabledApplications
        storageApplications = $storageApplications
        jobApplications = $jobApplications
        authApplications = $authApplications
        entraMetadata = $EntraMetadata
    }
    try {
        az deployment group create `
            --resource-group $ResourceGroupName `
            --template-file $RuntimeBicep `
            --parameters "@$parameterFile" `
            --parameters `
                location=$Location `
                postgresqlEntraAdministratorObjectId=$PostgresAdminGroupId `
                postgresqlEntraAdministratorName=$PostgresAdminGroupName `
                tenantId=$TenantId `
                notificationEmail=$NotificationEmail `
                acrName=$AcrName `
                keyVaultName=$KeyVaultName `
                postgresqlServerName=$PostgreSqlServerName `
                containerAppsEnvironmentName=$EnvironmentName `
                storageIdentityName=$StorageIdentityName `
                githubIdentityName=$GithubIdentityName `
                logAnalyticsWorkspaceName=$LogAnalyticsWorkspaceName `
                monitoringActionGroupName=$MonitoringActionGroupName `
            --only-show-errors `
            --output none
        if ($LASTEXITCODE -ne 0) { throw 'Runtime Bicep deployment failed.' }
    }
    finally {
        Remove-Item -LiteralPath $parameterFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-StorageKey([string]$StorageAccountName) {
    $key = az storage account keys list `
        --resource-group $ResourceGroupName `
        --account-name $StorageAccountName `
        --query '[0].value' -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($key)) { throw "Could not retrieve the Azure Files storage account key '$StorageAccountName'." }
    return $key.Trim()
}

function Ensure-KeyVaultSecret([string]$Name, [string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Cannot write Key Vault secret '$Name' because the secret value is empty."
    }

    $Value = $Value.Trim()

    az keyvault secret set `
        --vault-name $KeyVaultName `
        --name $Name `
        --value $Value `
        --only-show-errors `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to write Key Vault secret '$Name'."
    }
}

function Ensure-KeyVaultSecretAccess([string]$PrincipalId, [string]$SecretName) {
    if ([string]::IsNullOrWhiteSpace($PrincipalId)) { throw "Cannot assign Key Vault access because the principal ID is empty." }
    if ([string]::IsNullOrWhiteSpace($SecretName)) { throw "Cannot assign Key Vault access because the secret name is empty." }

    $vaultId = az keyvault show `
        --name $KeyVaultName `
        --resource-group $ResourceGroupName `
        --query id `
        -o tsv `
        --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vaultId)) {
        throw "Could not retrieve Key Vault '$KeyVaultName' resource ID."
    }

    $scope = "$vaultId/secrets/$SecretName"
    $secretRoleId = '4633458b-17de-408a-b874-0445c86b69e6' # Key Vault Secrets User
    $existing = @(az role assignment list `
        --scope $scope `
        --assignee-object-id $PrincipalId `
        --role $secretRoleId `
        --query '[].id' `
        -o tsv `
        --only-show-errors)

    if ($LASTEXITCODE -ne 0) {
        throw "Could not check Key Vault access for secret '$SecretName'."
    }

    if ($existing.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$existing[0])) {
        Write-Host "Key Vault Secrets User already assigned for '$SecretName'." -ForegroundColor Green
        return
    }

    az role assignment create `
        --assignee-object-id $PrincipalId `
        --assignee-principal-type ServicePrincipal `
        --role 'Key Vault Secrets User' `
        --scope $scope `
        --only-show-errors `
        --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to grant Key Vault Secrets User access to secret '$SecretName'."
    }
    Write-Host "Granted Key Vault Secrets User access to '$SecretName'." -ForegroundColor Green
}

function Ensure-KeyVaultOperatorAccess([string]$OperatorId) {
    Write-Step 'PHASE 2 - Grant Temporary Key Vault Bootstrap Access'

    $roleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7' # Key Vault Secrets Officer
    $vaultId = az keyvault show --name $KeyVaultName --resource-group $ResourceGroupName --query id -o tsv --only-show-errors

    $existing = az role assignment list --scope $vaultId --assignee-object-id $OperatorId --role $roleId --query '[0].id' -o tsv --only-show-errors
    if ([string]::IsNullOrWhiteSpace($existing)) {
        az role assignment create `
            --assignee-object-id $OperatorId `
            --assignee-principal-type User `
            --role $roleId `
            --scope $vaultId `
            --only-show-errors `
            --output none
        if ($LASTEXITCODE -ne 0) { throw 'Failed to grant temporary Key Vault Secrets Officer access.' }
    }
}

function Ensure-EntraGroup([string]$DisplayName, [string]$MailNickname, [string]$OperatorId) {

    $groupId = az ad group list `
        --display-name $DisplayName `
        --query '[0].id' `
        -o tsv `
        --only-show-errors

    if ([string]::IsNullOrWhiteSpace($groupId)) {

        $groupId = az ad group create `
            --display-name $DisplayName `
            --mail-nickname $MailNickname `
            --query id `
            -o tsv `
            --only-show-errors

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($groupId)) {
            throw "Failed to create Entra group '$DisplayName'."
        }

        Write-Host "Created Entra security group '$DisplayName'." -ForegroundColor Green
    }
    else {
        Write-Host "Entra security group '$DisplayName' already exists." -ForegroundColor Green
    }

    # Make the deployment idempotent.
    # Only add the operator if the user is not already a member.
    $isMember = az ad group member check `
        --group $groupId `
        --member-id $OperatorId `
        --query value `
        -o tsv `
        --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to check membership of operator '$OperatorId' in group '$DisplayName'."
    }

    if ($isMember -ne 'true') {

        az ad group member add `
            --group $groupId `
            --member-id $OperatorId `
            --only-show-errors `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to add operator '$OperatorId' to Entra group '$DisplayName'."
        }

        Write-Host "Added current operator to '$DisplayName'." -ForegroundColor Green
    }
    else {
        Write-Host "Current operator is already a member of '$DisplayName'." -ForegroundColor Green
    }

    return $groupId.Trim()
}

function Ensure-AppManagedIdentity([string]$IdentityName) {
    if ([string]::IsNullOrWhiteSpace($IdentityName)) {
        throw 'Managed identity name cannot be empty.'
    }

    $principalId = az identity show `
        --resource-group $ResourceGroupName `
        --name $IdentityName `
        --query principalId `
        -o tsv `
        --only-show-errors 2>$null

    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($principalId)) {
        Write-Host "Managed identity '$IdentityName' already exists." -ForegroundColor Green
        return $principalId.Trim()
    }

    Write-Host "Creating managed identity '$IdentityName'..." -ForegroundColor Yellow
    $principalId = az identity create `
        --resource-group $ResourceGroupName `
        --name $IdentityName `
        --query principalId `
        -o tsv `
        --only-show-errors

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($principalId)) {
        throw "Failed to create managed identity '$IdentityName'."
    }

    Write-Host "Managed identity '$IdentityName' created." -ForegroundColor Green
    return $principalId.Trim()
}

function Ensure-EntraApplication(
    [string]$DisplayName,
    [string]$RedirectUri,
    [string]$SecretName,
    [string]$GroupId,
    [string]$OperatorId
) {
    Write-Host "Preparing Entra application: $DisplayName" -ForegroundColor Yellow

    $clientId = az ad app list `
        --display-name $DisplayName `
        --query '[0].appId' `
        -o tsv `
        --only-show-errors

    if ([string]::IsNullOrWhiteSpace($clientId)) {
        $clientId = az ad app create `
            --display-name $DisplayName `
            --sign-in-audience AzureADMyOrg `
            --query appId `
            -o tsv `
            --only-show-errors

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($clientId)) {
            throw "Failed to create Entra app '$DisplayName'."
        }
    }

    az ad app update `
        --id $clientId `
        --enable-id-token-issuance true `
        --web-redirect-uris $RedirectUri `
        --only-show-errors `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to configure redirect URI for '$DisplayName'."
    }

    $spId = az ad sp list `
        --filter "appId eq '$clientId'" `
        --query '[0].id' `
        -o tsv `
        --only-show-errors

    if ([string]::IsNullOrWhiteSpace($spId)) {
        az ad sp create `
            --id $clientId `
            --only-show-errors `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to create enterprise application for '$DisplayName'."
        }

        # Service principal creation can take a few seconds to become queryable.
        for ($attempt = 1; $attempt -le 12; $attempt++) {
            Start-Sleep -Seconds 5

            $spId = az ad sp list `
                --filter "appId eq '$clientId'" `
                --query '[0].id' `
                -o tsv `
                --only-show-errors

            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($spId)) {
                break
            }

            Write-Host "Waiting for Enterprise Application provisioning... attempt $attempt/12" -ForegroundColor Yellow
        }

        if ([string]::IsNullOrWhiteSpace($spId)) {
            throw "Enterprise application '$DisplayName' was created but its service principal could not be retrieved."
        }
    }

    # Require explicit assignment to the dedicated group.
    # Use a temporary JSON file for Graph request bodies. This avoids PowerShell/Azure CLI
    # quoting problems when JSON is passed directly through --body.
    $requestBodyFile = Join-Path $env:TEMP ("arrowhead-graph-" + [guid]::NewGuid().ToString('N') + ".json")

    try {
        $assignmentRequiredBody = '{"appRoleAssignmentRequired":true}'
        [System.IO.File]::WriteAllText(
            $requestBodyFile,
            $assignmentRequiredBody,
            [System.Text.UTF8Encoding]::new($false)
        )

        az rest `
            --method PATCH `
            --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId" `
            --headers Content-Type=application/json `
            --body ("@" + $requestBodyFile) `
            --only-show-errors `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to set assignment requirement for '$DisplayName'. Entra P1+ is required."
        }

        # Assign the dedicated Entra security group to the Enterprise Application.
        # The all-zero appRoleId is valid when the application does not expose
        # a custom app role.
        $assignmentBodyObject = @{
            principalId = $GroupId
            resourceId  = $spId
            appRoleId   = '00000000-0000-0000-0000-000000000000'
        }

        $assignmentBody = $assignmentBodyObject | ConvertTo-Json -Compress

        [System.IO.File]::WriteAllText(
            $requestBodyFile,
            $assignmentBody,
            [System.Text.UTF8Encoding]::new($false)
        )

        # Do not use an OData principalId filter here. Retrieve the assignments
        # and filter locally because that filter is not supported reliably by Graph.
        $existingAssignmentJson = az rest `
            --method GET `
            --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo" `
            --only-show-errors `
            --output json

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to retrieve existing app-role assignments for '$DisplayName'."
        }

        $existingAssignments = $existingAssignmentJson | ConvertFrom-Json

        $groupAlreadyAssigned = $false

        if ($null -ne $existingAssignments -and $null -ne $existingAssignments.value) {
            $groupAlreadyAssigned = @(
                $existingAssignments.value |
                Where-Object {
                    $_.principalId -eq $GroupId
                }
            ).Count -gt 0
        }

        if ($groupAlreadyAssigned) {
            Write-Host "Entra group '$GroupId' is already assigned to '$DisplayName'." -ForegroundColor Green
        }
        else {
            Write-Host "Assigning Entra group to '$DisplayName'..." -ForegroundColor Yellow

            az rest `
                --method POST `
                --url "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignedTo" `
                --headers Content-Type=application/json `
                --body ("@" + $requestBodyFile) `
                --only-show-errors `
                --output none

            if ($LASTEXITCODE -ne 0) {
                throw "Failed to assign '$DisplayName' to its dedicated Entra security group."
            }

            Write-Host "Successfully assigned Entra group to '$DisplayName'." -ForegroundColor Green
        }
    }
    finally {
        if (Test-Path $requestBodyFile) {
            Remove-Item $requestBodyFile -Force -ErrorAction SilentlyContinue
        }
    }

    # Only create a secret if the named secret is not already in Key Vault.
    $existingSecret = az keyvault secret list `
        --vault-name $KeyVaultName `
        --query "[?name=='$SecretName'].name | [0]" `
        -o tsv `
        --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        throw "Could not check whether Key Vault secret '$SecretName' exists."
    }

    if ([string]::IsNullOrWhiteSpace($existingSecret)) {
        Write-Host "Key Vault secret '$SecretName' does not exist. Creating Entra client secret..." -ForegroundColor Yellow

        $credentialPassword = az ad app credential reset `
            --id $clientId `
            --append `
            --display-name 'ACA-KeyVault' `
            --years 1 `
            --query password `
            --output tsv `
            --only-show-errors

        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($credentialPassword)) {
            throw "Entra application '$DisplayName' did not return a client secret. Key Vault was not updated."
        }

        Ensure-KeyVaultSecret -Name $SecretName -Value $credentialPassword
        Write-Host "Key Vault secret '$SecretName' created successfully." -ForegroundColor Green
    }
    else {
        Write-Host "Key Vault secret '$SecretName' already exists. Reusing existing secret." -ForegroundColor Green
    }

    return $clientId.Trim()
}

function Remove-TemporaryKeyVaultOperatorAccess([string]$OperatorId) {
    Write-Step 'Key Vault Bootstrap Cleanup'

    # Cleanup must be safe when Foundation deployment failed before the Key Vault
    # was created. Do not call role-assignment commands with an empty --scope.
    $vaultId = az keyvault show `
        --name $KeyVaultName `
        --resource-group $ResourceGroupName `
        --query id `
        -o tsv `
        --only-show-errors 2>$null

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($vaultId)) {
        Write-Host "Key Vault '$KeyVaultName' does not exist yet. Nothing to clean up." -ForegroundColor Gray
        return
    }

    $roleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
    $assignments = @(az role assignment list `
        --scope $vaultId `
        --assignee-object-id $OperatorId `
        --role $roleId `
        --query '[].id' `
        -o tsv `
        --only-show-errors)

    if ($LASTEXITCODE -ne 0) {
        Write-Host "Could not list temporary Key Vault role assignments. Cleanup will continue." -ForegroundColor Yellow
        return
    }

    foreach ($assignment in $assignments) {
        if (-not [string]::IsNullOrWhiteSpace($assignment)) {
            az role assignment delete --ids $assignment --only-show-errors --output none
        }
    }
}


function Ensure-PostgreSqlEntraAdministrator([string]$AdminGroupId) {
    Write-Step 'PHASE 2 - Configure PostgreSQL Microsoft Entra Administrator'
    Write-Host "Ensuring PostgreSQL '$PostgreSqlServerName' uses the dedicated Entra group '$PostgresAdminGroupName' as its Microsoft Entra administrator." -ForegroundColor Yellow

    if ([string]::IsNullOrWhiteSpace($AdminGroupId)) {
        throw "PostgreSQL administrator Entra group '$PostgresAdminGroupName' does not have a valid object ID."
    }

    $authConfig = az postgres flexible-server show `
        --resource-group $ResourceGroupName `
        --name $PostgreSqlServerName `
        --query authConfig `
        --output json `
        --only-show-errors

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($authConfig)) {
        throw "Could not read PostgreSQL authentication configuration for '$PostgreSqlServerName'."
    }

    $authObject = $authConfig | ConvertFrom-Json
    if ($authObject.activeDirectoryAuth -ne 'Enabled') {
        throw "PostgreSQL '$PostgreSqlServerName' does not have Microsoft Entra authentication enabled. Foundation configuration is inconsistent."
    }

    $adminsJson = az postgres flexible-server microsoft-entra-admin list `
        --resource-group $ResourceGroupName `
        --server-name $PostgreSqlServerName `
        --output json `
        --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        throw "Could not read the Microsoft Entra administrator configured on PostgreSQL '$PostgreSqlServerName'."
    }

    $admins = @()
    if (-not [string]::IsNullOrWhiteSpace($adminsJson)) {
        $parsedAdmins = $adminsJson | ConvertFrom-Json
        if ($null -ne $parsedAdmins) { $admins = @($parsedAdmins) }
    }

    if ($admins.Count -eq 0) {
        Write-Host "No PostgreSQL Microsoft Entra administrator is configured. Creating '$PostgresAdminGroupName' as the administrator..." -ForegroundColor Yellow
        az postgres flexible-server microsoft-entra-admin create `
            --resource-group $ResourceGroupName `
            --server-name $PostgreSqlServerName `
            --display-name $PostgresAdminGroupName `
            --object-id $AdminGroupId `
            --type Group `
            --only-show-errors `
            --output none
        if ($LASTEXITCODE -ne 0) { throw "Failed to configure '$PostgresAdminGroupName' as the PostgreSQL Microsoft Entra administrator." }
    }
    else {
        $currentAdmin = $admins[0]
        $currentObjectId = [string]$currentAdmin.objectId
        $currentDisplayName = ''
        if ($currentAdmin.PSObject.Properties.Name -contains 'displayName') {
            $currentDisplayName = [string]$currentAdmin.displayName
        }
        elseif ($currentAdmin.PSObject.Properties.Name -contains 'administratorName') {
            $currentDisplayName = [string]$currentAdmin.administratorName
        }

        $currentType = ''
        if ($currentAdmin.PSObject.Properties.Name -contains 'administratorType') {
            $currentType = [string]$currentAdmin.administratorType
        }
        # The objectId is the authoritative identity of the configured
        # Microsoft Entra administrator. Azure CLI/API versions can omit or
        # inconsistently populate displayName/administratorType. In particular,
        # do NOT delete/recreate the administrator merely because those optional
        # fields are missing or formatted differently.
        if ($currentObjectId -eq $AdminGroupId) {
            Write-Host "PostgreSQL Microsoft Entra administrator is already configured to '$PostgresAdminGroupName' ($AdminGroupId)." -ForegroundColor Green
        }
        else {
            Write-Host "PostgreSQL has a different Microsoft Entra administrator. Replacing it with '$PostgresAdminGroupName'..." -ForegroundColor Yellow
            if ([string]::IsNullOrWhiteSpace($currentObjectId)) { throw 'PostgreSQL returned an existing Microsoft Entra administrator without an object ID; cannot safely reconcile it.' }
            az postgres flexible-server microsoft-entra-admin delete `
                --resource-group $ResourceGroupName `
                --server-name $PostgreSqlServerName `
                --object-id $currentObjectId `
                --yes `
                --only-show-errors `
                --output none
            if ($LASTEXITCODE -ne 0) { throw "Failed to remove the previous PostgreSQL Microsoft Entra administrator '$currentDisplayName'." }
            az postgres flexible-server microsoft-entra-admin wait `
                --resource-group $ResourceGroupName `
                --server-name $PostgreSqlServerName `
                --object-id $currentObjectId `
                --deleted `
                --interval 10 `
                --timeout 300 `
                --only-show-errors
            if ($LASTEXITCODE -ne 0) { throw 'The previous PostgreSQL Microsoft Entra administrator was not fully removed.' }
            az postgres flexible-server microsoft-entra-admin create `
                --resource-group $ResourceGroupName `
                --server-name $PostgreSqlServerName `
                --display-name $PostgresAdminGroupName `
                --object-id $AdminGroupId `
                --type Group `
                --only-show-errors `
                --output none
            if ($LASTEXITCODE -ne 0) { throw "Failed to configure '$PostgresAdminGroupName' as the PostgreSQL Microsoft Entra administrator." }
        }
    }

    az postgres flexible-server microsoft-entra-admin wait `
        --resource-group $ResourceGroupName `
        --server-name $PostgreSqlServerName `
        --object-id $AdminGroupId `
        --exists `
        --interval 10 `
        --timeout 300 `
        --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "PostgreSQL Microsoft Entra administrator '$PostgresAdminGroupName' did not become ready." }

    $verifiedAdmin = az postgres flexible-server microsoft-entra-admin show `
        --resource-group $ResourceGroupName `
        --server-name $PostgreSqlServerName `
        --object-id $AdminGroupId `
        --output json `
        --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($verifiedAdmin)) { throw 'Could not verify the PostgreSQL Microsoft Entra administrator after configuration.' }
    $verifiedObject = $verifiedAdmin | ConvertFrom-Json
    $verifiedObjectId = ''
    if ($verifiedObject.PSObject.Properties.Name -contains 'objectId') {
        $verifiedObjectId = [string]$verifiedObject.objectId
    }

    $verifiedDisplayName = ''
    if ($verifiedObject.PSObject.Properties.Name -contains 'displayName') {
        $verifiedDisplayName = [string]$verifiedObject.displayName
    }
    elseif ($verifiedObject.PSObject.Properties.Name -contains 'administratorName') {
        $verifiedDisplayName = [string]$verifiedObject.administratorName
    }

    $verifiedType = ''
    if ($verifiedObject.PSObject.Properties.Name -contains 'administratorType') {
        $verifiedType = [string]$verifiedObject.administratorType
    }

    # The Azure CLI Microsoft Entra administrator resource does not reliably return
    # administratorType/displayName on every CLI/API version. The objectId is the
    # authoritative value for reconciliation because it identifies the configured
    # Entra administrator object. Do not fail a valid configuration merely because
    # optional display/type fields are absent.
    if ($verifiedObjectId -ne $AdminGroupId) {
        throw "PostgreSQL Microsoft Entra administrator verification failed for '$PostgresAdminGroupName'. Returned objectId='$verifiedObjectId', expected='$AdminGroupId'."
    }
    Write-Host "PostgreSQL Microsoft Entra administrator verified: $PostgresAdminGroupName ($AdminGroupId)." -ForegroundColor Green
}

function Escape-SqlLiteral([string]$Value) { return $Value.Replace("'", "''") }
function Escape-SqlIdentifier([string]$Value) { return $Value.Replace('"', '""') }

function Ensure-PostgreSqlManagedIdentityAccess([hashtable]$PrincipalIds) {
    Write-Step 'PHASE 3 - Configure PostgreSQL Managed Identity Access'
    Write-Host 'Mapping configured ACA managed identities to PostgreSQL Entra roles and applying least-privilege schema grants.' -ForegroundColor Yellow
    Write-Host 'The bootstrap runs inside the VNet-integrated ACA environment because PostgreSQL public access is disabled.' -ForegroundColor Yellow

    $pgHost = az postgres flexible-server show `
        --resource-group $ResourceGroupName `
        --name $PostgreSqlServerName `
        --query fullyQualifiedDomainName `
        --output tsv `
        --only-show-errors

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($pgHost)) {
        throw 'Could not retrieve the PostgreSQL fully qualified domain name.'
    }

    # Create every configured application MI as a PostgreSQL Entra service principal.
    $roleStatements = New-Object System.Collections.Generic.List[string]
    foreach ($entry in $PrincipalIds.GetEnumerator()) {
        $app = $Apps[$entry.Key]
        $roleName = Escape-SqlIdentifier ([string]$app.identity.name)
        $roleLiteral = Escape-SqlLiteral ([string]$app.identity.name)
        $principalLiteral = Escape-SqlLiteral ([string]$entry.Value)
        $roleStatements.Add("IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$roleLiteral') THEN PERFORM pg_catalog.pgaadauth_create_principal_with_oid('$roleLiteral', '$principalLiteral', 'service', false, false); END IF;")
    }
    $roleSql = "DO `$`$ BEGIN $($roleStatements -join ' ') END `$`$;"

    # Database creation must happen outside a transaction, so the shell script
    # checks/creates each configured database first, then executes grants.
    $databaseSetupLines = New-Object System.Collections.Generic.List[string]
    $databaseNames = @($postgresApps | ForEach-Object { [string]$_.Value.postgres.databaseName } | Select-Object -Unique)
    foreach ($databaseName in $databaseNames) {
        $dbLiteral = Escape-SqlLiteral $databaseName
        $dbIdentifier = Escape-SqlIdentifier $databaseName
        $databaseSetupLines.Add(('echo "Checking {0} database..."' -f $dbLiteral))
        $databaseSetupLines.Add(('if [ "$(psql -Atqc "SELECT 1 FROM pg_database WHERE datname = ''{0}''")" != "1" ]; then createdb "{1}"; fi' -f $dbLiteral, $dbIdentifier))

        $grantStatements = New-Object System.Collections.Generic.List[string]
        foreach ($entry in $PrincipalIds.GetEnumerator()) {
            $app = $Apps[$entry.Key]
            if ($app.enabled -and $app.postgres.enabled -and ([string]$app.postgres.databaseName -eq $databaseName)) {
                $role = Escape-SqlIdentifier ([string]$app.identity.name)
                $schema = Escape-SqlIdentifier ([string]$app.postgres.schemaName)
                $grantStatements.Add(('GRANT CONNECT ON DATABASE "{0}" TO "{1}"; CREATE SCHEMA IF NOT EXISTS "{2}" AUTHORIZATION "{1}"; GRANT USAGE, CREATE ON SCHEMA "{2}" TO "{1}";' -f $dbIdentifier, $role, $schema))
            }
        }

        # Base64 avoids shell quoting issues and keeps SQL out of command-line
        # parsing while the bootstrap Job is being created.
        $grantSql = $grantStatements -join ' '
        $grantSqlB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($grantSql))
        $databaseSetupLines.Add(('printf ''%s'' ''{0}'' | base64 -d | psql -v ON_ERROR_STOP=1 -d "{1}"' -f $grantSqlB64, $dbIdentifier))
    }

    $bootstrapScript = @"
set -eu

echo "Starting PostgreSQL managed identity bootstrap..."
printf '%s' "`$BOOTSTRAP_SQL_B64" | base64 -d | psql -v ON_ERROR_STOP=1
$($databaseSetupLines -join "`n")
echo "PostgreSQL managed identity bootstrap completed successfully."
"@

    $bootstrapJob = 'nanda-pg-bootstrap'
    $adminToken = $null
    try {
        $existingJob = az containerapp job list `
            --resource-group $ResourceGroupName `
            --query "[?name=='$bootstrapJob'].name | [0]" `
            --output tsv `
            --only-show-errors `
            2>$null

        if (-not [string]::IsNullOrWhiteSpace($existingJob)) {
            az containerapp job delete `
                --name $bootstrapJob `
                --resource-group $ResourceGroupName `
                --yes `
                --only-show-errors `
                --output none
            if ($LASTEXITCODE -ne 0) { throw "Could not remove previous PostgreSQL bootstrap Job '$bootstrapJob'." }
        }

        for ($attempt = 1; $attempt -le 6; $attempt++) {
            Write-Host "Obtaining a fresh Entra token for PostgreSQL admin group (attempt $attempt/6)..." -ForegroundColor Yellow
            $adminToken = az account get-access-token `
                --resource 'https://ossrdbms-aad.database.windows.net' `
                --query accessToken `
                --output tsv `
                --only-show-errors
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($adminToken)) { throw 'Could not obtain a Microsoft Entra token for PostgreSQL.' }

            $sqlB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($roleSql))
            az containerapp job create `
                --name $bootstrapJob `
                --resource-group $ResourceGroupName `
                --environment $EnvironmentName `
                --trigger-type Manual `
                --replica-timeout 120 `
                --replica-retry-limit 0 `
                --replica-completion-count 1 `
                --parallelism 1 `
                --image 'postgres:16' `
                --container-name 'postgres' `
                --cpu 0.25 `
                --memory 0.5Gi `
                --secrets "pg-admin-token=$adminToken" `
                --env-vars `
                    'PGPASSWORD=secretref:pg-admin-token' `
                    "PGHOST=$pgHost" `
                    'PGPORT=5432' `
                    "PGUSER=$PostgresAdminGroupName" `
                    'PGDATABASE=postgres' `
                    'PGSSLMODE=require' `
                    "BOOTSTRAP_SQL_B64=$sqlB64" `
                --only-show-errors `
                --output none
            if ($LASTEXITCODE -ne 0) { throw 'Failed to create the PostgreSQL bootstrap Job.' }

            $jobJson = az containerapp job show `
                --name $bootstrapJob `
                --resource-group $ResourceGroupName `
                --output json `
                --only-show-errors
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($jobJson)) { throw 'Could not read the PostgreSQL bootstrap Job before applying the command override.' }

            $jobObject = $jobJson | ConvertFrom-Json
            $container = $jobObject.properties.template.containers[0]
            $container | Add-Member -MemberType NoteProperty -Name command -Value @('/bin/sh') -Force
            $container | Add-Member -MemberType NoteProperty -Name args -Value @('-c', $bootstrapScript) -Force
            $patchBody = @{ properties = @{ template = @{ containers = @($container) } } } | ConvertTo-Json -Depth 30 -Compress

            $subscriptionId = az account show --query id --output tsv --only-show-errors
            $managementToken = az account get-access-token --resource https://management.azure.com/ --query accessToken --output tsv --only-show-errors
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($managementToken)) { throw 'Could not obtain Azure management token for the PostgreSQL bootstrap REST PATCH.' }
            $jobUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/jobs/${bootstrapJob}?api-version=2026-01-01"
            Invoke-RestMethod -Method Patch -Uri $jobUri -Headers @{ Authorization = "Bearer $managementToken" } -ContentType 'application/json' -Body $patchBody -ErrorAction Stop | Out-Null

            $verifyJobJson = az containerapp job show --name $bootstrapJob --resource-group $ResourceGroupName --output json --only-show-errors
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($verifyJobJson)) { throw 'Could not verify the PostgreSQL bootstrap Job.' }
            $verifyJob = $verifyJobJson | ConvertFrom-Json
            $configuredCommand = @($verifyJob.properties.template.containers[0].command)
            $configuredArgs = @($verifyJob.properties.template.containers[0].args)
            if ($configuredCommand.Count -ne 1 -or $configuredCommand[0] -ne '/bin/sh') { throw 'Azure did not persist the /bin/sh command override on the PostgreSQL bootstrap Job.' }
            if ($configuredArgs.Count -lt 2 -or $configuredArgs[0] -ne '-c' -or [string]::IsNullOrWhiteSpace([string]$configuredArgs[1])) { throw 'Azure did not persist the expected PostgreSQL bootstrap command.' }

            $execution = az containerapp job start --name $bootstrapJob --resource-group $ResourceGroupName --query name --output tsv --only-show-errors
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($execution)) { throw 'Failed to start the PostgreSQL bootstrap Job.' }

            $completed = $false
            for ($poll = 1; $poll -le 24; $poll++) {
                $status = az containerapp job execution show --name $bootstrapJob --resource-group $ResourceGroupName --job-execution-name $execution --query properties.status --output tsv --only-show-errors
                Write-Host "PostgreSQL bootstrap execution status: $status" -ForegroundColor Gray
                if ($status -eq 'Succeeded') { $completed = $true; break }
                if ($status -eq 'Failed' -or $status -eq 'Canceled') { break }
                Start-Sleep -Seconds 5
            }
            if ($completed) { Write-Host 'PostgreSQL managed identity bootstrap completed successfully.' -ForegroundColor Green; return }

            Write-Host 'Bootstrap execution failed; collecting Log Analytics output before retry...' -ForegroundColor Yellow
            $workspaceId = az containerapp env show --name $EnvironmentName --resource-group $ResourceGroupName --query properties.appLogsConfiguration.logAnalyticsConfiguration.customerId --output tsv --only-show-errors 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($workspaceId)) {
                Start-Sleep -Seconds 10
                $logQuery = "ContainerAppConsoleLogs_CL | where ContainerJobName_s == '$bootstrapJob' | where ContainerGroupName_s startswith '$execution' | project TimeGenerated, Log_s | order by TimeGenerated asc"
                $logs = az monitor log-analytics query --workspace $workspaceId --analytics-query $logQuery --query '[].Log_s' --output tsv --only-show-errors 2>$null
                if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($logs)) { Write-Host $logs }
            }
            if ($attempt -lt 6) {
                az containerapp job delete --name $bootstrapJob --resource-group $ResourceGroupName --yes --only-show-errors --output none
                Start-Sleep -Seconds 15
            }
            else { throw 'PostgreSQL managed identity bootstrap failed after 6 attempts.' }
        }
    }
    finally {
        $adminToken = $null
        try {
            $jobCheck = az containerapp job list --resource-group $ResourceGroupName --query "[?name=='$bootstrapJob'].name | [0]" --output tsv --only-show-errors 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($jobCheck)) {
                az containerapp job delete --name $bootstrapJob --resource-group $ResourceGroupName --yes --only-show-errors --output none 2>$null
            }
        }
        catch {
            Write-Host "Temporary PostgreSQL bootstrap Job cleanup skipped: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Show-DeploymentSummary {
    Write-Step 'Deployment Summary'
    Write-Host 'Foundation resources : Shared VNet, ACA subnet, Private DNS, Log Analytics, ACR, Key Vault, PostgreSQL, shared Storage, Recovery Services backup policy and ACA environment' -ForegroundColor Green
    Write-Host 'Application resources: Configured applications from apps/apps.json' -ForegroundColor Green
    Write-Host 'Security              : Per-application managed identities, scoped Key Vault RBAC and Entra group-based Easy Auth' -ForegroundColor Green
    Write-Host 'Database access       : Configured PostgreSQL managed identities mapped to application schemas' -ForegroundColor Green
    Write-Host 'CI/CD                  : Full-SHA ACR image -> ACA revision -> health gate -> approval -> validation -> promotion' -ForegroundColor Green
}

function Get-DefaultDomain {
    $domain = az containerapp env show --name $EnvironmentName --resource-group $ResourceGroupName --query properties.defaultDomain -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($domain)) { throw 'Could not retrieve ACA environment default domain.' }
    return $domain.Trim()
}

# --------------------------- START ---------------------------

Assert-AzCli
if (-not (Test-Path $FoundationBicep)) { throw "main.bicep not found: $FoundationBicep" }
if (-not (Test-Path $RuntimeBicep)) { throw "runtime.bicep not found: $RuntimeBicep" }
Assert-BicepCompilation
$account = Assert-AzureLogin
$TenantId = $account.tenantId

if ($GithubRepository -notmatch '^[^/]+/[^/]+$') { throw "GithubRepository must be in OWNER/REPOSITORY format. Received '$GithubRepository'." }
$githubRepositorySubjectPrefix = Get-GitHubRepositorySubjectPrefix
Ensure-ResourceGroupForRecovery
if ($NotificationEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') { throw 'NotificationEmail must be a valid email address.' }

if (-not $PostgreSqlPassword) { $PostgreSqlPassword = Read-Host -Prompt 'PostgreSQL administrator password' -AsSecureString }
$plainPassword = [System.Net.NetworkCredential]::new('', $PostgreSqlPassword).Password
$now = Get-Date
$budgetStartDate = '{0:yyyy}-{0:MM}-01T00:00:00Z' -f $now
if ([string]::IsNullOrWhiteSpace($plainPassword) -or $plainPassword.Length -lt 8) { throw 'PostgreSQL administrator password must be at least 8 characters.' }

$operatorId = Get-OperatorObjectId
Write-Host "Subscription: $($account.id)" -ForegroundColor Gray
Write-Host "Tenant      : $($account.tenantId)" -ForegroundColor Gray
Write-Host "Repository  : $GithubRepository" -ForegroundColor Gray
Write-Host "Resource RG : $ResourceGroupName" -ForegroundColor Gray
if ($FoundationOnly) { Write-Host 'Applications: NOT DEPLOYED (foundation-only mode)' -ForegroundColor Gray } else { Write-Host "Applications: $($Apps.Keys -join ', ')" -ForegroundColor Gray }

try {
    # 1. Shared foundation + application identities + storage resources.
    Invoke-FoundationDeployment -Password $plainPassword

    if ($FoundationOnly) {
        Write-Step 'FOUNDATION DEPLOYMENT COMPLETE'
        Write-Host 'Shared platform infrastructure is ready. Application onboarding was intentionally skipped.' -ForegroundColor Green
        return
    }

    # 2. Temporary operator access is used only to populate application secrets.
    Ensure-KeyVaultOperatorAccess -OperatorId $operatorId

    foreach ($entry in $storageApps) {
        $app = $entry.Value
        if ($app.keyVault.readStorageKeySecret) {
            $key = Get-StorageKey -StorageAccountName ([string]$app.storage.accountName)
            try { Ensure-KeyVaultSecret -Name ([string]$app.keyVault.storageKeySecretName) -Value $key }
            finally { $key = $null }
        }
    }

    $postgresAdminGroupId = Ensure-EntraGroup -DisplayName $PostgresAdminGroupName -MailNickname 'NANDAPureOTAPostgreSQLAdmins' -OperatorId $operatorId
    Ensure-PostgreSqlEntraAdministrator -AdminGroupId $postgresAdminGroupId

    $domain = Get-DefaultDomain
    $entraMetadata = @{}
    $principalIds = @{}

    foreach ($entry in $enabledApplications) {
        $app = $entry.Value
        $principalIds[$entry.Key] = Ensure-AppManagedIdentity -IdentityName ([string]$app.identity.name)
    }

    foreach ($entry in $Apps.GetEnumerator()) {
        $key = $entry.Key
        $app = $entry.Value
        if (-not $app.enabled) { continue }

        $mailNickname = if ($app.entra.PSObject.Properties.Name -contains 'mailNickname' -and -not [string]::IsNullOrWhiteSpace([string]$app.entra.mailNickname)) { [string]$app.entra.mailNickname } else { ('NANDA' + $key + 'Users') }
        $groupId = Ensure-EntraGroup -DisplayName ([string]$app.entra.groupName) -MailNickname $mailNickname -OperatorId $operatorId
        $redirectPath = [string]$app.entra.redirectPath
        if ([string]::IsNullOrWhiteSpace($redirectPath)) { $redirectPath = '/.auth/login/aad/callback' }
        $redirectUri = "https://$($app.containerAppName).$domain$redirectPath"

        $clientId = ''
        if ($app.keyVault.readAuthSecret) {
            $clientId = Ensure-EntraApplication `
                -DisplayName ([string]$app.entra.applicationName) `
                -RedirectUri $redirectUri `
                -SecretName ([string]$app.keyVault.authSecretName) `
                -GroupId $groupId `
                -OperatorId $operatorId
        }
        else {
            $clientId = az ad app list --display-name ([string]$app.entra.applicationName) --query '[0].appId' -o tsv --only-show-errors
            if ([string]::IsNullOrWhiteSpace($clientId)) { throw "Application '$key' has readAuthSecret=false but Entra application '$($app.entra.applicationName)' does not exist." }
        }

        $entraMetadata[$key] = @{ groupId = $groupId; clientId = $clientId }
        if (-not $principalIds.ContainsKey($key) -or [string]::IsNullOrWhiteSpace([string]$principalIds[$key])) {
            throw "Managed identity principal ID is missing for application '$key'."
        }
    }

    # Key Vault secret-scoped RBAC is applied only after the secrets have been created.
    foreach ($entry in $enabledApplications) {
        $app = $entry.Value
        if ($app.keyVault.readAuthSecret) {
            Ensure-KeyVaultSecretAccess -PrincipalId ([string]$principalIds[$entry.Key]) -SecretName ([string]$app.keyVault.authSecretName)
        }
    }

    # 3. Database roles/schemas are established before runtime apps start.
    if ($principalIds.Count -gt 0 -and $postgresApps.Count -gt 0) {
        $postgresPrincipalIds = @{}
        foreach ($entry in $postgresApps) { $postgresPrincipalIds[$entry.Key] = $principalIds[$entry.Key] }
        Ensure-PostgreSqlManagedIdentityAccess -PrincipalIds $postgresPrincipalIds
    }

    # 4. Runtime references the same apps.json configuration.
    Invoke-RuntimeDeployment -PostgresAdminGroupId $postgresAdminGroupId -EntraMetadata $entraMetadata

    Show-DeploymentSummary
    Write-Step 'DEPLOYMENT COMPLETE'
    Write-Host "Resource Group : $ResourceGroupName" -ForegroundColor Green
    Write-Host "Applications   : $($Apps.Keys -join ', ')" -ForegroundColor Green
    Write-Host 'Infrastructure is ready for GitHub application CI/CD deployment.' -ForegroundColor Green
}
finally {
    if ($storageKey) { $storageKey = $null }
    $plainPassword = $null
    $PostgreSqlPassword = $null
    if (-not [string]::IsNullOrWhiteSpace($operatorId)) {
        try { Remove-TemporaryKeyVaultOperatorAccess -OperatorId $operatorId } catch { Write-Warning "Temporary Key Vault role cleanup failed: $($_.Exception.Message)" }
    }
}
