# Authelia

Single sign-on at `https://auth.wuguishifu.dev` (tailnet only, like everything on `*.wuguishifu.dev`).
It is an OpenID Connect provider for apps that support OIDC (ArgoCD, Beszel) and a Traefik
forward-auth endpoint for apps that have no login of their own.

One stateless Deployment. Users are a YAML file in Infisical (no admin UI). Passkeys, TOTP devices
and OIDC consents live in the `authelia` database on the shared PostgreSQL. Sessions live in Redis DB 2
on the shared Redis. Configuration is `configuration.yml`, and kustomize turns it into a ConfigMap
with a content hash, so editing it restarts the pod.

To upgrade, bump the image tag in `deployment.yaml`. The schema migrates on start.

Vaultwarden is deliberately left out: if Authelia breaks, the password manager has to still work.
ArgoCD and Beszel keep their local admin logins as a fallback.

## Setup

1. Create the database and role. With a port-forward
   (`kubectl port-forward -n databases svc/postgresql 5432:5432`) and the admin password from
   `database-credentials` (see `RESTORE.md`), run as `postgres`:

   ```sql
   CREATE ROLE authelia WITH LOGIN PASSWORD '<openssl rand -hex 24>';
   CREATE DATABASE authelia OWNER authelia;
   ```

2. Generate the secrets below and add them to Infisical. All commands use the Authelia image:
   `alias authelia='docker run --rm -it -v "$PWD:/keys" authelia/authelia:4.39.28 authelia'`.
3. Push. The pod starts once `authelia-secrets` exists.
4. Sign in at `https://auth.wuguishifu.dev` with your password. Every client requires two factors,
   so register a passkey (or TOTP) under **Settings**. Registering asks for a one-time code, which
   is written to a file rather than emailed:

   ```sh
   kubectl -n authelia exec deploy/authelia -- cat /data/notification.txt
   ```

   After that a passkey alone gets you past the username/password step, and the password is then
   your second factor.

5. Add `authelia` to `SENSITIVE_DATABASES` in `manifests/databases-backup/configmap.yaml` (not
   before step 1: the backup fails on a missing database). It holds the 2FA registrations, so it
   goes in the encrypted set.

## Secrets

Infisical `homelab` project, `prod` environment, `/authelia` (→ `authelia-secrets`, mounted at
`/secrets`):

| Key                           | Description                                                                                                                                                              |
| ----------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `SESSION_SECRET`              | `authelia crypto rand --length 64 --charset alphanumeric`                                                                                                                |
| `STORAGE_ENCRYPTION_KEY`      | Same command. Encrypts the 2FA data in the database. Never change it once set                                                                                            |
| `OIDC_HMAC_SECRET`            | Same command                                                                                                                                                             |
| `OIDC_JWKS_KEY`               | Signs ID tokens. `authelia crypto pair rsa generate --bits 2048 --directory /keys`, then paste `private.pem`                                                             |
| `STORAGE_POSTGRES_PASSWORD`   | The `authelia` role's password from step 1                                                                                                                               |
| `REDIS_PASSWORD`              | `REDIS_PASSWORD` from `database-credentials`                                                                                                                             |
| `USERS_DATABASE`              | The users file (below)                                                                                                                                                   |
| `ARGOCD_CLIENT_SECRET_DIGEST` | `Digest` from `authelia crypto hash generate pbkdf2 --variant sha512 --random --random.length 72 --random.charset rfc3986`. The `Random Password` goes to `/argocd/oidc` |
| `BESZEL_CLIENT_SECRET_DIGEST` | `Digest` from the same command. The `Random Password` goes into Beszel (see `manifests/beszel/README.md`)                                                                |

Infisical `/argocd/oidc` (→ `argocd-oidc` in `argocd`):

| Key                  | Description                                    |
| -------------------- | ---------------------------------------------- |
| `OIDC_CLIENT_SECRET` | The plaintext of `ARGOCD_CLIENT_SECRET_DIGEST` |

### Users

`USERS_DATABASE` is the whole file. Hash the password with `authelia crypto hash generate argon2`:

```yaml
users:
  bo:
    disabled: false
    displayname: Bo
    password: "$argon2id$v=19$m=65536,t=3,p=4$..."
    email: you@example.com # must match the email of your account in apps that link by email (Beszel)
    groups: [admins] # admins = ArgoCD role:admin (manifests/argocd-config/argocd-rbac-cm.yaml)
```

Password reset and password change are turned off, because Authelia can't write to the file. To
change a password or add a user, edit `USERS_DATABASE` in Infisical. The operator syncs it within a
minute and restarts the pod (`secrets.infisical.com/auto-reload`).

## Adding an app

- **OIDC.** Add a client under `identity_providers.oidc.clients` in `configuration.yml`, with its
  digest as a new `/authelia` key read through `secret "/secrets/<KEY>"`. Authelia's
  [integration guides](https://www.authelia.com/integration/openid-connect/) list per-app settings.
  The app's pod reaches `auth.wuguishifu.dev` through Traefik via the CoreDNS rewrite in
  `manifests/coredns-config/`.
- **Forward-auth** (no login of its own). Add
  `traefik.ingress.kubernetes.io/router.middlewares: authelia-forwardauth@kubernetescrd` to the
  app's Ingress. Unauthenticated requests are redirected to the login page, and two factors are
  required unless `access_control` says otherwise.

## Checking it

```sh
kubectl -n authelia get pods
kubectl -n authelia logs deploy/authelia   # "Startup complete"
curl -s https://auth.wuguishifu.dev/.well-known/openid-configuration | jq .issuer
```
