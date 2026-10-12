# clipper-service

clipper-service (universe `projects/clipper/service`) finds the moments worth posting in Medal
clips. A run is a batch of clips analyzed with the same options: it's created over HTTP, each clip
becomes a job on the `clipper-queue:analyze` queue in the shared Redis, and the worker (in the same
pod, 6 at a time) downloads the clip's proxy from Garage, cuts it with ffmpeg and asks Gemini for
timestamps. Runs, clip jobs and results live in `convex-app`'s prod deployment; tracking events go
to analytics-service.

It's reachable from the tailnet at `https://clipper.wuguishifu.dev` (for the backlog scripts in
universe `tools/scripts/media`, and later the Windows client), and in-cluster at
`http://clipper-service.clipper-service.svc.cluster.local`. Every route but `/api/health` and
`/api/version` needs `Authorization: Bearer <API_TOKEN>`.

Image Updater pins the `clipper-service` image's digest, so publishing a new image (merging to
universe `main`, or **Deploy Server App** → `projects/clipper/service`) rolls it out.

ffmpeg comes from `media-tools` (needs libx264 and aac; the service checks on startup). Gemini
spend is capped per UTC day by `CLIPPER_DAILY_SPEND_LIMIT_USD` in the ConfigMap; once it's reached,
clip jobs wait for the next day rather than failing.

## Secrets

Infisical `universe` project, `prod` environment. The app reads the same paths as its
`secretsPaths` in universe (`environment-config.json`), plus `/platform/convex/app` for prod
Convex's URL, each synced to its own Secret and loaded in this order, so a key in a later path
wins:

| Path                         | Secret                             | Keys                                                                                          |
| ---------------------------- | ---------------------------------- | --------------------------------------------------------------------------------------------- |
| `/platform/gemini`           | `clipper-service-gemini`           | `GEMINI_API_KEY`                                                                              |
| `/platform/s3`               | `clipper-service-s3`               | `S3_ENDPOINT`, `S3_REGION`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY`, `S3_FORCE_PATH_STYLE` |
| `/platform/analytics/client` | `clipper-service-analytics-client` | `ANALYTICS_SERVICE_API_TOKEN`                                                                 |
| `/platform/redis`            | `clipper-service-redis`            | `REDIS_URL`                                                                                   |
| `/platform/convex/app`       | `clipper-service-convex`           | `CONVEX_URL`                                                                                  |
| `/projects/clipper/service`  | `clipper-service-secrets`          | `API_TOKEN`, `CLIPPER_CONVEX_SECRET`                                                          |

- `S3_ENDPOINT` stays the tailnet one (`https://s3-dev.wuguishifu.dev`), not Garage's in-cluster
  address: the service also hands out presigned upload URLs, which have to work from outside.
- The S3 key needs read and write on the `clipper` bucket (`CLIPPER_S3_BUCKET`, default
  `clipper`; see `GARAGE.md`).
- `CONVEX_URL` comes from `/platform/convex/app`, `convex-app`'s prod variables, so it follows the
  prod deployment. `CLIPPER_CONVEX_SECRET` is a random string (`openssl rand -hex 32`) that must
  match the prod deployment's env var.
- `API_TOKEN` is what callers send; the scripts read it from their own `.env.local`.

## Before the first deploy

- [ ] `convex-app` (universe `platform/convex/app`) is deployed to prod, with
      `CLIPPER_CONVEX_SECRET` set: `pnpm nx convex convex-app -- env set CLIPPER_CONVEX_SECRET <value> --prod`.
- [ ] The `clipper` bucket exists in Garage and the `/platform/s3` key can read and write it.
- [ ] The secrets above are in Infisical's `prod` environment.
- [ ] The image has been built (universe merged to `main`, or **Deploy Server App** →
      `projects/clipper/service`). Until then the pod is in `ImagePullBackOff`.

## Checking it

```sh
kubectl -n clipper-service logs -f deploy/clipper-service
curl -s https://clipper.wuguishifu.dev/api/health
curl -s -H "Authorization: Bearer $API_TOKEN" https://clipper.wuguishifu.dev/api/runs/<runId>
```
