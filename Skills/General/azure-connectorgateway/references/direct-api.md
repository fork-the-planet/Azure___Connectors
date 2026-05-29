# Direct API Calls via `dynamicInvoke`

Call connector operations on demand via `az rest` against the ARM `dynamicInvoke` endpoint.
The gateway injects the stored OAuth credential automatically. **Use `request` format (NOT `parameters`).**

> **⚠️ Do NOT include `Content-*` headers in the request object** — `Content-Type`
> is set by the platform.

## 1. Get the Swagger and select the operation

```powershell
# Get connector Swagger — save to file (ConvertFrom-Json fails on piped output)
az rest --method GET `
  --url "https://management.azure.com/subscriptions/{sub}/providers/Microsoft.Web/locations/{location}/managedApis/{connector}" `
  --url-parameters "api-version=2016-06-01" "export=true" -o json > $env:TEMP\swagger.json

# Extract operationId → path table
python -c "
import json
with open(r'$env:TEMP\swagger.json') as f:
    data = json.load(f)
paths = data.get('properties',{}).get('apiDefinitions',{}).get('value',{}).get('paths',{})
for path, methods in paths.items():
    for method, details in methods.items():
        if isinstance(details, dict) and 'operationId' in details:
            clean_path = path.replace('/{connectionId}', '')
            print(f'{details[\"operationId\"]:40s} {method.upper():6s} {clean_path}')
"
```

To list available operations (for presenting choices or matching user intent):
```powershell
# Quick list of operations with summaries (lighter than full swagger)
az rest --method GET `
  --url "https://management.azure.com/subscriptions/{sub}/providers/Microsoft.Web/locations/{location}/managedApis/{connector}/apiOperations?api-version=2016-06-01" `
  --query "value[].{name:name, summary:properties.summary, trigger:properties.trigger}" -o table
```

Match user's intent to the best operation. If ambiguous, ask with specific choices.
Do NOT dump all operations for the user — choose the right one yourself.

**To find the HTTP path for a chosen operationId:** search the Swagger `paths` for the matching
`operationId`. Strip the `/{connectionId}` prefix — that's the path you pass to `dynamicInvoke`.

## 2. Collect parameter values interactively

For each required parameter, check its Swagger extension. Use `@$tmpFile` for `az rest --body` with special chars.

> **🚫 NEVER guess or infer dynamic parameter values. NEVER use placeholder IDs.**
> If a parameter has `x-ms-dynamic-values`, `x-ms-dynamic-list`, `x-ms-dynamic-tree`,
> or `x-ms-dynamic-schema`, you MUST:
> 1. Call the specified operationId via `dynamicInvoke` to fetch the actual values
> 2. Present the results to the user with `ask_user`
> 3. STOP and wait for the user to select — do NOT proceed until they answer
>
> **Wrong:** "I'll use the Inbox folder" (guessed without calling the API)
> **Wrong:** Using a teamId/channelId/siteUrl without fetching the list first
> **Right:** Call the dynamic operation → show user the list → wait for selection

**Parameter resolution by extension type:**

| Extension | What it does | How to handle |
|-----------|-------------|---------------|
| `x-ms-dynamic-values` | Flat list of options | Call operationId → present choices → **STOP** |
| `x-ms-dynamic-list` | Same as above (nested variant) | Same as dynamic-values → **STOP** |
| `x-ms-dynamic-tree` | Hierarchical folder browsing | Call open → present → browse deeper → **STOP at each level** |
| `x-ms-dynamic-schema` | Fields depend on prior selection | Collect dependencies first → call schema op → **STOP** |
| Static enum | Fixed choices in Swagger | Present choices → **STOP** |
| Free-form | User provides value | Ask user (or use obvious default + inform) |

→ **Full algorithms with code examples:** See [dynamic-values.md](dynamic-values.md)

**Key rules:**
- **STOP at every dynamic parameter** — even if you think you know the answer.
  The user's Teams, channels, SharePoint sites, and folders are NOT predictable.
- **Always resolve `operationId` to HTTP path** — search the Swagger `paths` (from Step 1) for the matching
  `operationId`. Strip `/{connectionId}` prefix. That's the path for `dynamicInvoke`.
- **Always URL-encode IDs** with `[System.Uri]::EscapeDataString()`
- **Use `@file` pattern** for `az rest --body` when IDs contain `!` or special chars
- **Skip optional parameters** unless user mentioned them
- **Large lists (>10 items):** Do NOT pass all items as `ask_user` choices.
  Instead, print the numbered list in your response text and use `ask_user`
  with `allow_freeform: true` (no `choices` array): "Type the name or number."
  Only use the `choices` array when there are ≤10 items.
- **Very large lists (50+):** Fetch with `$top=20`, show results, ask
  "Do you see yours, or should I load more?"

**Do NOT proceed to step 3 until ALL required parameters are confirmed by the user.**

## 3. Build and call `dynamicInvoke`

The request object supports:
- `method` — HTTP method (GET, POST, PUT, DELETE)
- `path` — operation path from Swagger (strip `/{connectionId}` prefix)
- `queries` — query parameters as key-value dict
- `body` — request body (string or object)
- `headers` — HTTP headers (**except** `Content-*` headers)

Map Swagger `in` field: `path` → URL path, `query` → queries dict,
`body` → body field, `header` → headers dict (except `Content-*`).

```bash
# Example: Create a file in OneDrive
az rest --method POST \
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/connections/{conn}/dynamicInvoke?api-version=2026-05-01-preview" \
  --body '{
    "request": {
      "method": "POST",
      "path": "/datasets/default/files",
      "queries": {"folderPath": "/", "name": "hello.txt"},
      "body": "Hello from Connector Gateway!"
    }
  }'
```

In PowerShell, prefer the `@$tmpFile` pattern for the body:

```powershell
$body = @{
  request = @{
    method = "POST"
    path = "/v2/Mail"
    body = @{
      To = "user@contoso.com"
      Subject = "Hello"
      Body = "<p>Sent via dynamicInvoke</p>"
    }
  }
} | ConvertTo-Json -Depth 6 -Compress

$tmp = New-TemporaryFile; Set-Content $tmp $body
az rest --method POST `
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/connections/{conn}/dynamicInvoke?api-version=2026-05-01-preview" `
  --body "@$tmp"
Remove-Item $tmp
```

## 4. Unwrap the response

`dynamicInvoke` always wraps the connector response:

```json
{ "response": { "statusCode": "OK", "body": { ...actual data... }, "headers": {...} } }
```

Always extract from `response.body`. Use `--query "response.body"` with `az rest`.

| `response.statusCode` | Meaning |
|---|---|
| `OK` / `Created` / `Accepted` | Success — use `response.body` |
| `BadRequest` (400) | Check parameter names + body shape against the Swagger |
| `Unauthorized` (401) | Connection not consented — re-run [consent.md](consent.md) |
| `Forbidden` (403) | OAuth scope insufficient — re-consent with broader scopes |
| `NotFound` (404) | Wrong path (did you strip `/{connectionId}`?) or the resource doesn't exist |

## Common pitfalls

- **Inline JSON in PowerShell breaks** — always use `@$tmpFile` for `--body`
- **`Content-Type` in the inner `headers` returns 400** — omit it
- **Forgetting `/{connectionId}` strip** — Swagger path `/{connectionId}/datasets/...` becomes `dynamicInvoke` path `/datasets/...`
- **Using `parameters: { operationId: ... }` body** — that's an older shape; use `request: { method, path, ... }`
