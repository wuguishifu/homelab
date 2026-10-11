#!/bin/bash
# launchd entrypoint for a service defined in hosts/mini/services/<name>/:
#   1. loads secrets from Infisical when service.env sets INFISICAL_PATHS
#   2. runs pre-start.sh, if any, with those secrets, the ones at PRE_START_INFISICAL_PATHS,
#      service.env and config.env
#   3. starts the release in ~/.homelab/services/<name>/current with `node main.js`, with the
#      INFISICAL_PATHS secrets and config.env
# Usage: run-service.sh <name>
set -euo pipefail

name="$1"
HOMELAB_HOME="${HOMELAB_HOME:-$HOME/.homelab}"
svc_src="$HOMELAB_HOME/repo/hosts/mini/services/$name"
svc_home="$HOMELAB_HOME/services/$name"

export PATH="/opt/homebrew/opt/node@24/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
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

cd "$svc_home/current"

infisical_paths=$(read_service_env INFISICAL_PATHS)
pre_start_infisical_paths=$(read_service_env PRE_START_INFISICAL_PATHS)
if [ -n "$infisical_paths$pre_start_infisical_paths" ]; then
  infisical_domain=$(read_service_env INFISICAL_DOMAIN)
  # Machine identity credentials stay in this subshell; only the short-lived token comes out.
  token=$(
    # shellcheck source=/dev/null
    . "$HOMELAB_HOME/credentials.env"
    infisical login --method=universal-auth \
      --client-id="$INFISICAL_CLIENT_ID" --client-secret="$INFISICAL_CLIENT_SECRET" \
      --domain="$infisical_domain" --plain --silent
  )
  project_id=$(read_service_env INFISICAL_PROJECT_ID)
  infisical_env=$(read_service_env INFISICAL_ENV)
fi

# Exports the secrets at each of the space-separated Infisical paths in $1, in order, so a key in a
# later path wins (like universe's secretsPaths). They only live in this process's environment,
# never on disk.
load_secrets() {
  local secrets_path exports
  for secrets_path in $1; do
    exports=$(
      infisical export \
        --domain="$infisical_domain" --token="$token" --projectId="$project_id" \
        --env="$infisical_env" --path="$secrets_path" --format=json --silent |
        jq -r '.[] | "export \(.key)=\(.value | @sh)"'
    )
    eval "$exports"
  done
}

load_secrets "$infisical_paths"

# After the secrets, so pre-start.sh can use them. It runs in a subshell so what only it needs
# stays out of the app's environment: service.env's host-side settings, and the secrets at
# PRE_START_INFISICAL_PATHS (e.g. a token to download gated models).
if [ -f "$svc_src/pre-start.sh" ]; then
  (
    set -a
    # shellcheck source=/dev/null
    . "$svc_src/service.env"
    set +a
    load_secrets "$pre_start_infisical_paths"
    load_config
    /bin/bash "$svc_src/pre-start.sh"
  )
fi

# config.env is loaded after the secrets, so its values win over Infisical's.
load_config
exec node main.js
