# Install (or uninstall) the `az connector-namespace` Azure CLI extension.
#
# Usage:
#   # Default: install the version pinned below ($DefaultVersion)
#   irm https://raw.githubusercontent.com/Azure/Connectors/main/docs/early/cli/install.ps1 | iex
#
#   # Pin a different version:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Azure/Connectors/main/docs/early/cli/install.ps1))) -Version 1.0.0b9
#
#   # Uninstall:
#   & ([scriptblock]::Create((irm https://raw.githubusercontent.com/Azure/Connectors/main/docs/early/cli/install.ps1))) -Uninstall

[CmdletBinding()]
param(
    [string]$Version,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$Repo    = 'Azure/Connectors'
$ExtName = 'connector-namespace'
$PkgName = 'connector_namespace'

# Single source of truth — bump this with each new release.
$DefaultVersion = '1.0.0b9'

# Check for Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Write-Error "Azure CLI ('az') not found. Install it first: https://learn.microsoft.com/cli/azure/install-azure-cli"
    exit 1
}

if ($Uninstall) {
    $installed = (az extension show --name $ExtName --query name -o tsv 2>$null)
    if ($installed) {
        az extension remove --name $ExtName
        Write-Host "Uninstalled '$ExtName'."
    } else {
        Write-Host "'$ExtName' is not installed; nothing to do."
    }
    return
}

# Resolve wheel URL.
# - If -Version (or $env:CONNECTOR_NAMESPACE_VERSION) is set, pin to that GitHub Release.
# - Otherwise, use the script's $DefaultVersion.
if (-not $Version -and $env:CONNECTOR_NAMESPACE_VERSION) {
    $Version = $env:CONNECTOR_NAMESPACE_VERSION
    $pinSource = '$env:CONNECTOR_NAMESPACE_VERSION'
} elseif ($Version) {
    $pinSource = '-Version'
}

if (-not $Version) {
    $Version = $DefaultVersion
    $pinSource = ''
}

$wheelUrl = "https://github.com/$Repo/releases/download/v$Version/${PkgName}-${Version}-py3-none-any.whl"

if ($pinSource) {
    Write-Host "Installing '$ExtName' v$Version (pinned via $pinSource)"
} else {
    Write-Host "Installing '$ExtName' v$Version (default)"
}
Write-Host "  Wheel: $wheelUrl"
Write-Host ""

# --upgrade so re-running this script updates an existing install.
# --yes accepts the "extension is in preview" prompt automatically.
az extension add --upgrade --yes --source $wheelUrl

Write-Host ""
Write-Host "✓ Installed. Try:" -ForegroundColor Green
Write-Host "    az connector-namespace --help"
