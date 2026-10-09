# Homelab — Agent Guide

This repo is a GitOps homelab running on a single server, `sol`. ArgoCD runs on it and watches this repo to reconcile the cluster.

## Stack

| Component                  | Role                                                          |
| -------------------------- | ------------------------------------------------------------- |
| k3s                        | Lightweight single-node Kubernetes                            |
| Traefik                    | Ingress controller (bundled with k3s)                         |
| cert-manager               | Automatic TLS via Let's Encrypt (Cloudflare DNS-01 challenge) |
| ArgoCD                     | GitOps — watches this repo, syncs everything                  |
| Infisical                  | Self-hosted secrets manager                                   |
| Infisical secrets-operator | Syncs secrets from Infisical → Kubernetes `Secret` objects    |

The server is reachable over Tailscale only — no inbound ports are open. DNS for `wuguishifu.dev` is managed by Cloudflare with a wildcard A record pointing to the server's Tailscale IP (DNS only, not proxied). Nothing is currently public. A `cloudflared` Deployment in the cluster runs a Cloudflare Tunnel (an outbound connection to Cloudflare's edge) for exposing an app publicly: a tunnel public hostname gets a proxied CNAME that overrides the wildcard, and routes straight to the app's Service (bypassing Traefik). The tunnel is token-managed, so its routes live in the Cloudflare dashboard, not this repo.

## Repo Structure

```plaintext
apps/                        # ArgoCD Application resources (App-of-Apps pattern, recursive)
  root.yaml                  # Applied once manually — discovers all apps/ recursively
  sol/                       # All apps (destination: kubernetes.default.svc)
    certs/
      cert-manager.yaml
      cert-manager-config.yaml
    infisical/
      infisical.yaml
      infisical-operator.yaml
      infisical-secrets.yaml # Deploys InfisicalSecret CRDs from manifests/infisical-secrets/
    databases/
      postgresql.yaml        # Shared Bitnami PostgreSQL (namespace: databases); tailnet: postgres.wuguishifu.dev:5432
      redis.yaml             # Shared Bitnami Redis (namespace: databases); tailnet: redis.wuguishifu.dev:6379
      pgadmin.yaml
      databases-backup.yaml
      universe-db.yaml       # Runs universe monorepo drizzle migrations on the `universe` database
    system/
      argocd-config.yaml
      coredns-config.yaml
    homelab/
      thermo-automation.yaml # Daikin thermostat automation service
      jankbot.yaml           # jankbot Discord bot (core, stitcher, and one gateway per voice bot)
      media-tools.yaml       # ffmpeg/ffprobe/yt-dlp in /opt/media-tools on sol, for other apps to mount
      analytics-service.yaml # universe analytics-service (uses the `universe` database)
      internet-monitor.yaml  # universe internet-monitor (records ISP outages via analytics-service)
      cloudflared.yaml       # Cloudflare Tunnel connector

manifests/                   # Kubernetes manifests applied by ArgoCD apps
  argocd-config/             # ArgoCD ingress + insecure mode configmap
  coredns-config/            # coredns-custom: in-cluster rewrites for *.wuguishifu.dev names (redis, postgres)
  cert-manager-config/       # ClusterIssuer (letsencrypt-prod, Cloudflare DNS-01)
  infisical-secrets/         # InfisicalSecret CRDs — one file per secret group
  thermo-automation/         # Deployment for thermo-automation
  jankbot/                   # jankbot-core, jankbot-stitcher and the jankbot-gateway Deployments
  media-tools/               # media-tools Deployment (hostPath /opt/media-tools) and how to mount it
  analytics-service/         # Deployment + in-cluster Service for analytics-service
  internet-monitor/          # Deployment + ConfigMap for internet-monitor
  cloudflared/               # Cloudflare Tunnel connector Deployment
  databases-backup/          # Backup CronJobs and config
  universe-db/               # Migration Job for the `universe` database (see its README)

hosts/                       # Machines outside Kubernetes, managed with their own pull-based reconciler
  mini/                      # Apple M4 Mac mini: services run natively under launchd (see its README)
```

Not everything runs in k3s: `hosts/mini/` describes services that run natively on the Mac mini
(e.g. transcription-worker, which needs Apple Silicon's GPU). The mini pulls this repo every
minute and applies it, the same GitOps model as ArgoCD. See `hosts/mini/README.md`.

## Sync Wave Order

Apps deploy in waves to respect dependencies:

| Wave | Apps                                                                                                                   |
| ---- | ---------------------------------------------------------------------------------------------------------------------- |
| 0    | cert-manager                                                                                                           |
| 1    | cert-manager-config, coredns-config, postgresql, redis                                                                 |
| 2    | argocd-config, infisical, infisical-operator                                                                           |
| 3    | infisical-secrets, media-tools                                                                                         |
| 4    | thermo-automation, jankbot, cloudflared, universe-db                                                                   |
| 5    | garage-webui (depends on garage), analytics-service, internet-monitor, and other apps that use the `universe` database |

## Secrets Architecture

Secrets follow a strict hierarchy:

```plaintext
Infisical UI  →  InfisicalSecret CRD  →  Kubernetes Secret  →  App
```

**Two secrets are created manually and never stored in Git:**

- `database-credentials` in `databases` namespace — holds `POSTGRES_ADMIN_PASSWORD`, `POSTGRES_PASSWORD`, and `REDIS_PASSWORD`; used by the Bitnami PostgreSQL and Redis Helm charts for auth
- `infisical-secrets` in `infisical` namespace — bootstraps Infisical itself (ENCRYPTION_KEY, AUTH_SECRET, DB_CONNECTION_URI, REDIS_URL, SITE_URL); uses cross-namespace DNS to reach postgres and redis in `databases`

See `BOOTSTRAP.md` for how these are created.

Everything else goes through Infisical:

1. Add the secret value in the Infisical UI at `https://infisical.wuguishifu.dev`
2. Add an `InfisicalSecret` YAML to `manifests/infisical-secrets/`
3. Push — ArgoCD syncs the CRD and the operator creates the Kubernetes `Secret`

Credentials several apps share live in shared Infisical groups under `/platform/` (e.g.
`/platform/redis`, `/platform/analytics/client`) rather than being copied into each app's path. An
app lists the paths it reads in `secretsPaths` in its universe `environment-config.json`; mirror that
here with one `InfisicalSecret` per path, synced into the app's namespace, and load them with
`envFrom` in the same order (later wins). See `manifests/internet-monitor/` for an example.

The machine identity that allows the operator to authenticate with Infisical is stored in `kubectl secret generic infisical-machine-identity -n infisical-operator-system` (also manually created, never in Git).

## Adding a New App

1. Add a Kubernetes `Application` manifest to `apps/sol/`, using `destination.server: https://kubernetes.default.svc`
2. Add manifests to `manifests/<app-name>/` if using files from this repo, or point directly at a Helm chart
3. If the app needs secrets, add an `InfisicalSecret` to `manifests/infisical-secrets/` and the secret value to Infisical
4. Push — ArgoCD handles the rest
