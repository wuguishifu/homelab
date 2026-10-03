# universe-db

The `universe` database on the shared PostgreSQL (`databases` namespace), used by services from the
[universe](https://github.com/wuguishifu/universe) monorepo. Its schema lives in
`platform/postgres/db` there, and its drizzle migrations in `platform/postgres/utils`.

This app only runs migrations. `migrate-job.yaml` is a Job that runs the `universe-db-migrations`
image. Image Updater pins its digest, so publishing a new image (**Deploy Server App** →
`postgres/migrations` in universe) makes the app OutOfSync, and the sync replaces the Job, which
applies any new migrations.

It's deliberately not a Sync hook: ArgoCD doesn't diff hooks, so an app holding only a hook always
reads Synced and Healthy, auto-sync never fires, and the hook never runs. As a tracked resource,
the app is only Healthy once the Job completes, so apps that use the database go in wave 5 and the
root app waits for migrations before syncing them (on a full sync, e.g. a bootstrap).

Services that use the database deploy on their own, so every migration has to work with the code
that's already running: add columns and tables first, then ship the code that uses them, and drop
old ones in a later migration.

## Setup

The database and its role aren't created by anything in this repo. With a port-forward
(`kubectl port-forward -n databases svc/postgresql 5432:5432`) and the admin password from
`database-credentials` (see `RESTORE.md`), run as `postgres`:

```sql
CREATE ROLE universe WITH LOGIN PASSWORD '<openssl rand -hex 24>';
CREATE DATABASE universe OWNER universe;
```

`universe` owns the database, so it can run migrations. Services currently connect as the same
role.

### Optional: a runtime role without DDL

To keep services from changing the schema, give them a role that can only read and write rows in
tables `universe` creates:

```sql
CREATE ROLE universe_app WITH LOGIN PASSWORD '<openssl rand -hex 24>';
\c universe
GRANT CONNECT ON DATABASE universe TO universe_app;
GRANT USAGE ON SCHEMA public TO universe_app;
ALTER DEFAULT PRIVILEGES FOR ROLE universe IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO universe_app;
ALTER DEFAULT PRIVILEGES FOR ROLE universe IN SCHEMA public
  GRANT USAGE, SELECT ON SEQUENCES TO universe_app;
-- Default privileges only cover tables created after them; grant on existing ones too.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO universe_app;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO universe_app;
```

## Secrets

All under the `universe` Infisical project, `prod` environment.

`/platform/postgres` (→ `universe-db-migrator-secrets`):

- `UNIVERSE_DB_CONNECTION_STRING`:
  `postgresql://universe:<password>@postgresql.databases.svc.cluster.local:5432/universe`

This is the same path universe's `platform/environment` loads for `postgres-utils`. The host only
resolves in the cluster, so to run `nx migrate:run postgres-utils` from a laptop, port-forward and
point `UNIVERSE_DB_CONNECTION_STRING` at `127.0.0.1` instead.

The database is the one in the connection string's path. Services get their own
`UNIVERSE_DB_CONNECTION_STRING` in their own Infisical path (with `universe_app` credentials, if
you've set that role up).

## Checking a run

```sh
kubectl logs -n databases job/universe-db-migrate
```

A failed Job leaves the app Degraded. To re-run after fixing it, delete the Job and ArgoCD recreates it.
