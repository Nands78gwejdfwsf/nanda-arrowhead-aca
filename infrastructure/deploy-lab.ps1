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
    [string]$ResourceGroupName = 'NANDA-rg-arrowhead-aca-test1',
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

$KeyVaultName = 'NANDA-kv-aca-test20'
$StorageAccountName = 'nandastpureotaaca'
$StorageKeySecretName = 'pureota-storage-key'
$PureotaAuthSecretName = 'pureota-entra-client-secret'
$HelixAuthSecretName = 'helixbridge-entra-client-secret'
$EnvironmentName = 'NANDA-cae-arrowhead-aca-test'
$PureotaAppName = 'nanda-ca-pureota'
$HelixAppName = 'nanda-ca-helixbridge'
$PureotaJobName = 'nanda-job-pureota'
$PureotaGroupName = 'NANDA-PureOTA-Users'
$HelixGroupName = 'NANDA-HelixBridge-Users'
$PostgresAdminGroupName = 'NANDA-PureOTA-PostgreSQL-Admins'
$PureotaAppRegistrationName = 'NANDA-PureOTA-ACA-Test'
$HelixAppRegistrationName = 'NANDA-HelixBridge-ACA-Test'
$MonthlyBudgetAmount = 100
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
        --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        throw 'Foundation Bicep deployment failed.'
    }

    # PostgreSQL must be Ready before any runtime resource references it.
    for ($attempt = 1; $attempt -le 36; $attempt++) {
        $state = az postgres flexible-server show `
            --resource-group $ResourceGroupName `
            --name 'nanda-pg-aca-test' `
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
            notificationEmail=$NotificationEmail `
        --only-show-errors

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
    $vaultId = az keyvault show --name $KeyVaultName --resource-group $ResourceGroupName --query id -o tsv --only-show-errors
    $roleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'
    $assignments = @(az role assignment list --scope $vaultId --assignee-object-id $OperatorId --role $roleId --query '[].id' -o tsv --only-show-errors)
    foreach ($assignment in $assignments) {
        if (-not [string]::IsNullOrWhiteSpace($assignment)) {
            az role assignment delete --ids $assignment --only-show-errors
        }
    }
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

    $domain = Get-DefaultDomain
    $pureotaRedirect = "https://$PureotaAppName.$domain/.auth/login/aad/callback"
    $helixRedirect = "https://$HelixAppName.$domain/.auth/login/aad/callback"

    $pureotaClientId = Ensure-EntraApplication -DisplayName $PureotaAppRegistrationName -RedirectUri $pureotaRedirect -SecretName $PureotaAuthSecretName -GroupId $pureotaGroupId -OperatorId $operatorId
    $helixClientId = Ensure-EntraApplication -DisplayName $HelixAppRegistrationName -RedirectUri $helixRedirect -SecretName $HelixAuthSecretName -GroupId $helixGroupId -OperatorId $operatorId

    Invoke-RuntimeDeployment `
        -PureotaGroupId $pureotaGroupId `
        -PureotaClientId $pureotaClientId `
        -HelixGroupId $helixGroupId `
        -HelixClientId $helixClientId `
        -PostgresAdminGroupId $postgresAdminGroupId


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
