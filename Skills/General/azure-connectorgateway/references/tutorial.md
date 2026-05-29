# Tutorial: Two end-to-end walkthroughs

Two minimal real-world scenarios you can run to verify a gateway, a connection,
and a trigger config all work together.

- **Tutorial A** (no connection) — recurrence trigger pinging your webhook
  every 5 minutes
- **Tutorial B** (connector-event) — email me whenever a new file appears in a
  SharePoint folder

Set these variables once at the top of your terminal session:

```powershell
$sub      = "<your subscription id>"
$rg       = "tutorial-cg-rg"
$location = "eastus"
$gw       = "tutorial-gw"
$preview  = "2026-05-01-preview"
```

---

## One-time setup (both tutorials)

### 1. Resource group + provider

```bash
az group create --name $rg --location $location
az provider register --namespace Microsoft.Web
```

### 2. Connector gateway with system-assigned MI

```powershell
$gwBody = @{
  location = $location
  identity = @{ type = "SystemAssigned" }
  properties = @{}
} | ConvertTo-Json -Depth 4 -Compress

$tmp = New-TemporaryFile; Set-Content $tmp $gwBody
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/connectorGateways/$gw?api-version=$preview" `
  --body "@$tmp"
Remove-Item $tmp

# Wait for provisioningState = Succeeded
az rest --method GET `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/connectorGateways/$gw?api-version=$preview" `
  --query "{state:properties.provisioningState, mi:identity.principalId}"
```

Save the `mi` value as `$gwMi`. Also capture `$gwTenant = (az account show --query tenantId -o tsv)`.

---

## Tutorial A — Recurrence trigger to your webhook

**Goal:** every 5 minutes, the gateway POSTs to `https://your-webhook.example.com/ping`.

### A.1 Create the trigger config

```powershell
$callback = "https://your-webhook.example.com/ping"  # replace with your real URL

$triggerBody = @{
  properties = @{
    description = "Tutorial recurrence trigger"
    type = "Recurrence"
    recurrence = @{ frequency = "Minute"; interval = 5 }
    notificationDetails = @{
      callbackUrl = $callback
      httpMethod  = "Post"
    }
    state = "Enabled"
  }
} | ConvertTo-Json -Depth 6 -Compress

$tmp = New-TemporaryFile; Set-Content $tmp $triggerBody
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/connectorGateways/$gw/triggerConfigs/tut-recur?api-version=$preview" `
  --body "@$tmp"
Remove-Item $tmp
```

### A.2 Verify

```bash
az rest --method GET \
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/connectorGateways/$gw/triggerConfigs/tut-recur?api-version=$preview" \
  --query "{state:properties.state, callback:properties.notificationDetails.callbackUrl}"
```

Within 5 minutes, check `triggerConfigs/tut-recur/runs`:

```bash
az rest --method GET \
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/connectorGateways/$gw/triggerConfigs/tut-recur/runs?api-version=$preview" \
  --query "value[].{status:properties.status, start:properties.startTime, end:properties.endTime}" -o table
```

You should see `Succeeded` runs as long as your webhook returns 2xx.

### A.3 Add MSI auth on the callback (optional)

If your webhook is an Azure resource that accepts AAD tokens:

```powershell
$triggerBody = @{
  properties = @{
    description = "Tutorial recurrence trigger (MSI)"
    type = "Recurrence"
    recurrence = @{ frequency = "Minute"; interval = 5 }
    notificationDetails = @{
      callbackUrl = $callback
      httpMethod  = "Post"
      authentication = @{
        type = "ManagedServiceIdentity"
        audience = "api://your-aad-app"
      }
    }
    state = "Enabled"
  }
} | ConvertTo-Json -Depth 8 -Compress
# Re-PUT with the same URL
```

The gateway will mint a token with its system-assigned MI for `audience` and
attach it as `Authorization: Bearer ...`.

### A.4 Cleanup (Tutorial A only)

```bash
az rest --method DELETE \
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/connectorGateways/$gw/triggerConfigs/tut-recur?api-version=$preview"
```

---

## Tutorial B — Connector event trigger from SharePoint

**Goal:** when a new file appears in `Shared Documents` of a SharePoint site, the
gateway POSTs the file metadata to your webhook.

### B.1 Create a SharePoint connection

```powershell
$connBody = @{
  location = $location
  properties = @{ connectorName = "sharepointonline" }
} | ConvertTo-Json -Compress

$tmp = New-TemporaryFile; Set-Content $tmp $connBody
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/connectorGateways/$gw/connections/sp-conn?api-version=$preview" `
  --body "@$tmp"
Remove-Item $tmp
```

### B.2 Complete consent

Follow [consent.md](consent.md): fetch `properties.createdBy.{objectId,tenantId}`,
PUT a body with `parameters[]` containing `{objectId, tenantId, redirectUrl, parameterName:"token"}`,
then open the returned link in a browser and sign in.

Confirm `Connected`:

```bash
az rest --method GET \
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/connectorGateways/$gw/connections/sp-conn?api-version=$preview" \
  --query "properties.statuses[0].status"
```

### B.3 Grant the gateway MI access to the connection

```powershell
$aclBody = @{
  location = $location
  properties = @{
    principal = @{
      type = "ActiveDirectory"
      identity = @{ objectId = $gwMi; tenantId = $gwTenant }
    }
  }
} | ConvertTo-Json -Depth 5 -Compress

$tmp = New-TemporaryFile; Set-Content $tmp $aclBody
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/connectorGateways/$gw/connections/sp-conn/accessPolicies/gateway-acl?api-version=$preview" `
  --body "@$tmp"
Remove-Item $tmp
```

### B.4 Resolve `dataset` and `folder_id` via dynamic values

Per [dynamic-values.md](dynamic-values.md). The SharePoint operation
`OnNewFile` needs:

- `dataset` (site URL) — comes from `GetDataSets`
- `folder_id` (library + path) — comes from `GetAllTables` once `dataset` is set

Use `dynamicInvoke` to list each, **STOP** for the user to pick, and pass the
chosen `value-path` field forward.

Suppose the user picks:

- `dataset = "https://contoso.sharepoint.com/sites/team"`
- `folder_id = "%252fShared%2520Documents"` (URL-encoded)

### B.5 PUT the trigger config

```powershell
$callback = "https://your-webhook.example.com/sp-newfile"

$triggerBody = @{
  properties = @{
    description = "New file in Shared Documents"
    connectionDetails = @{ connectorName = "sharepointonline"; connectionName = "sp-conn" }
    operationName = "OnNewFile"
    parameters = @(
      @{ name = "dataset";   value = "https://contoso.sharepoint.com/sites/team" }
      @{ name = "folder_id"; value = "%252fShared%2520Documents" }
    )
    notificationDetails = @{
      callbackUrl = $callback
      httpMethod  = "Post"
      authentication = @{
        type = "QueryString"
        name = "code"
        value = "<webhook-secret>"
      }
    }
    state = "Enabled"
  }
} | ConvertTo-Json -Depth 8 -Compress

$tmp = New-TemporaryFile; Set-Content $tmp $triggerBody
az rest --method PUT `
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/connectorGateways/$gw/triggerConfigs/tut-spnewfile?api-version=$preview" `
  --body "@$tmp"
Remove-Item $tmp
```

### B.6 Verify

```bash
# Trigger config state
az rest --method GET --url ".../triggerConfigs/tut-spnewfile?api-version=$preview" \
  --query "{state:properties.state}"

# Upload a file to the SharePoint folder, then within ~30s:
az rest --method GET --url ".../triggerConfigs/tut-spnewfile/runs?api-version=$preview" \
  --query "value[0:5].{status:properties.status, start:properties.startTime, statusCode:properties.outputs.statusCode}" -o table
```

### B.7 Cleanup (Tutorial B)

```bash
az rest --method DELETE --url ".../triggerConfigs/tut-spnewfile?api-version=$preview"
az rest --method DELETE --url ".../connections/sp-conn/accessPolicies/gateway-acl?api-version=$preview"
az rest --method DELETE --url ".../connections/sp-conn?api-version=$preview"
```

---

## Final cleanup

```bash
az rest --method DELETE \
  --url "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/connectorGateways/$gw?api-version=$preview"

az group delete --name $rg --yes --no-wait
```
