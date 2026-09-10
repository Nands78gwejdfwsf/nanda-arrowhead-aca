[CmdletBinding()]
param(
    [string]$ResourceGroupName = 'NANDA-rg-arrowhead-aca-test'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw 'Azure CLI is not installed or not in PATH.'
}

$account = az account show --only-show-errors --output json 2>$null
if ($LASTEXITCODE -ne 0) {
    throw 'Azure CLI is not logged in. Run az login first.'
}

Write-Host "Deleting resource group '$ResourceGroupName'..." -ForegroundColor Yellow
az group delete --name $ResourceGroupName --yes --no-wait --only-show-errors
if ($LASTEXITCODE -ne 0) {
    throw "Failed to start deletion of resource group '$ResourceGroupName'."
}

Write-Host 'Resource group deletion started.' -ForegroundColor Green
Write-Host 'Tenant-level Entra groups and app registrations are intentionally not deleted.' -ForegroundColor Gray
