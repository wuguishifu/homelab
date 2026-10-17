# Redash

Redash at `https://redash.wuguishifu.dev` (tailnet only, like everything on `*.wuguishifu.dev`).

Three Deployments run the `redash/redash` image: `redash-server` (web UI and API), `redash-scheduler`
and `redash-worker` (runs queries off every queue). Its metadata (users, queries, dashboards, data
sources) lives in the `redash` database on the shared PostgreSQL, and its job queues in Redis DB 1
on the shared Redis (Infisical uses DB 0).

To upgrade, bump the image tag in all four places in `deployment.yaml`. The server's init container
runs any new migrations before it starts.

## Setup

The database and its role aren't created by anything in this repo. With a port-forward
(`kubectl port-forward -n databases svc/postgresql 5432:5432`) and the admin password from
`database-credentials` (see `RESTORE.md`), run as `postgres`:

```sql
CREATE ROLE redash WITH LOGIN PASSWORD '<openssl rand -hex 24>';
CREATE DATABASE redash OWNER redash;
```

Then add the secrets below. On first start the server creates the tables; open
`https://redash.wuguishifu.dev` to create the admin account.

Once the database exists, add `redash` to `SENSITIVE_DATABASES` in
`manifests/databases-backup/configmap.yaml` (not before: the backup fails on a missing database). It
holds user accounts and API keys, so it goes in the encrypted set.

## Secrets

Infisical `homelab` project, `prod` environment, `/redash` (→ `redash-secrets`):

| Key                    | Description                                                                         |
| ---------------------- | ----------------------------------------------------------------------------------- |
| `REDASH_DATABASE_URL`  | `postgresql://redash:<password>@postgresql.databases.svc.cluster.local:5432/redash` |
| `REDASH_REDIS_URL`     | `redis://:<REDIS_PASSWORD>@redis-master.databases.svc.cluster.local:6379/1`         |
| `REDASH_COOKIE_SECRET` | Signs session cookies (`openssl rand -hex 32`)                                      |
| `REDASH_SECRET_KEY`    | Encrypts data source credentials (`openssl rand -hex 32`). Never change it once set |

`REDIS_PASSWORD` is the one in `database-credentials`.

To send email (invites, alerts, password resets), also add `REDASH_MAIL_SERVER`, `REDASH_MAIL_PORT`,
`REDASH_MAIL_USE_TLS`, `REDASH_MAIL_USERNAME`, `REDASH_MAIL_PASSWORD` and
`REDASH_MAIL_DEFAULT_SENDER`.

## Login

Authelia's forward-auth sits in front of the Ingress, and Redash logs you in as the `Remote-Email`
header it sets (`REDASH_REMOTE_USER_*` in `deployment.yaml`). A matching email logs in as that user
and keeps its groups. A new email gets a user in the `default` group. Redash sets the display name to
the email on each login.

Until password login is off, the login page shows a link to remote-user login rather than using
it. Turn password login off in **Settings → General** for a seamless login.
Anything that calls the API with a key (scripts, shared dashboard links) also has to pass Authelia
now.

## Data sources

Add them in the UI. From the cluster, the shared PostgreSQL is
`postgresql.databases.svc.cluster.local:5432`. Give Redash a read-only role rather than an app's
own credentials, e.g. for the `universe` database:

```sql
CREATE ROLE redash_reader WITH LOGIN PASSWORD '<openssl rand -hex 24>';
\c universe
GRANT CONNECT ON DATABASE universe TO redash_reader;
GRANT USAGE ON SCHEMA public TO redash_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO redash_reader;
ALTER DEFAULT PRIVILEGES FOR ROLE universe IN SCHEMA public GRANT SELECT ON TABLES TO redash_reader;
```

## Checking it

```sh
kubectl -n redash get pods
kubectl -n redash logs deploy/redash-server -c migrate
kubectl -n redash logs -f deploy/redash-worker
```
