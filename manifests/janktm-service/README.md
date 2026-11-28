# janktm-service

janktm-service (universe `projects/janktm/service`) is the janktm photo album's backend. A scan lists
the `janktm-album` bucket in production Garage (one top-level folder per album), reads each new or
changed file's metadata with small ranged reads, and indexes it into `convex-app`'s prod deployment
(`album/*` functions). Each item then becomes a BullMQ flow in the shared Redis: an ffmpeg job that
the ffmpeg worker on the mini runs (`hosts/mini/services/ffmpeg-worker`), and a `complete` job back
here that records the results in Convex. Derivatives go to `janktm-album-derived`. The site never
talks to this service: it reads Convex, which hands out presigned URLs on `s3-public.wuguishifu.dev`.

It's reachable from the tailnet at `https://janktm.wuguishifu.dev`, and in-cluster at
`http://janktm-service.janktm-service.svc.cluster.local`. Every route but `/api/health` and
`/api/version` needs `Authorization: Bearer <API_TOKEN>`.

Its queues use the `janktm-service-queue` prefix (in Bull Board); the ffmpeg jobs are under
`ffmpeg-worker-queue`.

Image Updater pins the `janktm-service` image's digest, so publishing a new image (merging to
universe `main`, or **Deploy Server App** → `projects/janktm/service`) rolls it out.

## Secrets

Infisical `universe` project, `prod` environment. The app reads the same paths as its
`secretsPaths` in universe (`environment-config.json`), plus `/platform/convex/app` for prod
Convex's URL, each synced to its own Secret and loaded in this order, so a key in a later path
wins:

| Path                       | Secret                    | Keys                                                                                          |
| -------------------------- | ------------------------- | --------------------------------------------------------------------------------------------- |
| `/platform/s3`             | `janktm-service-s3`       | `S3_ENDPOINT`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_FORCE_PATH_STYLE` |
| `/platform/redis`          | `janktm-service-redis`    | `REDIS_URL`                                                                                   |
| `/platform/convex/app`     | `janktm-service-convex`   | `CONVEX_URL`                                                                                  |
| `/projects/janktm/service` | `janktm-service-secrets`  | `API_TOKEN`, `JANKTM_CONVEX_SECRET`                                                           |

- `/platform/s3` is production Garage (`https://s3.wuguishifu.dev`, the NAS), the same key the
  ffmpeg worker uses: the worker reads originals and writes derivatives with it, so both have to
  see the same buckets. The key needs read on `janktm-album` and read + write on
  `janktm-album-derived` (the service deletes replaced derivatives).
- `REDIS_URL` must be the Redis the ffmpeg worker uses (sol's, which it reaches as
  `redis.wuguishifu.dev`): flows only work within one Redis.
- `JANKTM_CONVEX_SECRET` is a random string (`openssl rand -hex 32`) that must match the prod
  deployment's env var.

## Before the first deploy

- [ ] Production Garage (NAS) has the `janktm-album` and `janktm-album-derived` buckets, and the
      `/platform/s3` key can read the first and read and write the second.
- [ ] A separate read-only key for both buckets, for Convex to sign the site's URLs with.
- [ ] `convex-app` (universe `platform/convex/app`) is deployed to prod with its album env vars:
      ```sh
      pnpm nx convex convex-app -- env set JANKTM_CONVEX_SECRET <value> --prod
      pnpm nx convex convex-app -- env set ALBUM_S3_PUBLIC_ENDPOINT https://s3-public.wuguishifu.dev --prod
      pnpm nx convex convex-app -- env set ALBUM_S3_REGION garage --prod
      pnpm nx convex convex-app -- env set ALBUM_S3_ACCESS_KEY_ID <read-only key ID> --prod
      pnpm nx convex convex-app -- env set ALBUM_S3_SECRET_ACCESS_KEY <read-only secret> --prod
      ```
- [ ] The secrets above are in Infisical's `prod` environment.
- [ ] The ffmpeg worker on the mini runs `ffmpeg-full` (libwebp, zscale), per its `config.env`.
- [ ] The image has been built (universe merged to `main`, or **Deploy Server App** →
      `projects/janktm/service`). Until then the pod is in `ImagePullBackOff`.

## Using it

```sh
# scan everything (or one album: ?album=<folder name>), then follow it
curl -s -X POST -H "Authorization: Bearer $API_TOKEN" https://janktm.wuguishifu.dev/api/scans
curl -s -H "Authorization: Bearer $API_TOKEN" https://janktm.wuguishifu.dev/api/scans/<scanId>

# regenerate derivatives, e.g. every video's hover loop after changing its preset
curl -s -X POST -H "Authorization: Bearer $API_TOKEN" -H 'content-type: application/json' \
  -d '{"kind":"video","derivatives":["hover"]}' https://janktm.wuguishifu.dev/api/items/reprocess

kubectl -n janktm-service logs -f deploy/janktm-service
```
