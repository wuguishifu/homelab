# thermo-automation

thermo-automation (universe `projects/thermo-automation/service`) automates the Daikin thermostats
at one house. Every 3 minutes (`TICK_INTERVAL_MINUTES`) it reads each thermostat through the Daikin
One integrator API, records the reading in the `universe` database and runs the automations
against it, switching thermostats between AUTO and OFF. The same pod serves the SPA, with live
updates over Server-Sent Events on `/api/stream`. How the automations decide is in the service's
README in universe.

It's reachable from the tailnet at `https://thermo.wuguishifu.dev`, behind Authelia's forward-auth
(the app has no login of its own; see `manifests/authelia/README.md`). A Cloudflare Tunnel route
straight to the Service would skip that login, so a public route has to go through Traefik.

Image Updater pins the `thermo-automation-service` image's digest, so publishing a new image
(merging to universe `main`, or **Deploy Server App** → `projects/thermo-automation/service`)
rolls it out. It runs as one replica with `Recreate` rollouts, since two pods would both control
the same thermostats.

Its tables are in the `thermo` schema of the `universe` database, created by universe-db's
migrations (wave 4), which is why this app is in wave 5. The house, its timezone and °F/°C are
picked in the app's settings and stored there too, not in this repo.

## Secrets

Infisical `universe` project, `prod` environment. The app reads the same paths as its
`secretsPaths` in universe (`environment-config.json`), each synced to its own Secret and loaded in
this order, so a key in a later path wins:

| Path                                  | Secret                               | Keys                                                 |
| ------------------------------------- | ------------------------------------ | ---------------------------------------------------- |
| `/platform/analytics/client`          | `thermo-automation-analytics-client` | `ANALYTICS_SERVICE_API_TOKEN`                        |
| `/platform/postgres`                  | `thermo-automation-postgres`         | `UNIVERSE_DB_CONNECTION_STRING`                      |
| `/projects/thermo-automation/service` | `thermo-automation-secrets`          | `DAIKIN_API_KEY`, `DAIKIN_INTEGRATOR_TOKEN`, `EMAIL` |

`EMAIL` is the Daikin account the integrator token was issued for. The ConfigMap in
`deployment.yaml` sets `ANALYTICS_SERVICE_BASE_URL` (the in-cluster analytics-service) and
`TICK_INTERVAL_MINUTES`.

## Before the first deploy

This replaces the old Next.js app (`ghcr.io/wuguishifu/thermo-automation`, with its curl CronJobs
and migration init container) in place, on the same namespace and hostname.

- [ ] `DAIKIN_API_KEY`, `DAIKIN_INTEGRATOR_TOKEN` and `EMAIL` are in the universe project at
      `/projects/thermo-automation/service` (`prod`). The Daikin keys are the same ones the old app
      read from the homelab project's `/thermo-automation`.
- [ ] universe-db has run the `0005_thermo_automation` migration (the `universe-db-migrations`
      image published from the same universe merge).
- [ ] The `thermo-automation-service` image has been built.
- [ ] The old app's automations are written down: they aren't migrated, and need entering again
      in the new app once it's up.

After the sync, the old app's pod, CronJobs and Service are pruned, and `thermo-automation-secrets`
is repointed at the universe path. Thermostats aren't automated from then until the automations
are entered again.

## After cutover

Once the new app is working, these are only used by the old one:

- the old app's database (its `DATABASE_URL` in the homelab project's `/thermo-automation`)
- the homelab project's `/thermo-automation` path in Infisical
- the `ghcr.io/wuguishifu/thermo-automation` and `thermo-automation-migration` images

## Checking it

```sh
kubectl -n thermo-automation logs -f deploy/thermo-automation
curl -s https://thermo.wuguishifu.dev/api/status
curl -sN https://thermo.wuguishifu.dev/api/stream   # a snapshot event, then pings every 25s
```

`/api/status` shows the last tick, and `lastError` says what failed (a Daikin call, the database).
Every write to a thermostat is also recorded as a `thermo_automation-action` event, and failed ticks
as `thermo_automation-tick_failed`.
