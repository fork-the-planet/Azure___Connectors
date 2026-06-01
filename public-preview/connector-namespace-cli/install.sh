#!/usr/bin/env sh
# Install (or uninstall) the `az connector-namespace` Azure CLI extension.
#
# Usage:
#   # Default: install the latest published wheel (https://aka.ms/connector-namespace.whl)
#   curl -fsSL https://raw.githubusercontent.com/Azure/Connectors/main/public-preview/connector-namespace-cli/install.sh | sh
#
#   # Pin a different version:
#   curl -fsSL https://raw.githubusercontent.com/Azure/Connectors/main/public-preview/connector-namespace-cli/install.sh \
#     | CONNECTOR_NAMESPACE_VERSION=1.0.0b9 sh
#
#   # Uninstall:
#   curl -fsSL https://raw.githubusercontent.com/Azure/Connectors/main/public-preview/connector-namespace-cli/install.sh \
#     | sh -s -- --uninstall

set -eu

REPO="Azure/Connectors"
EXT_NAME="connector-namespace"
PKG_NAME="connector_namespace"
AKAMS_URL="https://aka.ms/connector-namespace.whl"

UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --uninstall|-u) UNINSTALL=1 ;;
  esac
done

if ! command -v az >/dev/null 2>&1; then
  echo "ERROR: Azure CLI ('az') not found." >&2
  echo "Install it first: https://learn.microsoft.com/cli/azure/install-azure-cli" >&2
  exit 1
fi

if [ "$UNINSTALL" -eq 1 ]; then
  if az extension show --name "$EXT_NAME" >/dev/null 2>&1; then
    az extension remove --name "$EXT_NAME"
    echo "Uninstalled '$EXT_NAME'."
  else
    echo "'$EXT_NAME' is not installed; nothing to do."
  fi
  exit 0
fi

# Resolve wheel source.
# - If CONNECTOR_NAMESPACE_VERSION is set, pin to that GitHub Release.
# - Otherwise, use the aka.ms link (latest published wheel).
VERSION="${CONNECTOR_NAMESPACE_VERSION:-}"
if [ -n "$VERSION" ]; then
  WHEEL_URL="https://github.com/${REPO}/releases/download/v${VERSION}/${PKG_NAME}-${VERSION}-py3-none-any.whl"
  echo "Installing '$EXT_NAME' v$VERSION (pinned via \$CONNECTOR_NAMESPACE_VERSION)"
else
  WHEEL_URL="$AKAMS_URL"
  echo "Installing '$EXT_NAME' (latest)"
fi
echo "  Wheel: $WHEEL_URL"
echo ""

if ! command -v curl >/dev/null 2>&1; then
  echo "ERROR: 'curl' not found; cannot download the wheel." >&2
  exit 1
fi

# Download the wheel to a temp file, then install from the local file.
# (aka.ms is a redirect, so download first rather than pass the URL to az.)
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
WHEEL_FILE="$TMP_DIR/${PKG_NAME}.whl"
curl -fsSL "$WHEEL_URL" -o "$WHEEL_FILE"

# --upgrade so re-running this script updates an existing install.
# --yes accepts the "extension is in preview" prompt automatically.
az extension add --upgrade --yes --source "$WHEEL_FILE"

echo ""
echo "✓ Installed. Try:"
echo "    az connector-namespace --help"
