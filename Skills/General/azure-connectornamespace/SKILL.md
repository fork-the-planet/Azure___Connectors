---
name: azure-connectornamespace
description: |
  Azure Connector Namespace — manage namespaces, connections, triggers, and MCP server configs.
  Connect external SaaS services (Office 365, Teams, SharePoint, OneDrive, Forms, GitHub,
  Azure Blob, ...) to any user-provided webhook URL via event-driven triggers, expose
  selected connector operations as an MCP server endpoint, or call connector operations
  on demand via `dynamicInvoke`.
  Use when:
  - Creating or managing connector namespaces and connections
  - Creating or managing trigger configs that POST to an arbitrary callback URL
  - Subscribing to connector events (email, file, list-item, form response, Teams message)
  - Wiring event sources to a customer-owned webhook, Function App, Logic App, or API
  - Recurrence / sliding-window triggers that fire on a schedule
  - Exposing connector operations as Model Context Protocol (MCP) tools at a namespace endpoint
  - Calling connector APIs (send email, post Teams message, upload files, list items, ...)
  Triggers: "connector namespace", "connector gateway", "create trigger", "trigger config", "webhook trigger",
  "recurrence trigger", "schedule trigger", "on new email", "on new file",
  "on new item", "on form response", "callback url", "notification url",
  "mcp", "mcp server", "mcp tools", "model context protocol",
  "send email", "post teams message", "upload to onedrive", "automate"
---

# Azure Connector Namespace (generic)

Manage Microsoft.Web connector namespaces, their connections, trigger configs, and MCP
server configs. This skill is **sandbox-agnostic** — it does not assume your callback
target. Callbacks can be any HTTP(S) URL (Function App, Logic App, App Service,
ngrok, anywhere) and you choose how the namespace authenticates to it.

> If you specifically need to fan events into an Azure Container Apps sandbox group
> (with declarative `gatewayConnections[]` wiring and sandbox callbacks), use the
> companion skill at `Skills/Sandbox/azure-connectorgateway` instead.

> **Naming note.** This skill was previously called "Connector Gateway". The
> resource is now displayed as **"Connector Namespace"** everywhere (matching
> the Cascade portal rename — see `Cascade.Portal.Client/src/components/CreateConnectorNamespacePanel.tsx`).
> **The ARM resource type is still `Microsoft.Web/connectorGateways`** (legacy
> URL segment kept for backwards compatibility) and the property `gatewayConnections[]`
> on sandbox groups also keeps its name. Do not rewrite those API strings.

## Three patterns this skill supports

| Pattern | When to use | Output |
|---|---|---|
| **A) Trigger config** | "Notify my webhook when X happens" / "Run my workflow every N minutes" | A `triggerConfigs/{name}` resource that POSTs to your `callbackUrl` |
| **B) MCP server config** | "Expose these connector operations as MCP tools to an LLM client" | A `mcpServerConfigs/{name}` resource with a public `mcpEndpointUrl` |
| **C) Direct API call** | "Send an email" / "Post a Teams message" — one-off operation | One `dynamicInvoke` POST against the connection |

## Rules (MUST follow)

| Rule | Details |
|------|---------|
| **No hallucination** | Check `references/` for details. Use `az rest --help` for syntax. |
| **No generated notebooks/scripts** | Walk the user through interactively. Do NOT generate a standalone notebook or script. |
| **No guessing dynamic values** | `x-ms-dynamic-*` → call the API, present results, STOP. Never assume a team/channel/folder/site/list. |
| **No guessing the callback URL** | The callback URL is **always** user-provided. Ask for it explicitly. Do NOT invent one. |
| **MSI audience: ask, then default** | For `ManagedServiceIdentity` callback auth, **ask the user for `audience`** (the AAD-protected resource the namespace should acquire a token for, e.g. an AAD app they own, `https://graph.microsoft.com/`, etc.). If the user doesn't provide one, default to `https://management.azure.com/`. **Never** use the callback URL as the audience. |
| **Execute, don't ask** | Once you have inputs, run the commands. Don't ask "Can I run this?" |
| **`az rest` only** | No `az connectornamespace` (or legacy `az connectorgateway`) extension exists. Use `az rest` for ARM and `az rest --resource` for data-plane. |
| **Always `@$tmpFile`** | For `az rest --body` in PowerShell — inline JSON breaks quoting. See [gotchas.md](references/gotchas.md). |
| **Trigger body schema** | Properties root contains: `type` OR `connectionDetails`+`operationName`+`parameters`, plus `notificationDetails` (`callbackUrl`+`authentication`+`body?`). **Body-sourced leaves (top-level body param + every nested sub-property) are aggregated into ONE `parameters[]` entry whose `name` is literally `"body"` and whose `value` is the nested object** (dotted leaf names like `filter.labels` get rolled up via `setNestedValue`). The wrapper name `"body"` is independent of the Swagger body parameter's own name. Non-body dotted leaves are grouped under their root segment. See [trigger-setup.md](references/trigger-setup.md) §2b. |
| **Trigger needs `namespace-acl`** | For connector-event triggers, the namespace MI must have an access policy on the connection. See [trigger-setup.md](references/trigger-setup.md) Step 4. |
| **MCP user params** | Each `userParameters[]` entry is a **fixed value** for a connector-operation parameter (resolved via `dynamic-values` against the connection at config time). Each `agentParameters[]` entry declares a JSON-Schema input the **caller (LLM) supplies** at tool-call time. **Every required parameter (including required body sub-properties) MUST appear in one of the two arrays** — the runtime rejects the call with `missing required property '<path>'` otherwise. See [mcp-server-config.md](references/mcp-server-config.md). |
| **MCP per-parameter triage** | **STOP and ask the user, for each operation parameter (path/query/body field, including each required body sub-property), whether it should be a fixed `userParameter`, a caller-supplied `agentParameter`, or skipped (optional only).** Do this **before** the `mcpServerConfigs` PUT, even when no `x-ms-dynamic-*` markers are present. Decompose the body's object schema and triage each leaf. **For MCP, body wrapper name = the Swagger body param's own name (e.g. `emailMessage`).** See [mcp-server-config.md](references/mcp-server-config.md) §"Per-parameter triage workflow". |
| **Parallel execution** | Run independent ops (connections, ACLs, dynamic-value lookups, MCP operations) as parallel tool calls. |

**When to STOP and ask the user:** subscription/resource group, namespace name, connection name, any parameter with dynamic values (teams/channels/folders/sites/lists), callback URL, callback authentication type, **MSI `audience` (if MSI auth chosen — default to `https://management.azure.com/` if user doesn't provide one)**, OAuth consent completion, **MCP per-parameter triage (`userParameter` vs `agentParameter` vs skip — for every path/query/body field, including each body sub-property)**.

**When to EXECUTE immediately:** namespace/connection/trigger/MCP-config/access-policy CRUD, role assignments, dynamic-value lookups.

---

### Step 0: Prerequisites & Azure context

1. Check `az account show`. If missing, see [prerequisites.md](references/prerequisites.md).
2. **Select subscription** — list, ask user to pick:
   ```bash
   az account list --query "[].{name:name, id:id, isDefault:isDefault}" -o table
   ```
   Set if non-default: `az account set --subscription "{sub}"`. Store `{sub}` for all
   subsequent commands.
3. **Select resource group**:
   - Existing: `az group list --query "[].{name:name, location:location}" -o table` → user picks.
   - New: ask for name + location, then `az group create --name {rg} --location {location}`.

**Stop and wait for the user's answers before continuing.**

---

### Step 1: Namespace setup

> **ARM base:** `https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorNamespaces`
> **API version:** `2026-05-01-preview`

Ask the user: "Do you have an existing connector namespace, or should I create a new one?"

- **Existing:** ask for the name and fetch it:
  ```bash
  az rest --method GET \
    --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{namespace}?api-version=2026-05-01-preview" \
    --query "{name:name, location:location, principalId:identity.principalId, tenantId:identity.tenantId, identityType:identity.type, userAssigned:identity.userAssignedIdentities}"
  ```
- **New:** ask for `{namespace}` name + location. **Create with a SystemAssigned managed identity**
  (required for trigger event subscriptions on connector-event triggers AND for
  `ManagedServiceIdentity` callback auth):
  ```powershell
  $namespaceBody = @{ location = "{location}"; identity = @{ type = "SystemAssigned" } } | ConvertTo-Json -Compress
  $tmp = New-TemporaryFile; Set-Content $tmp $namespaceBody
  az rest --method PUT `
    --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{namespace}?api-version=2026-05-01-preview" `
    --body "@$tmp" `
    --query "{name:name, principalId:identity.principalId, tenantId:identity.tenantId}"
  Remove-Item $tmp
  ```

**Capture `principalId` and `tenantId`** — needed later for the `namespace-acl`
access policy and (optionally) for `ManagedServiceIdentity` callback authentication.

> If a user later wants to call their callback URL using a **user-assigned** identity,
> they'll need to add that identity to the namespace separately. See
> [notification-authentication.md](references/notification-authentication.md).

---

### Step 2: Connection(s) + OAuth consent

Required for **trigger configs**, **MCP server configs**, and **direct API calls**.
Recurrence / sliding-window triggers with no connector-event source can skip this.

Create connections in parallel:

```powershell
$connBody = @{ properties = @{ connectorName = "office365" }; location = "{location}" } | ConvertTo-Json -Compress
$tmp = New-TemporaryFile; Set-Content $tmp $connBody
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{namespace}/connections/o365-conn?api-version=2026-05-01-preview" `
  --body "@$tmp"
Remove-Item $tmp
```

Then generate consent links and open in the browser — **see [consent.md](references/consent.md)** for the exact body format and `Start-Process` pattern. Verify status `Connected` before continuing. See also [connections.md](references/connections.md) for the full CRUD reference.

> **For trigger configs:** also create a `namespace-acl` access policy granting the
> namespace MI access to the connection (required for the namespace to subscribe to
> connector events). See [trigger-setup.md](references/trigger-setup.md) Step 4.

---

### Step 3: Choose the pattern

Ask the user:
- **A) Trigger config** — push notifications to your callback URL when events happen, or on a schedule.
- **B) MCP server config** — expose selected connector operations as MCP tools at a namespace endpoint, callable by any MCP client (Claude Desktop, VS Code, etc.).
- **C) Direct API call** — one-off `dynamicInvoke` (send an email now, list items now).

**Stop and wait for the user's answer.**

- A → **Step 4A**
- B → **Step 4B**
- C → **Step 4C**

---

### Step 4A: Trigger config

→ **Full details:** [trigger-setup.md](references/trigger-setup.md) | **Auth options:** [notification-authentication.md](references/notification-authentication.md) | **Dynamic params:** [dynamic-values.md](references/dynamic-values.md)

1. **Pick the trigger source.** Ask the user:
   - **Connector event** (e.g., new email, new file, new form response) — needs the connection from Step 2.
   - **Recurrence** — fires every N seconds / minutes / hours / days.
   - **Sliding window** — fires on time intervals with `startTime`/`endTime` window state.

2. **Connector event:** discover trigger operations on the connector:
   ```bash
   az rest --method GET \
     --url "https://management.azure.com/subscriptions/{sub}/providers/Microsoft.Web/locations/{location}/managedApis/{connector}/apiOperations?api-version=2016-06-01" \
     --query "value[?properties.trigger != null].{name:name, summary:properties.summary, trigger:properties.trigger}" -o table
   ```
   Pick one with the user. **Enumerate every parameter — including each
   sub-property of a `body` object** (resolve `$ref`, recurse into nested
   objects and array `items`). Triage each leaf:
   - `x-ms-dynamic-*` → resolve via [dynamic-values.md](references/dynamic-values.md). **STOP at every dynamic param.**
   - Static enum → present choices and **STOP** for user pick.
   - Free-form with obvious default (e.g., `folderPath=Inbox`) → use default, inform user.
   - Free-form with no default → **STOP and ask the user.**

   **When assembling `parameters[]`, build a nested object — do NOT emit dotted
   leaf names.** All body-sourced leaves (top-level body + every nested
   sub-property) collapse into ONE entry whose `name` is **literally the string
   `"body"`** (NOT the Swagger body parameter's name) and whose `value` is the
   nested object. Non-body dotted leaves group under their root segment. See
   [trigger-setup.md](references/trigger-setup.md) §2b for the exact pattern
   and worked examples.

3. **Recurrence / sliding window:** ask for `frequency` (Second/Minute/Hour/Day) and `interval`.

4. **Callback URL — ask the user explicitly.** Do NOT invent one. Format examples:
   - Function App: `https://{app}.azurewebsites.net/api/{fn}?code={key}`
   - Logic App HTTP trigger: full SAS URL from the Logic App's "When a HTTP request is received"
   - Custom API: any `https://...` endpoint

5. **Callback authentication — ask the user.** Options (full reference in [notification-authentication.md](references/notification-authentication.md)):
   | Type | Use when |
   |---|---|
   | *(none)* | Callback URL already contains its own auth token (e.g., Logic App SAS in querystring) |
   | `QueryString` | Add a `?key=value` automatically (e.g., Function App key) |
   | `Raw` | Send a literal `Authorization: <scheme> <parameter>` header |
   | `Basic` | HTTP Basic with `username`/`password` |
   | `ManagedServiceIdentity` | Namespace acquires a token for `audience` using its own MI (system- or user-assigned). **Ask the user for `audience`** — if they don't provide one, default to `https://management.azure.com/`. Never use the callback URL as the audience. See [notification-authentication.md](references/notification-authentication.md). |
   | `ActiveDirectoryOAuth` | Namespace authenticates as an Entra app (tenant/clientId/secret/audience) |
   | `ClientCertificate` | Mutual TLS with a `pfx`/`password` |

6. **Create the trigger config** (one PUT). See [trigger-setup.md](references/trigger-setup.md) Step 3 for the canonical body templates for each source × auth combination.

7. **Create the `namespace-acl`** (only for connector-event triggers). See [trigger-setup.md](references/trigger-setup.md) Step 4.

8. **Verify** the trigger state is `Enabled`:
   ```bash
   az rest --method GET \
     --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{namespace}/triggerConfigs/{name}?api-version=2026-05-01-preview" \
     --query "properties.state" -o tsv
   ```

---

### Step 4B: MCP server config

→ **Full details:** [mcp-server-config.md](references/mcp-server-config.md) | **Dynamic params:** [dynamic-values.md](references/dynamic-values.md)

1. **Pick connector(s) + operation(s).** Discover them:
   ```bash
   az rest --method GET \
     --url "https://management.azure.com/subscriptions/{sub}/providers/Microsoft.Web/locations/{location}/managedApis/{connector}/apiOperations?api-version=2016-06-01" \
     --query "value[?properties.trigger == null].{name:name, summary:properties.summary, description:properties.description}" -o table
   ```
   Each MCP "tool" maps to one connector operation under one connection.

2. **For each operation, triage every parameter — including each body sub-property.**

   First enumerate every parameter from the Swagger:
   - All `parameters[]` entries (`path` / `query` / `body` / `header`).
   - For each `body` parameter whose schema is an object (resolve `$ref`),
     enumerate its `properties` and the inner `required` array. Recurse into
     nested objects and `items` of arrays.

   Then resolve dynamic markers — the four extension kinds
   (`x-ms-dynamic-values`, `-list`, `-tree`, `-schema`) **all apply** here,
   exactly like trigger setup:
   - `x-ms-dynamic-values` / `-list` → `dynamicInvoke` the lookup operation, **STOP** for user pick, store the `value-path` value.
   - `x-ms-dynamic-tree` → walk the tree (root → children), **STOP** at each level, store the final opaque token.
   - `x-ms-dynamic-schema` / `-properties` → resolve schema after parents are picked. Bake the parents so the LLM gets a stable tool shape.
   - Cascading params (e.g., channel depends on team): always resolve parents first; pass their `value` (not display name) to child lookups.

   **STOP and ask the user, for every parameter (and every required body
   sub-property)**, whether it should be:

   | Choice | What it means |
   |---|---|
   | **`userParameter`** | Bake a fixed value now (`{name, value}`). LLM cannot change it. Use this for enumerable connector IDs (team/channel/site/list/folder/file/db/table) and for org-default fields. |
   | **`agentParameter`** | LLM supplies on each call (`{name, schema}`). Use this for free-form content (subject/body/recipient) and for required fields with no fixed value. |
   | **skip** | Only valid if the field is optional (not in the Swagger `required` array). |

   **Required fields cannot be skipped.** Body sub-properties are nested under
   one `agentParameter` whose `schema.type` is `"object"` and whose
   `schema.properties` mirrors the body. See
   [mcp-server-config.md](references/mcp-server-config.md) §"Per-parameter
   triage workflow" and [dynamic-values.md](references/dynamic-values.md).

3. **PUT the MCP server config.** Body shape:
   ```json
   {
     "properties": {
       "description": "...",
       "connectors": [
         {
           "name": "office365",
           "displayName": "Office 365",
           "connectionName": "o365-conn",
           "operations": [
             {
               "name": "Send_Email_(V2)",
               "displayName": "Send Email",
               "description": "Send an email via Office 365.",
               "userParameters": [
                 { "name": "from", "value": "alerts@contoso.com" }
               ],
               "agentParameters": [
                 { "name": "emailMessage", "schema": { "type": "object", "required": true, "properties": { "To": { "type": "string", "required": true }, "Subject": { "type": "string" }, "Body": { "type": "string" } } } }
               ]
             }
           ]
         }
       ]
     }
   }
   ```
   PUT to: `.../connectorGateways/{namespace}/mcpServerConfigs/{name}?api-version=2026-05-01-preview`

   > **Always serialize with `ConvertTo-Json -Depth 20`** (or higher). The
   > default depth (2) silently flattens nested body schemas to the literal
   > string `"System.Collections.Hashtable"`. GET the config after the PUT and
   > verify the nested properties are real objects.

4. **GET the config** and return `properties.mcpEndpointUrl` — that's the URL the MCP
   client points at. See [mcp-server-config.md](references/mcp-server-config.md) for the auth-mode + access-policy details.

---

### Step 4C: Direct API call via `dynamicInvoke`

→ **Full details:** [direct-api.md](references/direct-api.md) | **Dynamic params:** [dynamic-values.md](references/dynamic-values.md)

1. Get the connector Swagger (`managedApis/{connector}?export=true`) → operationId → path table
2. Resolve any `x-ms-dynamic-*` parameters with [dynamic-values.md](references/dynamic-values.md). **STOP at every dynamic param.**
3. POST to `dynamicInvoke` with the resolved `method` + `path` (+ optional `queries`, `body`, non-`Content-*` headers).

---

### Final verification checklist

**For trigger configs (path A):**
- ✅ Namespace exists; for `ManagedServiceIdentity` callback auth, namespace has the requested identity
- ✅ For connector-event triggers: connection `Connected`, `namespace-acl` exists on the connection
- ✅ Trigger `properties.state` is `Enabled`
- ✅ User-provided callback URL is reachable + accepts the chosen auth

**For MCP server configs (path B):**
- ✅ All referenced connections are `Connected`
- ✅ `properties.mcpEndpointUrl` is populated in the GET response
- ✅ For Hosted MCP servers with `AuthenticationMode != NotSpecified`: `resourceAuth` is set (see [mcp-server-config.md](references/mcp-server-config.md))
- ✅ Access policies on the MCP server config grant the consuming clients access

**For direct API (path C):**
- ✅ Connection `Connected`
- ✅ `dynamicInvoke` returns `response.statusCode` in 2xx

## Quick reference

```bash
# ARM base:  https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways
# API ver:   api-version=2026-05-01-preview

# Namespace
az rest --method GET --url ".../connectorGateways/{namespace}?api-version=2026-05-01-preview"

# Connections
az rest --method GET --url ".../connectorGateways/{namespace}/connections?api-version=2026-05-01-preview"

# List trigger operations + summaries
az rest --method GET --url ".../locations/{location}/managedApis/{connector}/apiOperations?api-version=2016-06-01"

# Get Swagger (paths, parameters, x-ms-dynamic-*)
az rest --method GET --url ".../locations/{location}/managedApis/{connector}" --url-parameters "api-version=2016-06-01" "export=true"

# Dynamic invoke
az rest --method POST --url ".../connectorGateways/{namespace}/connections/{conn}/dynamicInvoke?api-version=2026-05-01-preview" --body '{"request":{"method":"GET","path":"/..."}}'

# Trigger configs
az rest --method GET --url ".../connectorGateways/{namespace}/triggerConfigs?api-version=2026-05-01-preview"
az rest --method POST --url ".../connectorGateways/{namespace}/triggerConfigs/{name}/disable?api-version=2026-05-01-preview"
az rest --method POST --url ".../connectorGateways/{namespace}/triggerConfigs/{name}/enable?api-version=2026-05-01-preview"

# MCP server configs
az rest --method GET --url ".../connectorGateways/{namespace}/mcpServerConfigs?api-version=2026-05-01-preview"
az rest --method GET --url ".../connectorGateways/{namespace}/mcpServerConfigs/{name}?api-version=2026-05-01-preview" --query "properties.mcpEndpointUrl" -o tsv
```

## References

- [prerequisites.md](references/prerequisites.md) — required tooling and Azure setup
- [quickstart.md](references/quickstart.md) — minimal commands to list everything
- [connections.md](references/connections.md) — connection CRUD + ACLs
- [consent.md](references/consent.md) — OAuth consent link generation (exact body format)
- [dynamic-values.md](references/dynamic-values.md) — `x-ms-dynamic-{values,list,tree,schema}` resolution algorithms
- [trigger-setup.md](references/trigger-setup.md) — trigger config creation (all source types, all auth types)
- [notification-authentication.md](references/notification-authentication.md) — callback authentication reference
- [mcp-server-config.md](references/mcp-server-config.md) — MCP server config CRUD
- [direct-api.md](references/direct-api.md) — `dynamicInvoke` recipes
- [trigger-flow.md](references/trigger-flow.md) — end-to-end architecture diagram
- [tutorial.md](references/tutorial.md) — walkthrough: recurrence trigger → user webhook
- [gotchas.md](references/gotchas.md) — common issues
