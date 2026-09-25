# Tungsten

Media worker service from the [universe](https://github.com/wuguishifu/universe) monorepo
(`apps/tungsten`). Other apps send it audio over HTTP and get transcripts back; see the app's
README for the API. In-cluster only, at `http://tungsten.tungsten.svc.cluster.local`.

## Layout

One image (`ghcr.io/wuguishifu/universe/tungsten`), two Deployments, split by `TUNGSTEN_ROLE`:

| Deployment        | Role     | Service | Notes                                                      |
| ----------------- | -------- | ------- | ---------------------------------------------------------- |
| `tungsten`        | `api`    | yes     | Validates requests, queues them in Redis, returns results  |
| `tungsten-worker` | `worker` | none    | Runs ffmpeg + whisper for both lanes; mounts the model PVC |

sol is a 4-core Intel N100 whose other pods use about 0.3 cores. The worker runs 2 whisper
threads per lane and may use all 4 cores when both lanes are busy; the other pods' CPU requests
keep their share (see comments in `configmap.yaml` and `worker-deployment.yaml`).

They only talk through Redis (BullMQ, prefix `tungsten-queue`), so the worker can later move
to other hardware (a GPU node, or natively on a Mac over Tailscale) without changing callers.

## Models

The worker's `fetch-models` init container keeps the `tungsten-models` PVC in sync with
`models.txt` in [`configmap.yaml`](./configmap.yaml): each model is pinned to a Hugging Face
commit (`HF_REVISION`) and verified by SHA-256. On start it downloads missing or corrupt
models, deletes unlisted ones, and does nothing if everything already matches.

To add a model:

1. Uncomment (or add) its line in `models.txt`. For a model not listed there, the SHA-256 is the
   `oid` in `https://huggingface.co/ggerganov/whisper.cpp/raw/<HF_REVISION>/ggml-<name>.bin`.
2. Add it to `WHISPER_MODELS` in the same file so callers can request it.
3. Push. The worker restarts and downloads it; the init container fails if step 2 names a model
   step 1 doesn't download.

## Secrets

Add these to Infisical under the `universe` project, `prod` environment, path `/tungsten`:

| Key                                                       | Description                                                                |
| --------------------------------------------------------- | -------------------------------------------------------------------------- |
| `TUNGSTEN_API_TOKEN`                                      | Bearer token callers send (`openssl rand -hex 32`); give it to each caller |
| `REDIS_URL`                                               | `redis://:<password>@redis-master.databases.svc.cluster.local:6379`        |
| `S3_ENDPOINT`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | Optional, only for `s3` audio sources: a read-only Garage key              |

Don't set `TUNGSTEN_ROLE` or `TUNGSTEN_WORKER_LANES` in Infisical: each Deployment sets its own,
and a Deployment's `env` would override them anyway.

## Before the first deploy

- [ ] Prod secrets above exist in Infisical.
- [ ] The tungsten image has been built at least once (`build-server-app.yml`, app `tungsten`).
- [ ] The GHCR package can be pulled. It's private, like silver's; sol pulls private GHCR images
      with the credentials in `/etc/rancher/k3s/registries.yaml`.
- [ ] After it's up, check the worker log's realtime factor on a short clip
      (`kubectl -n tungsten logs deploy/tungsten-worker`) to see what the N100 actually does. The
      image's CPU build already uses AVX2/FMA/F16C, which sol supports. If it's too slow, trade
      threads between lanes in `configmap.yaml` or keep interactive on `base.en`.

## Checking it from inside the cluster

```sh
kubectl -n tungsten run curl --rm -it --image=curlimages/curl:8.22.0 -- \
  curl -s http://tungsten/api/health
```
