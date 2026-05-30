# Notification (callback) Authentication

Reference for `properties.notificationDetails.authentication` on a trigger config.
Pick one type per trigger. If you omit `authentication` entirely, the namespace just
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

### 4) `ManagedServiceIdentity` — namespace uses its own MI

The namespace uses its managed identity to call the callback. If `audience` is
provided, the namespace acquires an Entra token for that audience and sends it
as `Authorization: Bearer {token}`. If `audience` is omitted, the namespace
still calls using its MI (no AAD-protected token is minted for a specific
resource).

> ⚠️ **ASK THE USER for `audience`. If they don't provide one, default to `https://management.azure.com/`.**
> The audience is the AAD-protected resource the namespace acquires a token for.
> Set it explicitly if the callback is AAD-protected and the user knows the
> resource URI of the AAD app guarding it (e.g., `api://my-app`,
> `https://graph.microsoft.com/`, `https://vault.azure.net/`, or a custom AAD
> app's `Application ID URI`). The callback URL itself is **NOT** a valid
> audience — do not default to it.
>
> **Workflow:**
> 1. Ask the user: "What AAD resource should the namespace acquire a token for? (e.g., the App ID URI of an AAD-registered API you control, `https://graph.microsoft.com/`, etc.) — leave blank to default to `https://management.azure.com/`."
> 2. If the user provides an audience, use it.
> 3. If the user declines, skips, or doesn't know → use `https://management.azure.com/` as the default. This is a real AAD-protected resource (ARM), so the namespace can mint a valid token for it. The callback may not validate the token, but at least nothing is fabricated.
> 4. If the callback isn't AAD-protected (e.g., a generic webhook), tell the user that MSI auth is providing no real security benefit — they may want `QueryString` or no auth instead.

**System-assigned with default audience** (simplest — namespace must have `identity.type = SystemAssigned`, user didn't specify):

```json
"authentication": {
  "type": "ManagedServiceIdentity",
  "audience": "https://management.azure.com/"
}
```

**System-assigned with user-supplied audience** (for AAD-protected callbacks):

```json
"authentication": {
  "type": "ManagedServiceIdentity",
  "audience": "api://my-app"
}
```

**User-assigned** (namespace must have the user-assigned identity attached):

```json
"authentication": {
  "type": "ManagedServiceIdentity",
  "audience": "api://{aad-app-id}",
  "identity": "/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.ManagedIdentity/userAssignedIdentities/{name}"
}
```

> Validation rules (from BPM `AIGatewayApiTests_NotificationAuthValidation_*`):
> - `audience` is required (non-empty) — if the user doesn't provide one, default to `https://management.azure.com/`
> - If `identity` is omitted → namespace must have a SystemAssigned identity
> - If `identity` is set → it must be a valid `/subscriptions/.../userAssignedIdentities/{name}` resource ID AND that identity must already be attached to the namespace

To attach a user-assigned identity to an existing namespace:

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
  --url "https://management.azure.com/subscriptions/{sub}/resourceGroups/{rg}/providers/Microsoft.Web/connectorGateways/{namespace}?api-version=2026-05-01-preview" `
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
3. **Your own API, accepts Entra tokens, namespace is in the same tenant**
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
