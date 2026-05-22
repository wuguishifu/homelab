# Gogs

Self-hosted Git service at `https://git.wuguishifu.dev`.

Registration is disabled. All new accounts must be created manually.

## Secrets

Add these to Infisical under the `homelab` project, `prod` environment, path `/gogs`:

| Key                | Description                                                                    |
| ------------------ | ------------------------------------------------------------------------------ |
| `GOGS_DB_PASSWORD` | Password for the `gogs` PostgreSQL user                                        |
| `GOGS_SECRET_KEY`  | Random string used for session security (generate with `openssl rand -hex 32`) |

## Creating additional user accounts

Since registration is disabled, new accounts must be created via the Gogs admin CLI:

```bash
kubectl exec -it -n gogs \
  $(kubectl get pod -n gogs -l app=gogs -o jsonpath='{.items[0].metadata.name}') \
  -- /app/gogs/gogs admin create-user \
     --name <username> \
     --password <password> \
     --email <email> \
     --admin
```

Remove `--admin` for a regular (non-admin) user.

## Re-enabling registration temporarily

You can toggle registration from the Gogs admin panel at `https://git.wuguishifu.dev/-/admin/config` without touching the config file.
