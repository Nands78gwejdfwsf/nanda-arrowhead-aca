[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Application,

    [string]$ResourceGroupName = 'NANDA-rg-arrowhead-aca-test',
    [string]$Location = 'westus',
    [string]$KeyVaultName = 'NANDA-kv-aca-test40',
    [string]$AcrName = 'nandaacrarrowheadaca',
    [string]$PostgreSqlServerName = 'nanda-pg-aca-test',
    [string]$ContainerAppsEnvironmentName = 'NANDA-cae-arrowhead-aca-test',
    [string]$StorageAccountName = 'nandaarrowheadacatest',
    [string]$StorageIdentityName = 'NANDA-id-aca-storage',
    [string]$GithubIdentityName = 'NANDA-id-github-actions',
    [string]$LogAnalyticsWorkspaceName = 'NANDA-law-arrowhead-aca-test',
    [string]$MonitoringActionGroupName = 'NANDA-ag-aca-platform',
    [string]$PostgresAdminGroupName = 'NANDA-PureOTA-PostgreSQL-Admins',
    [string]$RecoveryServicesVaultName = 'NANDA-rsv-arrowhead-aca-files1',
    [string]$AzureFilesBackupPolicyName = 'NANDA-afs-daily-30d',
    [string]$RuntimeBicepPath = "$PSScriptRoot\runtime.bicep",
    [string]$AppsConfigPath = "$PSScriptRoot\..\apps\apps.json"
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host $Message -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
}

function Invoke-Az {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & az @Arguments

    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }
}


function Get-AzText {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $oldNativePreference = $null
    $hasNativePreference = $false

    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $hasNativePreference = $true
        $oldNativePreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }

    try {
        $output = @(& az @Arguments --output tsv 2>$null)
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }

    if ($exitCode -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }

    return (($output -join "`n").Trim())
}


function Get-AzJson {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [switch]$AllowNotFound
    )

    $oldNativePreference = $null
    $hasNativePreference = $false

    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $hasNativePreference = $true
        $oldNativePreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }

    try {
        $output = @(& az @Arguments --output json 2>$null)
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }

    if ($exitCode -ne 0) {
        if ($AllowNotFound) {
            return $null
        }
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }

    $text = ($output -join "`n").Trim()

    if ([string]::IsNullOrWhiteSpace($text)) {
        return $null
    }

    try {
        return ($text | ConvertFrom-Json)
    }
    catch {
        throw "Azure CLI returned invalid JSON: az $($Arguments -join ' ')"
    }
}


function Require-Resource {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ResourceType,

        [Parameter(Mandatory = $true)]
        [string]$ResourceName
    )

    $result = & az resource show `
        --resource-group $ResourceGroupName `
        --resource-type $ResourceType `
        --name $ResourceName `
        --output none 2>$null

    if ($LASTEXITCODE -ne 0) {
        throw "Required Azure resource does not exist: $ResourceType/$ResourceName"
    }
}
function Get-AppConfig {
    if (-not (Test-Path -LiteralPath $AppsConfigPath)) {
        throw "apps.json not found: $AppsConfigPath"
    }

    $jsonText = Get-Content -LiteralPath $AppsConfigPath -Raw

    try {
        $cfg = $jsonText | ConvertFrom-Json
    }
    catch {
        # Be tolerant of configuration files produced by tooling that writes
        # PowerShell/.NET boolean literals (True/False) instead of strict JSON
        # literals (true/false). Only replace those tokens outside quoted words.
        $normalizedJson = $jsonText -replace '(?<!["\w])True(?!["\w])', 'true'
        $normalizedJson = $normalizedJson -replace '(?<!["\w])False(?!["\w])', 'false'

        try {
            $cfg = $normalizedJson | ConvertFrom-Json
        }
        catch {
            throw "apps.json is not valid JSON. The parser failed at the configuration file. Fix the JSON syntax before onboarding. Original error: $($_.Exception.Message)"
        }
    }

    if ($null -eq $cfg.applications) {
        throw "apps.json must contain an 'applications' object."
    }

    # Case-insensitive lookup so -Application helixBridge and -Application
    # helixbridge resolve to the same configured application. The canonical
    # key from apps.json is then used for all downstream runtime metadata.
    $property = $cfg.applications.PSObject.Properties | Where-Object { $_.Name -ieq $Application } | Select-Object -First 1
    if ($null -eq $property) {
        throw "Application '$Application' was not found in apps.json."
    }

    # Normalize the command-line name to the exact key from apps.json. This is
    # important for runtime metadata and future applications whose key casing
    # may differ from the operator's command-line input.
    $script:Application = [string]$property.Name

    $raw = $property.Value

    # Normalize the selected application into one canonical contract.
    # This is deliberately independent of the input layout so future apps can
    # use either the current flat shape or the older azure/source/runtime shape.
    $getProp = {
        param($Object, [string]$Name, $Default)
        if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) {
            return $Object.PSObject.Properties[$Name].Value
        }
        return $Default
    }

    $enabledValue = & $getProp $raw 'enabled' $true
    $azure = & $getProp $raw 'azure' $null
    $source = & $getProp $raw 'source' $null
    $runtime = & $getProp $raw 'runtime' $null
    $legacyDb = & $getProp $raw 'database' $null
    $keyVaultRaw = & $getProp $raw 'keyVault' $null
    $storageRaw = & $getProp $raw 'storage' $null
    $jobRaw = & $getProp $raw 'job' $null
    $identityRaw = & $getProp $raw 'identity' $null
    $entraRaw = & $getProp $raw 'entra' $null
    $ingressRaw = & $getProp $raw 'ingress' $null
    $postgresRaw = & $getProp $raw 'postgres' $null

    $containerAppName = if ($null -ne $raw.PSObject.Properties['containerAppName']) { [string]$raw.containerAppName } else { [string]$azure.containerAppName }
    $imageName = if ($null -ne $raw.PSObject.Properties['imageName']) { [string]$raw.imageName } else { [string]$source.imageName }
    $buildContext = if ($null -ne $raw.PSObject.Properties['buildContext']) { [string]$raw.buildContext } else { [string]$source.buildContext }
    $dockerfile = if ($null -ne $raw.PSObject.Properties['dockerfile']) { [string]$raw.dockerfile } else { [string]$source.dockerfile }
    $targetPort = if ($null -ne $raw.PSObject.Properties['targetPort']) { [int]$raw.targetPort } else { [int]$runtime.targetPort }
    $healthPath = if ($null -ne $raw.PSObject.Properties['healthPath']) { [string]$raw.healthPath } else { [string]$runtime.healthPath }
    $minReplicas = if ($null -ne $raw.PSObject.Properties['minReplicas']) { [int]$raw.minReplicas } elseif ($null -ne $runtime -and $null -ne $runtime.PSObject.Properties['minReplicas']) { [int]$runtime.minReplicas } else { 1 }
    $maxReplicas = if ($null -ne $raw.PSObject.Properties['maxReplicas']) { [int]$raw.maxReplicas } elseif ($null -ne $runtime -and $null -ne $runtime.PSObject.Properties['maxReplicas']) { [int]$runtime.maxReplicas } else { 2 }

    $identityName = if ($null -ne $identityRaw -and $null -ne $identityRaw.PSObject.Properties['name']) { [string]$identityRaw.name } else { [string]$azure.managedIdentityName }
    $groupName = if ($null -ne $entraRaw -and $null -ne $entraRaw.PSObject.Properties['groupName']) { [string]$entraRaw.groupName } else { [string]$azure.entraGroupName }
    $applicationName = if ($null -ne $entraRaw -and $null -ne $entraRaw.PSObject.Properties['applicationName']) { [string]$entraRaw.applicationName } else { [string]$azure.appRegistrationName }
    $redirectPath = if ($null -ne $entraRaw -and $null -ne $entraRaw.PSObject.Properties['redirectPath']) { [string]$entraRaw.redirectPath } else { '/.auth/login/aad/callback' }

    $kvAuth = if ($null -ne $keyVaultRaw) { [string]$keyVaultRaw.authSecretName } else { '' }
    $kvStorage = if ($null -ne $keyVaultRaw) { [string]$keyVaultRaw.storageKeySecretName } else { '' }
    $readAuth = if ($null -ne $keyVaultRaw -and $null -ne $keyVaultRaw.PSObject.Properties['readAuthSecret']) { [bool]$keyVaultRaw.readAuthSecret } else { $true }
    $readStorage = if ($null -ne $keyVaultRaw -and $null -ne $keyVaultRaw.PSObject.Properties['readStorageKeySecret']) { [bool]$keyVaultRaw.readStorageKeySecret } else { [bool](& $getProp $storageRaw 'enabled' $false) }

    $dbEnabled = if ($null -ne $postgresRaw) { [bool]$postgresRaw.enabled } elseif ($null -ne $legacyDb) { [bool]$legacyDb.enabled } else { $false }
    $dbName = if ($null -ne $postgresRaw) { [string]$postgresRaw.databaseName } elseif ($null -ne $legacyDb) { [string]$legacyDb.databaseName } else { '' }
    $schemaName = if ($null -ne $postgresRaw) { [string]$postgresRaw.schemaName } elseif ($null -ne $legacyDb) { [string]$legacyDb.schemaName } else { '' }

    $storageEnabled = [bool](& $getProp $storageRaw 'enabled' $false)
    $jobEnabled = [bool](& $getProp $jobRaw 'enabled' $false)

    $app = [pscustomobject][ordered]@{
        displayName = [string](& $getProp $raw 'displayName' $Application)
        enabled = [bool]$enabledValue
        containerAppName = $containerAppName
        imageName = $imageName
        buildContext = $buildContext
        dockerfile = $dockerfile
        targetPort = $targetPort
        healthPath = $healthPath
        minReplicas = $minReplicas
        maxReplicas = $maxReplicas
        ingress = [pscustomobject][ordered]@{
            external = if ($null -ne $ingressRaw) { [bool]$ingressRaw.external } else { [bool](& $getProp $runtime 'ingressExternal' $true) }
            transport = if ($null -ne $ingressRaw -and $null -ne $ingressRaw.PSObject.Properties['transport']) { [string]$ingressRaw.transport } else { [string](& $getProp $runtime 'ingressTransport' 'auto') }
        }
        identity = [pscustomobject]@{ name = $identityName }
        entra = [pscustomobject][ordered]@{
            groupName = $groupName
            applicationName = $applicationName
            redirectPath = $redirectPath
        }
        keyVault = [pscustomobject][ordered]@{
            authSecretName = $kvAuth
            storageKeySecretName = $kvStorage
            readAuthSecret = $readAuth
            readStorageKeySecret = $readStorage
        }
        postgres = [pscustomobject][ordered]@{
            enabled = $dbEnabled
            databaseName = $dbName
            schemaName = $schemaName
        }
        storage = [pscustomobject][ordered]@{
            enabled = $storageEnabled
            accountName = [string](& $getProp $storageRaw 'accountName' '')
            fileShareName = [string](& $getProp $storageRaw 'fileShareName' '')
            bindingName = [string](& $getProp $storageRaw 'bindingName' "nanda-$($property.Name)-storage")
            mountPath = [string](& $getProp $storageRaw 'mountPath' '')
            privateEndpointName = [string](& $getProp $storageRaw 'privateEndpointName' '')
            privateDnsLinkName = [string](& $getProp $storageRaw 'privateDnsLinkName' '')
            privateDnsZoneGroupName = [string](& $getProp $storageRaw 'privateDnsZoneGroupName' '')
            backupPolicyName = [string](& $getProp $storageRaw 'backupPolicyName' '')
        }
        job = [pscustomobject][ordered]@{
            enabled = $jobEnabled
            jobName = [string](& $getProp $jobRaw 'jobName' '')
            command = [string](& $getProp $jobRaw 'command' '')
        }
    }

    if (-not [bool]$app.enabled) {
        throw "Application '$Application' is disabled in apps.json."
    }

    foreach ($required in @('containerAppName','imageName','targetPort','healthPath','identity','entra','keyVault','postgres','storage','job')) {
        if ($null -eq $app.PSObject.Properties[$required]) {
            throw "Application '$Application' is missing required configuration section/property '$required'."
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$app.identity.name)) {
        throw "Application '$Application' is missing identity.name in apps.json."
    }

    if ([bool]$app.storage.enabled -and [string]$app.storage.accountName -ne $StorageAccountName) {
        throw "Application '$Application' references storage account '$($app.storage.accountName)', but the foundation shared storage account is '$StorageAccountName'."
    }

    return $app
}

function Ensure-Foundation {
    Write-Step "1. Validate foundation"
    Require-Resource 'Microsoft.App/managedEnvironments' $ContainerAppsEnvironmentName
    Require-Resource 'Microsoft.ContainerRegistry/registries' $AcrName
    Require-Resource 'Microsoft.KeyVault/vaults' $KeyVaultName
    Require-Resource 'Microsoft.DBforPostgreSQL/flexibleServers' $PostgreSqlServerName
    Require-Resource 'Microsoft.Storage/storageAccounts' $StorageAccountName
    Require-Resource 'Microsoft.ManagedIdentity/userAssignedIdentities' $StorageIdentityName
    Require-Resource 'Microsoft.ManagedIdentity/userAssignedIdentities' $GithubIdentityName

    $state = Get-AzText @('postgres','flexible-server','show','--resource-group',$ResourceGroupName,'--name',$PostgreSqlServerName,'--query','state')
    if ($state -ne 'Ready') { throw "PostgreSQL is not Ready. Current state: $state" }

    if (-not (Test-Path -LiteralPath $RuntimeBicepPath)) {
        throw "runtime.bicep not found: $RuntimeBicepPath"
    }

    Write-Host "Foundation validation successful." -ForegroundColor Green
}

function Ensure-AppIdentity {
    param($App)
    Write-Step "2. Ensure $Application managed identity"
    $name = [string]$App.identity.name
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Application '$Application' has an empty identity.name."
    }

    # Use identity list for existence checks. This returns an empty array when
    # the identity is absent and avoids ResourceNotFound/native-stderr handling
    # differences across Windows PowerShell and Azure CLI versions.
    $existing = @(Get-AzJson @(
        'identity','list',
        '--resource-group',$ResourceGroupName,
        '--query',"[?name=='$($name.Replace("'","''"))'] | [0]"
    )) | Select-Object -First 1

    if ($null -eq $existing) {
        Write-Host "Managed identity '$name' does not exist. Creating it now..." -ForegroundColor Yellow
        Invoke-Az @('identity','create','--resource-group',$ResourceGroupName,'--name',$name,'--location',$Location,'--only-show-errors','--output','none')
    }
    else {
        Write-Host "Managed identity already exists: $name" -ForegroundColor Green
    }

    # Azure may need a short period before the newly-created identity is fully
    # readable. identity show returns principalId/clientId at the TOP LEVEL.
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $id = $null
        try {
            $id = Get-AzJson @(
                'identity','show',
                '--resource-group',$ResourceGroupName,
                '--name',$name
            ) -AllowNotFound
        }
        catch {
            $id = $null
        }

        if ($null -ne $id -and
            -not [string]::IsNullOrWhiteSpace([string]$id.id) -and
            -not [string]::IsNullOrWhiteSpace([string]$id.principalId) -and
            -not [string]::IsNullOrWhiteSpace([string]$id.clientId)) {
            Write-Host "Managed identity ready: $name" -ForegroundColor Green
            return $id
        }

        if ($attempt -lt 12) {
            Write-Host "Waiting for managed identity '$name' to become readable ($attempt/12)..." -ForegroundColor Gray
            Start-Sleep -Seconds 5
        }
    }

    throw "Managed identity '$name' could not be resolved after creation. Verify Azure RBAC/resource-provider access in resource group '$ResourceGroupName'."
}

function Ensure-EntraGroup {
    param($App)
    Write-Step "3. Ensure $Application Entra security group"
    $name = [string]$App.entra.groupName
    if ([string]::IsNullOrWhiteSpace($name)) {
        throw "Application '$Application' has an empty entra.groupName."
    }

    # Use list rather than group show so a missing group is represented by an
    # empty result without emitting a ResourceNotFound native error.
    $groups = Get-AzJson @(
        'ad','group','list',
        '--filter',"displayName eq '$($name.Replace("'","''"))'"
    )
    $group = @($groups | Where-Object { [string]$_.displayName -eq $name } | Select-Object -First 1)

    if ($group.Count -eq 0) {
        Write-Host "Creating Entra group: $name" -ForegroundColor Yellow
        $group = @(Get-AzJson @(
            'ad','group','create',
            '--display-name',$name,
            '--mail-nickname',($name -replace '[^a-zA-Z0-9]','')
        )) | Select-Object -First 1
    }
    else {
        $group = $group[0]
        Write-Host "Entra group already exists: $name" -ForegroundColor Green
    }

    if ($null -eq $group -or [string]::IsNullOrWhiteSpace([string]$group.id)) {
        throw "Unable to obtain Entra group object ID for '$name'."
    }
    return [string]$group.id
}

function Ensure-AppRegistration {
    param($App,[string]$GroupId)
    Write-Step "4. Ensure $Application app registration"

    $name = [string]$App.entra.applicationName
    $appReg = @(Get-AzJson @('ad','app','list','--display-name',$name)) | Select-Object -First 1

    if ($null -eq $appReg) {
        Write-Host "Creating app registration: $name"
        $appReg = Get-AzJson @('ad','app','create','--display-name',$name)
    } else {
        Write-Host "App registration already exists: $name"
    }

    if ($null -eq $appReg) { throw "Unable to obtain app registration '$name'." }

    $clientId = [string]$appReg.appId
    $sp = @(Get-AzJson @('ad','sp','list','--filter',"appId eq '$clientId'")) | Select-Object -First 1
    if ($null -eq $sp) {
        Write-Host "Creating service principal."
        Invoke-Az @('ad','sp','create','--id',$clientId,'--output','none')
        $sp = @(Get-AzJson @('ad','sp','list','--filter',"appId eq '$clientId'")) | Select-Object -First 1
        if ($null -eq $sp) { throw "Unable to obtain service principal for '$name'." }
    }

    return @{
        ClientId = $clientId
        ObjectId = [string]$appReg.id
        GroupId = $GroupId
    }
}

function Ensure-OnboardingKeyVaultAccess {
    param(
        [string]$SecretName
    )

    Write-Step "5. Ensure current operator can manage Key Vault secrets"

    # The onboarding operator needs secret write access only to this vault.
    # The script grants the least-privileged built-in role required for secret
    # create/update operations. It is intentionally scoped to this Key Vault.
    $subscriptionId = Get-AzText @('account','show','--query','id')
    if ([string]::IsNullOrWhiteSpace($subscriptionId)) {
        throw "Unable to resolve the current Azure subscription."
    }

    $signedInObjectId = Get-AzText @('ad','signed-in-user','show','--query','id')
    if ([string]::IsNullOrWhiteSpace($signedInObjectId)) {
        throw "Unable to resolve the object ID of the signed-in Azure user."
    }

    $scope = "/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.KeyVault/vaults/$KeyVaultName"
    $roleName = 'Key Vault Secrets Officer'

    $assignments = Get-AzJson @(
        'role','assignment','list',
        '--assignee',$signedInObjectId,
        '--scope',$scope,
        '--query',"[?roleDefinitionName=='$roleName']"
    ) -AllowNotFound

    if ($null -ne $assignments -and @($assignments).Count -gt 0) {
        Write-Host "Current operator already has '$roleName' on Key Vault '$KeyVaultName'." -ForegroundColor Green
        return
    }

    Write-Host "Granting '$roleName' to the current operator on Key Vault '$KeyVaultName'..."

    try {
        Invoke-Az @(
            'role','assignment','create',
            '--assignee-object-id',$signedInObjectId,
            '--assignee-principal-type','User',
            '--role',$roleName,
            '--scope',$scope,
            '--only-show-errors',
            '--output','none'
        )
    }
    catch {
        throw "Unable to grant '$roleName' to the current operator. The operator must already have Azure permission to create RBAC role assignments (for example Owner or User Access Administrator/RBAC Administrator) at this scope or a parent scope. The onboarding script cannot bootstrap that Azure control-plane permission without an existing privileged principal."
    }

    Write-Host "Key Vault Secrets Officer assignment created for the current operator." -ForegroundColor Green
    Write-Host "Waiting briefly for Azure RBAC propagation..." -ForegroundColor Yellow
    Start-Sleep -Seconds 15
}

function Ensure-ClientSecret {
    param(
        $App,
        [string]$ClientId
    )

    Write-Step "5. Ensure Entra client secret in Key Vault"

    $secretName = [string]$App.keyVault.authSecretName
    # Missing secrets are expected during first onboarding. Use list metadata
    # instead of `secret show` so SecretNotFound is never emitted as an error.
    $secretCount = Get-AzText @(
        'keyvault','secret','list',
        '--vault-name',$KeyVaultName,
        '--query',"[?name=='$secretName'] | length(@)"
    )

    if ([int]$secretCount -gt 0) {
        Write-Host "Key Vault secret already exists: $secretName" -ForegroundColor Green
        return
    }

    Write-Host "Generating Entra client secret and storing it directly in Key Vault."

    $oldNativePreference = $null
    $hasNativePreference = $false

    if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
        $hasNativePreference = $true
        $oldNativePreference = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }

    try {
        $credentialOutput = @(
            & az ad app credential reset `
                --id $ClientId `
                --append `
                --display-name "ACA-$Application" `
                --years 2 `
                --only-show-errors `
                --output json 2>$null
        )
        $credentialExitCode = $LASTEXITCODE
    }
    finally {
        if ($hasNativePreference) {
            $PSNativeCommandUseErrorActionPreference = $oldNativePreference
        }
    }

    if ($credentialExitCode -ne 0) {
        throw "Azure CLI failed while generating the Entra client secret."
    }

    $credentialText = ($credentialOutput -join "`n").Trim()
    if ([string]::IsNullOrWhiteSpace($credentialText)) {
        throw "Azure CLI returned no credential data."
    }

    try {
        $credential = $credentialText | ConvertFrom-Json
    }
    catch {
        throw "Azure CLI returned invalid credential JSON."
    }

    $password = if ($null -ne $credential -and $credential.PSObject.Properties.Name -contains 'password') { [string]$credential.password } else { '' }
    $keyId = if ($null -ne $credential -and $credential.PSObject.Properties.Name -contains 'keyId') { [string]$credential.keyId } else { '' }

    if ([string]::IsNullOrWhiteSpace($password)) {
        throw "Azure CLI did not return a client secret. No secret was written to Key Vault."
    }

    try {
        $oldNativePreference = $null
        $hasNativePreference = $false

        if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
            $hasNativePreference = $true
            $oldNativePreference = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
        }

        try {
            & az keyvault secret set `
                --vault-name $KeyVaultName `
                --name $secretName `
                --value $password `
                --output none 2>$null
            $secretExitCode = $LASTEXITCODE
        }
        finally {
            if ($hasNativePreference) {
                $PSNativeCommandUseErrorActionPreference = $oldNativePreference
            }
        }

        if ($secretExitCode -ne 0) {
            throw "Failed to store the generated Entra client secret in Key Vault."
        }
    }
    catch {
        # If Key Vault storage fails and we know the credential key ID,
        # remove the newly-created credential so a rerun does not accumulate
        # unused credentials.
        if (-not [string]::IsNullOrWhiteSpace($keyId)) {
            try {
                $oldNativePreference = $null
                $hasNativePreference = $false

                if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
                    $hasNativePreference = $true
                    $oldNativePreference = $PSNativeCommandUseErrorActionPreference
                    $PSNativeCommandUseErrorActionPreference = $false
                }

                try {
                    & az ad app credential delete --id $ClientId --key-id $keyId --output none 2>$null
                }
                finally {
                    if ($hasNativePreference) {
                        $PSNativeCommandUseErrorActionPreference = $oldNativePreference
                    }
                }
            }
            catch {
                Write-Host "Warning: generated Entra credential could not be automatically cleaned up." -ForegroundColor Yellow
            }
        }

        throw
    }

    Write-Host "Client secret generated and stored in Key Vault successfully." -ForegroundColor Green
}


function Ensure-StorageSecret {
    param($App)
    if (-not $App.storage.enabled) { return }

    Write-Step "6. Ensure Azure Files share and Key Vault storage secret"

    $share = [string]$App.storage.fileShareName

    # Check existence by listing shares. A missing share returns no matching
    # item, so ShareNotFound is never emitted by this check.
    $shares = Get-AzJson @(
        'storage','share-rm','list',
        '--resource-group',$ResourceGroupName,
        '--storage-account',$StorageAccountName
    ) -AllowNotFound

    $shareResource = @($shares | Where-Object { $_.name -eq $share } | Select-Object -First 1)

    if ($shareResource.Count -eq 0) {
        Write-Host "Creating Azure Files share: $share"
        Invoke-Az @(
            'storage','share-rm','create',
            '--resource-group',$ResourceGroupName,
            '--storage-account',$StorageAccountName,
            '--name',$share,
            '--quota','100',
            '--output','none'
        )
    } else {
        Write-Host "Azure Files share already exists: $share"
    }

    $secretName = [string]$App.keyVault.storageKeySecretName
    # Missing secrets are expected during first onboarding. Use list metadata
    # instead of `secret show` so SecretNotFound is never emitted as an error.
    $secretCount = Get-AzText @(
        'keyvault','secret','list',
        '--vault-name',$KeyVaultName,
        '--query',"[?name=='$secretName'] | length(@)"
    )
    if ([int]$secretCount -eq 0) {
        $key = Get-AzText @(
            'storage','account','keys','list',
            '--resource-group',$ResourceGroupName,
            '--account-name',$StorageAccountName,
            '--query','[0].value'
        )
        if ([string]::IsNullOrWhiteSpace($key)) { throw "Unable to obtain shared storage account key." }

        Invoke-Az @(
            'keyvault','secret','set',
            '--vault-name',$KeyVaultName,
            '--name',$secretName,
            '--value',$key,
            '--output','none'
        )
        Write-Host "Storage key stored in Key Vault." -ForegroundColor Green
    } else {
        Write-Host "Storage key secret already exists."
    }
}

function Ensure-KvSecretAccess {
    param([string]$PrincipalId,[string]$SecretName)
    $kvId = Get-AzText @('keyvault','show','--resource-group',$ResourceGroupName,'--name',$KeyVaultName,'--query','id')
    $scope = "$kvId/secrets/$SecretName"
    $assignments = @(Get-AzJson @('role','assignment','list','--scope',$scope,'--assignee-object-id',$PrincipalId))
    $hasAccess = $assignments | Where-Object { $_.roleDefinitionId -like '*4633458b-17de-408a-b874-0445c86b69e6' }
    if ($hasAccess) {
        Write-Host "KV Secrets User already assigned for $SecretName."
        return
    }
    Invoke-Az @(
        'role','assignment','create',
        '--assignee-object-id',$PrincipalId,
        '--assignee-principal-type','ServicePrincipal',
        '--role','Key Vault Secrets User',
        '--scope',$scope,
        '--output','none'
    )
}

function Ensure-StorageKvAccess {
    param($App)
    if (-not $App.storage.enabled) { return }
    Write-Step "7. Configure shared ACA storage identity access"
    $principalId = Get-AzText @(
        'identity','show',
        '--resource-group',$ResourceGroupName,
        '--name',$StorageIdentityName,
        '--query','principalId'
    )
    Ensure-KvSecretAccess -PrincipalId $principalId -SecretName ([string]$App.keyVault.storageKeySecretName)
}

function Ensure-AppKvAccess {
    param($App,$Identity)
    # Do not depend on the shape of the az identity JSON returned earlier.
    # Resolve the principalId directly from Azure.
    $principalId = Get-AzText @(
        'identity','show',
        '--resource-group',$ResourceGroupName,
        '--name',[string]$App.identity.name,
        '--query','principalId'
    )
    if ([string]::IsNullOrWhiteSpace($principalId)) {
        throw "Unable to resolve managed identity principalId for '$($App.identity.name)'."
    }
    Ensure-KvSecretAccess -PrincipalId $principalId -SecretName ([string]$App.keyVault.authSecretName)
}

function Ensure-AcrPull {
    param($Identity,$App)
    Write-Step "8. Configure ACR pull for $Application"

    $acrId = Get-AzText @('acr','show','--resource-group',$ResourceGroupName,'--name',$AcrName,'--query','id')
    # Resolve principalId directly instead of assuming $Identity.properties exists.
    $identityName = [string]$App.identity.name
    $principalId = if ($identityName) {
        Get-AzText @(
            'identity','show',
            '--resource-group',$ResourceGroupName,
            '--name',$identityName,
            '--query','principalId'
        )
    } else {
        ''
    }
    $existing = @(Get-AzJson @('role','assignment','list','--scope',$acrId,'--assignee-object-id',$principalId))
    $has = $existing | Where-Object { $_.roleDefinitionId -like '*7f951dda-4ed3-4680-a7ca-43fe172d538d' }
    if ($has) {
        Write-Host "AcrPull already assigned."
        return
    }
    Invoke-Az @(
        'role','assignment','create',
        '--assignee-object-id',$principalId,
        '--assignee-principal-type','ServicePrincipal',
        '--role','AcrPull',
        '--scope',$acrId,
        '--output','none'
    )
}

function Get-PostgresAdminGroupId {
    Write-Step "9. Resolve PostgreSQL Entra administrator group"

    # Use group list so a missing group is represented by an empty result rather
    # than a failed az group show command.
    $groupName = $PostgresAdminGroupName.Replace("'", "''")

    $groups = Get-AzJson @(
        'ad','group','list',
        '--filter',"displayName eq '$groupName'"
    )

    $group = @($groups | Where-Object {
        [string]$_.displayName -eq $PostgresAdminGroupName
    } | Select-Object -First 1)

    if ($group.Count -eq 0) {
        Write-Host "Creating PostgreSQL administrator group: $PostgresAdminGroupName" -ForegroundColor Yellow

        $group = @(Get-AzJson @(
            'ad','group','create',
            '--display-name',$PostgresAdminGroupName,
            '--mail-nickname',($PostgresAdminGroupName -replace '[^a-zA-Z0-9]','')
        )) | Select-Object -First 1
    }
    else {
        $group = $group[0]
        Write-Host "PostgreSQL administrator group already exists: $PostgresAdminGroupName" -ForegroundColor Green
    }

    if ($null -eq $group -or [string]::IsNullOrWhiteSpace([string]$group.id)) {
        throw "Unable to obtain PostgreSQL administrator group object ID."
    }

    $groupId = [string]$group.id

    # Match the previously working bootstrap design: the signed-in operator
    # must be a member of the PostgreSQL Entra admin group before requesting a
    # PostgreSQL Entra token. Keep this idempotent.
    $operatorId = Get-AzText @('ad','signed-in-user','show','--query','id')
    if ([string]::IsNullOrWhiteSpace($operatorId)) {
        throw "Unable to determine the signed-in Entra operator object ID."
    }

    $isMember = Get-AzText @(
        'ad','group','member','check',
        '--group',$groupId,
        '--member-id',$operatorId,
        '--query','value'
    )

    if ($isMember -eq 'true') {
        Write-Host "Current operator is already a member of '$PostgresAdminGroupName'." -ForegroundColor Green
    }
    else {
        Write-Host "Adding current operator to '$PostgresAdminGroupName' for PostgreSQL bootstrap..." -ForegroundColor Yellow

        Invoke-Az @(
            'ad','group','member','add',
            '--group',$groupId,
            '--member-id',$operatorId,
            '--only-show-errors',
            '--output','none'
        )

        Write-Host "Current operator added to '$PostgresAdminGroupName'." -ForegroundColor Green
    }

    return $groupId
}

function Escape-SqlIdentifier {
    param([string]$Value)
    return '"' + $Value.Replace('"','""') + '"'
}

function Escape-SqlLiteral {
    param([string]$Value)
    return $Value.Replace("'","''")
}

function Ensure-PostgreSqlEntraAdministrator {
    param([Parameter(Mandatory = $true)][string]$AdminGroupId)

    Write-Step "9. Configure PostgreSQL Microsoft Entra administrator"

    if ([string]::IsNullOrWhiteSpace($AdminGroupId)) {
        throw "PostgreSQL Entra administrator group object ID is empty."
    }

    # Read the currently configured PostgreSQL Entra administrator. The list
    # command is safe when no administrator exists and avoids ResourceNotFound.
    $admins = @(Get-AzJson @(
        'postgres','flexible-server','microsoft-entra-admin','list',
        '--resource-group',$ResourceGroupName,
        '--server-name',$PostgreSqlServerName
    ))
    $current = $admins | Select-Object -First 1

    $currentObjectId = if ($null -ne $current -and $current.PSObject.Properties.Name -contains 'objectId') { [string]$current.objectId } else { '' }

    if ($currentObjectId -eq $AdminGroupId) {
        Write-Host "PostgreSQL Microsoft Entra administrator is already configured correctly." -ForegroundColor Green
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($currentObjectId)) {
            Write-Host "PostgreSQL has a different Entra administrator. Replacing it with '$PostgresAdminGroupName'..." -ForegroundColor Yellow
            Invoke-Az @(
                'postgres','flexible-server','microsoft-entra-admin','delete',
                '--resource-group',$ResourceGroupName,
                '--server-name',$PostgreSqlServerName,
                '--yes',
                '--only-show-errors',
                '--output','none'
            )
        }
        else {
            Write-Host "No PostgreSQL Microsoft Entra administrator is configured. Creating '$PostgresAdminGroupName'..." -ForegroundColor Yellow
        }

        Invoke-Az @(
            'postgres','flexible-server','microsoft-entra-admin','create',
            '--resource-group',$ResourceGroupName,
            '--server-name',$PostgreSqlServerName,
            '--display-name',$PostgresAdminGroupName,
            '--object-id',$AdminGroupId,
            '--type','Group',
            '--only-show-errors',
            '--output','none'
        )
    }

    # Verify with retries because PostgreSQL control-plane changes can take
    # time to converge before the administrator is returned by list.
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        $verifyList = @(Get-AzJson @(
            'postgres','flexible-server','microsoft-entra-admin','list',
            '--resource-group',$ResourceGroupName,
            '--server-name',$PostgreSqlServerName
        ))
        $verify = $verifyList | Select-Object -First 1
        $verifiedObjectId = if ($null -ne $verify -and $verify.PSObject.Properties.Name -contains 'objectId') { [string]$verify.objectId } else { '' }

        if ($verifiedObjectId -eq $AdminGroupId) {
            Write-Host "PostgreSQL Microsoft Entra administrator verified: $PostgresAdminGroupName ($AdminGroupId)." -ForegroundColor Green
            return
        }

        if ($attempt -lt 12) {
            Write-Host "Waiting for PostgreSQL Entra administrator propagation ($attempt/12)..." -ForegroundColor Gray
            Start-Sleep -Seconds 10
        }
    }

    throw "PostgreSQL Microsoft Entra administrator verification failed. Expected group object ID '$AdminGroupId'."
}

function Ensure-PostgreSqlApplicationAccess {
    param(
        [Parameter(Mandatory = $true)]$App,
        [Parameter(Mandatory = $true)][string]$PrincipalId,
        [Parameter(Mandatory = $true)][string]$PostgresAdminGroupId
    )

    if (-not [bool]$App.postgres.enabled) {
        return
    }

    Write-Step "10. Ensure PostgreSQL application database and schema"

    $databaseName = [string]$App.postgres.databaseName
    $schemaName = [string]$App.postgres.schemaName
    $identityName = [string]$App.identity.name

    if ([string]::IsNullOrWhiteSpace($databaseName)) { throw "PostgreSQL database name is missing for '$Application'." }
    if ([string]::IsNullOrWhiteSpace($schemaName)) { throw "PostgreSQL schema name is missing for '$Application'." }
    if ($databaseName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Unsupported PostgreSQL database name '$databaseName'. Use only letters, numbers and underscores, starting with a letter or underscore." }
    if ($schemaName -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') { throw "Unsupported PostgreSQL schema name '$schemaName'. Use only letters, numbers and underscores, starting with a letter or underscore." }
    if ([string]::IsNullOrWhiteSpace($PrincipalId)) { throw "Managed identity principalId is missing for '$identityName'." }
    if ([string]::IsNullOrWhiteSpace($PostgresAdminGroupId)) { throw "PostgreSQL administrator group object ID is missing." }

    $pgHost = Get-AzText @(
        'postgres','flexible-server','show',
        '--resource-group',$ResourceGroupName,
        '--name',$PostgreSqlServerName,
        '--query','fullyQualifiedDomainName'
    )

    $dbId = Escape-SqlIdentifier $databaseName
    $dbLiteral = Escape-SqlLiteral $databaseName
    $schemaId = Escape-SqlIdentifier $schemaName
    $roleId = Escape-SqlIdentifier $identityName
    $roleLiteral = Escape-SqlLiteral $identityName
    $principalLiteral = Escape-SqlLiteral $PrincipalId

    # The role is created as a Microsoft Entra service principal in PostgreSQL.
    # The database is created outside a transaction, then the application schema
    # is created with the application managed identity as owner.
    $roleSql = @"
DO `$`$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$roleLiteral') THEN
    PERFORM pg_catalog.pgaadauth_create_principal_with_oid('$roleLiteral', '$principalLiteral', 'service', false, false);
  END IF;
END
`$`$;
"@

    $roleSqlB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($roleSql))
    $grantSql = "GRANT CONNECT ON DATABASE $dbId TO $roleId; CREATE SCHEMA IF NOT EXISTS $schemaId AUTHORIZATION $roleId; GRANT USAGE, CREATE ON SCHEMA $schemaId TO $roleId;"
    $grantSqlB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($grantSql))

    $bootstrapScript = @"
set -eu

echo "Starting PostgreSQL application bootstrap..."

printf '%s' "`$BOOTSTRAP_ROLE_SQL_B64" | base64 -d | psql -v ON_ERROR_STOP=1

echo "Checking $dbLiteral database..."
if [ "`$(psql -Atqc "SELECT 1 FROM pg_database WHERE datname = '$dbLiteral'")" != "1" ]; then
    echo "Creating $dbLiteral database..."
    createdb "$databaseName"
fi

printf '%s' "`$BOOTSTRAP_GRANT_SQL_B64" | base64 -d | psql -v ON_ERROR_STOP=1 -d $dbId

echo "PostgreSQL application database/schema bootstrap completed successfully."
"@

    $bootstrapJob = 'nanda-pg-app-bootstrap'
    $adminToken = $null

    try {
        $existingJob = Get-AzText @(
            'containerapp','job','list',
            '--resource-group',$ResourceGroupName,
            '--query',"[?name=='$bootstrapJob'].name | [0]"
        ) 2>$null

        if (-not [string]::IsNullOrWhiteSpace($existingJob)) {
            Invoke-Az @(
                'containerapp','job','delete',
                '--name',$bootstrapJob,
                '--resource-group',$ResourceGroupName,
                '--yes',
                '--only-show-errors',
                '--output','none'
            )
        }

        for ($attempt = 1; $attempt -le 6; $attempt++) {
            Write-Host "Obtaining PostgreSQL Entra admin token (attempt $attempt/6)..." -ForegroundColor Yellow

            $adminToken = Get-AzText @(
                'account','get-access-token',
                '--resource','https://ossrdbms-aad.database.windows.net',
                '--query','accessToken'
            )

            $sqlArgs = @(
                'containerapp','job','create',
                '--name',$bootstrapJob,
                '--resource-group',$ResourceGroupName,
                '--environment',$ContainerAppsEnvironmentName,
                '--trigger-type','Manual',
                '--replica-timeout','120',
                '--replica-retry-limit','0',
                '--replica-completion-count','1',
                '--parallelism','1',
                '--image','postgres:16',
                '--container-name','postgres',
                '--cpu','0.25',
                '--memory','0.5Gi',
                '--secrets',"pg-admin-token=$adminToken",
                '--env-vars',
                'PGPASSWORD=secretref:pg-admin-token',
                "PGHOST=$pgHost",
                'PGPORT=5432',
                "PGUSER=$PostgresAdminGroupName",
                'PGDATABASE=postgres',
                'PGSSLMODE=require',
                "BOOTSTRAP_ROLE_SQL_B64=$roleSqlB64",
                "BOOTSTRAP_GRANT_SQL_B64=$grantSqlB64",
                '--only-show-errors',
                '--output','none'
            )

            Invoke-Az $sqlArgs

            # Azure CLI versions can omit command/args on Job create, so patch them
            # through the Container Apps management API and verify persistence.
            $jobJson = Get-AzJson @(
                'containerapp','job','show',
                '--name',$bootstrapJob,
                '--resource-group',$ResourceGroupName
            )

            $container = $jobJson.properties.template.containers[0]
            $container | Add-Member -MemberType NoteProperty -Name command -Value @('/bin/sh') -Force
            $container | Add-Member -MemberType NoteProperty -Name args -Value @('-c',$bootstrapScript) -Force
            $patchBody = @{
                properties = @{
                    template = @{
                        containers = @($container)
                    }
                }
            } | ConvertTo-Json -Depth 30 -Compress

            # Use Azure CLI's authenticated ARM REST client instead of
            # Invoke-RestMethod. This avoids Windows PowerShell HTTP handling
            # issues and keeps authentication entirely inside Azure CLI.
            #
            # Use the stable Container Apps API version currently documented
            # for Job operations. The 2026-01-01 API exists, but the PATCH
            # against the Job resource can return a generic InternalServerError
            # from this client path. The 2025-07-01 resource API accepts the
            # Job template container command/args used here.
            $subscriptionId = Get-AzText @('account','show','--query','id')
            $jobUri = "https://management.azure.com/subscriptions/$subscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.App/jobs/${bootstrapJob}?api-version=2025-07-01"

            $patchFile = Join-Path $env:TEMP ("aca-pg-bootstrap-{0}.json" -f ([guid]::NewGuid().ToString('N')))
            try {
                [System.IO.File]::WriteAllText(
                    $patchFile,
                    $patchBody,
                    [System.Text.UTF8Encoding]::new($false)
                )

                $patchOutput = & az rest `
                    --method PATCH `
                    --url $jobUri `
                    --headers Content-Type=application/json `
                    --body "@$patchFile" `
                    --only-show-errors `
                    --output none 2>&1

                $patchExitCode = $LASTEXITCODE
                if ($patchExitCode -ne 0) {
                    $patchMessage = ($patchOutput -join "`n").Trim()
                    if ([string]::IsNullOrWhiteSpace($patchMessage)) {
                        $patchMessage = "Azure CLI REST PATCH returned exit code $patchExitCode."
                    }
                    throw "Failed to patch PostgreSQL bootstrap Job command/args: $patchMessage"
                }
            }
            finally {
                if (Test-Path -LiteralPath $patchFile) {
                    Remove-Item -LiteralPath $patchFile -Force -ErrorAction SilentlyContinue
                }
            }

            $verifyJob = Get-AzJson @(
                'containerapp','job','show',
                '--name',$bootstrapJob,
                '--resource-group',$ResourceGroupName
            )
            $configuredContainer = $verifyJob.properties.template.containers[0]
            if (@($configuredContainer.command).Count -ne 1 -or $configuredContainer.command[0] -ne '/bin/sh') {
                throw 'Azure did not persist the PostgreSQL bootstrap command.'
            }

            $execution = Get-AzText @(
                'containerapp','job','start',
                '--name',$bootstrapJob,
                '--resource-group',$ResourceGroupName,
                '--query','name'
            )

            $completed = $false
            for ($poll = 1; $poll -le 30; $poll++) {
                $status = Get-AzText @(
                    'containerapp','job','execution','show',
                    '--name',$bootstrapJob,
                    '--resource-group',$ResourceGroupName,
                    '--job-execution-name',$execution,
                    '--query','properties.status'
                )
                Write-Host "PostgreSQL bootstrap execution status: $status" -ForegroundColor Gray

                if ($status -eq 'Succeeded') {
                    $completed = $true
                    break
                }

                if ($status -in @('Failed','Canceled')) {
                    break
                }

                Start-Sleep -Seconds 5
            }

            if ($completed) {
                Write-Host "PostgreSQL database '$databaseName' and schema '$schemaName' are ready for '$identityName'." -ForegroundColor Green
                return
            }

            if ($attempt -lt 6) {
                Write-Host "PostgreSQL bootstrap did not succeed; retrying..." -ForegroundColor Yellow
                Invoke-Az @(
                    'containerapp','job','delete',
                    '--name',$bootstrapJob,
                    '--resource-group',$ResourceGroupName,
                    '--yes',
                    '--only-show-errors',
                    '--output','none'
                )
                Start-Sleep -Seconds 10
            }
        }

        throw "PostgreSQL application bootstrap failed after 6 attempts for '$Application'."
    }
    finally {
        $adminToken = $null
        try {
            $jobCheck = Get-AzText @(
                'containerapp','job','list',
                '--resource-group',$ResourceGroupName,
                '--query',"[?name=='$bootstrapJob'].name | [0]"
            ) 2>$null

            if (-not [string]::IsNullOrWhiteSpace($jobCheck)) {
                Invoke-Az @(
                    'containerapp','job','delete',
                    '--name',$bootstrapJob,
                    '--resource-group',$ResourceGroupName,
                    '--yes',
                    '--only-show-errors',
                    '--output','none'
                )
            }
        }
        catch {
            Write-Host "Temporary PostgreSQL bootstrap Job cleanup skipped: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

function Get-NotificationEmail {
    $email = Get-AzText @(
        'monitor','action-group','show',
        '--resource-group',$ResourceGroupName,
        '--name',$MonitoringActionGroupName,
        '--query','emailReceivers[0].emailAddress'
    )
    if ([string]::IsNullOrWhiteSpace($email)) {
        $email = Read-Host "Enter monitoring notification email"
    }
    if ([string]::IsNullOrWhiteSpace($email)) {
        throw "A monitoring notification email is required for runtime monitoring."
    }
    return $email
}

function Convert-ToRuntimeConfig {
    param($App)

    # runtime.bicep expects the same application contract used by apps/apps.json:
    # { key = '<app>'; value = <application object> }.
    # Do not translate the configuration into a second/nested schema.
    $runtimeApp = [ordered]@{
        key = $Application
        value = [ordered]@{
            displayName = [string]$App.displayName
            enabled = [bool]$App.enabled
            containerAppName = [string]$App.containerAppName
            imageName = [string]$App.imageName
            buildContext = [string]$App.buildContext
            dockerfile = [string]$App.dockerfile
            targetPort = [int]$App.targetPort
            healthPath = [string]$App.healthPath
            minReplicas = [int]$App.minReplicas
            maxReplicas = [int]$App.maxReplicas
            ingress = [ordered]@{
                external = [bool]$App.ingress.external
                transport = [string]$App.ingress.transport
            }
            identity = [ordered]@{
                name = [string]$App.identity.name
            }
            entra = [ordered]@{
                groupName = [string]$App.entra.groupName
                applicationName = [string]$App.entra.applicationName
                redirectPath = if ($App.entra.PSObject.Properties.Name -contains 'redirectPath') { [string]$App.entra.redirectPath } else { '/.auth/login/aad/callback' }
            }
            keyVault = [ordered]@{
                authSecretName = [string]$App.keyVault.authSecretName
                storageKeySecretName = [string]$App.keyVault.storageKeySecretName
                readAuthSecret = if ($App.keyVault.PSObject.Properties.Name -contains 'readAuthSecret') { [bool]$App.keyVault.readAuthSecret } else { $true }
                readStorageKeySecret = if ($App.keyVault.PSObject.Properties.Name -contains 'readStorageKeySecret') { [bool]$App.keyVault.readStorageKeySecret } else { [bool]$App.storage.enabled }
            }
            postgres = [ordered]@{
                enabled = [bool]$App.postgres.enabled
                databaseName = [string]$App.postgres.databaseName
                schemaName = [string]$App.postgres.schemaName
            }
            storage = [ordered]@{
                enabled = [bool]$App.storage.enabled
                accountName = [string]$App.storage.accountName
                fileShareName = [string]$App.storage.fileShareName
                bindingName = if ($App.storage.PSObject.Properties.Name -contains 'bindingName' -and -not [string]::IsNullOrWhiteSpace([string]$App.storage.bindingName)) { [string]$App.storage.bindingName } else { "nanda-$Application-storage" }
                mountPath = [string]$App.storage.mountPath
            }
            job = [ordered]@{
                enabled = [bool]$App.job.enabled
                jobName = [string]$App.job.jobName
                command = [string]$App.job.command
            }
        }
    }

    $enabledApplications = @($runtimeApp)
    $storageApplications = @()
    $jobApplications = @()
    $authApplications = @($runtimeApp)

    if ([bool]$App.storage.enabled) { $storageApplications += $runtimeApp }
    if ([bool]$App.job.enabled) { $jobApplications += $runtimeApp }

    return @{
        enabledApplications = $enabledApplications
        storageApplications = $storageApplications
        jobApplications = $jobApplications
        authApplications = $authApplications
    }
}

function New-DeploymentParameterFile {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Values
    )

    $file = Join-Path $env:TEMP ("arrowhead-runtime-" + [guid]::NewGuid().ToString('N') + '.json')
    $parameterObject = [ordered]@{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0'
        parameters = [ordered]@{}
    }
    foreach ($key in $Values.Keys) {
        $parameterObject.parameters[$key] = @{ value = $Values[$key] }
    }
    $parameterObject | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $file -Encoding UTF8
    return $file
}

function Invoke-Runtime {
    param(
        $App,
        [string]$GroupId,
        [string]$ClientId,
        [string]$PostgresAdminGroupId,
        [string]$NotificationEmail
    )

    Write-Step "11. Deploy $Application runtime"

    if (-not (Test-Path -LiteralPath $RuntimeBicepPath)) {
        throw "runtime.bicep not found: $RuntimeBicepPath"
    }

    $runtime = Convert-ToRuntimeConfig -App $App
    $entraMetadata = [ordered]@{}
    $entraMetadata[$Application] = [ordered]@{
        groupId = $GroupId
        clientId = $ClientId
    }

    # Use the standard ARM deployment-parameters document. This prevents
    # singleton arrays from being interpreted as objects by the Azure CLI/Bicep
    # parameter deserializer.
    $parameterFile = New-DeploymentParameterFile -Values @{
        enabledApplications = @($runtime.enabledApplications)
        storageApplications = @($runtime.storageApplications)
        jobApplications = @($runtime.jobApplications)
        authApplications = @($runtime.authApplications)
        entraMetadata = $entraMetadata
    }

    try {
        Invoke-Az @(
            'deployment','group','create',
            '--resource-group',$ResourceGroupName,
            '--template-file',$RuntimeBicepPath,
            '--parameters',"@$parameterFile",
            '--parameters',"location=$Location",
            "postgresqlEntraAdministratorObjectId=$PostgresAdminGroupId",
            "postgresqlEntraAdministratorName=$PostgresAdminGroupName",
            "tenantId=$((Get-AzText @('account','show','--query','tenantId')))",
            "notificationEmail=$NotificationEmail",
            "acrName=$AcrName",
            "keyVaultName=$KeyVaultName",
            "postgresqlServerName=$PostgreSqlServerName",
            "containerAppsEnvironmentName=$ContainerAppsEnvironmentName",
            "storageIdentityName=$StorageIdentityName",
            "githubIdentityName=$GithubIdentityName",
            "logAnalyticsWorkspaceName=$LogAnalyticsWorkspaceName",
            "monitoringActionGroupName=$MonitoringActionGroupName",
            '--only-show-errors',
            '--output','none'
        )
    }
    finally {
        Remove-Item -LiteralPath $parameterFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host "$Application runtime deployment completed." -ForegroundColor Green
}

function Configure-RedirectUri {
    param($App,[string]$ClientId)

    Write-Step "12. Configure Entra redirect URI for $Application"

    $fqdn = Get-AzText @(
        'containerapp','show',
        '--resource-group',$ResourceGroupName,
        '--name',[string]$App.containerAppName,
        '--query','properties.configuration.ingress.fqdn'
    )

    if ([string]::IsNullOrWhiteSpace($fqdn)) {
        throw "$Application Container App FQDN could not be resolved."
    }

    $uri = "https://$fqdn/.auth/login/aad/callback"

    $appRegistration = Get-AzJson @('ad','app','show','--id',$ClientId)
    $existingUris = @()

    if ($null -ne $appRegistration -and $null -ne $appRegistration.web -and $null -ne $appRegistration.web.redirectUris) {
        $existingUris = @($appRegistration.web.redirectUris | ForEach-Object { [string]$_ })
    }

    if ($existingUris -notcontains $uri) {
        $updatedUris = @($existingUris + $uri)

        $redirectArgs = @(
            'ad','app','update',
            '--id',$ClientId,
            '--web-redirect-uris'
        ) + $updatedUris

        Invoke-Az -Arguments $redirectArgs
    }
    else {
        Write-Host "Redirect URI already configured." -ForegroundColor Green
    }

    Write-Host "Redirect URI: $uri" -ForegroundColor Green
    Write-Host "Redirect URI configured: $uri" -ForegroundColor Green
}

function Ensure-AzureFilesBackup {
    param($App)

    if (-not $App.storage.enabled) { return }

    Write-Step "13. Ensure Azure Files backup protection"

    $vault = Get-AzJson @(
        'backup','vault','show',
        '--resource-group',$ResourceGroupName,
        '--name',$RecoveryServicesVaultName
    ) -AllowNotFound
    if ($null -eq $vault) {
        Write-Host "Recovery Services Vault '$RecoveryServicesVaultName' was not found; foundation backup infrastructure must be deployed first." -ForegroundColor Yellow
        return
    }

    $policy = Get-AzJson @(
        'backup','policy','show',
        '--resource-group',$ResourceGroupName,
        '--vault-name',$RecoveryServicesVaultName,
        '--name',$AzureFilesBackupPolicyName
    ) -AllowNotFound
    if ($null -eq $policy) {
        throw "Azure Files backup policy '$AzureFilesBackupPolicyName' was not found."
    }

    $protected = Get-AzJson @(
        'backup','item','list',
        '--resource-group',$ResourceGroupName,
        '--vault-name',$RecoveryServicesVaultName,
        '--backup-management-type','AzureStorage',
        '--workload-type','AzureFileShare',
'--query',"[?contains(properties.sourceResourceId, '$StorageAccountName') && properties.containerName=='$($App.storage.fileShareName)']"
    )

    if ($protected) {
        Write-Host "Azure Files share is already protected by Recovery Services." -ForegroundColor Green
        return
    }

    # Azure Backup discovery can lag behind creation of a new file share.
    # Retry the protection operation instead of failing the whole onboarding
    # because the share has not appeared in the vault's discovery view yet.
    $maxAttempts = 4
    $protectedSuccessfully = $false

    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            Invoke-Az @(
                'backup','protection','enable-for-azurefileshare',
                '--resource-group',$ResourceGroupName,
                '--vault-name',$RecoveryServicesVaultName,
                '--storage-account',$StorageAccountName,
                '--azure-file-share',$App.storage.fileShareName,
                '--policy-name',$AzureFilesBackupPolicyName,
                '--only-show-errors',
                '--output','none'
            )

            $protectedSuccessfully = $true
            break
        }
        catch {
            if ($attempt -eq $maxAttempts) {
                throw "Azure Files backup protection could not be enabled after $maxAttempts attempts. The Recovery Services vault/policy exists, but Azure Backup has not accepted protection for share '$($App.storage.fileShareName)'."
            }

            Write-Host "Azure Backup has not accepted the share yet. Waiting 20 seconds before retry $($attempt + 1)/$maxAttempts..." -ForegroundColor Yellow
            Start-Sleep -Seconds 20
        }
    }

    if (-not $protectedSuccessfully) {
        throw "Azure Files backup protection was not enabled."
    }

    Write-Host "Azure Files backup protection enabled." -ForegroundColor Green
}

function Validate-Onboarding {
    param($App,[string]$GroupId)

    Write-Step "14. Validate $Application onboarding"

    $ca = Get-AzJson @('containerapp','show','--resource-group',$ResourceGroupName,'--name',$App.containerAppName)
    if ($null -eq $ca) { throw "$Application Container App was not created." }

    # The ACA environment is internal/private. In an internal ACA environment,
    # ingress.external=true means the app is exposed through the environment's
    # internal ingress, not the public internet. The environment's public
    # network access is the boundary that keeps the workload private.
    $environment = Get-AzJson @(
        'containerapp','env','show',
        '--resource-group',$ResourceGroupName,
        '--name',$ContainerAppsEnvironmentName
    )
    if ($null -eq $environment) {
        throw "ACA environment '$ContainerAppsEnvironmentName' could not be read."
    }
    if ([string]$environment.properties.publicNetworkAccess -ne 'Disabled') {
        throw "ACA environment '$ContainerAppsEnvironmentName' has public network access enabled. Private/internal deployment requires publicNetworkAccess=Disabled."
    }

    if ([bool]$ca.properties.configuration.ingress.allowInsecure) {
        throw "$Application allows insecure HTTP. HTTPS-only ingress is required."
    }

    $auth = Get-AzJson @('containerapp','auth','show','--resource-group',$ResourceGroupName,'--name',$App.containerAppName)
    if ($null -eq $auth -or -not [bool]$auth.platform.enabled) {
        throw "$Application ACA built-in authentication is not enabled."
    }

    Write-Host "Container App + internal ingress + Easy Auth validation: PASS" -ForegroundColor Green

    if ([bool]$App.storage.enabled) {
        $share = [string]$App.storage.fileShareName
        $shares = Get-AzJson @(
            'storage','share-rm','list',
            '--resource-group',$ResourceGroupName,
            '--storage-account',$StorageAccountName
        ) -AllowNotFound
        $shareExists = @($shares | Where-Object { $_.name -eq $share }).Count -gt 0
        if (-not $shareExists) { throw "$Application Azure Files share is missing." }
        Write-Host "Azure Files share validation: PASS" -ForegroundColor Green
    }
    else {
        Write-Host "Azure Files share validation: SKIPPED (not configured for $Application)" -ForegroundColor Gray
    }

    if ([bool]$App.job.enabled) {
        $job = Get-AzJson @('containerapp','job','show','--resource-group',$ResourceGroupName,'--name',$App.job.jobName)
        if ($null -eq $job) { throw "$Application ACA Job is missing." }
        Write-Host "ACA Job validation: PASS" -ForegroundColor Green
    }
    else {
        Write-Host "ACA Job validation: SKIPPED (not configured for $Application)" -ForegroundColor Gray
    }

    Write-Host ""
    Write-Host "NOTE: PostgreSQL database/schema boundary is provisioned here; RI owns application tables and data model." -ForegroundColor Yellow
    Write-Host "The Arrowhead requirements assign application table/data-model ownership to RI; this onboarding provisions the database, application schema, identity access and platform/runtime boundary." -ForegroundColor Yellow
}

function Show-Summary {
    param($App)
    Write-Step "$Application onboarding complete"
    Write-Host "Resource Group       : $ResourceGroupName"
    Write-Host "Container App        : $($App.containerAppName)"
    Write-Host "Managed Identity     : $($App.identity.name)"
    Write-Host "Entra Group          : $($App.entra.groupName)"
    Write-Host "App Registration     : $($App.entra.applicationName)"
    Write-Host "Key Vault            : $KeyVaultName"
    if ([bool]$App.storage.enabled) {
        Write-Host "Storage Account      : $StorageAccountName"
        Write-Host "File Share           : $($App.storage.fileShareName)"
    }
    if ([bool]$App.postgres.enabled) {
        Write-Host "PostgreSQL           : $PostgreSqlServerName / $($App.postgres.databaseName)"
        Write-Host "Schema               : $($App.postgres.schemaName) (RI-owned)"
    }
    if ([bool]$App.job.enabled) {
        Write-Host "ACA Job              : $($App.job.jobName)"
    }
    Write-Host ""
    Write-Host "$($Application.ToUpperInvariant()) ONBOARDING SUCCESSFUL" -ForegroundColor Green
}

# Main
Write-Step "$Application application onboarding"
Write-Host "Application: $Application"

Invoke-Az @('account','show','--output','none')
Ensure-Foundation
$app = Get-AppConfig

$identity = Ensure-AppIdentity -App $app
$groupId = Ensure-EntraGroup -App $app
$appRegistration = Ensure-AppRegistration -App $app -GroupId $groupId

Ensure-OnboardingKeyVaultAccess -SecretName ([string]$app.keyVault.authSecretName)
Ensure-ClientSecret -App $app -ClientId $appRegistration.ClientId
Ensure-StorageSecret -App $app
Ensure-AppKvAccess -App $app -Identity $identity
Ensure-StorageKvAccess -App $app
Ensure-AcrPull -Identity $identity -App $app

$postgresAdminGroupId = Get-PostgresAdminGroupId
Ensure-PostgreSqlEntraAdministrator -AdminGroupId $postgresAdminGroupId

if ([bool]$app.postgres.enabled) {
    $appPrincipalId = Get-AzText @(
        'identity','show',
        '--resource-group',$ResourceGroupName,
        '--name',[string]$app.identity.name,
        '--query','principalId'
    )

    Ensure-PostgreSqlApplicationAccess `
        -App $app `
        -PrincipalId $appPrincipalId `
        -PostgresAdminGroupId $postgresAdminGroupId
}

$notificationEmail = Get-NotificationEmail

Invoke-Runtime `
    -App $app `
    -GroupId $groupId `
    -ClientId $appRegistration.ClientId `
    -PostgresAdminGroupId $postgresAdminGroupId `
    -NotificationEmail $notificationEmail

Configure-RedirectUri -App $app -ClientId $appRegistration.ClientId
Ensure-AzureFilesBackup -App $app
Validate-Onboarding -App $app -GroupId $groupId
Show-Summary -App $app
