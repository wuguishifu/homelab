# Ruby

Discord bot from the [universe](https://github.com/wuguishifu/universe) monorepo (`apps/ruby`)
that tracks how often people say chosen phrases in voice channels. It records voice clips,
sends them to [tungsten](../tungsten) for transcription, and stores counts in Convex (hydrogen).
It also streams recent transcripts to sapphire's `/ruby` page over a WebSocket.

One replica, `Recreate` rollouts. See the comments in `deployment.yaml` for why.

## Live feed (public via Cloudflare Tunnel)

`ruby.wuguishifu.dev` goes through the Cloudflare Tunnel straight to the `ruby` Service
(`service.yaml`), bypassing Traefik. It has **no Cloudflare Access app**: the browser connects to `/api/feed` directly and can't send a service token. Instead the socket
requires a short-lived ticket signed by sapphire with `RUBY_FEED_SECRET`, and only shows servers
the signed-in Discord user is a member of. `/api/health` and `/api/version` are public too.

The route is configured in the Cloudflare dashboard (the tunnel is token-managed): Zero Trust →
Networks → Tunnels → the tunnel → Public Hostname: `ruby.wuguishifu.dev` →
`HTTP` `ruby.ruby.svc.cluster.local:80`.

## Secrets

Add these to Infisical under the `universe` project, `prod` environment, path `/ruby`:

| Key                  | Description                                                                                |
| -------------------- | ------------------------------------------------------------------------------------------ |
| `DISCORD_TOKEN`      | Bot token from the Discord developer portal                                                |
| `REDIS_URL`          | `redis://:<password>@redis-master.databases.svc.cluster.local:6379` (its job queue)        |
| `CONVEX_URL`         | hydrogen's **prod** deployment URL                                                         |
| `RUBY_CONVEX_SECRET` | Random string (`openssl rand -hex 32`); must match the hydrogen prod env var               |
| `TUNGSTEN_API_TOKEN` | Same value as `TUNGSTEN_API_TOKEN` in `/tungsten`                                          |
| `RUBY_FEED_SECRET`   | Random string (`openssl rand -hex 32`); must match sapphire's. Ruby won't start without it |

`TUNGSTEN_URL` and `DISCORD_DEV_GUILD_IDS` are set in `configmap.yaml`, which wins over Infisical.

## Before the first deploy

- [ ] universe `feat-ruby` is merged, and hydrogen is deployed to prod (it has ruby's tables and
      functions).
- [ ] `RUBY_CONVEX_SECRET` is set on hydrogen's prod deployment:
      `pnpm nx convex hydrogen -- env set RUBY_CONVEX_SECRET <value> --prod`.
- [ ] The ruby image has been built (**Deploy Server App** workflow, app `ruby`).
- [ ] Prod secrets above exist in Infisical.
- [ ] Nothing else is running with the same bot token (e.g. a local `nx serve ruby`).

Slash commands register globally in production, so they can take up to an hour to appear.

## Checking it

```sh
sudo kubectl -n ruby logs deploy/ruby          # expect "Logged in as ..."
curl https://ruby.wuguishifu.dev/api/health    # expect {"status":200}
npx wscat -c wss://ruby.wuguishifu.dev/api/feed  # expect close code 4401 (no ticket)
```
