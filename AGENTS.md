# Homelab — Agent Guide

This repo is a GitOps homelab running across two servers managed by a single ArgoCD instance (hub-spoke multi-cluster). ArgoCD runs on the apartment server (`sol`) and watches this repo to reconcile both clusters.

## Stack

| Component                  | Role                                                          |
| -------------------------- | ------------------------------------------------------------- |
| k3s                        | Lightweight single-node Kubernetes                            |
| Traefik                    | Ingress controller (bundled with k3s)                         |
| cert-manager               | Automatic TLS via Let's Encrypt (Cloudflare DNS-01 challenge) |
| ArgoCD                     | GitOps — watches this repo, syncs everything                  |
| Infisical                  | Self-hosted secrets manager                                   |
| Infisical secrets-operator | Syncs secrets from Infisical → Kubernetes `Secret` objects    |

Both servers are connected via Tailscale. The apartment server (`sol`) is Tailscale-only. The home server has a public port forward for ingress traffic. DNS for `wuguishifu.dev` is managed by Cloudflare with a wildcard A record pointing to the apartment server's Tailscale IP (DNS only, not proxied).

## Repo Structure

```plaintext
apps/                        # ArgoCD Application resources (App-of-Apps pattern, recursive)
  root.yaml                  # Applied once manually — discovers all apps/ recursively
  apartment/                 # Apps targeting the apartment server (destination: kubernetes.default.svc)
    certs/
      cert-manager.yaml
      cert-manager-config.yaml
    infisical/
      infisical.yaml
      infisical-operator.yaml
      infisical-secrets.yaml # Deploys InfisicalSecret CRDs from manifests/infisical-secrets/
    databases/
      postgresql.yaml        # Shared Bitnami PostgreSQL (namespace: databases)
      redis.yaml             # Shared Bitnami Redis (namespace: databases)
      pgadmin.yaml
      databases-backup.yaml
    system/
      argocd-config.yaml
    homelab/
      thermo-automation.yaml # Daikin thermostat automation service
  home/                      # Apps targeting the home server (destination: name: home-server)

manifests/                   # Kubernetes manifests applied by ArgoCD apps
  argocd-config/             # ArgoCD ingress + insecure mode configmap
  cert-manager-config/       # ClusterIssuer (letsencrypt-prod, Cloudflare DNS-01)
  infisical-secrets/         # InfisicalSecret CRDs — one file per secret group
  thermo-automation/         # Deployment for thermo-automation
  databases-backup/          # Backup CronJobs and config
```

## Sync Wave Order

Apps deploy in waves to respect dependencies:

| Wave | Apps                                         |
| ---- | -------------------------------------------- |
| 0    | cert-manager                                 |
| 1    | cert-manager-config, postgresql, redis       |
| 2    | argocd-config, infisical, infisical-operator |
| 3    | infisical-secrets                            |
| 4    | thermo-automation                            |

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

The machine identity that allows the operator to authenticate with Infisical is stored in `kubectl secret generic infisical-machine-identity -n infisical-operator-system` (also manually created, never in Git).

## Adding a New App

1. Add a Kubernetes `Application` manifest to `apps/apartment/` or `apps/home/` depending on which cluster it targets
   - Apartment apps use `destination.server: https://kubernetes.default.svc`
   - Home server apps use `destination.name: home-server`
2. Add manifests to `manifests/<app-name>/` if using files from this repo, or point directly at a Helm chart
3. If the app needs secrets, add an `InfisicalSecret` to `manifests/infisical-secrets/` and the secret value to Infisical
4. Push — ArgoCD handles the rest
