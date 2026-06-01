# Prerequisites

## Required

| Requirement | Check | Install |
|-------------|-------|---------|
| Azure CLI 2.55+ | `az --version` | [Install](https://learn.microsoft.com/cli/azure/install-azure-cli) |
| Azure login | `az account show` | `az login` |
| Python 3.8+ *(only if parsing Swagger locally)* | `python --version` | [python.org](https://python.org) |

> **No extensions required.** There are no `az connectornamespace`,
> `az connectorgateway`, or `az aigateway` commands. Everything goes through
> `az rest` against ARM. Do not try to install a connector-namespace-specific
> extension.

## Azure resource providers

Register once per subscription:

```bash
az provider register --namespace Microsoft.Web
# Wait until "registrationState": "Registered"
az provider show --namespace Microsoft.Web --query "registrationState" -o tsv
```

## Resource group

Pick or create one. The namespace, connections, trigger configs, and MCP server
configs all live inside it:

```bash
az group create --name {rg} --location {location}
```

Common locations where connector namespaces are available: `eastus`, `eastus2`,
`westus`, `westus2`, `westus3`, `northeurope`, `westeurope`, `australiaeast`,
`southeastasia`, `brazilsouth`. If a PUT fails with a region error, try a different
location.

## Optional: identity for `ManagedServiceIdentity` callback auth

If you want the trigger namespace to authenticate to your callback URL with a
**user-assigned** managed identity, create it ahead of time and attach it to the
namespace when creating the namespace resource. See
[notification-authentication.md](notification-authentication.md) for the `identity` block shape.
