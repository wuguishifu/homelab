#!/bin/sh
# Imports every Gogs repository you can see into Forgejo under the same owner and name, with its
# issues, labels, milestones and wiki (not LFS). Run it from a machine with kubectl access:
#
#   GOGS_TOKEN=... FORGEJO_TOKEN=... ./migrate-from-gogs.sh
#
# GOGS_TOKEN: Gogs → Your Settings → Applications → Generate New Token.
# FORGEJO_TOKEN: an admin's token with write:repository,write:organization,read:user (README.md).
#
# Repositories already in Forgejo are skipped, so it's safe to re-run (delete a failed import in
# Forgejo first, or it's skipped too). Owners that don't exist in Forgejo are created as private
# organizations; your own user has to exist already, with the same username as in Gogs.
set -eu

: "${GOGS_TOKEN:?}" "${FORGEJO_TOKEN:?}"
FORGEJO=${FORGEJO:-https://git.wuguishifu.dev}
# Forgejo calls Gogs' API here (it's in [migrations] ALLOWED_DOMAINS), but clones from the URL Gogs
# reports, so Gogs' EXTERNAL_URL has to point here too while this runs (README.md).
GOGS_INTERNAL=http://gogs.gogs.svc.cluster.local:3000

# Gogs' Ingress is behind Authelia, so list its repositories through a port-forward.
kubectl -n gogs port-forward svc/gogs 3001:3000 >/dev/null &
trap 'kill $!' EXIT
sleep 3

forgejo() {
  curl -sS -H "Authorization: token $FORGEJO_TOKEN" -H 'Content-Type: application/json' "$@"
}
# POSTs $2 to $1 and stops with Forgejo's error if it fails.
post() {
  if ! out=$(forgejo --fail-with-body "$FORGEJO/api/v1/$1" -d "$2"); then
    echo "$out" >&2
    exit 1
  fi
}
exists() {
  [ "$(forgejo -o /dev/null -w '%{http_code}' "$FORGEJO/api/v1/$1")" = 200 ]
}

curl -sSf -H "Authorization: token $GOGS_TOKEN" http://localhost:3001/api/v1/user/repos |
  jq -r '.[] | "\(.owner.username) \(.name)"' |
  while read -r owner name; do
    if exists "repos/$owner/$name"; then
      echo "$owner/$name: already in Forgejo"
      continue
    fi
    if ! exists "users/$owner"; then
      echo "$owner: creating organization"
      post orgs "$(jq -n --arg o "$owner" '{username: $o, visibility: "private"}')"
    fi

    echo "$owner/$name: migrating"
    post repos/migrate "$(jq -n \
      --arg addr "$GOGS_INTERNAL/$owner/$name.git" --arg token "$GOGS_TOKEN" \
      --arg owner "$owner" --arg name "$name" \
      '{clone_addr: $addr, auth_token: $token, service: "gogs", repo_owner: $owner, repo_name: $name,
        private: true, issues: true, labels: true, milestones: true, wiki: true, lfs: false}')"
  done
