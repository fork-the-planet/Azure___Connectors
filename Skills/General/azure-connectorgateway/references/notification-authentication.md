# Notification (callback) Authentication

Reference for `properties.notificationDetails.authentication` on a trigger config.
Pick one type per trigger. If you omit `authentication` entirely, the gateway just
POSTs to `callbackUrl` with no extra credentials — fine for callback URLs that
already embed their own auth (e.g., Logic App SAS in the querystring or a Function
App key embedded in the URL).

## Shapes

### 1) `QueryString` — append `?name=value`

Useful for Function App keys, ngrok tokens, etc.

```json
"authentication": {
  "type": "QueryString",
  "name": "code",
  "value": "{function_key}"
}
```

### 2) `Raw` — literal `Authorization` header

You provide the full `<scheme> <parameter>`.

```json
"authentication": {
  "type": "Raw",
  "scheme": "Bearer",
  "parameter": "{static_token}"
}
```

> Use this when you have a long-lived static bearer token. For dynamic tokens,
> prefer `ManagedServiceIdentity` or `ActiveDirectoryOAuth`.

### 3) `Basic` — HTTP Basic auth

```json
"authentication": {
  "type": "Basic",
  "username": "{user}",
  "password": "{pass}"
}
```

### 4) `ManagedServiceIdentity` — gateway uses its own MI

The gateway uses its managed identity to call the callback. If `audience` is
provided, the gateway acquires an Entra token for that audience and sends it
as `Authorization: Bearer {token}`. If `audience` is omitted, the gateway
still calls using its MI (no AAD-protected token is minted for a specific
resource).

> ⚠️ **`audience` is OPTIONAL — ASK THE USER whether to set one. Never fabricate it.**
> Only set `audience` if the callback endpoint is AAD-protected and the user
> knows the resource URI of the AAD app guarding it (e.g.,
> `api://my-app`, `https://management.azure.com/`, `https://graph.microsoft.com/`,
> or the `Application ID URI` of a custom AAD app). The callback URL itself
> is **NOT** a valid audience — do not default to it. If the callback isn't
> AAD-protected (e.g., a generic webhook like Pipedream), omit `audience` and
> proceed with just `type: ManagedServiceIdentity`.
>
> **STOP and ask the user** — offer:
> - Skip the audience (recommended for non-AAD endpoints)
> - Provide the audience of an AAD app they own
> - Set up a new AAD app registration first (then come back with its Application ID URI)

**System-assigned, no audience** (simplest — gateway must have `identity.type = SystemAssigned`):

```json
"authentication": {
  "type": "ManagedServiceIdentity"
}
```

**System-assigned with audience** (for AAD-protected callbacks):

```json
"authentication": {
  "type": "ManagedServiceIdentity",
  "audience": "api://my-app"
}
```

**User-assigned** (gateway must have the user-assigned identity attached):

```json
"authentication": {
  "type": "ManagedServiceIdentity",
  "audience": "api://{aad-app-id}",
  "identity": "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/{name}"
}
```

> Validation rules (from BPM `AIGatewayApiTests_NotificationAuthValidation_*`):
> - `audience` is optional — omit it for non-AAD callbacks
> - If `identity` is omitted → gateway must have a SystemAssigned identity
> - If `identity` is set → it must be a valid `/subscriptions/.../userAssignedIdentities/{name}` resource ID AND that identity must already be attached to the gateway

To attach a user-assigned identity to an existing gateway:

```powershell
$body = @{
  identity = @{
    type = "SystemAssigned,UserAssigned"   # or just "UserAssigned"
    userAssignedIdentities = @{
      "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/{name}" = @{}
    }
  }
} | ConvertTo-Json -Depth 5 -Compress
$tmp = New-TemporaryFile; Set-Content $tmp $body
az rest --method PATCH `
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{gw}?api-version=2026-05-01-preview" `
  --body "@$tmp"
Remove-Item $tmp
```

### 5) `ActiveDirectoryOAuth` — Entra app (client credentials)

```json
"authentication": {
  "type": "ActiveDirectoryOAuth",
  "tenant": "{tenant-id}",
  "audience": "api://{aad-app-id}",
  "clientId": "{client-id}",
  "secret": "{client-secret}"
}
```

> Store the secret in Key Vault and reference it via Key Vault links if your
> deployment pipeline supports it. Plain-text secrets in trigger configs are
> persisted as-is.

### 6) `ClientCertificate` — mutual TLS

```json
"authentication": {
  "type": "ClientCertificate",
  "pfx": "{base64-pfx}",
  "password": "{pfx-password}"
}
```

`pfx` is the base64-encoded PKCS#12 file.

## Picking an auth type — decision tree

1. **Callback URL already contains a secret/token** (e.g. Logic App SAS, Function App `?code=`)
   → omit `authentication`. The URL is self-authenticating.
2. **Function App with a key** but you want to keep the key out of the URL
   → `QueryString` with `name: "code"`.
3. **Your own API, accepts Entra tokens, gateway is in the same tenant**
   → `ManagedServiceIdentity` (system-assigned is simplest).
4. **Your own API, accepts Entra tokens, you want fine-grained control / different tenant**
   → `ActiveDirectoryOAuth` with a dedicated app registration.
5. **Legacy API with HTTP Basic**
   → `Basic`.
6. **mTLS endpoint**
   → `ClientCertificate`.
7. **Static long-lived bearer token**
   → `Raw` (last resort — rotates are manual).

## Where this fits

In the trigger config PUT body:

```json
{
  "properties": {
    "type": "Recurrence",
    "recurrence": { "frequency": "Minute", "interval": 5 },
    "notificationDetails": {
      "callbackUrl": "https://my-api.contoso.com/hook",
      "httpMethod": "Post",
      "authentication": { "type": "ManagedServiceIdentity", "audience": "api://my-api" }
    }
  }
}
```

See [trigger-setup.md](trigger-setup.md) for the full PUT body templates per trigger source.
