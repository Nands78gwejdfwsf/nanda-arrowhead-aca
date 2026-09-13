param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot '..\apps\apps.json')
)

$ErrorActionPreference = 'Stop'

function Fail([string]$Message) { Write-Error $Message; exit 1 }
if (-not (Test-Path -LiteralPath $ConfigPath)) { Fail "Application configuration not found: $ConfigPath" }
try { $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json } catch { Fail "apps.json is not valid JSON: $($_.Exception.Message)" }
if ($null -eq $config.applications) { Fail "apps.json must contain an 'applications' object." }

$requiredTopLevel = @('displayName','enabled','containerAppName','imageName','buildContext','dockerfile','targetPort','healthPath','minReplicas','maxReplicas','ingress','identity','entra','keyVault','postgres','storage','job')
$names = @{}
foreach ($property in $config.applications.PSObject.Properties) {
    $key = $property.Name; $app = $property.Value
    if ([string]::IsNullOrWhiteSpace($key)) { Fail 'Application key cannot be empty.' }
    foreach ($field in $requiredTopLevel) { if ($null -eq $app.PSObject.Properties[$field]) { Fail "Application '$key' is missing required field '$field'." } }
    $caName=[string]$app.containerAppName
    if ($names.ContainsKey($caName)) { Fail "Duplicate containerAppName '$caName' used by '$key' and '$($names[$caName])'." }
    $names[$caName]=$key
    if ($app.enabled -and [string]::IsNullOrWhiteSpace([string]$app.buildContext)) { Fail "Enabled application '$key' must have buildContext." }
    if ($app.enabled -and [string]::IsNullOrWhiteSpace([string]$app.dockerfile)) { Fail "Enabled application '$key' must have dockerfile." }
    if ([int]$app.targetPort -lt 1 -or [int]$app.targetPort -gt 65535) { Fail "Application '$key' has invalid targetPort." }
    if ([int]$app.minReplicas -lt 0 -or [int]$app.maxReplicas -lt [int]$app.minReplicas) { Fail "Application '$key' has invalid replica settings." }
    if ([string]::IsNullOrWhiteSpace([string]$app.identity.name)) { Fail "Application '$key' must define identity.name." }
    if ([string]::IsNullOrWhiteSpace([string]$app.entra.groupName)) { Fail "Application '$key' must define entra.groupName." }
    if ([string]::IsNullOrWhiteSpace([string]$app.entra.applicationName)) { Fail "Application '$key' must define entra.applicationName." }
    if ($app.enabled -and -not $app.keyVault.readAuthSecret) { Fail "Application '$key' must have keyVault.readAuthSecret=true for Easy Auth." }
    if ([string]::IsNullOrWhiteSpace([string]$app.keyVault.authSecretName)) { Fail "Application '$key' must define keyVault.authSecretName." }
    if ($app.postgres.enabled) {
        if ([string]::IsNullOrWhiteSpace([string]$app.postgres.databaseName)) { Fail "Application '$key' has PostgreSQL enabled but no databaseName." }
        if ([string]::IsNullOrWhiteSpace([string]$app.postgres.schemaName)) { Fail "Application '$key' has PostgreSQL enabled but no schemaName." }
    }
    if ($app.storage.enabled) {
        foreach ($field in @('accountName','fileShareName','bindingName','mountPath','privateEndpointName','privateDnsLinkName','privateDnsZoneGroupName','backupPolicyName')) { if ([string]::IsNullOrWhiteSpace([string]$app.storage.$field)) { Fail "Application '$key' has storage enabled but storage.$field is empty." } }
        if (-not $app.keyVault.readStorageKeySecret) { Fail "Application '$key' has storage enabled but readStorageKeySecret is false." }
        if ([string]::IsNullOrWhiteSpace([string]$app.keyVault.storageKeySecretName)) { Fail "Application '$key' has storage enabled but storageKeySecretName is empty." }
    }
    if ($app.job.enabled) {
        if ([string]::IsNullOrWhiteSpace([string]$app.job.jobName)) { Fail "Application '$key' has job enabled but jobName is empty." }
        if ([string]::IsNullOrWhiteSpace([string]$app.job.command)) { Fail "Application '$key' has job enabled but job.command is empty." }
    }
}
Write-Host ''
Write-Host 'Application configuration validation PASSED.' -ForegroundColor Green
Write-Host 'Configured applications:'
foreach ($property in $config.applications.PSObject.Properties) { Write-Host ('  - {0} ({1})' -f $property.Name, $property.Value.displayName) }
Write-Host ''
