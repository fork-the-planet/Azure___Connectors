# Swagger Discovery — Connector Operations via Metadata URL

How to fetch a connector's full Swagger and find the right operation to use.
This is the canonical reference for operation/trigger discovery in this skill.

## Endpoint

Fetch the Swagger from the **connection's runtime metadata URL**:

- Take the connection's `connectionRuntimeUrl` (e.g., `https://{host}/apim/teams/{id}`)
- Replace `/apim/` with `/metadata/`
- Append `?export=true`

Result: `https://{host}/metadata/teams/{id}?export=true`

**Do NOT** use the legacy ARM endpoint
`https://management.azure.com/.../providers/Microsoft.Web/locations/{location}/managedApis/{connector}?api-version=2016-06-01&export=true`.
The ARM endpoint is a different API surface and should not be used by this skill,
even if it returns Swagger-shaped content.

## Auth (outside-sandbox swagger discovery)

To call the metadata URL from outside a sandbox (the typical design-time path), two things are required:

1. A **user-ACL** on the connection for the signed-in user's objectId
2. An **API Hub token** (`az rest --resource "https://apihub.azure.com"`)

### Step 1 — Ensure the user-ACL exists (idempotent: GET first, PUT only if missing)

```powershell
$USER_OID  = (az ad signed-in-user show --query id -o tsv)
$TENANT_ID = (az account show --query tenantId -o tsv)
$CONN_URL  = "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/connections/{conn}"
$ACL_URL   = "$CONN_URL/accessPolicies/$USER_OID`?api-version=2026-05-01-preview"

# GET first — only create if missing
$existing = az rest --method GET --url $ACL_URL 2>$null
if (-not $existing) {
    $connInfo = az rest --method GET --url "$CONN_URL`?api-version=2026-05-01-preview" | ConvertFrom-Json
    $aclBody = @{
        location   = $connInfo.location
        properties = @{
            principal = @{
                type     = "ActiveDirectory"
                identity = @{ objectId = $USER_OID; tenantId = $TENANT_ID }
            }
        }
    } | ConvertTo-Json -Depth 5 -Compress
    $tmp = New-TemporaryFile; Set-Content $tmp $aclBody
    az rest --method PUT --url $ACL_URL --body "@$tmp"
    Remove-Item $tmp
}
```

> **Never blindly recreate a user-ACL.** Always GET first; PUT only if missing.
> This rule applies specifically to user-ACL creation for swagger discovery.
> `gateway-acl` and `sandbox-acl` are typically PUT directly during setup —
> see [gateway-connections.md](gateway-connections.md) — and may need updates
> when the gateway/sandbox-group principal changes.

### Step 2 — Fetch the Swagger

```powershell
$runtimeUrl  = (az rest --method GET --url "$CONN_URL`?api-version=2026-05-01-preview" --query "properties.connectionRuntimeUrl" -o tsv)
$metadataUrl = $runtimeUrl -replace '/apim/', '/metadata/'
az rest --method GET --url "$metadataUrl`?export=true" --resource "https://apihub.azure.com" -o json > $env:TEMP\swagger.json
```

## Parse and find operations

The response is a raw Swagger 2.0 document — `paths` is at the top level (no envelope wrapper). All operations live under `paths[<path>][<method>]`. Each operation entry has:

- `operationId` — string identifier (use this when calling `dynamicInvoke`)
- `summary` / `description` — human-readable text
- `x-ms-visibility` — `important` / `default` / `advanced` / `internal`
- `x-ms-trigger` — object like `{"type": "polling"}` if the operation is a trigger; absent for callable actions

### Quick listing

Use `jq` to stream the swagger and print each operation (operationId, method, path). No temp file beyond what the metadata fetch already wrote, no separate parse process. Substitute the path you wrote the swagger to (`%TEMP%\swagger.json` in PowerShell, `/tmp/swagger.json` in bash):

```bash
# Bash
jq -r '.paths | to_entries[] as $p | $p.value | to_entries[]
  | select(.value.operationId)
  | "\(.value.operationId)\t\(.key | ascii_upcase)\t\($p.key | sub("/\\{connectionId\\}"; ""))"' \
  /tmp/swagger.json
```

```powershell
# PowerShell — same jq, just the env var differs
jq -r '.paths | to_entries[] as $p | $p.value | to_entries[]
  | select(.value.operationId)
  | "\(.value.operationId)\t\(.key | ascii_upcase)\t\($p.key | sub("/\\{connectionId\\}"; ""))"' `
  "$env:TEMP\swagger.json"
```

### Find the right operation for the user's intent

Filter the swagger by keyword on `operationId + summary + description`. For **direct API** (callable actions), exclude operations that have `x-ms-trigger` set and skip `x-ms-visibility: internal`. For **trigger discovery**, invert the filter — keep only operations with `x-ms-trigger` set.

```bash
# Bash
jq -r --arg kw 'message|chat|post|send' '
  .paths | to_entries[] as $p | $p.value | to_entries[]
  | select(.value.operationId)
  | select(.value["x-ms-trigger"] | not)
  | select(.value["x-ms-visibility"] != "internal")
  | select((.value.operationId + " " + (.value.summary // "") + " " + (.value.description // "")) | ascii_downcase | test($kw))
  | "\(.value.operationId)\t\(.key | ascii_upcase)\t\($p.key | sub("/\\{connectionId\\}"; ""))\n  \(.value.summary // "")"' \
  /tmp/swagger.json
```

```powershell
# PowerShell
jq -r --arg kw 'message|chat|post|send' '
  .paths | to_entries[] as $p | $p.value | to_entries[]
  | select(.value.operationId)
  | select(.value[\"x-ms-trigger\"] | not)
  | select(.value[\"x-ms-visibility\"] != \"internal\")
  | select((.value.operationId + \" \" + (.value.summary // \"\") + \" \" + (.value.description // \"\")) | ascii_downcase | test($kw))
  | \"\(.value.operationId)\t\(.key | ascii_upcase)\t\($p.key | sub(\"/\\{connectionId\\}\"; \"\"))\n  \(.value.summary // \"\")\"' `
  "$env:TEMP\swagger.json"
```

### Picking the best match

- **`x-ms-visibility`** — prefer `important` > `default` > `advanced`. Skip `internal`.
- **Versioned variants** — when V2/V3 exist, prefer the highest-numbered unless the user asks otherwise.
- **Intent match** — "send to user" → 1:1 chat operation; "post to channel" → channel operation; etc.
- **Ambiguity** — if multiple operations are plausible, ask the user with specific choices. Don't dump all of them.

### Resolving operationId → HTTP path

Look up the chosen operationId under the top-level `paths` object (e.g., `$swag.paths` in PowerShell). Strip the `/{connectionId}` prefix — that's the path you pass to `dynamicInvoke`.

## Narrate progress

Before running the shell commands above, print a short chat message naming what
you're doing and the exact URL/objectId being touched. Examples:

- `Ensuring user-ACL exists on connection {conn} for objectId {oid} (GET {ACL_URL})`
- `Fetching Swagger from {metadataUrl}?export=true (--resource https://apihub.azure.com)`
- `Found {N} operations matching '{keywords}'. Picking {chosen_op}.`

Never run a swagger-discovery shell command silently — the user shouldn't have to
expand a collapsed shell block to see what URL you're hitting.
