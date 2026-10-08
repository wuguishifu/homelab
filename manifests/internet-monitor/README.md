# internet-monitor

internet-monitor (universe `projects/internet-monitor/service`) records when the apartment's
internet goes out, as evidence for the ISP. Every 15s it opens TCP connections to public resolvers
(1.1.1.1, 8.8.8.8, 9.9.9.9 on 443) and to the router (`GATEWAY_HOST`). Two failed checks in a row
open an incident; the first successful check closes it. Events go to analytics-service and land in
the `universe` database:

| Event                         | When                                                                     |
| ----------------------------- | ------------------------------------------------------------------------ |
| `internet_outage-started`     | No resolver reachable. `gatewayUp: true` means the router was still up   |
| `internet_outage-ended`       | A resolver is reachable again. Carries `durationMs`                      |
| `gateway_outage-started`      | The router stopped answering                                             |
| `gateway_outage-ended`        | The router answers again                                                 |
| `internet_monitor-heartbeat`  | Every 5 minutes, so gaps without events can be told apart from downtime  |

A start and its end share `properties.reconciliationId`. The open incident is kept in Redis, so a
restart mid-outage still records the end (with `restoredIncident: true`).

Image Updater pins the `internet-monitor-service` image's digest, so publishing a new image
(**Deploy Server App** → `projects/internet-monitor/service` in universe) rolls it out. It runs as
one replica with `Recreate` rollouts, since two pods would both track the same incidents.

Nothing has inbound traffic: the HTTP server (3006) only serves the kubelet's health probes, so
there's no Service.

## Secrets

Infisical `universe` project, `prod` environment. The app reads the same paths as its
`secretsPaths` in universe (`environment-config.json`), each synced to its own Secret and loaded in
that order, so a key in a later path wins:

| Path                                 | Secret                              | Keys                          |
| ------------------------------------ | ----------------------------------- | ----------------------------- |
| `/platform/redis`                    | `internet-monitor-redis`            | `REDIS_URL`                   |
| `/platform/analytics/client`         | `internet-monitor-analytics-client` | `ANALYTICS_SERVICE_API_TOKEN` |
| `/projects/internet-monitor/service` | `internet-monitor-secrets`          | `GATEWAY_HOST`                |

`REDIS_URL` uses `redis.wuguishifu.dev`, which CoreDNS rewrites to the in-cluster Redis (see
`coredns-config`). `GATEWAY_HOST` is the router's LAN address, `10.21.164.1`; sol is
`10.21.164.12` on the same subnet, so the pod reaches it through the node. `GATEWAY_PORT` defaults
to 80, and a refused connection counts as up, so any port the router answers on works.

The ConfigMap in `deployment.yaml` only sets `ANALYTICS_SERVICE_BASE_URL`, the in-cluster
analytics-service.

## Checking it

```sh
kubectl -n internet-monitor logs -f deploy/internet-monitor
```

The first heartbeat after startup should have `gatewayUp: true`; if not, the pod can't reach the
router.
