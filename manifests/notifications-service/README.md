# notifications-service

notifications-service (universe `platform/notifications/service`) sends push notifications to the
phones running notifications-mobile. A notification is a job on the `notifications-queue:notifications-send`
queue in the shared Redis: in-cluster apps add it directly with `NotificationsClient`'s `queue`
transport, and anything else on the tailnet POSTs it to `/api/notifications` (the `http` transport,
and universe `tools/scripts/notifications`). The worker in the same pod reads the devices subscribed
to the notification's channel from `convex-app`'s prod deployment and sends through Expo's push
service. 15 minutes later a job on `notifications-queue:notifications-receipts` checks delivery and
removes devices whose app was uninstalled.

The phones register themselves in Convex, not here, so they never need to reach this service.

It's reachable from the tailnet at `https://notifications.wuguishifu.dev`, and in-cluster at
`http://notifications-service.notifications-service.svc.cluster.local`. Every route but
`/api/health` and `/api/version` needs `Authorization: Bearer <API_TOKEN>`.

Image Updater pins the `notifications-service` image's digest, so publishing a new image (merging to
universe `main`, or **Deploy Server App** → `platform/notifications/service`) rolls it out.

## Secrets

Infisical `universe` project, `prod` environment. The app reads the same paths as its
`secretsPaths` in universe (`environment-config.json`), plus `/platform/convex/app` for prod
Convex's URL, each synced to its own Secret and loaded in this order, so a key in a later path
wins:

| Path                              | Secret                          | Keys                                                            |
| --------------------------------- | ------------------------------- | --------------------------------------------------------------- |
| `/platform/redis`                 | `notifications-service-redis`   | `REDIS_URL`                                                     |
| `/platform/convex/app`            | `notifications-service-convex`  | `CONVEX_URL`                                                    |
| `/platform/notifications/service` | `notifications-service-secrets` | `API_TOKEN`, `NOTIFICATIONS_CONVEX_SECRET`, `EXPO_ACCESS_TOKEN` |

- `API_TOKEN` is what HTTP callers send. Put the same value in `/platform/notifications/client` as
  `NOTIFICATIONS_SERVICE_API_TOKEN`, next to `NOTIFICATIONS_SERVICE_URL=https://notifications.wuguishifu.dev`;
  that's the group callers list in their `secretsPaths`.
- `NOTIFICATIONS_CONVEX_SECRET` is a random string (`openssl rand -hex 32`) that must match the prod
  deployment's env var. It's different from `NOTIFICATIONS_DEVICE_SECRET`, which is built into the
  app and only lets a phone register itself.
- `EXPO_ACCESS_TOKEN` is an Expo access token; the Expo project has enhanced push security on, so
  sends without it are rejected.

## Before the first deploy

- [ ] `convex-app` (universe `platform/convex/app`) is deployed to prod, with both secrets set:
      `pnpm nx convex convex-app -- env set NOTIFICATIONS_CONVEX_SECRET <value> --prod`, and the same
      for `NOTIFICATIONS_DEVICE_SECRET`.
- [ ] The secrets above are in Infisical's `prod` environment.
- [ ] The image has been built (universe merged to `main`, or **Deploy Server App** →
      `platform/notifications/service`). Until then the pod is in `ImagePullBackOff`.

## Checking it

```sh
kubectl -n notifications-service logs -f deploy/notifications-service
curl -s https://notifications.wuguishifu.dev/api/health

# from universe, with tools/scripts/notifications/.env.local pointing here
node tools/scripts/notifications/send.mjs "Hello from sol"
```

Each send logs `Sent "<title>" to <n>/<m> device(s), tickets: …`. `0/0` means no device is
registered in prod Convex for that channel, or every device has it muted.
