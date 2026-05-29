# Trigger Flow & Lifecycle

How a connector-gateway trigger actually works end-to-end, and the ARM operations
you use to manage its lifecycle.

## Architecture

### Connector-event trigger

```
┌─────────────────┐   1. Subscribe        ┌──────────────────────┐
│  Connector SaaS │ ◀──────────────────── │   Connector Gateway  │
│  (Office 365,   │                       │   (Microsoft.Web/    │
│   SharePoint,   │   2. Webhook event    │    connectorGateways)│
│   Teams, ...)   │ ────────────────────▶ │                      │
└─────────────────┘                       │                      │
                                          │   3. POST to         │
                                          │      callbackUrl     │
                                          └───────────┬──────────┘
                                                      │
                                                      ▼
                                         ┌────────────────────────┐
                                         │  Your callback URL     │
                                         │  (any HTTPS endpoint:  │
                                         │   Function App,        │
                                         │   App Service, Logic   │
                                         │   App, custom API ...) │
                                         └────────────────────────┘
```

1. When you `PUT` a connector-event trigger config, the gateway uses the
   underlying **connection** to subscribe to the connector (via the operation's
   `x-ms-notification-url`).
2. When the SaaS detects the event, it POSTs a webhook to the gateway.
3. The gateway forwards the payload to your `callbackUrl`, applying any
   configured `authentication`.

### Recurrence / SlidingWindow trigger

```
┌──────────────────────┐   1. Timer fires    ┌────────────────────────┐
│   Connector Gateway  │ ──────────────────▶ │  Your callback URL     │
│   (scheduler)        │                     │  (any HTTPS endpoint)  │
└──────────────────────┘                     └────────────────────────┘
```

No external SaaS, no subscription, no connection needed. Just a timer inside the
gateway that POSTs to your `callbackUrl` per the `recurrence` schedule.

## Required pieces

| Pattern | Connection? | `gateway-acl` ACL? | Notification auth? |
|---|---|---|---|
| Connector event | Yes | Yes (gateway MI → connection) | Recommended |
| Recurrence | No | No | Recommended |
| SlidingWindow | No | No | Recommended |

## Lifecycle

```bash
# Create / update
az rest --method PUT --url ".../triggerConfigs/{name}?api-version=2026-05-01-preview" --body "@$tmp"

# Get
az rest --method GET --url ".../triggerConfigs/{name}?api-version=2026-05-01-preview"

# List
az rest --method GET --url ".../triggerConfigs?api-version=2026-05-01-preview" \
  --query "value[].{name:name, state:properties.state, type:properties.type}" -o table

# Disable (subscription/timer paused; state -> Disabled)
az rest --method POST --url ".../triggerConfigs/{name}/disable?api-version=2026-05-01-preview"

# Enable (state -> Enabled)
az rest --method POST --url ".../triggerConfigs/{name}/enable?api-version=2026-05-01-preview"

# Delete (removes subscription on SaaS side too — for event triggers)
az rest --method DELETE --url ".../triggerConfigs/{name}?api-version=2026-05-01-preview"
```

## Run history

Each invocation produces a `run` resource:

```bash
az rest --method GET --url ".../triggerConfigs/{name}/runs?api-version=2026-05-01-preview" \
  --query "value[].{name:name, status:properties.status, start:properties.startTime, end:properties.endTime, statusCode:properties.outputs.statusCode, error:properties.error.message}" -o table
```

| `status` | Meaning |
|---|---|
| `Succeeded` | Callback returned 2xx |
| `Failed` | Callback returned 4xx/5xx, or the gateway couldn't reach it. See `error.message`. |
| `Skipped` | Trigger fired but a downstream rule (e.g., dedup) suppressed the callback. |
| `Cancelled` | Trigger was disabled while a run was in flight. |

## Updates

To change anything (callback URL, auth, parameters, schedule), re-PUT the full
config. The platform diffs against the existing config and:

- Re-subscribes if `connectionDetails` / `operationName` / `parameters` change
- Updates the schedule if `recurrence` changes
- Updates the callback URL / auth without re-subscribing for everything else
