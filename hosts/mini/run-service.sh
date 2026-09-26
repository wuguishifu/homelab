#!/bin/bash
# launchd entrypoint for a service defined in hosts/mini/services/<name>/:
#   1. loads config.env (non-secret app settings) and runs pre-start.sh, if any
#   2. starts the release in ~/.homelab/services/<name>/current with `node main.js`, with
#      secrets from Infisical when service.env sets INFISICAL_PATH
# Usage: run-service.sh <name>
set -euo pipefail

name="$1"
HOMELAB_HOME="${HOMELAB_HOME:-$HOME/.homelab}"
svc_src="$HOMELAB_HOME/repo/hosts/mini/services/$name"
svc_home="$HOMELAB_HOME/services/$name"

export PATH="/opt/homebrew/opt/node@22/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# Services keep persistent files (e.g. models) here; config.env can refer to it.
export SERVICE_DATA="$svc_home/data"

# service.env holds host-side settings (Infisical location, hook settings). It's read in a
# subshell where needed so none of it leaks into the app's environment.
read_service_env() {
  # shellcheck source=/dev/null
  (. "$svc_src/service.env" && eval "echo \"\${$1:-}\"")
}

load_config() {
  set -a
  # shellcheck source=/dev/null
  . "$svc_src/config.env"
  set +a
}

echo "--- $(date '+%Y-%m-%dT%H:%M:%S') starting $name ($(readlink "$svc_home/current"))"

if [ -f "$svc_src/pre-start.sh" ]; then
  (load_config && HF_REVISION=$(read_service_env HF_REVISION) /bin/bash "$svc_src/pre-start.sh")
fi

cd "$svc_home/current"

infisical_path=$(read_service_env INFISICAL_PATH)
if [ -z "$infisical_path" ]; then
  load_config
  exec node main.js
fi

infisical_domain=$(read_service_env INFISICAL_DOMAIN)
# Machine identity credentials stay in this subshell; only the short-lived token comes out.
token=$(
  # shellcheck source=/dev/null
  . "$HOMELAB_HOME/credentials.env"
  infisical login --method=universal-auth \
    --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" \
    --domain="$infisical_domain" --plain --silent
)

# config.env is loaded after the secrets are injected, so its values win over Infisical's
# (e.g. REDIS_URL pointing at this machine's Redis instead of the cluster's).
# shellcheck disable=SC2016 # $1 is expanded by the inner bash
exec infisical run \
  --domain="$infisical_domain" \
  --token="$token" \
  --projectId="$(read_service_env INFISICAL_PROJECT_ID)" \
  --env="$(read_service_env INFISICAL_ENV)" \
  --path="$infisical_path" \
  --silent \
  -- /bin/bash -c 'set -a; . "$1"; set +a; exec node main.js' run-service "$svc_src/config.env"
