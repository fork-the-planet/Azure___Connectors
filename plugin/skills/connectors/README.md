# Azure Connectors Skills

Skills for [Azure Connector Namespaces](https://connectors.azure.com) — install
once, drive connector namespaces, connections, triggers, and MCP server configs
from natural language in your coding agent.

> The plugin descriptors live under `plugin/` (`plugin/.plugin/plugin.json` and
> `plugin/.claude-plugin/plugin.json`); the marketplace manifest
> (`marketplace.json`) lives at the repo root. Skill sources live in
> sibling folders under `plugin/skills/`.

## Install

### GitHub Copilot CLI

```bash
# Direct install (single command)
/plugin install Azure/Connectors

# Or via marketplace (useful when this repo adds more skills)
/plugin marketplace add Azure/Connectors
/plugin install azure-connectornamespace@Azure-Connectors
```

### Claude Code

```bash
claude plugin add Azure/Connectors
```

## Skills

| Skill | Description |
|-------|-------------|
| [azure-connectornamespace](SKILL.md) | Generic, callback-agnostic — manage connector namespaces, connections, trigger configs that POST to any HTTP(S) callback (Function App, Logic App, App Service, custom webhook), and MCP server configs that expose connector operations as MCP tools. |
| [azure-connectornamespace-aca-sandbox](../aca-sandboxes/SKILL.md) | ACA-sandbox edition — manage connector namespaces, connections, and triggers; wire external services (Office 365, Teams, Forms, SharePoint, OneDrive, GitHub, Azure Blob) to Azure Container Apps sandbox apps via event-driven triggers or direct API calls using connection runtime URLs. |
