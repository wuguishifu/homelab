# Gogs

Being replaced by Forgejo (`manifests/forgejo/`). Gogs stays at `https://gogs.wuguishifu.dev`, behind
Authelia, until its repositories are migrated and checked, then it gets removed.

`git.wuguishifu.dev` now points at Forgejo. Gogs can't do SSO, so its Ingress uses the Authelia
forward-auth middleware, which also means git can't reach it over its hostname. Forgejo imports from
the in-cluster Service (`http://gogs.gogs.svc.cluster.local:3000`) instead.

Registration is disabled. All configuration, including the database connection, was entered in the
install wizard and lives in `/data/gogs/conf/app.ini` on the `gogs-data` PVC, not in this repo.
Nothing reads Infisical.

## Moving to gogs.wuguishifu.dev

Gogs builds its links, login redirects and the clone URLs in its API from `DOMAIN` and
`EXTERNAL_URL` (`ROOT_URL` before Gogs 0.13). After the Ingress moved, they need to change too:

```sh
kubectl -n gogs exec deploy/gogs -c gogs -- sed -i -E \
  -e 's#^DOMAIN *=.*#DOMAIN = gogs.wuguishifu.dev#' \
  -e 's#^EXTERNAL_URL *=.*#EXTERNAL_URL = https://gogs.wuguishifu.dev/#' \
  /data/gogs/conf/app.ini
kubectl -n gogs rollout restart deploy/gogs
```

While repositories are being imported into Forgejo, `EXTERNAL_URL` is set to
`http://gogs.gogs.svc.cluster.local:3000/` instead (see `manifests/forgejo/README.md`), and the web
UI's links point there until it's set back.

The init container hands `/data` back to uid 1000 on restart.

## Removing it

Once every repository is in Forgejo (`manifests/forgejo/README.md`):

1. Keep a copy of the PVC outside the cluster. The `local-path` volume is deleted with its PVC.

   ```sh
   kubectl -n gogs exec deploy/gogs -- tar -C /data -czf - . > gogs-data.tar.gz
   ```

2. Follow `REMOVING-APPS.md` for `apps/sol/homelab/gogs.yaml` and this directory.
3. If `app.ini`'s `[database]` points at the shared PostgreSQL, drop its database and role.
4. Remove the Gogs entries from `manifests/authelia/README.md`, and the `[migrations]` variables from
   `manifests/forgejo/deployment.yaml`.
