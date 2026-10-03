# analytics-service

analytics-service (universe `platform/analytics/service`) takes tracking events from other
universe services and writes them to the `universe` database. It's in-cluster only, at
`http://analytics-service.analytics-service.svc.cluster.local`, with no Ingress or tunnel route.

Image Updater pins the `analytics-service` image's digest, so publishing a new image
(**Deploy Server App** → `analytics/service` in universe) rolls it out.

It deploys in wave 5, after `universe-db` (wave 4), whose migration Job has to complete before that
app is Healthy. That ordering only applies when the root app syncs everything, e.g. a fresh
bootstrap. Day to day the two images ship independently, so migrations have to work with the
service code that's already running (see [`universe-db`](../universe-db/README.md)).

## Secrets

Infisical `universe` project, `prod` environment, `/platform/analytics/service`
(→ `analytics-service-secrets`):

| Key                             | Description                                                                                |
| ------------------------------- | ------------------------------------------------------------------------------------------ |
| `API_TOKEN`                     | Bearer token callers send. Callers keep a copy, e.g. jankbot-core's `ANALYTICS_SERVICE_API_TOKEN` |
| `UNIVERSE_DB_CONNECTION_STRING` | `postgresql://…@postgresql.databases.svc.cluster.local:5432/universe`                     |

## Checking it

```sh
kubectl -n analytics-service logs -f deploy/analytics-service
kubectl -n analytics-service run curl --rm -it --restart=Never --image=curlimages/curl:8.22.0 -- \
  curl -s http://analytics-service/api/health
```
