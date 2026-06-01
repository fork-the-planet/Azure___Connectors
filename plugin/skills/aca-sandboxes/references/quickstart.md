# Quick Start

```bash
# 1. Login
az login
az account show --query "{subscription:id, tenant:tenantId}" -o table

# 2. List gateways
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways?api-version=2026-05-01-preview" \
  --query "value[].{name:name, location:location}" -o table

# 3. List triggers on a gateway
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}/triggerConfigs?api-version=2026-05-01-preview" \
  --query "value[].{name:name, state:properties.state, connector:properties.connectionDetails.connectorName}" -o table

# 4. Discover operations for a connector (classic locations endpoint)
az rest --method GET \
  --url "https://management.azure.com/subscriptions/{sub}/providers/Microsoft.Web/locations/{location}/managedApis/office365/apiOperations?api-version=2016-06-01"
```

For an end-to-end walkthrough, see [`tutorial-welcome-emailer.md`](tutorial-welcome-emailer.md).
