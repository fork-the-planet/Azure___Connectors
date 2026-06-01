# Install (or uninstall) the `az connector-namespace` Azure CLI extension.
#
# Usage:
#   # Default: install the latest published wheel (https://aka.ms/connector-namespace.whl)
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
$AkamsUrl = 'https://aka.ms/connector-namespace.whl'

# Check for Azure CLI
if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    throw "Azure CLI ('az') not found. Install it first: https://learn.microsoft.com/cli/azure/install-azure-cli"
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

# Resolve wheel source.
# - If -Version (or $env:CONNECTOR_NAMESPACE_VERSION) is set, pin to that GitHub Release.
# - Otherwise, use the aka.ms link (latest published wheel).
if (-not $Version -and $env:CONNECTOR_NAMESPACE_VERSION) {
    $Version = $env:CONNECTOR_NAMESPACE_VERSION
    $pinSource = '$env:CONNECTOR_NAMESPACE_VERSION'
} elseif ($Version) {
    $pinSource = '-Version'
}

if ($Version) {
    $wheelUrl = "https://github.com/$Repo/releases/download/v$Version/${PkgName}-${Version}-py3-none-any.whl"
    Write-Host "Installing '$ExtName' v$Version (pinned via $pinSource)"
} else {
    $wheelUrl = $AkamsUrl
    Write-Host "Installing '$ExtName' (latest)"
}
Write-Host "  Wheel: $wheelUrl"
Write-Host ""

# Download the wheel to a temp file, then install from the local file.
# (aka.ms is a redirect, so download first rather than pass the URL to az.)
$wheelFile = Join-Path ([System.IO.Path]::GetTempPath()) "$PkgName.whl"
try {
    Invoke-WebRequest -Uri $wheelUrl -OutFile $wheelFile -UseBasicParsing

    # --upgrade so re-running this script updates an existing install.
    # --yes accepts the "extension is in preview" prompt automatically.
    az extension add --upgrade --yes --source $wheelFile
} finally {
    Remove-Item -Path $wheelFile -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "✓ Installed. Try:" -ForegroundColor Green
Write-Host "    az connector-namespace --help"
