# Quick Start

```bash
# 1. Login
az login
az account show --query "{subscription:id, tenant:tenantId}" -o table

# 2. List connector namespaces in a resource group
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways?api-version=2026-05-01-preview" \
  --query "value[].{name:name, location:location, identityType:identity.type, principalId:identity.principalId}" -o table

# 3. List connections on a namespace
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{namespace}/connections?api-version=2026-05-01-preview" \
  --query "value[].{name:name, connector:properties.connectorName, status:properties.statuses[0].status}" -o table

# 4. List trigger configs on a namespace
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{namespace}/triggerConfigs?api-version=2026-05-01-preview" \
  --query "value[].{name:name, state:properties.state, type:properties.type, connector:properties.connectionDetails.connectorName, op:properties.operationName, callbackUrl:properties.notificationDetails.callbackUrl}" -o table

# 5. List MCP server configs on a namespace
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{namespace}/mcpServerConfigs?api-version=2026-05-01-preview" \
  --query "value[].{name:name, kind:kind, endpoint:properties.mcpEndpointUrl}" -o table

# 6. Discover operations for a connector
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/providers/Microsoft.Web/locations/{location}/managedApis/office365/apiOperations?api-version=2016-06-01" \
  --query "value[].{name:name, summary:properties.summary, trigger:properties.trigger}" -o table
```
