# Restore

Procedures for restoring Vaultwarden and Infisical from encrypted backups stored in the `secrets` R2 bucket. Backups run daily at 3am and are stored at `daily/<db>/<timestamp>.sql.gz.enc`.

Before starting, you will need:

- The `BACKUP_ENCRYPTION_PASSPHRASE` (stored offline)
- The `SECRETS_R2_ACCESS_KEY_ID` and `SECRETS_R2_SECRET_ACCESS_KEY` for the `secrets` bucket
- The `R2_ACCOUNT_ID` for your Cloudflare account
- `kubectl` access to the cluster

---

## Step 1 — Find and download the backup

Replace `<db>` with `vaultwarden` or `infisicalDB`. Backups are mirrored to both Cloudflare R2 and Amazon S3 — use whichever is available.

**From Cloudflare R2:**

```sh
aws s3 ls "s3://secrets/daily/<db>/" \
  --endpoint-url "https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com"

aws s3 cp \
  "s3://secrets/daily/<db>/<timestamp>.sql.gz.enc" \
  ./<db>.sql.gz.enc \
  --endpoint-url "https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com"
```

**From Amazon S3:**

```sh
aws s3 ls "s3://<S3_BUCKET>/daily/<db>/"

aws s3 cp \
  "s3://<S3_BUCKET>/daily/<db>/<timestamp>.sql.gz.enc" \
  ./<db>.sql.gz.enc
```

## Step 2 — Decrypt and decompress

```sh
openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
  -in ./<db>.sql.gz.enc \
  -out ./<db>.sql.gz \
  -pass pass:'<BACKUP_ENCRYPTION_PASSPHRASE>'

gunzip ./<db>.sql.gz
```

You should now have `<db>.sql` — a plain PostgreSQL dump.

## Step 3 — Open a connection to PostgreSQL

Port-forward to the PostgreSQL service. Keep this running in a separate terminal for the steps below.

```sh
kubectl port-forward -n databases svc/postgresql 5432:5432
```

Get the postgres admin password from the `database-credentials` secret:

```sh
kubectl get secret database-credentials -n databases \
  -o jsonpath='{.data.POSTGRES_ADMIN_PASSWORD}' | base64 -d && echo
```

## Step 4 — Restore the database

Scale down the application first so it is not writing to the database during restore:

```sh
# For Vaultwarden
kubectl scale deployment vaultwarden -n vaultwarden --replicas=0

# For Infisical
kubectl scale deployment infisical -n infisical --replicas=0
```

Wait for pods to terminate:

```sh
kubectl get pods -n <namespace> -w
```

Drop and recreate the database, then restore:

```sh
PGPASSWORD='<POSTGRES_ADMIN_PASSWORD>' psql -h 127.0.0.1 -U postgres \
  -c "DROP DATABASE <db> WITH (FORCE);"

PGPASSWORD='<POSTGRES_ADMIN_PASSWORD>' psql -h 127.0.0.1 -U postgres \
  -c "CREATE DATABASE <db>;"

PGPASSWORD='<POSTGRES_ADMIN_PASSWORD>' psql -h 127.0.0.1 -U postgres <db> \
  < ./<db>.sql
```

## Step 5 — Bring the application back up

Scale the deployment back to 1 replica and verify it starts cleanly:

```sh
# For Vaultwarden
kubectl scale deployment vaultwarden -n vaultwarden --replicas=1
kubectl rollout status deployment/vaultwarden -n vaultwarden

# For Infisical
kubectl scale deployment infisical -n infisical --replicas=1
kubectl rollout status deployment/infisical -n infisical
```

Check the application logs for errors:

```sh
kubectl logs -n <namespace> deployment/<app> --tail=50
```

---

## Full disaster recovery order

If the entire cluster is gone, restore in this order so that secrets are available before dependent apps come up:

1. Follow `BOOTSTRAP.md` to get k3s, ArgoCD, and the bootstrap secrets back up
2. Restore the **Infisical** database (steps above) before ArgoCD finishes syncing — Infisical needs to be healthy before the `infisical-operator` can sync secrets to other apps
3. Restore the **Vaultwarden** database
4. ArgoCD will reconcile everything else automatically once Infisical is syncing

---

## Cleanup

Remove the local plaintext SQL files after the restore is verified:

```sh
rm ./<db>.sql ./<db>.sql.gz.enc
```
