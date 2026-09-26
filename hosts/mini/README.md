# Mac mini (`mini`)

An Apple M4 Mac mini that runs services natively, outside Kubernetes, for work that needs
Apple Silicon (whisper on Metal is ~30–40x faster here than on sol's CPU). It follows the same
GitOps idea as the cluster: this directory is the desired state, and the mini pulls it.

```plaintext
universe CI (build-server-app)          this repo                      the mini
─────────────────────────────           ─────────                      ────────
builds <app>-vX.Y.Z image + a    ──►    services/<app>/release   ◄──  reconcile.sh, every minute
release bundle (.tar.gz)                 = "<app>-vX.Y.Z"               (launchd): pull, install,
                                                                         (re)start via launchd
```

## How it works

- **`reconcile.sh`** runs every minute (launchd job `dev.wuguishifu.homelab.reconcile`). It pulls
  this repo, and for each `services/<name>/`:
  - installs the release named in `release` from the
    [universe releases](https://github.com/wuguishifu/universe/releases) (the bundle is the app's
    Docker `/app` minus `node_modules`; it runs `pnpm install --prod`)
  - installs `Brewfile` dependencies
  - (re)starts the service as launchd job `dev.wuguishifu.homelab.svc.<name>` when anything in
    its directory changed

  Services whose directory is removed are stopped (their data is kept). If an install fails,
  the previous version keeps running. It only logs when it does something.

- **`run-service.sh`** is each service's launchd entrypoint: it runs `pre-start.sh`, then
  `node main.js` with secrets from Infisical plus `config.env` (which wins over Infisical).
- **launchd** restarts crashed services (within ~10s), starts everything at login, and on
  deploys sends SIGTERM and waits `EXIT_TIMEOUT` so in-flight work can finish.

Everything lives in `~/.homelab/` on the mini: `repo/` (this repo), `services/<name>/`
(`releases/`, `current` → the running release, `data/`), `logs/`, and `credentials.env`.

## A service directory

| File           | Purpose                                                                      |
| -------------- | ---------------------------------------------------------------------------- |
| `release`      | Release tag to run, e.g. `tungsten-v1.0.1`. Change it to deploy or roll back |
| `config.env`   | Non-secret app settings. Can use `$SERVICE_DATA` (the service's data dir)    |
| `service.env`  | Host-side settings: Infisical location, `EXIT_TIMEOUT`, hook settings        |
| `Brewfile`     | System dependencies (`brew bundle`)                                          |
| `pre-start.sh` | Optional; runs before every start (tungsten syncs its models here)           |

## Deploying

1. Build the app with universe's **Deploy Server App** workflow. It creates the
   `<app>-vX.Y.Z` release with the bundle attached.
2. Set `services/<app>/release` to that tag and push. The mini picks it up within a minute.

## Bootstrap (once)

1. **Mac settings:** FileVault off, automatic login, `sudo pmset -a sleep 0 autorestart 1`.
   `setup.sh` warns about any of these that are missing.
2. **Credentials:** create `~/.homelab/credentials.env` on the mini (`chmod 600`):

   ```sh
   # Infisical machine identity (Universal Auth) with read access to each service's secrets,
   # e.g. project `universe`, env `prod`, path `/tungsten`.
   INFISICAL_CLIENT_ID=...
   INFISICAL_CLIENT_SECRET=...
   # Fine-grained GitHub token: repository wuguishifu/universe only, Contents: read-only.
   # Used to download release bundles.
   GITHUB_TOKEN=...
   ```

   These are the only secrets not in Infisical, like the cluster's bootstrap secrets in
   `BOOTSTRAP.md`. Rotate them by editing the file; services pick them up on their next start.

3. **Run setup** on the mini:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/wuguishifu/homelab/main/hosts/mini/setup.sh | bash
   ```

   It installs `Brewfile` (Node 22, the Infisical CLI), clones this repo to `~/.homelab/repo`, and
   starts the reconciler.

## Operating

```sh
tail -f ~/.homelab/logs/reconcile.log                  # what the reconciler did
tail -f ~/.homelab/logs/<name>.log                     # a service's output
launchctl print gui/$(id -u)/dev.wuguishifu.homelab.svc.<name> | grep -E 'state|pid'
launchctl kickstart -k gui/$(id -u)/dev.wuguishifu.homelab.svc.<name>   # restart one service
bash ~/.homelab/repo/hosts/mini/reconcile.sh           # reconcile now instead of waiting
```

## Services

- **tungsten**: speech-to-text API (whisper.cpp on Metal) at `http://bos-mac-mini:3002` over
  Tailscale, with a local Redis for its queues. Callers need `TUNGSTEN_API_TOKEN`. It listens on
  all interfaces, so the token check is what protects it on the LAN.
