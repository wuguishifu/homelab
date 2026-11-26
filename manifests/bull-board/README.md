# Bull Board

A UI for the BullMQ queues in the shared Redis, at `https://bull.wuguishifu.dev` (tailnet
only, behind Authelia's two-factor login). It runs the official `ghcr.io/felixmosh/bull-board`
image, which finds queues itself: every `<prefix>:<queue>:meta` key under the prefixes in
`BULL_BOARD_PREFIX` (`deployment.yaml`), rescanned every 30 seconds. A new queue under a known
prefix shows up without a restart. A new prefix has to be added to that list, since it takes no
wildcards.

| Prefix                                         | Owner                                                              |
| ---------------------------------------------- | ------------------------------------------------------------------ |
| `jankbot-queue`                                | jankbot core, stitcher and gateways (incl. `voice-commands-<bot>`) |
| `clipper-queue`                                | clipper-service                                                    |
| `notifications-queue`                          | notifications-service and its clients                              |
| `transcription-worker-queue`                   | transcription-worker on the mini and its clients                   |
| `ffmpeg-worker-queue`                          | ffmpeg-worker on the mini and its clients                          |
| `tungsten-queue`, `ruby-queue`, `silver-queue` | other projects                                                     |

Infisical's own queues (prefix `bull`) are left out on purpose.

To list every prefix in use:

```sh
kubectl -n databases exec redis-master-0 -c redis -- sh -c \
  'REDISCLI_AUTH="$(cat $REDIS_PASSWORD_FILE)" redis-cli --scan --pattern "*:meta"' | cut -d: -f1 | sort -u
```

The board isn't read-only: it can retry, promote, clean and delete jobs. Authelia is the only
thing in front of it. Set `BULL_BOARD_READ_ONLY: "true"` in the ConfigMap to turn that off.

To upgrade, bump the image tag in `deployment.yaml`.

## Secrets

No secrets of its own. It reads `REDIS_URL` from the universe project's shared `/platform/redis`
(→ `bull-board-redis`, `manifests/infisical-secrets/bull-board.yaml`), the same URL the services
use. It points at `redis.wuguishifu.dev`, which CoreDNS rewrites to the in-cluster Redis. BullMQ
in universe ignores any database index in that URL, so the queues are always in DB 0. If the URL
ever gains a `/N`, the board would look in the wrong database.

## Checking it

```sh
kubectl -n bull-board get pods
kubectl -n bull-board logs deploy/bull-board   # discovered queues, Redis connection errors
```
