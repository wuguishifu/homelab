#!/bin/sh
# Backs up each repository that changed since its last backup, then the database, to the
# production Garage. Everything is encrypted with age to AGE_RECIPIENT; the private key is not in
# the cluster. See README.md for the layout and how to restore.
set -euo pipefail

apk add --no-cache git age aws-cli >/dev/null

export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="$S3_REGION"
# Newer aws-cli versions send checksums Garage doesn't accept.
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
aws configure set default.s3.addressing_style path

# The repositories belong to Forgejo's uid 1000, and git won't read them as root without this.
git config --global --add safe.directory '*'

s3() { aws --endpoint-url "$S3_ENDPOINT" "$@"; }

# Keys under a prefix, oldest first (each name starts with a UTC timestamp).
list() {
  s3 s3api list-objects-v2 --bucket "$S3_BUCKET" --prefix "$1" --query 'Contents[].Key' --output text |
    tr '\t' '\n' | sed '/^None$/d' | sort
}

# Deletes all but the newest $2 keys under $1.
prune() {
  keep=$2
  set -- $(list "$1")
  while [ $# -gt "$keep" ]; do
    s3 s3 rm "s3://$S3_BUCKET/$1"
    shift
  done
}

stamp=$(date -u +%Y%m%dT%H%M%SZ)
bundle=/work/repo.bundle

cd "$REPO_ROOT"
# owner/name.git, and owner/name.wiki.git for wikis.
for repo in */*.git; do
  [ -d "$repo" ] || continue
  name=${repo%.git}
  refs=$(git -C "$repo" for-each-ref --format='%(objectname) %(refname)')
  if [ -z "$refs" ]; then
    echo "$name: empty, skipping"
    continue
  fi

  # Same refs pointing at the same commits means nothing to back up.
  fingerprint=$(printf '%s\n' "$refs" | sha256sum | cut -c1-16)
  prefix="repos/$name/"
  case "$(list "$prefix" | tail -n 1)" in
    *"-$fingerprint.bundle.age")
      echo "$name: unchanged"
      continue
      ;;
  esac

  echo "$name: backing up"
  git -C "$repo" bundle create "$bundle" --all
  git -C "$repo" bundle verify --quiet "$bundle"
  age -r "$AGE_RECIPIENT" "$bundle" | s3 s3 cp - "s3://$S3_BUCKET/$prefix$stamp-$fingerprint.bundle.age"
  rm "$bundle"
  prune "$prefix" "$KEEP_REPO_BACKUPS"
done

echo "database: backing up"
PGPASSWORD="$DB_PASSWORD" pg_dump -h "$DB_HOST" -U forgejo --format=custom forgejo |
  age -r "$AGE_RECIPIENT" | s3 s3 cp - "s3://$S3_BUCKET/db/$stamp.dump.age"
prune db/ "$KEEP_DB_BACKUPS"
