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
[direct-api.md](direct-api.md) §1) to find the operation's parameter list. For each
parameter:

- **Has `x-ms-dynamic-*`** → resolve via [dynamic-values.md](dynamic-values.md) and **STOP** for user selection
- **Static enum** → present choices and **STOP**
- **Free-form with obvious default** (e.g., `folderPath=Inbox`) → use default, inform user
- **Free-form, no default** → ask the user

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
        # audience is OPTIONAL — only set if callback is AAD-protected.
        # ALWAYS ask the user; never default to the callback URL.
        # audience = "api://my-api"
      }
    }
    state = "Enabled"
  }
} | ConvertTo-Json -Depth 8 -Compress

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
| Forgetting `gateway-acl` on a connector-event trigger | Subscription fails silently — trigger state may show `Enabled` but never fires. Create the ACL. |
| Inline JSON `--body '...'` in PowerShell | "Unsupported Media Type" — always `@$tmpFile`. See [gotchas.md](gotchas.md). |
| `ManagedServiceIdentity` with a fabricated audience | Token is minted for a meaningless audience; if the callback validates AAD tokens it returns `401 invalid audience`, otherwise MSI auth is providing no value. `audience` is **optional** — **always ask the user** whether to set one and what value to use; never default to the callback URL. See [notification-authentication.md](notification-authentication.md). |
| `ManagedServiceIdentity` referencing a UAMI not on the gateway | Attach it to the gateway first (see [notification-authentication.md](notification-authentication.md)). |
