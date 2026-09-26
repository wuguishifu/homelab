# Tungsten (interface)

Tungsten, the speech-to-text service, runs natively on the Mac mini (see
[`hosts/mini`](../../hosts/mini)) because whisper needs Apple Silicon's GPU. This directory
doesn't run it; it gives in-cluster callers a stable address for it:

```
pod ──► http://tungsten.tungsten.svc.cluster.local ──► 100.81.149.1:3002 (bos-mac-mini, over Tailscale)
```

- `service.yaml`: a Service with no selector, so Kubernetes doesn't look for pods.
- `endpointslice.yaml`: the mini's Tailscale IP, listed by hand.

Callers still need tungsten's API token (`TUNGSTEN_API_TOKEN`, Infisical `universe` prod `/tungsten`).

If the mini is down, requests fail to connect; there's no fallback endpoint.

## Checking it

```sh
sudo kubectl -n tungsten run curl --rm -it --image=curlimages/curl:8.22.0 -- \
  curl -s http://tungsten/api/health
```
