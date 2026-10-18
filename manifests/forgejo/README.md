# Forgejo

Private git hosting at `https://git.wuguishifu.dev` (tailnet only, like everything on
`*.wuguishifu.dev`), replacing Gogs (`manifests/gogs/`). Every repository is private, registration
is off, and there is no SSH, LFS, Actions or package registry.

One Deployment on the `forgejo-data` PVC (repositories, plus `custom/conf/app.ini`, which the image
regenerates from the `FORGEJO__*` variables in `deployment.yaml` on every start). Users, tokens,
issues and the Authelia login source live in the `forgejo` database on the shared PostgreSQL.

To upgrade, bump the image tag in `deployment.yaml`. It's on the 15.x LTS line, supported until July 2027. The schema migrates on start.

## Logging in

- **Web UI:** through Authelia over OIDC (the `forgejo` client in
  `manifests/authelia/configuration.yml`), so it asks for both factors. The Ingress has no
  forward-auth because git can't follow a browser login.
- **git and the API:** HTTPS with a personal access token, never the account password
  (`ENABLE_BASIC_AUTHENTICATION=false`). Tokens don't go through Authelia, so git keeps working if
  Authelia is down.
- **Fallback:** the account's own password plus Forgejo's TOTP, for when Authelia is down.

### git

In Forgejo, go to **Settings → Applications → Generate new token** and give it read and write
on **repository**. macOS git keeps it in the keychain (`credential.helper osxkeychain`), so it's
entered once: username = your Forgejo username, password = the token. Remotes keep the Gogs URLs
(`https://git.wuguishifu.dev/<owner>/<repo>.git`), because owners and names carry over.

## Setup

Do these in order. Authelia won't start without its new digest, so add it before pushing.

1. Create the database and role. With a port-forward
   (`kubectl port-forward -n databases svc/postgresql 5432:5432`) and the admin password from
   `database-credentials` (see `RESTORE.md`), run as `postgres`:

   ```sql
   CREATE ROLE forgejo WITH LOGIN PASSWORD '<openssl rand -hex 24>';
   CREATE DATABASE forgejo OWNER forgejo;
   ```

2. Add `/forgejo` and `/authelia`'s `FORGEJO_CLIENT_SECRET_DIGEST` to Infisical (see **Secrets**).
   Keep the digest's `Random Password` for step 6.
3. Set up backups (see **Backups → Setup**).
4. Push. Gogs moves to `gogs.wuguishifu.dev`. Fix its `app.ini` as `manifests/gogs/README.md`
   describes.
5. Create your account with the same username as in Gogs and the same email as in Authelia. Put
   the printed password in Vaultwarden:

   ```sh
   kubectl -n forgejo exec deploy/forgejo -- forgejo admin user create --admin \
     --username <username> --email <email> --random-password --random-password-length 32 \
     --must-change-password=false
   ```

   Log in with it and turn on TOTP under **Settings → Security**. That's the fallback login.

6. Add Authelia as a login source. `admins` in Authelia means admin in Forgejo, and
   `--skip-local-2fa` stops Forgejo asking for its own TOTP after Authelia's:

   ```sh
   kubectl -n forgejo exec deploy/forgejo -- forgejo admin auth add-oauth \
     --name authelia --provider openidConnect --key forgejo --secret '<Random Password>' \
     --auto-discover-url https://auth.wuguishifu.dev/.well-known/openid-configuration \
     --scopes openid --scopes email --scopes profile --scopes groups \
     --group-claim-name groups --admin-group admins --skip-local-2fa
   ```

   The name has to stay `authelia`, because it's part of the redirect URI in Authelia's config.
   The secret is stored only in the database (encrypted with `SECRET_KEY`). If it's lost, generate
   a new pair and run `forgejo admin auth update-oauth`.

7. Log out and click **Sign in with authelia**. The first time, Forgejo asks you to link an
   existing account: sign in with the local password and TOTP. After that, Authelia logs you
   straight in.

## Migrating from Gogs

`migrate-from-gogs.sh` imports every repository your Gogs account can see, with issues, labels,
milestones and wikis. It doesn't bring LFS objects. Forgejo clones from Gogs' in-cluster Service,
which `[migrations]` in `deployment.yaml` allows.

1. In Gogs (`https://gogs.wuguishifu.dev`), go to **Your Settings → Applications** and generate a token.
2. Make a Forgejo token for the script:

   ```sh
   kubectl -n forgejo exec deploy/forgejo -- forgejo admin user generate-access-token \
     -u <username> -t gogs-migration --scopes write:repository,write:organization,read:user --raw
   ```

3. Run the script: `GOGS_TOKEN=... FORGEJO_TOKEN=... ./manifests/forgejo/migrate-from-gogs.sh`.
   Large repositories take a while each.
4. Check that every branch and tag made it. For each repository, these two lists should match:

   ```sh
   kubectl -n gogs port-forward svc/gogs 3001:3000 &
   git ls-remote "http://$GOGS_TOKEN@localhost:3001/<owner>/<repo>.git" | sort
   git ls-remote "https://<username>:$FORGEJO_TOKEN@git.wuguishifu.dev/<owner>/<repo>.git" | sort
   ```

5. Delete both tokens: Gogs under **Applications**, Forgejo under **Settings → Applications**.

Once you're done with Gogs, `manifests/gogs/README.md` says how to remove it.

## Backups

The `forgejo-backup` CronJob (`backup.yaml`, `backup.sh`) runs nightly at 04:00 UTC and writes to
the `forgejo-backups` bucket on the production Garage (`https://s3.wuguishifu.dev`, on the NAS; see
`GARAGE.md`). It doesn't use R2, so nothing from Forgejo leaves the tailnet.

- **Repositories:** each one (and its wiki, a separate `<repo>.wiki` repository) becomes one
  `git bundle --all` file. A repository is only backed up when its refs changed since its last
  backup. It compares a hash of every ref and the commit it points to with the hash in the newest
  backup's name, so an untouched repository costs nothing. The last 5 are kept:
  `repos/<owner>/<repo>/<UTC timestamp>-<ref hash>.bundle.age`.
- **Database:** a `pg_dump --format=custom` every night, the last 7 kept: `db/<UTC timestamp>.dump.age`.
- **Not backed up:** LFS objects, issue attachments and avatars.

Everything is encrypted with [age](https://age-encryption.org) to `AGE_RECIPIENT`, a public key.
The matching private key is only in Vaultwarden, so neither sol nor the NAS can read the backups.
Anything with the Garage key can delete them, though. ZFS snapshots of the Garage dataset on the NAS
protect against that.

To run it now: `kubectl -n forgejo create job --from=cronjob/forgejo-backup forgejo-backup-manual`,
then `kubectl -n forgejo logs -f job/forgejo-backup-manual`. Each repository prints `unchanged` or
`backing up`.

### Setup

1. With the `garage` CLI on the NAS (commands as in `GARAGE.md`), create the bucket and a key
   that can only use it:

   ```sh
   garage bucket create forgejo-backups
   garage key create forgejo-backup-key
   garage bucket allow --read --write forgejo-backups --key forgejo-backup-key
   ```

2. Make the age key pair: `age-keygen -o forgejo-backup.key`. Put the whole file in Vaultwarden,
   copy the `age1...` public key it prints, then delete the file.
3. Add `/forgejo/backup` to Infisical (below).

### Restoring

Decrypt any backup with the private key from Vaultwarden (saved as `forgejo-backup.key`):

```sh
export AWS_ACCESS_KEY_ID=... AWS_SECRET_ACCESS_KEY=... AWS_DEFAULT_REGION=garage
aws --endpoint-url https://s3.wuguishifu.dev s3 ls --recursive s3://forgejo-backups/repos/<owner>/<repo>/
aws --endpoint-url https://s3.wuguishifu.dev s3 cp s3://forgejo-backups/<key> - |
  age -d -i forgejo-backup.key > backup
```

**One repository into a running Forgejo.** A bundle can be cloned like any remote. Create an
empty repository with the same name in Forgejo, then push branches and tags into it:

```sh
git clone --mirror backup repo.git
git -C repo.git push https://git.wuguishifu.dev/<owner>/<repo>.git 'refs/heads/*:refs/heads/*' 'refs/tags/*:refs/tags/*'
```

**Everything (lost PVC).** If the database was lost too, restore it first, into an empty `forgejo`
database:

```sh
pg_restore --no-owner -h localhost -U forgejo -d forgejo backup   # through the postgresql port-forward
```

ArgoCD recreates the PVC empty, and Forgejo starts on the restored database with no repositories on
disk. Put each one back where the database expects it (lowercase names), then recreate the hooks:

```sh
kubectl -n forgejo cp backup <pod>:/tmp/gitea/backup
kubectl -n forgejo exec <pod> -- git clone --mirror /tmp/gitea/backup /var/lib/gitea/git/repositories/<owner>/<repo>.git
kubectl -n forgejo exec <pod> -- git -C /var/lib/gitea/git/repositories/<owner>/<repo>.git remote remove origin
kubectl -n forgejo exec deploy/forgejo -- forgejo admin regenerate hooks
```

## Secrets

Infisical `homelab` project, `prod` environment, `/forgejo` (→ `forgejo-secrets`, mounted at
`/secrets`):

| Key           | Description                                                                                                 |
| ------------- | ----------------------------------------------------------------------------------------------------------- |
| `SECRET_KEY`  | `openssl rand -hex 32`. Encrypts 2FA secrets and the login source in the database. Never change it once set |
| `DB_PASSWORD` | The `forgejo` role's password from setup step 1. The backup job uses it too                                 |

`/forgejo/backup` (→ `forgejo-backup-secrets`, the backup CronJob only):

| Key                    | Description                                                 |
| ---------------------- | ----------------------------------------------------------- |
| `S3_ACCESS_KEY_ID`     | `forgejo-backup-key`'s `GK...` ID                           |
| `S3_SECRET_ACCESS_KEY` | Its secret                                                  |
| `AGE_RECIPIENT`        | The `age1...` public key. The private key is in Vaultwarden |

Authelia's `FORGEJO_CLIENT_SECRET_DIGEST` is in `manifests/authelia/README.md`.

## Checking it

```sh
kubectl -n forgejo get pods
kubectl -n forgejo logs deploy/forgejo | grep -i 'listen'
curl -s https://git.wuguishifu.dev/api/healthz
kubectl -n forgejo get jobs                              # forgejo-backup runs, Complete
```
