<#!
.SYNOPSIS
Fresh, reusable deployment for the Arrowhead Container Apps POC platform. Azure authentication uses Azure CLI only.

.DESCRIPTION
The script intentionally uses two Azure deployments:
  1. Foundation: network, Log Analytics, ACR, Key Vault, PostgreSQL, Azure Files,
     private endpoints/DNS, ACA environment, Defender and GitHub OIDC identity.
  2. Runtime: after secrets and Entra configuration exist, deploys the two dummy reference apps,
     PureOTA ACA Job, Easy Auth, scoped Key Vault RBAC and Azure Monitor alerts.

Cato/SANDC01 changes are not performed by this script. Those are customer IT actions.
The acceptance/validation script is intentionally not included in this POC package.
#>

[CmdletBinding()]
param(
    [string]$Location = 'westus',
    [string]$ResourceGroupName = 'NANDA-rg-arrowhead-aca-test',
    [string]$GithubRepository = 'Nands78gwejdfwsf/nanda-arrowhead-aca',
    [string]$NotificationEmail = 'Nandan.NK@Stratogent.com',
    [string]$EntraOperatorObjectId,
    [SecureString]$PostgreSqlPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$FoundationBicep = Join-Path $Root 'main.bicep'
$RuntimeBicep = Join-Path $Root 'runtime.bicep'

# ---------------------------------------------------------------------------
# CANONICAL RESOURCE NAMES
# This is the single naming source of truth for the deployment.
# main.bicep and runtime.bicep receive these values as parameters.
# ---------------------------------------------------------------------------
$VnetName = 'NANDA-vnet-arrowhead-aca-test'
$AcaSubnetName = 'NANDA-snet-aca'
$PrivateEndpointSubnetName = 'NANDA-snet-private-endpoint'
$LogAnalyticsWorkspaceName = 'NANDA-law-arrowhead-aca-test'
$AcrName = 'nandaacrarrowheadaca'
$KeyVaultName = 'NANDA-kv-aca-test33'
$PostgreSqlServerName = 'nanda-pg-aca-test'
$EnvironmentName = 'NANDA-cae-arrowhead-aca-test'
$StorageAccountName = 'nandastpureotaaca'
$FileShareName = 'pureota-data'
$PureotaIdentityName = 'NANDA-id-pureota'
$HelixIdentityName = 'NANDA-id-helixbridge'
$StorageIdentityName = 'NANDA-id-aca-storage'
$GithubIdentityName = 'NANDA-id-github-actions'
$PureotaAppName = 'nanda-ca-pureota'
$HelixAppName = 'nanda-ca-helixbridge'
$PureotaJobName = 'nanda-job-pureota'
$StorageBindingName = 'nanda-pureota-storage'
$StorageKeySecretName = 'pureota-storage-key'
$PureotaAuthSecretName = 'pureota-entra-client-secret'
$HelixAuthSecretName = 'helixbridge-entra-client-secret'
$AzureFilesBackupVaultName = 'NANDA-rsv-arrowhead-aca-files12'
$AzureFilesBackupPolicyName = 'NANDA-afs-daily-30d'
$BudgetName = 'NANDA-budget-arrowhead-aca-test'
$AcrPrivateEndpointName = 'NANDA-pe-acr-arrowhead-aca'
$KeyVaultPrivateEndpointName = 'NANDA-pe-keyvault-aca'
$PostgresPrivateEndpointName = 'NANDA-pe-postgresql-aca'
$StoragePrivateEndpointName = 'NANDA-pe-pureota-storage'
$PostgreSqlDatabaseName = 'arrowhead'
$MonitoringActionGroupName = 'NANDA-ag-aca-platform'
$MonthlyBudgetAmount = 100
$PostgresAdminGroupName = 'NANDA-PureOTA-PostgreSQL-Admins'
$PureotaGroupName = 'NANDA-PureOTA-Users'
$HelixGroupName = 'NANDA-HelixBridge-Users'
$PureotaAppRegistrationName = 'NANDA-PureOTA-ACA-Test'
$HelixAppRegistrationName = 'NANDA-HelixBridge-ACA-Test'

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

function Invoke-FoundationDeployment([string]$Password) {
    Write-Step 'PHASE 1 - Deploy Foundation'
    Write-Host 'Deploying network, logging, managed identities, ACR/private connectivity, Key Vault, PostgreSQL/private connectivity, Azure Files, ACA environment, Defender and budget...' -ForegroundColor Yellow

    az deployment sub create `
        --location $Location `
        --template-file $FoundationBicep `
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
            containerAppsEnvironmentName=$EnvironmentName `
            pureotaStorageAccountName=$StorageAccountName `
            pureotaFileShareName=$FileShareName `
            pureotaIdentityName=$PureotaIdentityName `
            helixIdentityName=$HelixIdentityName `
            storageIdentityName=$StorageIdentityName `
            githubIdentityName=$GithubIdentityName `
            pureotaAppName=$PureotaAppName `
            helixAppName=$HelixAppName `
            pureotaJobName=$PureotaJobName `
            storageBindingName=$StorageBindingName `
            pureotaStorageKeySecretName=$StorageKeySecretName `
            pureotaAuthSecretName=$PureotaAuthSecretName `
            helixAuthSecretName=$HelixAuthSecretName `
            azureFilesBackupVaultName=$AzureFilesBackupVaultName `
            azureFilesBackupPolicyName=$AzureFilesBackupPolicyName `
            azureFilesBackupScheduleRunTimeUtc='2026-01-01T02:00:00Z' `
            azureFilesBackupRetentionDays=30 `
            budgetName=$BudgetName `
            acrPrivateEndpointName=$AcrPrivateEndpointName `
            keyVaultPrivateEndpointName=$KeyVaultPrivateEndpointName `
            postgresPrivateEndpointName=$PostgresPrivateEndpointName `
            storagePrivateEndpointName=$StoragePrivateEndpointName `
        --only-show-errors `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw 'Foundation Bicep deployment failed.'
    }

    # PostgreSQL must be Ready before any runtime resource references it.
    for ($attempt = 1; $attempt -le 36; $attempt++) {
        $state = az postgres flexible-server show `
            --resource-group $ResourceGroupName `
            --name $PostgreSqlServerName `
            --query state `
            -o tsv `
            --only-show-errors 2>$null

        if ($LASTEXITCODE -eq 0 -and $state -eq 'Ready') {
            Write-Host 'PostgreSQL is Ready.' -ForegroundColor Green
            return
        }

        Write-Host "Waiting for PostgreSQL to become Ready... attempt $attempt/36 (state=$state)" -ForegroundColor Yellow
        Start-Sleep -Seconds 10
    }

    throw 'PostgreSQL did not reach Ready state after foundation deployment.'
}

function Invoke-RuntimeDeployment(
    [string]$PureotaGroupId,
    [string]$PureotaClientId,
    [string]$HelixGroupId,
    [string]$HelixClientId,
    [string]$PostgresAdminGroupId
) {
    Write-Step 'PHASE 3 - Deploy Runtime and Monitoring'
    Write-Host 'Deploying PureOTA, HelixBridge, PureOTA Job, Easy Auth, Key Vault RBAC and Azure Monitor alerts...' -ForegroundColor Yellow

    az deployment group create `
        --resource-group $ResourceGroupName `
        --template-file $RuntimeBicep `
        --parameters `
            location=$Location `
            resourceGroupName=$ResourceGroupName `
            pureotaEntraGroupObjectId=$PureotaGroupId `
            pureotaEntraClientId=$PureotaClientId `
            helixbridgeEntraGroupObjectId=$HelixGroupId `
            helixbridgeEntraClientId=$HelixClientId `
            postgresqlEntraAdministratorObjectId=$PostgresAdminGroupId `
            postgresqlEntraAdministratorName=$PostgresAdminGroupName `
            tenantId=$TenantId `
            notificationEmail=$NotificationEmail `
            acrName=$AcrName `
            keyVaultName=$KeyVaultName `
            postgresqlServerName=$PostgreSqlServerName `
            containerAppsEnvironmentName=$EnvironmentName `
            pureotaStorageAccountName=$StorageAccountName `
            pureotaFileShareName=$FileShareName `
            pureotaIdentityName=$PureotaIdentityName `
            helixIdentityName=$HelixIdentityName `
            storageIdentityName=$StorageIdentityName `
            githubIdentityName=$GithubIdentityName `
            pureotaAppName=$PureotaAppName `
            helixAppName=$HelixAppName `
            pureotaJobName=$PureotaJobName `
            storageBindingName=$StorageBindingName `
            pureotaStorageKeySecretName=$StorageKeySecretName `
            pureotaAuthSecretName=$PureotaAuthSecretName `
            helixAuthSecretName=$HelixAuthSecretName `
            logAnalyticsWorkspaceName=$LogAnalyticsWorkspaceName `
            postgresDatabaseName=$PostgreSqlDatabaseName `
            monitoringActionGroupName=$MonitoringActionGroupName `
        --only-show-errors `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw 'Runtime Bicep deployment failed.'
    }
}

function Get-StorageKey {
    Write-Step 'PHASE 2 - Retrieve Azure Files Key'
    $key = az storage account keys list `
        --resource-group $ResourceGroupName `
        --account-name $StorageAccountName `
        --query '[0].value' -o tsv --only-show-errors

    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($key)) {
        throw 'Could not retrieve the Azure Files storage account key.'
    }
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

function Ensure-PostgreSqlManagedIdentityAccess(
    [string]$PureotaIdentityPrincipalId,
    [string]$HelixIdentityPrincipalId
) {
    Write-Step 'PHASE 3 - Configure PostgreSQL Managed Identity Access'
    Write-Host 'Preparing the PostgreSQL database and mapping both ACA managed identities as non-admin Entra roles.' -ForegroundColor Yellow
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

    $sql = @'
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'NANDA-id-pureota') THEN
    PERFORM pg_catalog.pgaadauth_create_principal_with_oid('NANDA-id-pureota', 'PUREOTA_PRINCIPAL_ID', 'service', false, false);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'NANDA-id-helixbridge') THEN
    PERFORM pg_catalog.pgaadauth_create_principal_with_oid('NANDA-id-helixbridge', 'HELIX_PRINCIPAL_ID', 'service', false, false);
  END IF;
END
$$;
'@

    $sql = $sql.Replace('PUREOTA_PRINCIPAL_ID', $PureotaIdentityPrincipalId).Replace('HELIX_PRINCIPAL_ID', $HelixIdentityPrincipalId)

    $bootstrapJob = 'nanda-pg-bootstrap'
    $adminToken = $null

    $existingJob = $null

    try {
        $existingJob = az containerapp job list `
            --resource-group $ResourceGroupName `
            --query "[?name=='$bootstrapJob'].name | [0]" `
            --output tsv `
            --only-show-errors `
            2>$null
    }
    catch {
        $existingJob = $null
    }

    if (-not [string]::IsNullOrWhiteSpace($existingJob)) {
        Write-Host "Removing previous bootstrap Job '$bootstrapJob'..." -ForegroundColor Yellow

        az containerapp job delete `
            --name $bootstrapJob `
            --resource-group $ResourceGroupName `
            --yes `
            --only-show-errors `
            --output none

        if ($LASTEXITCODE -ne 0) {
            throw "Could not remove the previous PostgreSQL bootstrap Job '$bootstrapJob'."
        }

        Write-Host "Previous PostgreSQL bootstrap Job removed." -ForegroundColor Green
    }
    else {
        Write-Host "No previous PostgreSQL bootstrap Job found. Continuing..." -ForegroundColor Gray
    }

    try {
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            Write-Host "Obtaining a fresh Entra token for PostgreSQL admin group (attempt $attempt/6)..." -ForegroundColor Yellow

            $adminToken = az account get-access-token `
                --resource 'https://ossrdbms-aad.database.windows.net' `
                --query accessToken `
                --output tsv `
                --only-show-errors

            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($adminToken)) {
                throw 'Could not obtain a Microsoft Entra token for PostgreSQL.'
            }

            Write-Host "Creating temporary VNet bootstrap Job '$bootstrapJob'..." -ForegroundColor Yellow

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
                    "BOOTSTRAP_SQL_B64=$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sql)))" `
                --only-show-errors `
                --output none

            if ($LASTEXITCODE -ne 0) {
                throw 'Failed to create the PostgreSQL bootstrap Job.'
            }

            # The installed Azure CLI/containerapp extension on this host does not
            # reliably persist --command/--args on Job create/update. Use the
            # Container Apps REST API to patch the container command explicitly.
            Write-Host 'Applying PostgreSQL client command through the Container Apps REST API...' -ForegroundColor Yellow

            $jobJson = az containerapp job show `
                --name $bootstrapJob `
                --resource-group $ResourceGroupName `
                --output json `
                --only-show-errors

            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($jobJson)) {
                throw 'Could not read the PostgreSQL bootstrap Job before applying the command override.'
            }

            $jobObject = $jobJson | ConvertFrom-Json
            $container = $jobObject.properties.template.containers[0]

$bootstrapScript = @'
set -eu

echo "Starting PostgreSQL managed identity bootstrap..."

printf '%s' "$BOOTSTRAP_SQL_B64" | base64 -d | psql -v ON_ERROR_STOP=1

echo "Checking arrowhead database..."

if [ "$(psql -Atqc "SELECT 1 FROM pg_database WHERE datname = 'arrowhead'")" != "1" ]; then
    echo "Creating arrowhead database..."
    createdb arrowhead
fi

echo "Configuring database permissions..."

psql -v ON_ERROR_STOP=1 -d arrowhead -c "GRANT CONNECT ON DATABASE arrowhead TO \"NANDA-id-pureota\", \"NANDA-id-helixbridge\"; CREATE SCHEMA IF NOT EXISTS pureota AUTHORIZATION \"NANDA-id-pureota\"; CREATE SCHEMA IF NOT EXISTS helixbridge AUTHORIZATION \"NANDA-id-helixbridge\"; GRANT USAGE, CREATE ON SCHEMA pureota TO \"NANDA-id-pureota\"; GRANT USAGE, CREATE ON SCHEMA helixbridge TO \"NANDA-id-helixbridge\";"

echo "PostgreSQL managed identity bootstrap completed successfully."
'@

            $container | Add-Member -MemberType NoteProperty -Name command -Value @('/bin/sh') -Force
            $container | Add-Member -MemberType NoteProperty -Name args -Value @('-c', $bootstrapScript) -Force

            $patchBody = @{
                properties = @{
                    template = @{
                        containers = @($container)
                    }
                }
            } | ConvertTo-Json -Depth 30 -Compress

            $subscriptionId = az account show --query id --output tsv --only-show-errors
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($subscriptionId)) {
                throw 'Could not determine the active Azure subscription ID.'
            }

            $jobUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/jobs/${bootstrapJob}?api-version=2026-01-01"

            Write-Host 'Requesting Azure management token for REST PATCH...' -ForegroundColor Gray
            $managementToken = az account get-access-token `
                --resource https://management.azure.com/ `
                --query accessToken `
                --output tsv `
                --only-show-errors

            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($managementToken)) {
                throw 'Could not obtain an Azure management access token for the PostgreSQL bootstrap REST PATCH.'
            }

            Write-Host 'Sending PostgreSQL bootstrap command to Azure Container Apps...' -ForegroundColor Gray
            try {
                Invoke-RestMethod `
                    -Method Patch `
                    -Uri $jobUri `
                    -Headers @{ Authorization = "Bearer $managementToken" } `
                    -ContentType 'application/json' `
                    -Body $patchBody `
                    -ErrorAction Stop | Out-Null
            }
            catch {
                throw "Failed to apply the PostgreSQL bootstrap command through the Container Apps REST API: $($_.Exception.Message)"
            }

            Write-Host 'Verifying PostgreSQL bootstrap command...' -ForegroundColor Yellow

            # Read the complete persisted container definition. Do not query a
            # multiline shell argument through TSV: Azure CLI can flatten or
            # omit multiline values in that mode.
            $verifyJobJson = az containerapp job show `
                --name $bootstrapJob `
                --resource-group $ResourceGroupName `
                --output json `
                --only-show-errors

            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($verifyJobJson)) {
                throw 'Could not read the PostgreSQL bootstrap Job after the REST PATCH.'
            }

            try {
                $verifyJob = $verifyJobJson | ConvertFrom-Json -ErrorAction Stop
                $verifyContainer = $verifyJob.properties.template.containers[0]
                $configuredCommand = @($verifyContainer.command)
                $configuredArgs = @($verifyContainer.args)
            }
            catch {
                throw "Could not parse the PostgreSQL bootstrap Job definition after the REST PATCH: $($_.Exception.Message)"
            }

            Write-Host "Configured command: $($configuredCommand -join ', ')" -ForegroundColor Gray
            Write-Host "Configured args   : count=$($configuredArgs.Count), first='$($configuredArgs[0])'" -ForegroundColor Gray

            if ($configuredCommand.Count -ne 1 -or $configuredCommand[0] -ne '/bin/sh') {
                throw "Azure did not persist the /bin/sh command override on the PostgreSQL bootstrap Job. Actual command: '$($configuredCommand -join ', ')'"
            }

            if ($configuredArgs.Count -lt 2 -or $configuredArgs[0] -ne '-c') {
                throw "Azure did not persist the expected Container Apps args array. Actual args count=$($configuredArgs.Count), first='$($configuredArgs[0])'"
            }

            # Azure has now persisted the complete second argument. Do not
            # inspect its multiline contents with PowerShell pattern matching;
            # the container will execute it when the Job starts.
            if ([string]::IsNullOrWhiteSpace([string]$configuredArgs[1])) {
                throw 'Azure persisted an empty PostgreSQL bootstrap shell script argument.'
            }

            Write-Host 'PostgreSQL bootstrap command verified successfully.' -ForegroundColor Green

            $execution = az containerapp job start `
                --name $bootstrapJob `
                --resource-group $ResourceGroupName `
                --query name `
                --output tsv `
                --only-show-errors

            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($execution)) {
                throw 'Failed to start the PostgreSQL bootstrap Job.'
            }

            Write-Host "Started PostgreSQL bootstrap execution: $execution" -ForegroundColor Gray

            $completed = $false
            for ($poll = 1; $poll -le 24; $poll++) {
                $status = az containerapp job execution show `
                    --name $bootstrapJob `
                    --resource-group $ResourceGroupName `
                    --job-execution-name $execution `
                    --query properties.status `
                    --output tsv `
                    --only-show-errors

                Write-Host "PostgreSQL bootstrap execution status: $status" -ForegroundColor Gray

                if ($status -eq 'Succeeded') {
                    $completed = $true
                    break
                }

                if ($status -eq 'Failed' -or $status -eq 'Canceled') {
                    break
                }

                Start-Sleep -Seconds 5
            }

            if ($completed) {
                Write-Host 'PostgreSQL managed identity roles configured successfully.' -ForegroundColor Green
                return
            }

            Write-Host 'Bootstrap execution failed. Collecting PostgreSQL bootstrap logs from Log Analytics...' -ForegroundColor Yellow

            $workspaceId = az containerapp env show `
                --name $EnvironmentName `
                --resource-group $ResourceGroupName `
                --query properties.appLogsConfiguration.logAnalyticsConfiguration.customerId `
                --output tsv `
                --only-show-errors 2>$null

            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($workspaceId)) {
                Start-Sleep -Seconds 10

                $logQuery = "ContainerAppConsoleLogs_CL | where ContainerJobName_s == '$bootstrapJob' | where ContainerGroupName_s startswith '$execution' | project TimeGenerated, Log_s | order by TimeGenerated asc"

                try {
                    $logs = az monitor log-analytics query `
                        --workspace $workspaceId `
                        --analytics-query $logQuery `
                        --query '[].Log_s' `
                        --output tsv `
                        --only-show-errors 2>$null

                    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($logs)) {
                        Write-Host 'PostgreSQL bootstrap Job output:' -ForegroundColor Yellow
                        Write-Host $logs
                    }
                    else {
                        Write-Host 'Bootstrap logs are not available yet. The failed execution will be retried.' -ForegroundColor Yellow
                    }
                }
                catch {
                    Write-Host "Could not retrieve bootstrap logs from Log Analytics: $($_.Exception.Message)" -ForegroundColor Yellow
                }
            }
            else {
                Write-Host 'Could not retrieve the Log Analytics workspace ID. Continuing with bootstrap retry.' -ForegroundColor Yellow
            }

            if ($attempt -lt 6) {
                Write-Host 'Bootstrap did not complete successfully; waiting before retrying with a fresh Entra token...' -ForegroundColor Yellow
                az containerapp job delete --name $bootstrapJob --resource-group $ResourceGroupName --yes --only-show-errors --output none
                Start-Sleep -Seconds 15
            }
            else {
                throw 'PostgreSQL managed identity bootstrap failed after 6 attempts.'
            }
        }
    }
    finally {
        $adminToken = $null

        Write-Host "Cleaning up temporary PostgreSQL bootstrap Job '$bootstrapJob'..." -ForegroundColor Yellow

        try {
            $jobCheck = az containerapp job list `
                --resource-group $ResourceGroupName `
                --query "[?name=='$bootstrapJob'].name | [0]" `
                --output tsv `
                --only-show-errors `
                2>$null

            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($jobCheck)) {
                az containerapp job delete `
                    --name $bootstrapJob `
                    --resource-group $ResourceGroupName `
                    --yes `
                    --only-show-errors `
                    --output none `
                    2>$null

                if ($LASTEXITCODE -eq 0) {
                    Write-Host 'Temporary PostgreSQL bootstrap Job removed.' -ForegroundColor Green
                }
            }
            else {
                Write-Host 'Temporary PostgreSQL bootstrap Job is already absent.' -ForegroundColor Gray
            }
        }
        catch {
            Write-Host "Temporary PostgreSQL bootstrap Job cleanup skipped: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Show-DeploymentSummary {
    Write-Step 'Deployment Summary'
    Write-Host 'Foundation resources : VNet, ACA subnet, Private DNS, Log Analytics, ACR, Key Vault, PostgreSQL and Azure Files' -ForegroundColor Green
    Write-Host 'Private connectivity : ACR, PostgreSQL and Azure Files private endpoints/DNS are configured' -ForegroundColor Green
    Write-Host 'GitHub OIDC           : Federated identity + Reader + Container Apps Contributor + Container Apps Jobs Contributor' -ForegroundColor Green
    Write-Host 'Database access       : PureOTA and HelixBridge UAMIs mapped as non-admin PostgreSQL Entra roles' -ForegroundColor Green
    Write-Host 'Application DB check  : PureOTA and HelixBridge images validate PostgreSQL using managed identity before nginx starts' -ForegroundColor Green
    Write-Host 'Job DB check          : PureOTA ACA Job performs the same managed-identity PostgreSQL check before job validation' -ForegroundColor Green
    Write-Host 'CI/CD                  : Full-SHA ACR image -> ACA revision -> health gate -> approval -> Job -> promotion' -ForegroundColor Green
}

function Get-DefaultDomain {
    $domain = az containerapp env show --name $EnvironmentName --resource-group $ResourceGroupName --query properties.defaultDomain -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($domain)) { throw 'Could not retrieve ACA environment default domain.' }
    return $domain.Trim()
}

# --------------------------- START ---------------------------

Assert-AzCli
Assert-BicepCompilation
$account = Assert-AzureLogin
$TenantId = $account.tenantId
if (-not (Test-Path $FoundationBicep)) { throw "main.bicep not found: $FoundationBicep" }

if ($GithubRepository -notmatch '^[^/]+/[^/]+$') {
    throw "GithubRepository must be in OWNER/REPOSITORY format. Received '$GithubRepository'."
}

$githubRepositorySubjectPrefix = Get-GitHubRepositorySubjectPrefix
Ensure-ResourceGroupForRecovery

if ($NotificationEmail -notmatch '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
    throw 'NotificationEmail must be a valid email address.'
}

if (-not $PostgreSqlPassword) {
    $PostgreSqlPassword = Read-Host -Prompt 'PostgreSQL administrator password' -AsSecureString
}
$plainPassword = [System.Net.NetworkCredential]::new('', $PostgreSqlPassword).Password
$now = Get-Date
$budgetStartDate = '{0:yyyy}-{0:MM}-01T00:00:00Z' -f $now
if ([string]::IsNullOrWhiteSpace($plainPassword) -or $plainPassword.Length -lt 8) {
    throw 'PostgreSQL administrator password must be at least 8 characters.'
}

$operatorId = Get-OperatorObjectId
Write-Host "Subscription: $($account.id)" -ForegroundColor Gray
Write-Host "Tenant      : $($account.tenantId)" -ForegroundColor Gray
Write-Host "Repository  : $GithubRepository" -ForegroundColor Gray
Write-Host "Resource RG : $ResourceGroupName" -ForegroundColor Gray

try {
    Invoke-FoundationDeployment -Password $plainPassword

    Ensure-KeyVaultOperatorAccess -OperatorId $operatorId
    $storageKey = Get-StorageKey
    Ensure-KeyVaultSecret -Name $StorageKeySecretName -Value $storageKey
    $storageKey = $null

    $pureotaGroupId = Ensure-EntraGroup -DisplayName $PureotaGroupName -MailNickname 'NANDAPureOTAUsers' -OperatorId $operatorId
    $helixGroupId = Ensure-EntraGroup -DisplayName $HelixGroupName -MailNickname 'NANDAHelixBridgeUsers' -OperatorId $operatorId
    $postgresAdminGroupId = Ensure-EntraGroup -DisplayName $PostgresAdminGroupName -MailNickname 'NANDAPureOTAPostgreSQLAdmins' -OperatorId $operatorId
    Ensure-PostgreSqlEntraAdministrator -AdminGroupId $postgresAdminGroupId

    $domain = Get-DefaultDomain
    $pureotaRedirect = "https://$PureotaAppName.$domain/.auth/login/aad/callback"
    $helixRedirect = "https://$HelixAppName.$domain/.auth/login/aad/callback"

    $pureotaClientId = Ensure-EntraApplication -DisplayName $PureotaAppRegistrationName -RedirectUri $pureotaRedirect -SecretName $PureotaAuthSecretName -GroupId $pureotaGroupId -OperatorId $operatorId
    $helixClientId = Ensure-EntraApplication -DisplayName $HelixAppRegistrationName -RedirectUri $helixRedirect -SecretName $HelixAuthSecretName -GroupId $helixGroupId -OperatorId $operatorId

    # PostgreSQL managed-identity bootstrap must happen BEFORE runtime apps/jobs are deployed.
    # The runtime containers perform a DB connectivity check during startup.
    $pureotaPrincipalId = az identity show --resource-group $ResourceGroupName --name $PureotaIdentityName --query principalId -o tsv --only-show-errors
    $helixPrincipalId = az identity show --resource-group $ResourceGroupName --name $HelixIdentityName --query principalId -o tsv --only-show-errors
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($pureotaPrincipalId) -or [string]::IsNullOrWhiteSpace($helixPrincipalId)) {
        throw 'Could not retrieve runtime managed identity principal IDs for PostgreSQL bootstrap.'
    }

    Ensure-PostgreSqlManagedIdentityAccess `
        -PureotaIdentityPrincipalId $pureotaPrincipalId `
        -HelixIdentityPrincipalId $helixPrincipalId

    Invoke-RuntimeDeployment `
        -PureotaGroupId $pureotaGroupId `
        -PureotaClientId $pureotaClientId `
        -HelixGroupId $helixGroupId `
        -HelixClientId $helixClientId `
        -PostgresAdminGroupId $postgresAdminGroupId

    Show-DeploymentSummary

    Write-Step 'DEPLOYMENT COMPLETE'
    Write-Host "Resource Group        : $ResourceGroupName" -ForegroundColor Green
    Write-Host 'ACA Environment       : Internal / VNet integrated' -ForegroundColor Green
    Write-Host 'ACR                   : Premium / admin disabled / retention enabled' -ForegroundColor Green
    Write-Host 'Key Vault             : RBAC / soft delete / purge protection' -ForegroundColor Green
    Write-Host 'PostgreSQL            : Private / Entra enabled / 7-day PITR retention' -ForegroundColor Green
    Write-Host 'Azure Files           : Private / persistent' -ForegroundColor Green
    Write-Host 'PureOTA               : Dummy ACA app + Easy Auth + persistent mount' -ForegroundColor Green
    Write-Host 'HelixBridge           : Dummy ACA app + Easy Auth' -ForegroundColor Green
    Write-Host 'PureOTA ACA Job       : Manual job with persistent mount' -ForegroundColor Green
    Write-Host 'Azure Monitor         : Required platform alerts configured' -ForegroundColor Green
    Write-Host 'GitHub OIDC           : Federated main + production credentials' -ForegroundColor Green

    Write-Host 'Infrastructure is ready.' -ForegroundColor Green
    Write-Host ''
}
finally {
    if ($storageKey) { $storageKey = $null }
    $plainPassword = $null
    $PostgreSqlPassword = $null
    if (-not [string]::IsNullOrWhiteSpace($operatorId)) {
        try { Remove-TemporaryKeyVaultOperatorAccess -OperatorId $operatorId } catch { Write-Warning "Temporary Key Vault role cleanup failed: $($_.Exception.Message)" }
    }
}
