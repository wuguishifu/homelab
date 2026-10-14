# Beszel

Resource monitoring for sol at `https://beszel.wuguishifu.dev` (tailnet only, like everything on
`*.wuguishifu.dev`): CPU, memory, disk usage and I/O, network, load and temperatures, with history
charts up to 30 days and optional alerts.

Two Deployments run here. `beszel-hub` is the web UI and keeps the metric history in SQLite on the
`beszel-data` PVC. `beszel-agent` runs on sol's host network and connects out to the hub over
WebSocket. It reports the host only, not individual pods (Beszel's container stats need Docker or
Podman, and k3s uses containerd). For a per-pod view, use `kubectl top pods -A`.

To upgrade, bump the image tag in `hub.yaml` and `agent.yaml` together.

## Setup

1. Push. The hub starts and the agent sits in `CreateContainerConfigError` until its secret exists.
2. Open `https://beszel.wuguishifu.dev` and create the admin account.
3. Click **Add System**, name it `sol`, enter `sol` as the host (unused: the hub never dials
   agents) and copy the **Public Key** and **Token** from the dialog. Save the system.
4. Add both to Infisical (below). Within a minute the operator syncs `beszel-secrets`, the agent
   starts and `sol` turns green in the hub.

## Secrets

Infisical `homelab` project, `prod` environment, `/beszel` (→ `beszel-secrets`):

| Key     | Description                                                                   |
| ------- | ----------------------------------------------------------------------------- |
| `KEY`   | The hub's public key (`ssh-ed25519 ...`). The agent only accepts this hub     |
| `TOKEN` | The system's registration token, from **Add System** or the system's settings |

The key pair is generated on the hub's first start and stored on its PVC. If the PVC is lost, the
new hub has a new key: update `KEY` (and `TOKEN`, after re-adding the system) in Infisical.

## Checking it

```sh
kubectl -n beszel get pods
kubectl -n beszel logs deploy/beszel-agent   # "Detected disk" and "WebSocket connected"
kubectl -n beszel logs deploy/beszel-hub
```
