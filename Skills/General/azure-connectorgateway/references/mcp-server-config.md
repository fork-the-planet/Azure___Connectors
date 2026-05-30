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
              { "name": "from", "value": "alice@contoso.com" }
            ],
            "agentParameters": [
              { "name": "emailMessage", "schema": { "type": "object", "properties": { "To": { "type": "string", "required": true }, "Subject": { "type": "string" }, "Body": { "type": "string" } } } }
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
| `operations[].userParameters[]` | optional | **Pre-bound (fixed)** values for operation parameters — see "User vs agent" below |
| `operations[].agentParameters[]` | optional | **Caller-supplied (LLM-at-call-time)** parameters, declared as JSON Schema — see "User vs agent" below |

### `userParameters` vs `agentParameters` — every required field must appear in one of them

This is the **single most important rule** for MCP server configs. The runtime
validates every required parameter of the operation (path, query, body —
including required body sub-properties) against the union of `userParameters`
and `agentParameters`. If a required field is missing from both, the endpoint
fails at invoke time with errors like:

```
The API operation 'SendEmailV2' is missing required property 'emailMessage/To'.
```

| Array | Shape | Semantics |
|---|---|---|
| `userParameters[]` | `{ "name": "<param>", "value": <literal> }` | The value is **baked into the config** and sent on every tool call. The LLM cannot change it. |
| `agentParameters[]` | `{ "name": "<param>", "schema": { "type": ..., "description": ..., "required": ..., "enum": ..., "properties": {...} } }` | The LLM **supplies the value on each tool call**. The schema becomes part of the MCP tool's input contract. |

Decision rule for each operation parameter:

- **Enumerable connector-supplied identifier** (team, channel, site, list, folder, file, database, table, mailbox) → bake as `userParameter` (use `dynamic-values` resolution — see below).
- **Free-form caller-controlled content** (subject, message body, recipient email, search query) → declare as `agentParameter`.
- **Required field with no obvious fixed value** → declare as `agentParameter` (so the LLM is forced to supply it).
- **Optional field that should be hidden from the LLM** → omit entirely.

> **STOP and ask the user for every operation parameter** before the PUT:
> "Should `<paramName>` be a fixed value you set now, supplied by the LLM at
> call time, or skipped (if optional)?" — do not guess. The LLM tool contract
> is exactly what's declared here.

### Body parameters — nested object decomposition

When an operation has a `body` parameter whose schema is a complex object
(e.g., Gmail `SendEmailV2`'s `emailMessage` body wraps `To`, `Subject`, `Body`,
…), the body becomes **one entry** in `agentParameters` whose `schema.type` is
`"object"` and whose `schema.properties` lists each inner field:

```json
{
  "name": "emailMessage",
  "schema": {
    "type": "object",
    "required": true,
    "properties": {
      "To":         { "type": "string", "required": true, "description": "Recipient address(es), semicolon- or comma-separated." },
      "Subject":    { "type": "string", "description": "Subject of the outgoing email." },
      "Body":       { "type": "string", "description": "HTML body of the outgoing email." },
      "Cc":         { "type": "string", "description": "Cc addresses." },
      "Bcc":        { "type": "string", "description": "Bcc addresses." },
      "Importance": { "type": "string", "enum": ["Normal","Low","High"], "description": "Importance." },
      "Attachments": {
        "type": "array",
        "description": "Attachments to send with the email.",
        "items": {
          "type": "object",
          "properties": {
            "Name":         { "type": "string", "description": "File name." },
            "ContentBytes": { "type": "string", "format": "byte", "description": "Base64 content." },
            "ContentType":  { "type": "string", "description": "MIME type." }
          }
        }
      }
    }
  }
}
```

Mirror Swagger faithfully: `type`, `format`, `description`, `enum`, and
`required` (as a boolean on each sub-property — not the JSON Schema array form,
this is the Connector-Gateway convention). For nested arrays use `items` with
its own object schema.

To bake parts of the body as fixed values, use the **same wrapper name** in
`userParameters` with `value` as an object literal:

```json
{ "name": "emailMessage", "value": { "From": "alerts@contoso.com" } }
```

You can have **both** a `userParameters` entry and an `agentParameters` entry
for the same body root — `userParameters` provides fixed sub-fields, and
`agentParameters` declares the caller-supplied sub-fields.

> **Heads up — `ConvertTo-Json` depth.** PowerShell defaults to depth 2 and the
> nested body schemas above are easily 4–6 levels deep. Always serialize with
> `-Depth 20` (or higher), otherwise inner properties will be silently flattened
> into the string `"System.Collections.Hashtable"` and the PUT will succeed but
> the runtime schema will be wrong.

## Per-parameter triage workflow

**Every connector operation parameter goes through this triage before the PUT —
no exceptions, even when there are no `x-ms-dynamic-*` markers anywhere on the
operation.** The body schema is part of the triage: a `body` parameter with a
nested object schema must be decomposed into its sub-properties so each one is
classified.

### Step 1: Get the connector's Swagger once

```bash
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/providers/Microsoft.Web/locations/{location}/managedApis/{connector}" \
  --url-parameters "api-version=2016-06-01" "export=true" -o json > $env:TEMP\swagger.json
```

Find the operation by `operationId` and read its `parameters[]`. For each
parameter, identify which extension is present.

### Step 2: Enumerate every parameter — including body sub-properties

For each operation:

1. List all top-level parameters from the Swagger (`parameters[]`): each has `in`
   ∈ `{path, query, body, header}` and a `name`.
2. For any `body` parameter whose schema is an object (resolve `$ref` to
   `definitions/<Name>`), enumerate its properties **and** its inner `required`
   array. Recurse into nested objects and `items` of arrays.
3. Note which fields are required at each level. Required fields MUST be
   classified — they cannot be skipped.

### Step 3: Triage every parameter — STOP and ASK per parameter

**Bring the full parameter list to the user and ask, for each one:**

> "Should this be a fixed value I bake now (`userParameter`), supplied by the
> caller / LLM on each tool call (`agentParameter`), or skipped (if optional)?"

| Parameter shape | Default recommendation to surface to the user | If `userParameter` chosen |
|---|---|---|
| `x-ms-dynamic-values` | `userParameter` — IDs are not LLM-discoverable. Resolve via [dynamic-values.md](dynamic-values.md) §`x-ms-dynamic-values`. **STOP** for the user's pick. | Store the `value-path` field, not the display name |
| `x-ms-dynamic-list` | `userParameter` — same as above. | Same |
| `x-ms-dynamic-tree` | `userParameter` — final `value` is opaque (e.g., `%252fShared%2520Documents`). Walk the tree (§`x-ms-dynamic-tree`), **STOP** at each level. | Store the opaque token |
| `x-ms-dynamic-schema` body | Bake the parent(s) as `userParameter`, then triage the resolved body fields the same way. See §"Dynamic schema" below. | The parent's `value-path` value |
| `x-ms-dynamic-properties` | Same as `x-ms-dynamic-schema` (older variant). | Same |
| Static enum on a fixed-meaning field | Either — `userParameter` if there's an obvious org default, otherwise `agentParameter` with `schema.enum`. | The exact enum value |
| Required free-form caller content (`To`, `subject`, `body`, `query`) | `agentParameter` — declare the JSON Schema. | n/a |
| Optional free-form | `agentParameter` (omit `required`) if the LLM should be able to use it, otherwise skip. | n/a |

> **Never invent a team / channel / site / folder / list / mailbox / database ID.**
> Resolve dynamic values via `dynamicInvoke` and STOP at every dynamic param.

> **Never silently skip a required field.** Every Swagger `required` (including
> required sub-properties of a body object) must appear in `userParameters` or
> `agentParameters`, or the runtime will fail with
> `missing required property '<path>'` at the first tool invocation.

### Step 4: Handle cascading dependencies

Many parameters' `x-ms-dynamic-*` lookups **depend on prior parameters**. You
must resolve the parents first and use the chosen `value` as input to the
child lookup. This is identical to the algorithm in
[dynamic-values.md](dynamic-values.md) §"Step 2: Understand value vs display name"
and §"x-ms-dynamic-schema".

**Worked example: "Post message to Teams channel"**

The `PostMessageToChannelV3` operation has:

```text
groupId   ← x-ms-dynamic-values via GetAllTeams
channelId ← x-ms-dynamic-values via GetChannelsForGroup(groupId)
message   ← LLM-supplied free-form
```

To bake `groupId` + `channelId` into `userParameters[]`:

1. Call `dynamicInvoke` → `GetAllTeams`. **STOP** for the user to pick a team.
   Capture the team's `value-path` field (e.g., `value-path = "id"` → `"abc..."`).
2. Call `dynamicInvoke` → `GetChannelsForGroup` with `groupId = "abc..."`.
   **STOP** for the user to pick a channel. Capture `id`.
3. Build the MCP config:
   ```json
   "userParameters": [
     { "name": "groupId",   "value": "abc..." },
     { "name": "channelId", "value": "19:def...@thread.tacv2" }
   ],
   "agentParameters": [
     { "name": "message", "schema": { "type": "object", "required": true, "properties": { "body": { "type": "object", "properties": { "content": { "type": "string", "required": true, "description": "Markdown / HTML message content." } } } } } }
   ]
   ```
4. Declare `message` as an `agentParameter` so the LLM supplies it per tool call.

> **Always pass the stored `value` (from `value-path`), not the display name
> (from `value-title`)**, as input to child lookups. The connector rejects
> display names with `NotFound` or empty results.

### Step 5: Dynamic schema (body shape)

When an operation's body parameter uses `x-ms-dynamic-schema` (e.g.,
"Create item in SharePoint list" — the body fields are the list's columns),
the schema can only be resolved after the parent parameters (`dataset`,
`table`) are known.

**Recommendation:** if a tool uses `x-ms-dynamic-schema` for its body, **always
bake the dependent parents** (`dataset`, `table`, ...) as `userParameters[]`
so the LLM gets a stable, concrete tool shape. Without that, the LLM cannot
know what fields it's allowed to send.

Resolve the schema once at config time, using
[dynamic-values.md](dynamic-values.md) §"x-ms-dynamic-schema" algorithm:

```bash
# Once dataset + table are chosen, fetch the schema:
az rest --method POST \
  --url ".../connectorGateways/{gw}/connections/{conn}/dynamicInvoke?api-version=2026-05-01-preview" \
  --body "@$schemaBody"
# (request body uses GetTable's operationId per the operation's
#  x-ms-dynamic-schema.operationId, with the resolved dataset + table)
```

Decompose the returned JSON schema into one `agentParameter` per resolved
field (or a single `agentParameter` whose `schema` mirrors the whole body
object), and STOP-and-ask the user per the Step 3 triage. Confirm with the
user before saving the MCP config.

### Step 6: LLM-facing input schema

The MCP tool's input contract is **exactly** the union of `agentParameters[]`
entries you declared in Step 3. `userParameters[]` are invisible to the LLM —
they're baked into the outbound call. So:

- Required body sub-property → must be an `agentParameter` (or baked as a
  `userParameter`). Never left implicit.
- `x-ms-dynamic-values` / `-list` left as `agentParameter` → the LLM must
  guess valid IDs; **this rarely works**. Prefer baking these as `userParameters[]`.
- `x-ms-dynamic-tree` left as `agentParameter` → almost never works (opaque
  tokens). Bake it.
- `x-ms-dynamic-schema` body left as `agentParameter` with parents un-baked →
  the body schema is unknown until tool-call time; the MCP tool input becomes
  generic `object`. **Bake the parents** as `userParameters`.

**Rule of thumb:** if a parameter's value space is "anything the user might
imagine" (a subject line, a message body, an email address), declare it as an
`agentParameter`. If it's "one of an enumerable, connector-supplied set"
(team, channel, site, list, folder, file, database, table), **bake it as a
`userParameter` via dynamic resolution**.

## PUT the config

```powershell
$body = @{
  properties = @{
    description = "Send emails via Office 365."
    connectors = @(
      @{
        name = "office365"
        displayName = "Office 365"
        connectionName = "o365-conn"
        operations = @(
          @{
            name = "Send_Email_(V2)"
            displayName = "Send email"
            description = "Send an email through Office 365. Caller must supply 'To'."
            userParameters = @(
              @{ name = "from"; value = "alerts@contoso.com" }
            )
            agentParameters = @(
              @{
                name = "emailMessage"
                schema = @{
                  type = "object"
                  required = $true
                  properties = @{
                    To      = @{ type = "string"; required = $true; description = "Recipient address(es), semicolon- or comma-separated." }
                    Subject = @{ type = "string"; description = "Subject line." }
                    Body    = @{ type = "string"; description = "HTML body." }
                  }
                }
              }
            )
          }
        )
      }
    )
  }
} | ConvertTo-Json -Depth 20 -Compress    # IMPORTANT: -Depth 20+ for nested body schemas

$tmp = New-TemporaryFile; Set-Content $tmp $body
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/mcpServerConfigs/{mcp_name}?api-version=2026-05-01-preview" `
  --body "@$tmp"
Remove-Item $tmp
```

> **Verify after the PUT** — `GET` the config and check that the nested
> `agentParameters[].schema.properties.<field>` are present as objects, NOT as
> the literal string `"System.Collections.Hashtable"`. That string means
> `ConvertTo-Json -Depth` was too shallow — re-serialize with `-Depth 20` (or
> higher) and re-PUT.

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
Grant access to whoever (user, group) needs to call the MCP tools.

**Important — MCP access-policy schema differs from connection access policies:**

1. The body needs BOTH a `principal.type` (must be `"ActiveDirectory"`) AND a
   sibling `properties.principalType` (must be `"User"` or `"Group"` —
   `"ActiveDirectory"` is NOT accepted here, and there is no MI/ServicePrincipal
   option). Sending only one of the two fields will fail validation.
2. The access-policy **name in the URL must equal the principal's `objectId`**
   (case-insensitive). The server-side validator rejects any other name.
3. `objectId` and `tenantId` must be well-formed GUIDs.

```powershell
$aclBody = @{
  location = "{location}"
  properties = @{
    principal = @{
      type = "ActiveDirectory"
      identity = @{ objectId = "{caller_object_id}"; tenantId = "{tenant_id}" }
    }
    principalType = "User"   # or "Group"
  }
} | ConvertTo-Json -Depth 5 -Compress
$tmp = New-TemporaryFile; Set-Content $tmp $aclBody
# IMPORTANT: the path segment after /accessPolicies/ must equal {caller_object_id}.
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/mcpServerConfigs/{mcp_name}/accessPolicies/{caller_object_id}?api-version=2026-05-01-preview" `
  --body "@$tmp"
Remove-Item $tmp
```

For the signed-in user, get `{caller_object_id}` with
`az ad signed-in-user show --query id -o tsv`. For another user,
`az ad user show --id <upn> --query id -o tsv`. For a group,
`az ad group show --group <name> --query id -o tsv`.

> ⚠️ Managed identities and service principals are NOT currently supported as
> MCP access-policy principals — only Entra users and groups. If a non-user
> caller needs access (e.g., another Azure resource's MI), use a group and add
> that principal to the group.

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
| **Skipping required body sub-properties** | Endpoint fails at invoke time with `missing required property '<body>/<field>'`. Every Swagger `required` field — including nested body properties — MUST be declared in `userParameters` or `agentParameters`. Triage them per §"Per-parameter triage workflow". |
| **Body params not nested under their root name** | The body becomes ONE `agentParameter` whose `name` is the body parameter's name (e.g., `emailMessage`) and whose `schema` is `{type:"object", properties: {...}}`. Don't flatten the inner fields to top-level entries. |
| **`ConvertTo-Json -Depth` too shallow → `"System.Collections.Hashtable"` in the saved schema** | Use `-Depth 20` (or higher) when serializing the PUT body. After the PUT, GET the config and confirm nested properties are objects, not the truncation string. |
