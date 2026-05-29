# Tutorial: Deploy a Welcome Emailer to a Sandbox

End-to-end walkthrough: create a sandbox app that sends welcome emails via the
Office 365 connector using **Direct API calls (Pattern A)**.

## What you'll build

- A connector gateway + OAuth connection to Office 365
- A sandbox running a Python script that sends a welcome email
- Declarative **gatewayConnections** wiring (SG-level PATCH + per-sandbox PUT
  body) so the sandbox calls the runtime URL with **no auth code** — the
  platform proxy injects the Bearer token automatically
- Access policies granting both the gateway MI and the sandbox-group MI
  permission to use the connection

## Prerequisites

- `az` CLI with `aca` extension installed (run `aca --version` to check)
- An Azure subscription with Contributor access
- An Office 365 account (the email sender)

→ Full prerequisites: [prerequisites.md](prerequisites.md)

---

## Step 1: Set up Azure context

```bash
# List subscriptions
az account list --query "[].{name:name, id:id, isDefault:isDefault}" -o table

# Set the subscription you want to use
az account set --subscription "{subscription_id}"

# Create or use an existing resource group
az group create --name welcome-emailer-rg --location eastus
```

Store these for later:
```
SUB="{subscription_id}"
RG="welcome-emailer-rg"
LOCATION="eastus"
```

## Step 2: Create connector gateway

```powershell
$gwBody = @{ location = $LOCATION; identity = @{ type = "SystemAssigned" } } | ConvertTo-Json -Compress
$tmp = New-TemporaryFile; Set-Content $tmp $gwBody
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/connectorGateways/welcome-gw?api-version=2026-05-01-preview" `
  --body "@$tmp"
Remove-Item $tmp
```

Capture the gateway's managed identity (needed for access policies later):
```bash
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Web/connectorGateways/welcome-gw?api-version=2026-05-01-preview" \
  --query "{principalId:identity.principalId, tenantId:identity.tenantId}"
```

Store: `GW_PRINCIPAL_ID` and `GW_TENANT_ID`.

## Step 3: Create connection + consent

Create an OAuth connection to Office 365:

```powershell
$connBody = @{
  location = $LOCATION
  properties = @{ connectorName = "office365" }
} | ConvertTo-Json -Compress
$tmp = New-TemporaryFile; Set-Content $tmp $connBody
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/connectorGateways/welcome-gw/connections/o365-conn?api-version=2026-05-01-preview" `
  --body "@$tmp"
Remove-Item $tmp
```

> **⚠️ Connection body uses `connectorName`** (NOT `api.name`).

Generate the consent link and authenticate:

```bash
az rest --method POST \
  --url "https://management.azure.com/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Web/connectorGateways/welcome-gw/connections/o365-conn/generateConsentLink?api-version=2026-05-01-preview" \
  --body '{}' \
  --query "consentLink" -o tsv
```

Open the link in a browser, sign in with the Office 365 account, and grant consent.

Verify the connection status:
```bash
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Web/connectorGateways/welcome-gw/connections/o365-conn?api-version=2026-05-01-preview" \
  --query "{status:properties.statuses[0].status, createdBy:properties.createdBy.objectId}"
```

Status should be `Connected`. The `createdBy.objectId` field shows who authenticated.

→ Full consent flow details: [consent.md](consent.md)

## Step 4: Create sandbox group + sandbox

```bash
# Create sandbox group
aca sandboxgroup create -g $RG -n welcome-sg -l $LOCATION

# Enable system-assigned managed identity
# (aca sandboxgroup create does NOT support --identity)
aca sandboxgroup identity assign --name welcome-sg --system-assigned

# Capture the sandbox group's principal ID
aca sandboxgroup identity show --name welcome-sg -o json
```

Store: `SG_PRINCIPAL_ID`.

> **⚠️ New sandbox groups take 5–20 minutes to propagate to the data plane.**
> If `create sandbox` fails with `SandboxGroupNotFound`, wait and retry.

The sandbox must be created with `gatewayConnections: [{resourceId}]` in its
data-plane PUT body so the platform proxy will inject Bearer auth on calls to
the connection's runtime URL. The `aca` CLI doesn't yet expose
`--gateway-connection` on `sandbox create`, so use `az rest` against the data
plane:

```bash
CONN_RESOURCE_ID="/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/connectorGateways/welcome-gw/connections/o365-conn"

cat > /tmp/sbx.json <<EOF
{
  "sourcesRef": {"diskImage": {"name": "ubuntu", "isPublic": true}},
  "vmmType": "CloudHypervisor",
  "resources": {"cpu": "2000m", "memory": "4096Mi", "disk": "20480Mi"},
  "gatewayConnections": [{"resourceId": "$CONN_RESOURCE_ID"}],
  "labels": {"sample": "welcome-emailer"}
}
EOF

# Regional dataplane endpoint — no api-version, no sandbox id in URL (Cascade shape)
az rest --method PUT \
  --url "https://management.$LOCATION.azuredevcompute.io/subscriptions/$SUB/resourceGroups/$RG/sandboxGroups/welcome-sg/sandboxes" \
  --resource "https://dynamicsessions.io" \
  --headers "Content-Type=application/json" \
  --body "@/tmp/sbx.json"
```

Parse the sandbox id from the response (`data.id` or `data.sandboxId`; if it's a
full ARM id, take everything after the last `/`). Store: `SANDBOX_ID`.

```bash
# Wait for Running state
aca sandbox show -g $RG --group welcome-sg --id $SANDBOX_ID --query "state"
```

Install Python (ubuntu image has none pre-installed):
```bash
aca sandbox exec -g $RG --group welcome-sg --id $SANDBOX_ID \
  -c "apt update && apt install -y python3 python3-pip python3-requests"
```

## Step 5: Wire the connection to the sandbox

Two ACLs on the connection (gateway MI + sandbox-group MI) plus a sandbox-group
`gatewayConnections[]` entry. Run the two ACL PUTs in parallel:

### 5a: Access policies on the connection

```powershell
function New-ConnectionAcl {
    param($AclName, $PrincipalId)
    $body = @{
        location = $LOCATION
        properties = @{
            principal = @{
                type = "ActiveDirectory"
                identity = @{ objectId = $PrincipalId; tenantId = $GW_TENANT_ID }
            }
        }
    } | ConvertTo-Json -Depth 5 -Compress
    $tmp = New-TemporaryFile; Set-Content $tmp $body
    az rest --method PUT `
      --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/connectorGateways/welcome-gw/connections/o365-conn/accessPolicies/$AclName?api-version=2026-05-01-preview" `
      --body "@$tmp"
    Remove-Item $tmp
}

New-ConnectionAcl -AclName "gateway-acl" -PrincipalId $GW_PRINCIPAL_ID
New-ConnectionAcl -AclName "sandbox-acl" -PrincipalId $SG_PRINCIPAL_ID
```

### 5b: Get the runtime URL

```bash
RUNTIME_URL=$(az rest --method GET \
  --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/connectorGateways/welcome-gw/connections/o365-conn?api-version=2026-05-01-preview" \
  --query "properties.connectionRuntimeUrl" -o tsv)
RUNTIME_URL="${RUNTIME_URL%/}"
echo "$RUNTIME_URL"
```

### 5c: PATCH the sandbox group's gatewayConnections[]

GET-merge-PATCH so you don't clobber pre-existing entries:

```powershell
$SG_URL = "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.App/sandboxGroups/welcome-sg`?api-version=2026-02-01-preview"
$CONN_RESOURCE_ID = "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/connectorGateways/welcome-gw/connections/o365-conn"

$current = az rest --method GET --url $SG_URL | ConvertFrom-Json
$existing = @($current.properties.gatewayConnections)
$ridLower = $CONN_RESOURCE_ID.ToLower()
$newEntry = @{
    resourceId           = $CONN_RESOURCE_ID
    connectionRuntimeUrl = $RUNTIME_URL
    authentication       = @{ type = "SystemAssignedManagedIdentity" }
}
$merged = New-Object System.Collections.ArrayList
$replaced = $false
foreach ($e in $existing) {
    if ($e -and $e.resourceId -and $e.resourceId.ToLower() -eq $ridLower) {
        $combined = @{}
        $e.PSObject.Properties | ForEach-Object { $combined[$_.Name] = $_.Value }
        foreach ($k in $newEntry.Keys) { $combined[$k] = $newEntry[$k] }
        [void]$merged.Add($combined); $replaced = $true
    } else { [void]$merged.Add($e) }
}
if (-not $replaced) { [void]$merged.Add($newEntry) }

$patchBody = @{ properties = @{ gatewayConnections = $merged } } | ConvertTo-Json -Depth 8 -Compress
$tmp = New-TemporaryFile; Set-Content $tmp $patchBody
az rest --method PATCH --url $SG_URL --headers "Content-Type=application/json" --body "@$tmp"
Remove-Item $tmp
```

> **⚠️ Critical values:**
> - Sandbox-group API version is `2026-02-01-preview` (under
>   `Microsoft.App/sandboxGroups`), different from the gateway's
>   `2026-05-01-preview`
> - ARM resource IDs are case-insensitive — always compare lowercased
> - `authentication.type` must be `SystemAssignedManagedIdentity` exactly

→ Full gatewayConnections details + troubleshooting: [gateway-connections.md](gateway-connections.md)

## Step 6: Write and deploy the emailer script

Create a local file `welcome_emailer.py`:

```python
#!/usr/bin/env python3
"""Send a welcome email via Office 365 connection runtime URL."""
import os, sys, time

# === SSL setup (MUST be before importing requests) ===
os.environ["REQUESTS_CA_BUNDLE"] = "/etc/ssl/certs/ca-certificates.crt"
try:
    import requests
    requests.get("https://management.azure.com", timeout=5)
except Exception:
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    os.environ.pop("REQUESTS_CA_BUNDLE", None)
    import requests
    SSL_VERIFY = False
else:
    SSL_VERIFY = True

# Runtime URL — platform proxy injects auth via gatewayConnections; do NOT add Authorization header
RUNTIME_URL = os.environ.get("O365_RUNTIME_URL",
    "https://REPLACE_ME.azure-apihub.net/apim/office365/REPLACE_ME")

def send_email(to, subject, body_html, retries=3, timeout=120):
    """Send email via Office 365 connector. Retries on cold-start errors."""
    url = f"{RUNTIME_URL}/v2/Mail"
    # Office 365 SendMailV2 uses a FLAT body — not nested under "emailMessage"
    payload = {
        "To": to,
        "Subject": subject,
        "Body": body_html,
        "Importance": "Normal",
        "IsHtml": True,
    }
    for attempt in range(retries):
        try:
            resp = requests.post(url, json=payload,
                                 verify=SSL_VERIFY, timeout=timeout)
            if resp.status_code in (200, 202):
                print(f"Email sent to {to}")
                return True
            if resp.status_code in (502, 503, 504) and attempt < retries - 1:
                wait = 5 * (attempt + 1)
                print(f"Cold-start {resp.status_code}, retrying in {wait}s...")
                time.sleep(wait)
                continue
            print(f"Failed: {resp.status_code} {resp.text}", file=sys.stdout)
            return False
        except requests.exceptions.Timeout:
            if attempt < retries - 1:
                print(f"Timeout, retrying ({attempt+1}/{retries})...")
                time.sleep(5 * (attempt + 1))
                continue
            print("Request timed out after all retries", file=sys.stdout)
            return False

if __name__ == "__main__":
    send_email(
        to="newhire@contoso.com",
        subject="Welcome to the team!",
        body_html="""<h2>Welcome!</h2>
<p>We're excited to have you join us. Here's what to expect on your first day:</p>
<ul>
  <li>9:00 AM — Team standup (link in calendar)</li>
  <li>10:00 AM — IT setup with your manager</li>
  <li>11:30 AM — Lunch with the team</li>
</ul>
<p>See you soon!</p>""",
    )
```

> **⚠️ Do NOT send an `Authorization` header** — the platform's gatewayConnections-aware proxy injects it.
> Adding your own will conflict with the platform-injected token.

> **⚠️ Office 365 `SendMailV2` uses a flat body** (`{"To", "Subject", "Body"}`),
> not nested under `{"emailMessage": {...}}`.

Deploy to the sandbox:
```bash
aca sandbox fs write --id $SANDBOX_ID --path /app/welcome_emailer.py \
  --file ./welcome_emailer.py -g $RG --group welcome-sg
```

→ SSL/retry rationale: [handler-guide.md](handler-guide.md)

## Step 7: Test it

Set the runtime URL environment variable and run:

```bash
aca sandbox exec -g $RG --group welcome-sg --id $SANDBOX_ID \
  -c "O365_RUNTIME_URL='$RUNTIME_URL' python3 /app/welcome_emailer.py"
```

Expected output: `Email sent to newhire@contoso.com`

Check the recipient's inbox to confirm delivery.

**Troubleshooting:**

| Result | Cause | Fix |
|--------|-------|-----|
| `Email sent to ...` ✅ | Working | — |
| `403` | `sandbox-acl` missing or not propagated | Wait 30s, check that BOTH `gateway-acl` and `sandbox-acl` exist on the connection |
| `401` / "AuthorizationToken required" | Sandbox-group `gatewayConnections[]` missing this connection's entry, or the sandbox was created without `gatewayConnections: [{resourceId}]` | Re-run Step 5c (PATCH), re-create the sandbox via the data-plane PUT in Step 4 |
| `504` / Timeout | Cold-start latency | Retry — script has built-in backoff |
| `CERTIFICATE_VERIFY_FAILED` | SSL proxy issue | Script handles this automatically (CA bundle → fallback) |

→ Full troubleshooting matrix: [gotchas.md](gotchas.md)

## Step 8: Cleanup

```bash
# Delete in this order: sandbox → group → connection → gateway → resource group
aca sandbox delete -g $RG --group welcome-sg --id $SANDBOX_ID
aca sandboxgroup delete -g $RG -n welcome-sg

# Delete connection + gateway
az rest --method DELETE \
  --url "https://management.azure.com/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Web/connectorGateways/welcome-gw/connections/o365-conn?api-version=2026-05-01-preview"
az rest --method DELETE \
  --url "https://management.azure.com/subscriptions/{SUB}/resourceGroups/{RG}/providers/Microsoft.Web/connectorGateways/welcome-gw?api-version=2026-05-01-preview"

# Optional: delete the resource group entirely
az group delete --name $RG --yes --no-wait
```

## Summary

| Step | What | Key gotcha |
|------|------|-----------|
| 1 | Azure context | Pick subscription + resource group |
| 2 | Gateway | Must have `SystemAssigned` identity |
| 3 | Connection + consent | Use `connectorName` (not `api.name`); verify `createdBy.objectId` |
| 4 | Sandbox group + sandbox | `aca sandboxgroup identity assign --system-assigned` after create; sandbox PUT must include `gatewayConnections: [{resourceId}]` via `az rest` (data-plane endpoint is **regional**); install Python |
| 5 | ACLs + gatewayConnections | TWO ACLs on the connection (gateway-acl + sandbox-acl); SG PATCH with `{resourceId, connectionRuntimeUrl, authentication.type=SystemAssignedManagedIdentity}` using GET-merge-PATCH; SG API version is `2026-02-01-preview` |
| 6 | Emailer script | Flat email body; no auth header; timeout=120 |
| 7 | Test | Check recipient inbox |
| 8 | Cleanup | Delete sandbox → group → connection → gateway |
