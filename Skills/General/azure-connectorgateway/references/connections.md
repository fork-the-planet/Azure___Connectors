# Connections

A **connection** is a stored credential for one connector (e.g., one Office 365
mailbox, one Teams tenant, one GitHub user) attached to one gateway. Triggers,
MCP server configs, and direct-API calls all reference connections by name.

This doc covers connection CRUD; for the **consent flow** that turns a freshly
created `Unauthenticated` / `Error` connection into a working `Connected` one,
see [consent.md](consent.md).

## Discover available connectors

```bash
# All connectors in a region
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/providers/Microsoft.Web/locations/{location}/managedApis?api-version=2016-06-01" \
  --query "value[].{name:name, displayName:properties.displayName}" -o table
```

Use the `name` value (lowercase, e.g., `office365`, `sharepointonline`, `teams`,
`outlook`, `github`, `salesforce`, ...) as the `connectorName` everywhere.

## Create a connection

PUT to `.../connectorGateways/{gw}/connections/{connection_name}?api-version=2026-05-01-preview`.

```powershell
$connBody = @{
  location = "{location}"                    # must match the gateway's location
  properties = @{ connectorName = "{connector}" }   # e.g. "office365"
} | ConvertTo-Json -Compress

$tmp = New-TemporaryFile; Set-Content $tmp $connBody
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/connections/{conn_name}?api-version=2026-05-01-preview" `
  --body "@$tmp"
Remove-Item $tmp
```

The PUT returns immediately with `properties.statuses[].status = "Error"` or
`"Unauthenticated"` — this is the **pre-consent** state. The connection isn't
broken; it just needs the user to complete OAuth. Run [consent.md](consent.md).

## Verify a connection is connected

```bash
az rest --method GET \
  --url ".../connectorGateways/{gw}/connections/{conn}?api-version=2026-05-01-preview" \
  --query "{name:name, status:properties.statuses[0].status, createdBy:properties.createdBy.objectId}"
```

A connection is ready when `status` is `Connected`.

## List connections

```bash
az rest --method GET \
  --url ".../connectorGateways/{gw}/connections?api-version=2026-05-01-preview" \
  --query "value[].{name:name, connector:properties.connectorName, status:properties.statuses[0].status}" -o table
```

## Delete a connection

```bash
# Delete access policies first (PUT-overwriting any leftover ones is fine too)
az rest --method DELETE --url ".../connections/{conn}/accessPolicies/{policy}?api-version=2026-05-01-preview"

# Then the connection
az rest --method DELETE --url ".../connections/{conn}?api-version=2026-05-01-preview"
```

> Deleting a connection that is still referenced by a trigger config or MCP
> server config will fail. Delete those first.

## Access policies — who can use the connection

A connection's access policies control which Azure AD principals can **use** it
(invoke operations via `dynamicInvoke`, subscribe to events for triggers, drive
MCP tool calls, etc.).

The gateway's own MI needs an `gateway-acl` policy on every connection it must
subscribe to for connector-event triggers, or invoke for MCP tool calls.

### Get the gateway's MI

```bash
az rest --method GET \
  --url ".../connectorGateways/{gw}?api-version=2026-05-01-preview" \
  --query "{principalId:identity.principalId, tenantId:identity.tenantId}"
```

> If `identity` is null, enable a system-assigned MI on the gateway:
> ```bash
> az rest --method PATCH \
>   --url ".../connectorGateways/{gw}?api-version=2026-05-01-preview" \
>   --body '{\"identity\":{\"type\":\"SystemAssigned\"}}'
> ```

### Create the gateway ACL

```powershell
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
  --url ".../connections/{conn}/accessPolicies/gateway-acl?api-version=2026-05-01-preview" `
  --body "@$tmp"
Remove-Item $tmp
```

### Grant other principals (users / apps / external MIs)

Same call, different `objectId` and a different policy name:

```powershell
# e.g., a user
$aclBody = @{
  location = "{location}"
  properties = @{
    principal = @{
      type = "ActiveDirectory"
      identity = @{ objectId = "{user_object_id}"; tenantId = "{tenant_id}" }
    }
  }
} | ConvertTo-Json -Depth 5 -Compress
# PUT to .../accessPolicies/{policy_name}
```

Policy names are arbitrary but should be descriptive (`gateway-acl`,
`developer-jane`, `agent-prod-mi`, ...).

### List policies

```bash
az rest --method GET \
  --url ".../connections/{conn}/accessPolicies?api-version=2026-05-01-preview" \
  --query "value[].{name:name, type:properties.principal.type, objectId:properties.principal.identity.objectId}" -o table
```

## Common connector names

| Connector | `connectorName` |
|---|---|
| Office 365 (Outlook) | `office365` |
| Outlook.com | `outlook` |
| SharePoint Online | `sharepointonline` |
| Microsoft Teams | `teams` |
| OneDrive for Business | `onedriveforbusiness` |
| OneDrive (consumer) | `onedrive` |
| Microsoft Forms | `microsoftforms` |
| Excel Online (Business) | `excelonlinebusiness` |
| Planner | `planner` |
| GitHub | `github` |
| Salesforce | `salesforce` |
| ServiceNow | `service-now` |
| Dropbox | `dropbox` |
| Slack | `slack` |

For anything not in this list, run the discovery command at the top of this doc.
