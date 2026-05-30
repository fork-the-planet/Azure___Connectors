# Trigger Setup

Detailed commands for creating trigger configs on a connector gateway. Triggers
fire on either a connector event (new email, new file, ...) or on a schedule
(Recurrence / SlidingWindow), and POST a notification to your `callbackUrl`.

## Step 1: Pick the trigger source

| Source | When fires | Requires connection? |
|---|---|---|
| **Connector event** | When the connector reports an event (e.g., `OnNewEmailV3`) | Yes — plus `gateway-acl` |
| **Recurrence** | Every N `Second`/`Minute`/`Hour`/`Day` | No |
| **SlidingWindow** | Every N units with a `startTime`/`endTime` window state | No |

## Step 2: Connector-event triggers — discover + collect parameters

```bash
# Discover trigger operations for the connector
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/providers/Microsoft.Web/locations/{location}/managedApis/{connector}/apiOperations?api-version=2016-06-01" \
  --query "value[?properties.trigger != null].{name:name, summary:properties.summary, trigger:properties.trigger}" -o table
```

Present operations to the user. After selection, fetch the full Swagger (see
[direct-api.md](direct-api.md) §1) to find the operation's parameter list.

### 2a. Enumerate every parameter — including body sub-properties

Trigger parameters are baked at config time (there's no `agentParameters` for
triggers — it's `parameters[]` and every entry has a fixed `value`). But the
enumeration step is the same as for MCP:

1. List all top-level `parameters[]` entries (`in: path | query | body | header`).
2. For any `body` parameter whose schema is an object (resolve `$ref` to
   `definitions/<Name>`), enumerate its `properties` and required fields.
   Recurse into nested objects and `items` of arrays.
3. For each leaf (top-level OR nested body sub-property), classify:
   - **Has `x-ms-dynamic-*`** → resolve via [dynamic-values.md](dynamic-values.md) and **STOP** for user selection
   - **Static enum** → present choices and **STOP**
   - **Free-form with obvious default** (e.g., `folderPath=Inbox`) → use default, inform user
   - **Free-form, no default** → **STOP** and ask the user

> **STOP-and-ask applies to every parameter — including required body
> sub-properties.** Required fields cannot be skipped or the trigger will fail
> at subscribe time or first fire.

### 2b. Wire shape — nested objects for body / dotted-path leaves

Triggers use a single `parameters[]` array (no user vs agent split). Each entry
is `{name, value}` where `value` may be a scalar OR a complex object. There are
three rules for assembling it (mirroring Cascade's `serializeTriggerParams`):

| Param shape (from Swagger) | Wire entry |
|---|---|
| Top-level scalar (`folderPath`, `groupId`) | `{ "name": "folderPath", "value": "Inbox" }` |
| Top-level object (non-body), with dotted leaf names like `filter.from` | `{ "name": "filter", "value": { "from": "..." } }` — group dotted entries under their root |
| **Any body-sourced leaf** (the Swagger `body` parameter or any of its nested sub-properties) | **All body leaves are collected into ONE entry named literally `"body"`** whose `value` is the nested object. Dotted leaf names like `repository.owner` are placed at their nested path inside `body`. |

> **Critical:** The wrapper name for body params is **literally the string `"body"`**,
> NOT the Swagger body parameter's own name. (Teams' Swagger declares the body
> param as `requestBody`, but the runtime expects the entry to be named `body`.)
> This is a trigger-ARM-config convention — different from MCP, where the body
> wrapper preserves the Swagger name (e.g. `emailMessage`). See
> [mcp-server-config.md](mcp-server-config.md) §"Body parameters" for the MCP convention.

**Example — single-body trigger** (e.g. a connector with `body.filter.labels`):

```powershell
parameters = @(
  @{ name = "groupId"; value = "abc..." }   # top-level scalar
  @{
    name  = "body"                           # literal "body" wrapper
    value = @{
      filter = @{                            # nested object built from
        labels = @("bug","release")          # what the user supplied
      }
      includeAttachments = $true
    }
  }
)
```

**Anti-pattern (do NOT do this)** — keeping the body leaves as flat dotted
parameter names. The runtime won't route them:

```powershell
# WRONG — flat dotted names won't be unwrapped server-side
parameters = @(
  @{ name = "body.filter.labels"; value = "bug,release" }
  @{ name = "body.includeAttachments"; value = $true }
)
```

### 2c. Worked example — Swagger → user answers → assembled body

For Teams `PostMessageToChannelV3` the Swagger body is:

```json
"requestBody": {                 // ← Swagger body param's own name
  "in": "body",
  "schema": {
    "type": "object",
    "required": ["recipient"],
    "properties": {
      "recipient": {
        "type": "object",
        "required": ["groupId", "channelId"],
        "properties": {
          "groupId":   { "type": "string", "x-ms-dynamic-values": {...} },
          "channelId": { "type": "string", "x-ms-dynamic-values": {...} }
        }
      },
      "messageBody": {
        "type": "object",
        "properties": {
          "content":     { "type": "string" },
          "contentType": { "type": "string", "enum": ["html","text"] }
        }
      },
      "subject": { "type": "string" }
    }
  }
}
```

**Step A — enumerate every leaf:** `recipient.groupId`, `recipient.channelId`,
`messageBody.content`, `messageBody.contentType`, `subject`. Required ones:
`recipient.groupId`, `recipient.channelId` (parents implied).

**Step B — STOP and ask per leaf** (record the user's answers):

| Leaf | Source | User-supplied answer |
|---|---|---|
| `recipient.groupId` | `x-ms-dynamic-values` → `GetAllTeams` → STOP, user picks "Engineering" | value-path = `"abc-team-id"` |
| `recipient.channelId` | `x-ms-dynamic-values` → `GetChannelsForGroup(groupId)` → STOP, user picks "general" | `"19:def@thread.tacv2"` |
| `messageBody.content` | Free-form, ask user | `"Build broken on main"` |
| `messageBody.contentType` | Static enum, ask user (default `text`) | `"text"` |
| `subject` | Free-form, optional, ask user | *(skipped)* |

**Step C — assemble the body as ONE nested object** named literally `"body"`
(NOT `"requestBody"`):

```powershell
parameters = @(
  @{
    name  = "body"                       # literal "body" — NOT "requestBody"
    value = @{
      recipient = @{                     # assembled from recipient.* leaves
        groupId   = "abc-team-id"
        channelId = "19:def@thread.tacv2"
      }
      messageBody = @{                   # assembled from messageBody.* leaves
        content     = "Build broken on main"
        contentType = "text"
      }
      # subject omitted because the user skipped it
    }
  }
)
```

> **Mental model:** treat the user's per-leaf answers as a flat
> `Record<dottedPath, value>` map, then `setNestedValue` each entry into a
> single accumulator object whose root is `body`. That accumulator becomes one
> `parameters[]` entry. This mirrors Cascade's `serializeTriggerParams` exactly
> (`src\Cascade.Portal.Client\src\components\ConnectorGateways\TriggerWizard\utils\serializeTriggerParams.ts`).

> **Polling cadence:** if the operation has neither `x-ms-notification` nor
> `x-ms-notification-content` in its Swagger, it polls (default ~3 min). Inform
> the user; if they want a different cadence, omit `type` and add a `recurrence`
> property on the trigger config:
> `recurrence: { frequency: "Minute", interval: 5 }`.

## Step 3: PUT the trigger config

PUT to `.../connectorGateways/{gw}/triggerConfigs/{name}?api-version=2026-05-01-preview`.

### 3A. Connector-event trigger

```powershell
$triggerBody = @{
  properties = @{
    description = "Notify webhook on new email"
    connectionDetails = @{
      connectorName = "office365"
      connectionName = "o365-conn"
    }
    operationName = "OnNewEmailV3"
    parameters = @(
      @{ name = "folderPath"; value = "Inbox" }
    )
    notificationDetails = @{
      callbackUrl = "https://my-api.contoso.com/email-hook"
      httpMethod  = "Post"
      authentication = @{
        type = "ManagedServiceIdentity"
        # Ask the user for audience. Default to https://management.azure.com/
        # if they don't provide one. NEVER default to the callback URL.
        audience = "https://management.azure.com/"
      }
    }
    state = "Enabled"
  }
} | ConvertTo-Json -Depth 20 -Compress   # -Depth 20+ for nested body objects

$tmp = New-TemporaryFile; Set-Content $tmp $triggerBody
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/triggerConfigs/{trigger_name}?api-version=2026-05-01-preview" `
  --body "@$tmp"
Remove-Item $tmp
```

> **`parameters`** must match the connector operation's input schema (resolved
> against the Swagger). See [direct-api.md](direct-api.md) §2 for parameter resolution.

### 3B. Recurrence trigger

```powershell
$triggerBody = @{
  properties = @{
    description = "Ping webhook every 5 minutes"
    type = "Recurrence"
    recurrence = @{
      frequency = "Minute"
      interval  = 5
    }
    notificationDetails = @{
      callbackUrl = "https://my-api.contoso.com/tick"
      httpMethod  = "Post"
      # Omit `authentication` if the URL is self-authenticating
    }
    state = "Enabled"
  }
} | ConvertTo-Json -Depth 6 -Compress

$tmp = New-TemporaryFile; Set-Content $tmp $triggerBody
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/triggerConfigs/{trigger_name}?api-version=2026-05-01-preview" `
  --body "@$tmp"
Remove-Item $tmp
```

| `frequency` | Allowed values |
|---|---|
| `Second` | interval ≥ 1 |
| `Minute` | interval ≥ 1 |
| `Hour`   | interval ≥ 1 |
| `Day`    | interval ≥ 1 |

### 3C. Sliding-window trigger

Same as Recurrence but with `type = "SlidingWindow"`. Use it when each invocation
needs a `windowStart`/`windowEnd` time range (e.g., "process records added in
the last hour, every hour"). The window state is tracked by the platform.

```powershell
$triggerBody = @{
  properties = @{
    description = "Hourly sliding window"
    type = "SlidingWindow"
    recurrence = @{
      frequency = "Hour"
      interval  = 1
    }
    notificationDetails = @{
      callbackUrl = "https://my-api.contoso.com/process-window"
      httpMethod  = "Post"
    }
    state = "Enabled"
  }
} | ConvertTo-Json -Depth 6 -Compress
# (same PUT as 3B)
```

### 3D. Custom callback body

Add `notificationDetails.body` if you want to override the default payload sent
to your callback:

```powershell
notificationDetails = @{
  callbackUrl = "..."
  httpMethod  = "Post"
  body = @{
    eventSource = "my-trigger"
    extra       = "context"
  }
}
```

If `body` is omitted, the connector-event payload (for event triggers) or an
empty body (for recurrence) is sent.

### Auth options

See [notification-authentication.md](notification-authentication.md) for all 6 auth types
(`QueryString`, `Raw`, `Basic`, `ManagedServiceIdentity`, `ActiveDirectoryOAuth`, `ClientCertificate`)
and their exact JSON shapes.

## Step 4: `gateway-acl` (connector-event triggers only)

The gateway MI must have an access policy on the connection so the gateway can
subscribe to connector events. Skip this for Recurrence / SlidingWindow.

```powershell
# Get gateway's principalId and tenantId first (from Step 1 of SKILL.md)
$aclBody = @{
  location = "{location}"
  properties = @{
    principal = @{
      type = "ActiveDirectory"
      identity = @{ objectId = "{gw_principal_id}"; tenantId = "{gw_tenant_id}" }
    }
  }
} | ConvertTo-Json -Depth 5 -Compress
$tmp = New-TemporaryFile; Set-Content $tmp $aclBody
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/connections/{conn}/accessPolicies/gateway-acl?api-version=2026-05-01-preview" `
  --body "@$tmp"
Remove-Item $tmp
```

This is independent of the trigger PUT — **run them in parallel**.

## Step 5: Verify

```bash
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/triggerConfigs/{trigger}?api-version=2026-05-01-preview" \
  --query "{state:properties.state, type:properties.type, callback:properties.notificationDetails.callbackUrl}"
# state should be: Enabled
```

For connector-event triggers, also wait for the subscription to be created on
the SaaS side. Most providers take seconds; some (notably SharePoint and Forms)
can take 1-2 minutes.

## Manage lifecycle

```bash
# Disable
az rest --method POST \
  --url ".../connectorGateways/{gw}/triggerConfigs/{name}/disable?api-version=2026-05-01-preview"

# Enable
az rest --method POST \
  --url ".../connectorGateways/{gw}/triggerConfigs/{name}/enable?api-version=2026-05-01-preview"

# Delete
az rest --method DELETE \
  --url ".../connectorGateways/{gw}/triggerConfigs/{name}?api-version=2026-05-01-preview"
```

## List recent runs (for debugging)

```bash
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/triggerConfigs/{name}/runs?api-version=2026-05-01-preview" \
  --query "value[].{name:name, status:properties.status, start:properties.startTime, end:properties.endTime, error:properties.error.message}" -o table
```

Each run shows whether the gateway succeeded in POSTing to your `callbackUrl`
and what HTTP status came back.

## Common mistakes

| Mistake | Fix |
|---|---|
| Putting `callbackUrl` at `properties.callbackUrl` | Goes under `properties.notificationDetails.callbackUrl` |
| Putting `parameters` inside `connectionDetails` | Goes at `properties.parameters` (sibling of `connectionDetails`) |
| Using `callbackTarget` | That field does not exist. Use `notificationDetails`. |
| **Body sub-properties emitted as flat dotted-name params** (e.g. `body.filter.labels`) | The runtime won't unwrap them. Build a nested object and emit it as `{ name = "body"; value = @{ filter = @{ labels = ... } } }`. See §2b. |
| **Body wrapper named after the Swagger param** (e.g. `requestBody` for Teams) | Triggers always use the literal string `"body"`. The Swagger body param's own name is irrelevant. (This is opposite to MCP, where the body wrapper preserves the Swagger name.) |
| **`ConvertTo-Json -Depth` too shallow** → nested objects coerced to `"System.Collections.Hashtable"` strings | Use `-Depth 20` (or higher) when serializing trigger configs that contain nested body objects. Verify with a GET after the PUT. |
| Forgetting `gateway-acl` on a connector-event trigger | Subscription fails silently — trigger state may show `Enabled` but never fires. Create the ACL. |
| Inline JSON `--body '...'` in PowerShell | "Unsupported Media Type" — always `@$tmpFile`. See [gotchas.md](gotchas.md). |
| `ManagedServiceIdentity` auth without an audience | `audience` is required (non-empty). Ask the user for it; if they don't provide one, default to `https://management.azure.com/`. |
| `ManagedServiceIdentity` with callback URL as audience | The token will be meaningless (and rejected if the callback validates AAD tokens). Use a real AAD-protected resource URI — when in doubt, default to `https://management.azure.com/`. See [notification-authentication.md](notification-authentication.md). |
| `ManagedServiceIdentity` referencing a UAMI not on the gateway | Attach it to the gateway first (see [notification-authentication.md](notification-authentication.md)). |
