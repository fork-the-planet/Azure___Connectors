# Gotchas & Troubleshooting

Common issues and their solutions.

| Issue | Solution |
|-------|----------|
| Trigger not firing | Ensure access policy exists granting gateway MI access to the connection |
| Gateway can't subscribe | Create an access policy granting the gateway MI access to the connection |
| Sandbox must be Running | For InvokePort targets, sandbox must be running; for ShellCommand, sandbox activates on demand |
| Port auth for InvokePort | Add gateway's principalId to the port's entraId objectIds on the sandbox |
| Cleanup order | Delete trigger config → access policies → connection → sandbox → gateway. Always delete triggers first (they hold subscriptions). |
| SandboxGroupNotFound 404 | Data plane propagation after ARM group creation can take **5–20+ minutes**. Use retry with 30-140s waits, up to 12 attempts. **Better: reuse existing sandbox groups** |
| Sandbox state field wrong path | State is at `sbx['state']` (top level), NOT `sbx['properties']['state']` — data plane returns flat JSON |
| Sandbox identity not found | Identity (principalId/tenantId) is on the **sandbox group**, not individual sandboxes. Use `group['identity']['principalId']` |
| `dynamicInvoke` 400: `parameters` not valid | Use `{"request": {"method": ..., "path": ...}}` format, NOT `{"parameters": {"operationId": ...}}` |
| `dynamicInvoke` 400: `Content-*` headers | Do NOT include `Content-Type` or other `Content-*` headers in the request object |
| `dynamicInvoke` returns `NotFound` for POST | Ensure you pass `queries` and `body` in the request object |
| Runtime URL 403: missing sandbox-acl | Create `sandbox-acl` granting sandbox-group MI access to the connection (pair with sandbox-group `gatewayConnections[]` — see [gateway-connections.md](gateway-connections.md)) |
| Runtime URL 401 / `AuthorizationToken required` from sandbox | Sandbox-group `properties.gatewayConnections[]` missing this connection's entry, OR sandbox was created without `gatewayConnections: [{resourceId}]` in its data-plane PUT body. See [gateway-connections.md](gateway-connections.md) |
| Consent redirect shows error | Body MUST use `parameters` array format: `{"parameters":[{"objectId":"...","tenantId":"...","redirectUrl":"https://microsoft.com","parameterName":"token"}]}`. Get objectId/tenantId from connection's `createdBy`. Always use `Start-Process` to open the link |
| Connection stuck in "Error" | User may not have completed browser auth. Re-generate consent link with `Start-Process`. Do NOT retry with different body formats |
| `dynamicInvoke` browse fails (mangled JSON) | Use `@file` pattern for `az rest --body` when IDs contain `!`. Always URL-encode IDs |
| Swagger paths include `/{connectionId}/...` | Strip the prefix — connection context is already set by the endpoint |
| ShellCommand trigger 403 on callback | Gateway MI needs "Dev Compute SandboxGroup Data Owner" role (`c24cf47c-5077-412d-a19c-45202126392c`) on sandbox group |
| Sandbox group `identity.principalId` is null | `aca sandboxgroup create` does not enable MI. Run `aca sandboxgroup identity assign --name {sg} --system-assigned` then re-read with `aca sandboxgroup identity show --name {sg}`. (The older `aca sandboxgroup update --identity SystemAssigned` no longer exists.) |
| `create_trigger()` SDK broken schema | SDK uses wrong body structure (`callbackTarget` which doesn't exist). Use `az rest` with correct schema: `metadata` + `notificationDetails` (callbackUrl/body/auth) + `operationName` + `parameters` at properties root. |
| `exec_command` "no such file" | `exec_command` treats whole string as binary path. Use `aca sandbox exec -c "python /app/handler.py"` (shell-interpreted) instead |
| `az rest --body` "Unsupported Media Type" | Inline JSON strings get mangled by PowerShell. Always use `@$tmpFile` pattern: write body to temp file, pass `--body "@$tmpFile"` |
| `gatewayConnections[]` PATCH clobbered other entries | Always GET-merge-PATCH on the sandbox group — never PUT or unconditionally PATCH `gatewayConnections` with just your entry. Match existing entries case-insensitively by `resourceId.toLower()`. See [gateway-connections.md](gateway-connections.md) Step 4. |
| `aca sandbox create` ignores connection wiring | The aca CLI does not yet expose `--gateway-connection`. Use the data-plane PUT via `az rest` with `gatewayConnections: [{resourceId}]` in the body. See [gateway-connections.md](gateway-connections.md) Step 5. |
| Sandbox data-plane endpoint 404s | The endpoint is **regional** — `https://management.{region}.azuredevcompute.io/...`, NOT `https://management.azuredevcompute.io/...` |
| aca CLI install 404 | GitHub releases URL requires auth. Use `gh release download` (needs `gh auth login`) or ask user for the .tgz path |
