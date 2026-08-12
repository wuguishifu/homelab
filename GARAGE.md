# Garage

Garage is the S3-compatible object store running in the `garage` namespace. The S3 API is exposed at `https://s3.wuguishifu.dev` (Tailscale-only, like everything else behind Traefik).

There is no web UI — buckets and keys are managed with the `garage` CLI via `kubectl exec`. For convenience:

```sh
alias garage='kubectl -n garage exec -it deploy/garage -- /garage'
```

## Client configuration

- **Endpoint:** `https://s3.wuguishifu.dev`
- **Region:** `garage`
- **Addressing:** path-style only (`s3.wuguishifu.dev/<bucket>/<key>`). Vhost-style (`<bucket>.s3.wuguishifu.dev`) does not resolve because the `*.wuguishifu.dev` wildcard only covers one label. Most SDKs need `forcePathStyle: true` (JS) / `s3ForcePathStyle` / `use_path_style_endpoint` set.

## One-time layout init (fresh cluster only)

After the first deploy, Garage has no storage assigned and rejects all requests until a layout is applied:

```sh
garage status                          # copy the node ID from the output
garage layout assign -z sol -c 50G <node-id>
garage layout apply --version 1
```

## Creating a bucket

```sh
garage bucket create <bucket-name>

# Verify
garage bucket list
garage bucket info <bucket-name>
```

## Creating an API key

Each app gets its own key with access to only the buckets it needs.

```sh
garage key create <app-name>-key
```

This prints the **Key ID** (`GK...`) and **Secret key** once — copy both immediately. The secret is shown again only via `garage key info <app-name>-key --show-secret`.

## Granting bucket access

```sh
# Read + write
garage bucket allow --read --write <bucket-name> --key <app-name>-key

# Read-only
garage bucket allow --read <bucket-name> --key <app-name>-key

# Also --owner for admin operations on the bucket (lifecycle config, website config)

# Revoke
garage bucket deny --write <bucket-name> --key <app-name>-key

# Verify
garage bucket info <bucket-name>       # lists authorized keys and their permissions
```

## Wiring credentials into an app

Follow the standard secrets flow (see `CLAUDE.md`):

1. In the Infisical UI, add the key to the app's secrets path, e.g. `/my-app`:
   - `S3_ENDPOINT` = `https://s3.wuguishifu.dev`
   - `S3_REGION` = `garage`
   - `S3_BUCKET` = `<bucket-name>`
   - `S3_ACCESS_KEY_ID` = the `GK...` key ID
   - `S3_SECRET_ACCESS_KEY` = the secret key
2. Reference them from the app's `InfisicalSecret` in `manifests/infisical-secrets/` as usual.

Apps running in-cluster can skip TLS/Traefik and use the internal endpoint `http://garage.garage.svc.cluster.local:3900` instead.

## Useful maintenance commands

```sh
garage status                          # cluster/node health
garage stats                           # storage usage
garage bucket list
garage key list
```
