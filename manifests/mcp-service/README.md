# mcp-service

mcp-service (universe `platform/mcp/service`) is the MCP server for claude.ai and Claude Code:
tools for the universe apps (thermo-automation's thermostats and automations so far), at
`https://mcp.wuguishifu.dev/mcp`. It calls the apps in-cluster through their Services.

It's the only app here that's public with its own login rather than Authelia's forward-auth or
Cloudflare Access: claude.ai calls MCP servers from Anthropic's servers, which can't reach the
tailnet or present an Access token. So it's a Cloudflare Tunnel route straight to the Service, and
`/mcp` needs an OAuth access token that mcp-service issues itself:

```plaintext
claude.ai ─► /oauth/register   (dynamic client registration; redirect URIs are allowlisted)
your browser ─► /oauth/authorize ─► auth.wuguishifu.dev (tailnet: passkey + password, admins only)
             ◄─ /oauth/callback  ◄─┘   mcp-service swaps Authelia's code for the user in-cluster
claude.ai ─► /oauth/token ─► access token (1 hour) + refresh token (30 days, renewed on use)
claude.ai ─► /mcp with the access token
```

Authelia never has to be public: only your browser visits it, so connecting a client needs a
device on the tailnet. After that the refresh token keeps the connection working from anywhere
(including the phone app) until it goes unused for 30 days. Codes, tokens and registered clients
live in the shared Redis under `mcp-service:*` (tokens as hashes), so the pod is stateless.

Image Updater pins the `mcp-service` image's digest, so publishing a new image (merging to
universe `main`, or **Deploy Server App** → `platform/mcp/service`) rolls it out.

## Secrets

Infisical `universe` project, `prod` environment. The app reads the same paths as its
`secretsPaths` in universe (`environment-config.json`), each synced to its own Secret and loaded in
this order, so a key in a later path wins:

| Path                    | Secret                | Keys                     |
| ----------------------- | --------------------- | ------------------------ |
| `/platform/redis`       | `mcp-service-redis`   | `REDIS_URL`              |
| `/platform/mcp/service` | `mcp-service-secrets` | `AUTHELIA_CLIENT_SECRET` |

`AUTHELIA_CLIENT_SECRET` is the `Random Password` whose digest is `MCP_CLIENT_SECRET_DIGEST` in the
homelab project's `/authelia` (see `manifests/authelia/README.md`). Put it in `dev` too, for running
mcp-service locally. The ConfigMap in `deployment.yaml` sets `PUBLIC_URL`, `AUTHELIA_URL` and the
URLs of the apps it has tools for.

## Before the first deploy

- [ ] Authelia's `mcp` client has a secret: run
      `authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986`,
      put the `Digest` in the homelab project's `/authelia` as `MCP_CLIENT_SECRET_DIGEST` (before
      pushing the `configuration.yml` change, or Authelia won't start) and the `Random Password` in
      universe `/platform/mcp/service` as `AUTHELIA_CLIENT_SECRET`.
- [ ] The image has been built (universe merged to `main`, or **Deploy Server App** →
      `platform/mcp/service`). Until then the pod is in `ImagePullBackOff`.
- [ ] A public hostname on the tunnel (Cloudflare dashboard → Zero Trust → Networks → Tunnels →
      the tunnel → Public Hostname): `mcp.wuguishifu.dev`, service `HTTP`,
      `mcp-service.mcp-service.svc.cluster.local:80`. Its proxied CNAME overrides the tailnet
      wildcard, so the name resolves to Cloudflare from everywhere, the tailnet included.

### Optional hardening

A WAF custom rule can block the paths servers call (`/mcp`, `/oauth/token`, `/oauth/register`,
`/.well-known/`) from anywhere but Anthropic's published outbound IP ranges, plus your own IP if you
use Claude Code. Leave `/oauth/authorize` and `/oauth/callback` open: your browser visits those.

## Connecting

- **claude.ai**: Settings → Connectors → Add custom connector, URL `https://mcp.wuguishifu.dev/mcp`.
  Connect from a device on the tailnet: it opens Authelia to sign in.
- **Claude Code**: `claude mcp add --transport http universe https://mcp.wuguishifu.dev/mcp`, then
  `/mcp` in a session to sign in.

## Revoking

Everything is in the Redis database `REDIS_URL` points at, so deleting keys revokes access, e.g. in
RedisInsight (filter by key pattern, then bulk delete):

- `mcp-service:*`: every client and token. Reconnecting signs in again.
- `mcp-service:grants:*`: every connection (one grant per sign-in). Its access and refresh tokens
  stop working at once.
- `mcp-service:clients:<client id>`: one client (the id is in the logs below). Its refresh token
  stops working, and the client has to be connected again; its current access token lasts up to an
  hour.

mcp-service also revokes a grant by itself when a spent refresh token or code is used again, since
that means it was stolen (`… was used again, so its grant … was revoked` in the logs).

## Checking it

```sh
kubectl -n mcp-service logs -f deploy/mcp-service   # "<client id> called thermo_get_status"
curl -s https://mcp.wuguishifu.dev/.well-known/oauth-protected-resource/mcp
curl -si -X POST https://mcp.wuguishifu.dev/mcp   # 401 with a WWW-Authenticate challenge
```
