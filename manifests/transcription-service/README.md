# transcription-service (interface)

transcription-service, the speech-to-text service (universe `platform/transcription/service`),
runs natively on the Mac mini (see [`hosts/mini`](../../hosts/mini)) because whisper needs Apple
Silicon's GPU. This directory doesn't run it; it gives in-cluster callers a stable address for it:

```
pod ──► http://transcription-service.transcription-service.svc.cluster.local
          ──► transcription-service-proxy (nginx) ──► 100.81.149.1:3002
                                                        (bos-mac-mini, over Tailscale)
```

- `service.yaml`: the in-cluster address.
- `deployment.yaml` + `configmap.yaml`: nginx forwarding to the mini's Tailscale IP. Pods can
  reach tailnet IPs through sol, but can't resolve MagicDNS names, hence the IP.

Why a proxy instead of a selector-less Service with a hand-written EndpointSlice: Argo CD
excludes `Endpoints` and `EndpointSlice` resources by default, so it silently never applies them.

Callers still need the service's API token (`API_TOKEN`, Infisical `universe` prod
`/platform/transcription/service`). The proxy is only ready while the mini answers `/api/health`,
so if the mini is down, callers get an immediate connection error rather than a timeout.

## Checking it

```sh
sudo kubectl -n transcription-service logs -f deploy/transcription-service-proxy   # one line per request, with timings
sudo kubectl -n transcription-service run curl --rm -it --image=curlimages/curl:8.22.0 -- \
  curl -s http://transcription-service/api/health
```

To point at a different host, change `proxy_pass` in `configmap.yaml` and bump `config-version`
in `deployment.yaml` (nginx only reads its config at startup).
