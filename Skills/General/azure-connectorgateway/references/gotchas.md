# Gotchas & Troubleshooting

Common issues for the generic connector-gateway skill and their fixes.

| Issue | Solution |
|-------|----------|
| **Trigger not firing** (connector event) | Make sure `gateway-acl` exists on the connection (gateway MI → connection). Without it the subscription silently fails. See [trigger-setup.md](trigger-setup.md) Step 4. |
| **Trigger state is `Enabled` but no runs** | Check `triggerConfigs/{name}/runs` for errors. Most commonly: the gateway couldn't reach `callbackUrl` (4xx/5xx from your endpoint) or authentication mismatch. |
| **Trigger run shows `Unauthorized` from callback** | Your callback URL's auth doesn't match `notificationDetails.authentication`. Re-check the type/audience/secret. See [notification-authentication.md](notification-authentication.md). |
| **`ManagedServiceIdentity` callback with no audience supplied by user** | `audience` is required. **Ask the user**; if they don't provide one, default to `https://management.azure.com/` (real AAD-protected resource). **Never** use the callback URL as the audience. See [notification-authentication.md](notification-authentication.md). |
| **`ManagedServiceIdentity` callback fails with "identity not configured"** | The requested MI isn't attached to the gateway. Either omit `identity` (uses SystemAssigned) or attach the UAMI to the gateway. See [notification-authentication.md](notification-authentication.md). |
| **Connection stuck in `Error` / `Unauthenticated`** | This is the normal pre-consent state. Run [consent.md](consent.md) and have the user complete the browser flow. If still stuck after consent, regenerate the consent link — do NOT retry with different body formats. |
| **Consent redirect shows error** | Body MUST be `{"parameters":[{"objectId":"...","tenantId":"...","redirectUrl":"https://microsoft.com","parameterName":"token"}]}`. Get `objectId`/`tenantId` from the connection's `properties.createdBy`. Always open with `Start-Process`. |
| **`dynamicInvoke` 400: `parameters` not valid** | Use `{"request": {"method":..., "path":...}}` format. The older `{"parameters": {"operationId":...}}` format is not supported. |
| **`dynamicInvoke` 400: `Content-*` headers** | Do NOT include `Content-Type` (or any other `Content-*` header) inside the inner `request.headers`. |
| **`dynamicInvoke` returns `NotFound`** | Wrong path: did you strip `/{connectionId}` from the Swagger path? Or the operation expects path-segment parameters that you put in `queries`. Re-check the Swagger `in:` markers. |
| **`dynamicInvoke` browse calls fail with mangled JSON** | IDs often contain `!`, `'`, spaces. Always use `@$tmpFile` for the body and `[System.Uri]::EscapeDataString()` for URL path segments. |
| **`az rest --body` "Unsupported Media Type"** | Inline JSON strings get mangled by PowerShell quoting. Always use `@$tmpFile`: write the body to a temp file and pass `--body "@$tmpFile"`. |
| **Swagger paths include `/{connectionId}/...`** | Strip the prefix when calling `dynamicInvoke` — the connection context is already set by the endpoint. |
| **`x-ms-dynamic-*` resolution returns empty** | The display value you used for the prior parameter wasn't the actual value. Always pass the **stored value** (from `value-path`), not the display name (from `value-title`). See [dynamic-values.md](dynamic-values.md). |
| **MCP tool calls 403 from MCP client** | The caller's objectId isn't in the MCP server config's access policies. Add an access policy on `mcpServerConfigs/{name}/accessPolicies/{objectId}` — the path segment **must be the caller's objectId** and the body needs BOTH `principal.type="ActiveDirectory"` AND `properties.principalType="User"` (or `"Group"`). MIs/service principals are not supported here. See [mcp-server-config.md](mcp-server-config.md). |
| **MCP tool calls 401** | Underlying connection isn't consented or the consent expired. Re-run [consent.md](consent.md). |
| **`resourceAuth` rejected on `ManagedMcpServer`** | `resourceAuth` is only valid on `HostedMcpServer`. Remove it. |
| **MCP `userParameters[].value` is the display name** | The connector rejects it because it expects the underlying ID/key. Re-resolve via `dynamicInvoke` and store the `value-path` field. |
| **MCP endpoint fails with `missing required property '<body>/<field>'`** | The operation's required body sub-property (e.g., `emailMessage/To`) wasn't declared in `userParameters` or `agentParameters`. Re-PUT with the body as a single `agentParameter` whose `schema.type` is `"object"` and whose `schema.properties` mirrors the Swagger body — see [mcp-server-config.md](mcp-server-config.md) §"Body parameters". |
| **MCP config GET shows `"System.Collections.Hashtable"` inside `agentParameters[].schema.properties`** | `ConvertTo-Json -Depth` was too shallow when serializing the PUT body — nested objects got coerced to strings. Re-PUT with `-Depth 20` (or higher) and verify with GET. |
| **Trigger fails to subscribe / fires with wrong shape — body leaves visible as flat `body.<path>` params in the GET** | The trigger config was PUT with dotted-name parameter entries instead of a single nested `body` object. Re-build `parameters[]` so all body-sourced leaves live under ONE entry named literally `"body"` with a nested object `value`. See [trigger-setup.md](trigger-setup.md) §2b. |
| **Trigger body wrapper named after the Swagger param (e.g. `requestBody`)** | Triggers always use the literal string `"body"` as the wrapper name, regardless of the Swagger body parameter's own name. (MCP is opposite — it uses the Swagger name.) See [trigger-setup.md](trigger-setup.md) §2b. |
| **`callbackTarget` rejected** | That field does not exist in the schema. Use `notificationDetails.callbackUrl`. |
| **PowerShell `ConvertFrom-Json` fails on Swagger** | `az rest ... export=true` returns content that piping breaks. Always `-o json > $env:TEMP\swagger.json` first, then read the file. |
| **Cleanup order** | Delete trigger configs and MCP server configs → delete access policies on connections → delete connections → delete gateway. Trigger configs hold subscriptions, so delete them first to avoid orphan webhooks. |
| **403 from `az rest` against ARM** | Your Azure CLI identity doesn't have RBAC on the resource group / gateway. You need at least `Microsoft.Web/connectorGateways/*` (Contributor or a custom role). |
| **PUT to gateway fails with "region not supported"** | Try another region. Common supported regions: `eastus`, `eastus2`, `westus`, `westus2`, `westus3`, `northeurope`, `westeurope`, `australiaeast`, `southeastasia`, `brazilsouth`. |
| **Provider not registered** | `az provider register --namespace Microsoft.Web` and wait for `Registered` state. |
