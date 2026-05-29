# MCP Server Config

Expose selected connector operations as Model Context Protocol (MCP) tools at a
gateway-hosted endpoint. Any MCP client (Claude Desktop, VS Code, an Agent SDK)
can connect to the resulting `mcpEndpointUrl` and call the tools — the gateway
forwards each tool call to the underlying connector using the stored OAuth
credential.

## Kinds

| `kind` | What it is | Use this when |
|---|---|---|
| `ManagedMcpServer` *(default)* | A **connector-backed** MCP server — you map MCP tools to connector operations. **This is the main pattern for this skill.** | You want an LLM to use Office 365 / Teams / SharePoint / GitHub / ... operations as tools. |
| `HostedMcpServer` | A **container-image-backed** MCP server (e.g., `mcp-sql`). The gateway runs the image. | You want one of the curated containerized MCP servers (currently a small registry). |

> The rest of this doc focuses on `ManagedMcpServer`. For `HostedMcpServer`, the
> shape is the same except `properties.hostedMcpServer.hostedMcpServerId` (e.g.,
> `"mcp-sql"`) replaces the `connectors[]` array, and `properties.resourceAuth`
> is required when `authenticationMode` is set. See "Hosted MCP server" at the end.

## Schema (ManagedMcpServer)

```json
{
  "properties": {
    "description": "Office 365 productivity tools for the agent",
    "connectors": [
      {
        "name": "office365",
        "displayName": "Office 365",
        "connectionName": "o365-conn",
        "operations": [
          {
            "name": "Send_Email_(V2)",
            "displayName": "Send email",
            "description": "Send an email via Office 365.",
            "userParameters": [
              { "name": "from", "displayName": "From", "value": "alice@contoso.com", "displayValue": "Alice" }
            ]
          }
        ]
      }
    ]
  }
}
```

### Field reference

| Path | Required | Meaning |
|---|---|---|
| `properties.description` | optional | Free-form description |
| `properties.connectors[]` | required | One entry per backing connector |
| `connectors[].name` | required | Connector key (e.g., `office365`, `sharepointonline`, `teams`) |
| `connectors[].displayName` | required | Human-readable name shown to MCP clients |
| `connectors[].connectionName` | required | Name of the **already-created** connection on the same gateway |
| `connectors[].operations[]` | required | Operations to expose as MCP tools |
| `operations[].name` | required | The operation `name` from the connector's `apiOperations` (e.g., `Send_Email_(V2)`) |
| `operations[].displayName` | required | Tool name shown to the LLM |
| `operations[].description` | optional | Tool description shown to the LLM — write it for the LLM, not for humans |
| `operations[].userParameters[]` | optional | **Pre-bound** values for operation parameters — see below |

### `userParameters` — pre-bound parameter values

Each entry in `userParameters[]` is a parameter whose value is **fixed at config
time** rather than supplied by the LLM at call time. Typical examples:

- "Always post to this Teams channel"
- "Always send from this mailbox"
- "Always upload to this folder"

```json
{
  "name": "channelId",
  "displayName": "Channel",
  "value": "19:abc...@thread.tacv2",
  "displayValue": "Logic Apps / general"
}
```

- `value` is what's sent to the connector (the ID/key)
- `displayValue` is human-readable
- Parameters **not** listed in `userParameters[]` remain LLM-supplied inputs at tool-call time

> Resolve dynamic IDs by running the parameter's `x-ms-dynamic-*` lookups
> against the connection — exactly like [trigger-setup.md](trigger-setup.md) Step 2.
> See [dynamic-values.md](dynamic-values.md). **STOP** at each dynamic param for user selection.

## PUT the config

```powershell
$body = @{
  properties = @{
    description = "Office 365 productivity tools"
    connectors = @(
      @{
        name = "office365"
        displayName = "Office 365"
        connectionName = "o365-conn"
        operations = @(
          @{
            name = "Send_Email_(V2)"
            displayName = "Send email"
            description = "Send an email via Office 365."
            userParameters = @(
              @{ name = "from"; displayName = "From"; value = "alice@contoso.com"; displayValue = "Alice" }
            )
          }
        )
      }
    )
  }
} | ConvertTo-Json -Depth 10 -Compress

$tmp = New-TemporaryFile; Set-Content $tmp $body
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/mcpServerConfigs/{mcp_name}?api-version=2026-05-01-preview" `
  --body "@$tmp"
Remove-Item $tmp
```

## Get the endpoint URL

```bash
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/mcpServerConfigs/{mcp_name}?api-version=2026-05-01-preview" \
  --query "properties.mcpEndpointUrl" -o tsv
```

Format looks like:
`https://<gateway-host>/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/mcpServerConfigs/{mcp_name}/mcp`

Point your MCP client at this URL.

## Listing operations to expose

Use the connector's `apiOperations` endpoint and filter out trigger operations
(they're not tools):

```bash
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/providers/Microsoft.Web/locations/{location}/managedApis/{connector}/apiOperations?api-version=2016-06-01" \
  --query "value[?properties.trigger == null].{name:name, summary:properties.summary}" -o table
```

The `name` value from this list is exactly what goes into `operations[].name`.

## Access policies on the MCP server config

The MCP endpoint accepts callers based on access policies on the config itself.
Grant access to whoever (user, MI, app) needs to call the MCP tools:

```powershell
$aclBody = @{
  location = "{location}"
  properties = @{
    principal = @{
      type = "ActiveDirectory"
      identity = @{ objectId = "{caller_object_id}"; tenantId = "{tenant_id}" }
    }
  }
} | ConvertTo-Json -Depth 5 -Compress
$tmp = New-TemporaryFile; Set-Content $tmp $aclBody
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/mcpServerConfigs/{mcp_name}/accessPolicies/{policy_name}?api-version=2026-05-01-preview" `
  --body "@$tmp"
Remove-Item $tmp
```

List existing policies:

```bash
az rest --method GET \
  --url ".../mcpServerConfigs/{mcp_name}/accessPolicies?api-version=2026-05-01-preview" \
  --query "value[].{name:name, objectId:properties.principal.identity.objectId}" -o table
```

## Update / delete

```bash
# Update (re-PUT with the new full body)
az rest --method PUT --url ".../mcpServerConfigs/{name}?api-version=2026-05-01-preview" --body "@$tmp"

# Delete
az rest --method DELETE --url ".../mcpServerConfigs/{name}?api-version=2026-05-01-preview"
```

## Hosted MCP server (briefly)

For curated containerized MCP servers (e.g., `mcp-sql`):

```json
{
  "kind": "HostedMcpServer",
  "properties": {
    "description": "Hosted SQL MCP server",
    "hostedMcpServer": {
      "hostedMcpServerId": "mcp-sql"
    },
    "authenticationMode": "OnBehalfOfUserWithApp",
    "resourceAuth": {
      "adminAppRegistration": {
        "clientId": "{aad-app-client-id}",
        "tenantId": "{tenant-id}",
        "name": "my-mcp-admin-app"
      },
      "targetResource": "https://database.windows.net/",
      "identity": { "type": "SystemAssigned" }
    }
  }
}
```

Validation rules (from BPM tests):

- `resourceAuth` is required when `authenticationMode` ∈ {`OnBehalfOfUserWithApp`, `AppOnly`}, and forbidden when `authenticationMode` is `NotSpecified` or null.
- `resourceAuth` is **only** valid on `HostedMcpServer` — providing it on `ManagedMcpServer` fails validation.
- For `identity.type = SystemAssigned`, the gateway must have a SystemAssigned MI; for user-assigned, the resource ID must be attached.

## Common mistakes

| Mistake | Fix |
|---|---|
| Putting `connectors[]` for a Hosted MCP server | Hosted servers use `hostedMcpServer.hostedMcpServerId` instead. |
| Putting `resourceAuth` on a `ManagedMcpServer` | Remove it — only valid on `HostedMcpServer`. |
| `operations[].name` not matching the connector's apiOperations | Re-fetch with `apiOperations?api-version=2016-06-01` and copy the `name` verbatim — case + parens matter. |
| Guessing dynamic-value IDs in `userParameters[].value` | Always resolve via `dynamicInvoke` first ([dynamic-values.md](dynamic-values.md)). |
| Forgetting access policies | The MCP endpoint will 403 your MCP client. Add the caller's objectId. |
| Skipping consent on the underlying connection | Tool calls fail with 401 — go through [consent.md](consent.md) first. |
