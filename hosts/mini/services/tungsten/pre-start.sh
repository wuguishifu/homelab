#!/bin/bash
# Runs before every tungsten start (see run-service.sh). Makes $WHISPER_MODELS_DIR match
# models.txt: downloads missing or corrupt models, deletes unlisted ones, and fails if
# WHISPER_MODELS names a model that models.txt doesn't download.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
: "${WHISPER_MODELS_DIR:?} ${WHISPER_MODELS:?} ${HF_REVISION:?}"
base="https://huggingface.co/ggerganov/whisper.cpp/resolve/$HF_REVISION"
mkdir -p "$WHISPER_MODELS_DIR"
listed=" "

while read -r name sha _; do
  case "$name" in '' | '#'*) continue ;; esac
  listed="$listed$name "
  file="$WHISPER_MODELS_DIR/ggml-$name.bin"
  if [ -f "$file" ] && echo "$sha  $file" | shasum -a 256 -c -s -; then
    continue
  fi
  echo "models: downloading $name"
  curl -fsSL --retry 5 --retry-delay 5 -o "$file.part" "$base/ggml-$name.bin"
  echo "$sha  $file.part" | shasum -a 256 -c -s -
  mv "$file.part" "$file"
done < "$here/models.txt"

for file in "$WHISPER_MODELS_DIR"/*; do
  [ -e "$file" ] || continue
  name=$(basename "$file")
  name=${name#ggml-}
  name=${name%.bin}
  case "$listed" in *" $name "*) ;; *) echo "models: removing $file" && rm -f "$file" ;; esac
done

for model in $(echo "$WHISPER_MODELS" | tr ',' ' '); do
  case "$listed" in
    *" $model "*) ;;
    *) echo "models: WHISPER_MODELS lists $model, but models.txt doesn't" >&2 && exit 1 ;;
  esac
done
