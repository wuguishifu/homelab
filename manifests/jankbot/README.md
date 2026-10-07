# jankbot

Discord bot from the [universe](https://github.com/wuguishifu/universe) monorepo (`projects/jankbot`)
that tracks how often people say chosen phrases in voice channels. It replaces ruby, the old
single-process bot. Voice clips are transcribed by transcription-worker on the Mac mini
([hosts/mini](../../hosts/mini)) through a BullMQ queue in the shared Redis, and counts
are stored in Convex (`convex-app`).

A Discord bot can only be in one voice channel per server, so jankbot runs several bots:

| Deployment               | Role      | What it does                                                                          |
| ------------------------ | --------- | ------------------------------------------------------------------------------------- |
| `jankbot-core`           | —         | Transcription, phrase matching, Convex, every slash command. Talks to Discord by HTTP |
| `jankbot-gateway-bo`     | `primary` | Voice bot "Bo". Its bot owns the slash commands, so it forwards every command to core |
| `jankbot-gateway-mikey`  | `worker`  | Voice bot "Mikey": joins and leaves when core tells it to                             |
| `jankbot-gateway-steven` | `worker`  | Voice bot "Steven"                                                                    |
| `jankbot-gateway-jenn`   | `worker`  | Voice bot "Jenn"                                                                      |

They talk only through Redis (BullMQ queues and a few keys), so core can be redeployed without
anyone leaving voice. A gateway redeploy drops its bot from voice for a few seconds; it rejoins on
start. Every gateway is one replica with `Recreate` rollouts, since two pods for the same bot token
would fight over its voice connections.

Nothing here has inbound traffic. The HTTP servers (core on 3003, gateways on 3004) only serve
the kubelet's health probes, so there's no Service, Ingress, or tunnel route. To reach them
anyway, see [Hitting a pod's HTTP endpoints](#hitting-a-pods-http-endpoints).

## Adding or removing a voice bot

1. Create a Discord application and bot, and invite it to the server with View Channel and
   Connect permissions. It doesn't need the `applications.commands` scope; only Bo's does.
2. Add its `DISCORD_TOKEN` to Infisical at `/projects/jankbot/gateway/bot-<name>`.
3. Copy a worker's `gateway-<name>.yaml`, change the name, `NAME` and secret, and list it in
   `kustomization.yaml`.
4. Add a matching `InfisicalSecret` to `../infisical-secrets/jankbot.yaml`.
5. Add the name to `VOICE_BOTS` in `core.yaml`.

## Secrets

All under the `universe` Infisical project, `prod` environment.

`/projects/jankbot/core` (→ `jankbot-core-secrets`):

| Key                               | Description                                                                      |
| --------------------------------- | -------------------------------------------------------------------------------- |
| `DISCORD_TOKEN`                   | **Bo's** bot token (the primary bot, which owns the slash commands)              |
| `REDIS_URL`                       | `redis://:<password>@redis-master.databases.svc.cluster.local:6379`              |
| `CONVEX_URL`                      | `convex-app`'s **prod** deployment URL                                           |
| `RUBY_CONVEX_SECRET`              | Random string (`openssl rand -hex 32`); must match the `convex-app` prod env var |

`/projects/jankbot/gateway` (→ `jankbot-gateway-secrets`, shared by every gateway):

| Key                           | Description                                                |
| ----------------------------- | ---------------------------------------------------------- |
| `REDIS_URL`                   | The same Redis URL as core's                               |
| `ANALYTICS_SERVICE_API_TOKEN` | Same value as `API_TOKEN` in `/platform/analytics/service` |

`/projects/jankbot/gateway/bot-<name>` for `bo`, `mikey`, `steven` and `jenn`
(→ `jankbot-gateway-<name>-secrets`):

| Key             | Description                                            |
| --------------- | ------------------------------------------------------ |
| `DISCORD_TOKEN` | That bot's token. `bot-bo` is the same token as core's |

`ROLE` and `NAME` are set on each Deployment, and the rest of the non-secret settings are in the
ConfigMaps (`jankbot-core-env`, `jankbot-gateway-env`), which win over Infisical.

## Before the first deploy

- [ ] `convex-app` (universe `platform/convex/app`) is deployed to prod, with `RUBY_CONVEX_SECRET`
      set: `pnpm nx convex convex-app -- env set RUBY_CONVEX_SECRET <value> --prod`.
- [ ] Both images have been built (**Deploy Server App** workflow, apps `jankbot/core` and
      `jankbot/gateway`).
- [ ] Prod secrets above exist in Infisical.
- [ ] All four bots are invited to the server.
- [ ] Nothing else is running with any of these bot tokens (e.g. a local `nx serve`).

Slash commands register globally in production, so they can take up to an hour to appear.

## Checking it

```sh
sudo kubectl -n jankbot get pods                              # expect 5 pods, all 1/1 Ready
sudo kubectl -n jankbot logs deploy/jankbot-core              # expect "Registered 4 global commands"
sudo kubectl -n jankbot logs deploy/jankbot-gateway-mikey     # expect "Logged in as ..."
```

### Hitting a pod's HTTP endpoints

With no Service, the only way in is `kubectl port-forward`, which tunnels through the k3s API. It
works from your own machine over Tailscale (no `sudo` or SSH needed):

```sh
kubectl -n jankbot port-forward deploy/jankbot-core 3003:3003
```

Then, in another terminal:

```sh
curl localhost:3003/api/version   # {"version":"0.2.6","versionTag":"jankbot-core-v0.2.6",...}
curl localhost:3003/api/health
```

For a gateway, forward port 3004 from its Deployment instead, e.g.
`kubectl -n jankbot port-forward deploy/jankbot-gateway-bo 3004:3004`. To forward more than one
at a time, give each its own local port (`13004:3004`, `23004:3004`, ...). Stop the forward with
Ctrl-C.
