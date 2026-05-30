# Gateway Connections — Declarative Sandbox ↔ Connection Wiring

How to wire a connector-gateway connection to a sandbox group + sandbox so that
calls from inside the sandbox to the connection's **runtime URL** are
authenticated automatically by the platform.

> Canonical pattern used by the sample at
> `azure-samples/azure-container-apps-sandboxes/cli/samples/10-connectors-triggers`.

## Overview

Two declarative pieces wire a connection to a sandbox:

1. **Sandbox group** has `properties.gatewayConnections[]` — an array of
   `{resourceId, connectionRuntimeUrl, authentication}` entries. One entry per
   connection the group needs to call.
2. **Each sandbox** is created with `gatewayConnections: [{resourceId}]` in its
   data-plane PUT body, referencing the same connection.

Plus the two ACLs on the connection:

3. **gateway-acl** — gateway MI → connection (lets the gateway subscribe to events)
4. **sandbox-acl** — sandbox-group MI → connection (lets the platform mint tokens for the runtime URL)

Once all four exist, the platform's gatewayConnections-aware proxy:
- **Mediates** every outbound call from the sandbox to the connection's runtime URL
- **Injects** `Authorization: Bearer <token>` automatically using the sandbox-group MI
- Works **independent of egress policy** — the runtime URL host does NOT need to
  be on the egress host-allow list, even with `defaultAction=Deny`

The sandbox handler makes plain `requests.get(...)` calls to the runtime URL
with **no auth header**.

## Step 1: Access policies on the connection

Two ACLs are required: one for the gateway MI (so it can subscribe to events
for triggers), one for the sandbox-group MI (so the platform can mint tokens
for the runtime URL).

```powershell
function New-ConnectionAcl {
    param($AclName, $PrincipalId)
    $body = @{
        location = $LOCATION
        properties = @{
            principal = @{
                type = "ActiveDirectory"
                identity = @{ objectId = $PrincipalId; tenantId = $TENANT_ID }
            }
        }
    } | ConvertTo-Json -Depth 5 -Compress
    $tmp = New-TemporaryFile; Set-Content $tmp $body
    az rest --method PUT `
      --url "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/connectorGateways/$GW/connections/$CONN/accessPolicies/$AclName?api-version=2026-05-01-preview" `
      --body "@$tmp"
    Remove-Item $tmp
}

New-ConnectionAcl -AclName "gateway-acl"  -PrincipalId $GW_PRINCIPAL_ID
New-ConnectionAcl -AclName "sandbox-acl"  -PrincipalId $SG_PRINCIPAL_ID
```

> Run the two PUTs as **parallel** tool calls — they're independent.

## Step 2: Enable SystemAssigned MI on the sandbox group

The sandbox group needs a SystemAssigned MI so the platform proxy can mint
tokens for the runtime URL.

```bash
# Probe — if principalId already present, skip the assign:
aca sandboxgroup identity show --name {sg} -o json

# Enable (if not present):
aca sandboxgroup identity assign --name {sg} --system-assigned
```

> **⚠️ The aca CLI does NOT have `aca sandboxgroup update --identity SystemAssigned`.**
> Use `aca sandboxgroup identity assign --system-assigned`.

Capture `principalId` — needed for `sandbox-acl` above and the runtime token
the platform mints.

## Step 3: Get the connection's runtime URL

```bash
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/connections/{conn}?api-version=2026-05-01-preview" \
  --query "properties.connectionRuntimeUrl" -o tsv
```

> Poll for up to 60s after consent — the control plane mints
> `connectionRuntimeUrl` once the OAuth secret is in place. It may be `null`
> for the first 5–30s.

Strip any trailing `/`. Store as `RUNTIME_URL`.

## Step 4: PATCH gatewayConnections[] on the sandbox group

The sandbox group's `properties.gatewayConnections[]` must contain an entry
for this connection. **GET-merge-PATCH** so you don't clobber pre-existing
entries (e.g. MCP servers added by other tools).

```powershell
$SG_URL = "https://management.azure.com/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.App/sandboxGroups/$SG`?api-version=2026-02-01-preview"
$CONN_RESOURCE_ID = "/subscriptions/$SUB/resourceGroups/$RG/providers/Microsoft.Web/connectorGateways/$GW/connections/$CONN"

# GET current state
$current = az rest --method GET --url $SG_URL | ConvertFrom-Json

# Merge: replace by lowercased resourceId match, else append
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
        # preserve any unknown fields, overwrite ours
        $combined = @{}
        $e.PSObject.Properties | ForEach-Object { $combined[$_.Name] = $_.Value }
        foreach ($k in $newEntry.Keys) { $combined[$k] = $newEntry[$k] }
        [void]$merged.Add($combined)
        $replaced = $true
    } else {
        [void]$merged.Add($e)
    }
}
if (-not $replaced) { [void]$merged.Add($newEntry) }

# PATCH
$patchBody = @{ properties = @{ gatewayConnections = $merged } } | ConvertTo-Json -Depth 8 -Compress
$tmp = New-TemporaryFile; Set-Content $tmp $patchBody
az rest --method PATCH --url $SG_URL --headers "Content-Type=application/json" --body "@$tmp"
Remove-Item $tmp
```

> **⚠️ Sandbox-group API version is different.** Sandbox groups live under
> `Microsoft.App/sandboxGroups` with API version `2026-02-01-preview`
> (not the `2026-05-01-preview` used by `Microsoft.Web/connectorGateways`).

> **⚠️ ARM resource IDs are case-insensitive.** Always compare lowercased when
> merging existing entries.

## Step 5: Reference the connection from each sandbox

Each sandbox that needs to call this connection must include the same
`resourceId` in its `gatewayConnections[]` at create time.

> **The aca CLI does NOT yet expose `--gateway-connection` on `sandbox create`.**
> Hit the data-plane PUT directly via `az rest` so you can pass the field.
> All subsequent operations (`exec`, `fs write`, `delete`) still use the `aca` CLI.

```bash
# Build the sandbox body
cat > /tmp/sbx.json <<EOF
{
  "sourcesRef": {"diskImage": {"name": "ubuntu", "isPublic": true}},
  "vmmType": "CloudHypervisor",
  "resources": {"cpu": "2000m", "memory": "4096Mi", "disk": "20480Mi"},
  "gatewayConnections": [{"resourceId": "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/connections/{conn}"}],
  "labels": {"sample": "trigger-handler"}
}
EOF

# Data-plane PUT (note: regional endpoint, no api-version, no sandbox id in URL — Cascade shape)
az rest --method PUT \
  --url "https://management.{region}.azuredevcompute.io/subscriptions/{sub}/resourceGroups/{rg}/sandboxGroups/{sg}/sandboxes" \
  --resource "https://dynamicsessions.io" \
  --headers "Content-Type=application/json" \
  --body "@/tmp/sbx.json"
```

The response includes the generated sandbox id (`data.id` or `data.sandboxId` —
strip the trailing path segment if it's a full ARM id).

> **⚠️ Regional endpoint required.** Sandbox data plane is at
> `https://management.{region}.azuredevcompute.io/...` — the non-regional
> `https://management.azuredevcompute.io/...` returns **404**.

> **⚠️ Multiple connections.** To wire more than one connection (e.g. Teams +
> Office 365), pass them all in `gatewayConnections[]` and PATCH each one
> into the sandbox-group `gatewayConnections[]` separately.

## Step 6: Verify the wiring from inside the sandbox

After Steps 1–5 the sandbox can call the runtime URL with no auth header:

```bash
aca sandbox exec -g {rg} --group {sg} --id {sandbox_id} -c \
  "curl -sS -o /dev/null -w '%{http_code}' --max-time 15 '$RUNTIME_URL/v2/Mail?folderPath=Inbox&top=1'"
```

Expected: `200`. The platform proxy intercepts the request and adds the Bearer
header transparently.

| Result | Cause | Fix |
|--------|-------|-----|
| `200` ✅ | Working | — |
| `403` | `sandbox-acl` missing on connection, or sandbox-group MI not yet propagated | Wait 30s, verify ACL exists |
| `401` / "AuthorizationToken required" | `gatewayConnections[]` entry on sandbox group missing or has wrong runtime URL | GET sandbox group; verify the entry's `connectionRuntimeUrl` matches the connection |
| `Connection refused` / DNS error | Sandbox not in `gatewayConnections[]` (per-sandbox), or sandbox not running | Re-create sandbox with the data-plane PUT above |
| `CERTIFICATE_VERIFY_FAILED` | TLS-intercepting proxy CA not loaded | `REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt` (see [handler-guide.md](handler-guide.md)) |

## Why this works — what the platform does

When the sandbox makes an outbound HTTPS request whose host matches the
`connectionRuntimeUrl` host of one of its declared `gatewayConnections[]`
entries:

1. The platform proxy intercepts the connection (the proxy is gatewayConnections-
   aware, **independent of** the egress policy).
2. It mints a Bearer token using the sandbox-group's SystemAssigned MI against
   the connection (this is why `sandbox-acl` must exist).
3. It adds `Authorization: Bearer <token>` to the outbound request.
4. The connector gateway authorizes the call (sandbox-group MI is on its ACL),
   exchanges the token for the stored OAuth credentials, and forwards to the
   downstream API (Office 365, Teams, etc.).

Because the proxy mediates these calls separately from the egress data path,
you can run the sandbox with `egress.defaultAction=Deny` and **no host-Allow
rule for the runtime URL host** — connection calls still work.

## Cleanup

When deleting the sandbox group / connection, also detach the entry from
`properties.gatewayConnections[]` so the platform doesn't keep a dangling
reference:

```powershell
# GET, filter out the entry whose resourceId matches (case-insensitive), PATCH back
$current = az rest --method GET --url $SG_URL | ConvertFrom-Json
$ridLower = $CONN_RESOURCE_ID.ToLower()
$remaining = @($current.properties.gatewayConnections | Where-Object {
    $_.resourceId.ToLower() -ne $ridLower
})
$patchBody = @{ properties = @{ gatewayConnections = $remaining } } | ConvertTo-Json -Depth 8 -Compress
$tmp = New-TemporaryFile; Set-Content $tmp $patchBody
az rest --method PATCH --url $SG_URL --headers "Content-Type=application/json" --body "@$tmp"
Remove-Item $tmp
```

(Deleting the sandbox group entirely removes the array along with it; the
explicit detach is only relevant if you're keeping the group around.)
