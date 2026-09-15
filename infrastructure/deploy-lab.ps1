<#
.SYNOPSIS
Reusable foundation-only deployment for the Arrowhead Container Apps POC platform.

.DESCRIPTION
Deploys only the shared Azure platform foundation through main.bicep.
Application onboarding and application runtime deployment are intentionally
handled separately by onboard.ps1 and runtime.bicep and are not executed here.

Foundation includes the shared network, logging, ACR, Key Vault, PostgreSQL,
private connectivity, shared storage, ACA environment, GitHub OIDC identity,
and platform monitoring dependencies defined by main.bicep.

Azure authentication uses Azure CLI. No GitHub CLI is required.
#>

[CmdletBinding()]
param(
    [string]$Location = 'westus',
    [string]$ResourceGroupName = 'NANDA-rg-arrowhead-aca-test1',
    [string]$GithubRepository = 'Nands78gwejdfwsf/nanda-arrowhead-aca',
    [string]$NotificationEmail = 'Nandan.NK@Stratogent.com',
    [SecureString]$PostgreSqlPassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$FoundationBicep = Join-Path $Root 'main.bicep'

# ---------------------------------------------------------------------------
# PLATFORM CONFIGURATION
# These are shared platform resources. Application-specific values belong in
# apps/apps.json and must not be duplicated here.
# ---------------------------------------------------------------------------
$VnetName = 'NANDA-vnet-arrowhead-aca-test'
$AcaSubnetName = 'NANDA-snet-aca'
$PrivateEndpointSubnetName = 'NANDA-snet-private-endpoint'
$LogAnalyticsWorkspaceName = 'NANDA-law-arrowhead-aca-test'
$AcrName = 'nandaacrarrowheadaca'
$KeyVaultName = 'NANDA-kv-aca-test41'
$PostgreSqlServerName = 'nanda-pg-aca-test'
$StorageAccountName = 'nandaarrowheadacatest'
$StorageIdentityName = 'NANDA-id-aca-storage'
$EnvironmentName = 'NANDA-cae-arrowhead-aca-test'
$GithubIdentityName = 'NANDA-id-github-actions'
$BudgetName = 'NANDA-budget-arrowhead-aca-test'
$AcrPrivateEndpointName = 'NANDA-pe-acr-arrowhead-aca'
$KeyVaultPrivateEndpointName = 'NANDA-pe-keyvault-aca'
$PostgresPrivateEndpointName = 'NANDA-pe-postgresql-aca'
$StoragePrivateEndpointName = 'NANDA-pe-arrowhead-storage'
$StoragePrivateDnsLinkName = 'NANDA-link-arrowhead-storage-private-dns'
$RecoveryServicesVaultName = 'NANDA-rsv-arrowhead-aca-files'
$AzureFilesBackupPolicyName = 'NANDA-afs-daily-30d'
$MonitoringActionGroupName = 'NANDA-ag-aca-platform'
$MonthlyBudgetAmount = 120

$plainPassword = $null
$PostgreSqlPassword = $null
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
                recoveryServicesVaultName=$RecoveryServicesVaultName `
                azureFilesBackupPolicyName=$AzureFilesBackupPolicyName `
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
function Ensure-PlatformActionGroup {
    Write-Step "Ensure platform monitoring action group"

$existing = az monitor action-group list `
    --resource-group $ResourceGroupName `
    --query "[?name=='NANDA-ag-aca-platform'].id | [0]" `
    --output tsv `
    --only-show-errors

if (-not [string]::IsNullOrWhiteSpace($existing)) {
    Write-Host "Platform action group already exists: NANDA-ag-aca-platform"
    return
}

    Write-Host "Creating platform action group: NANDA-ag-aca-platform"

    $notificationEmail = $NotificationEmail

    if ([string]::IsNullOrWhiteSpace($notificationEmail)) {
        throw "Notification email is required to create the platform action group."
    }

    az monitor action-group create `
        --resource-group $ResourceGroupName `
        --name "NANDA-ag-aca-platform" `
        --short-name "NANDAACA" `
        --action email "PlatformEmail" $notificationEmail `
        --only-show-errors `
        --output none

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create platform monitoring action group."
    }

    Write-Host "Platform action group created successfully." -ForegroundColor Green
}

# --------------------------- START ---------------------------

Assert-AzCli
if (-not (Test-Path -LiteralPath $FoundationBicep)) { throw "main.bicep not found: $FoundationBicep" }
Assert-BicepCompilation
$account = Assert-AzureLogin

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

Write-Host "Subscription: $($account.id)" -ForegroundColor Gray
Write-Host "Tenant      : $($account.tenantId)" -ForegroundColor Gray
Write-Host "Repository  : $GithubRepository" -ForegroundColor Gray
Write-Host "Resource RG : $ResourceGroupName" -ForegroundColor Gray
Write-Host 'Mode        : FOUNDATION ONLY' -ForegroundColor Gray

try {
    Invoke-FoundationDeployment -Password $plainPassword
    Ensure-PlatformActionGroup

    Write-Step 'FOUNDATION DEPLOYMENT COMPLETE'
    Write-Host 'Shared platform infrastructure is ready.' -ForegroundColor Green
    Write-Host 'Application onboarding was intentionally not run.' -ForegroundColor Green
}
finally {
    $plainPassword = $null
    $PostgreSqlPassword = $null
}
