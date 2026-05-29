# Connector Namespaces

> Connect your AI agents and workloads to the apps you already use.

**🌐 Portal: [connectors.azure.com](https://connectors.azure.com)**

Connector Namespaces is a Microsoft Azure service that lets you bring connectors into your own namespace and use them with AI agents, Logic Apps, and other workloads — with the security, governance, and lifecycle controls your organization expects.

## Status

🚧 This repository is being set up. Content, samples, and documentation will be added shortly.

## Skills for Coding Agents

This repo doubles as a plugin marketplace for GitHub Copilot CLI and Claude Code.
Install the skills once and drive Azure Connectors from natural language inside
your coding agent.

### GitHub Copilot CLI

Quickest install — install directly from this repo:

```bash
/plugin install Azure/Connectors
```

Or install via the marketplace (useful when more plugins are added later):

```bash
/plugin marketplace add Azure/Connectors
/plugin install azure-connectorgateway@Azure-Connectors
```

### Claude Code

```bash
claude plugin add Azure/Connectors
```

### Available skills

| Skill | Description |
|-------|-------------|
| [azure-connectorgateway](Skills/Sandbox/azure-connectorgateway/SKILL.md) | Manage connector gateways, connections, and triggers — wire external services (Office 365, Teams, Forms, SharePoint, OneDrive, GitHub, Azure Blob) to sandbox apps via event-driven triggers or direct API calls using connection runtime URLs. |

See [`Skills/Sandbox/README.md`](Skills/Sandbox/README.md) for more detail.

## Resources

- 🌐 [Portal](https://connectors.azure.com) — the Connector Namespaces home page
- 🛠️ [Azure CLI extension](./cli/) — `az connector-namespace ...` for managing Connector Namespaces from the command line
- 📖 [Documentation](https://learn.microsoft.com/azure/) — coming soon
- 💬 [Discussions](https://github.com/Azure/Connectors/issues) — file an issue to start a conversation
- 🐛 [Report a bug](https://github.com/Azure/Connectors/issues/new?template=bug_report.yml)
- 💡 [Request a feature](https://github.com/Azure/Connectors/issues/new?template=feature_request.yml)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

This project has adopted the [Microsoft Open Source Code of Conduct](https://opensource.microsoft.com/codeofconduct/). For more information see the [Code of Conduct FAQ](https://opensource.microsoft.com/codeofconduct/faq/) or contact [opencode@microsoft.com](mailto:opencode@microsoft.com) with any additional questions or comments.

## Security

To report a security issue, see [SECURITY.md](SECURITY.md). Please **do not** open public issues for security vulnerabilities.

## License

This project is licensed under the [MIT License](LICENSE).

## Trademarks

This project may contain trademarks or logos for projects, products, or services. Authorized use of Microsoft trademarks or logos is subject to and must follow [Microsoft's Trademark & Brand Guidelines](https://www.microsoft.com/legal/intellectualproperty/trademarks/usage/general). Use of Microsoft trademarks or logos in modified versions of this project must not cause confusion or imply Microsoft sponsorship. Any use of third-party trademarks or logos are subject to those third-party's policies.
