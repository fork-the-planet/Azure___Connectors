# Azure Connectors Skills

Skills for [Azure Connector Namespaces](https://connectors.azure.com) — install
once, drive connector gateways, connections, and triggers from natural language
in your coding agent.

> The plugin descriptors live at the repo root (`.plugin/plugin.json`,
> `.claude-plugin/plugin.json`, and `marketplace.json`). Skill source lives in
> this folder.

## Install

### GitHub Copilot CLI

```bash
# Direct install (single command)
/plugin install Azure/Connectors

# Or via marketplace (useful when this repo adds more skills)
/plugin marketplace add Azure/Connectors
/plugin install azure-connectorgateway@Azure-Connectors
```

### Claude Code

```bash
claude plugin add Azure/Connectors
```

## Skills

| Skill | Description |
|-------|-------------|
| [azure-connectorgateway](azure-connectorgateway/SKILL.md) | Manage connector gateways, connections, and triggers — wire external services (Office 365, Teams, Forms, SharePoint, OneDrive, GitHub, Azure Blob) to sandbox apps via event-driven triggers or direct API calls using connection runtime URLs. |

