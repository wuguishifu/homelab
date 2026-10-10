#!/bin/bash
# Runs before every transcription-worker start (see run-service.sh).
#   - Makes $WHISPER_MODELS_DIR match models.txt: downloads missing or corrupt models, deletes
#     unlisted ones, and fails if WHISPER_MODELS names a model that models.txt doesn't download.
#   - When DIARIZER_PATH is set and the release has a diarizer: installs it into DIARIZER_PATH's
#     venv and downloads pyannote's model at PYANNOTE_REVISION into DIARIZER_MODEL_DIR.
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

# --- diarizer -------------------------------------------------------------------------------
release_diarizer="$(dirname "$SERVICE_DATA")/current/diarizer"
if [ -n "${DIARIZER_PATH:-}" ] && [ -d "$release_diarizer" ]; then
  : "${DIARIZER_MODEL_DIR:?} ${PYANNOTE_REVISION:?}"
  venv=${DIARIZER_PATH%/bin/diarize}
  [ "$venv" != "$DIARIZER_PATH" ] || { echo "diarizer: DIARIZER_PATH must end in /bin/diarize" >&2 && exit 1; }

  # A no-op unless the release's lockfile changed.
  UV_PROJECT_ENVIRONMENT="$venv" uv sync --project "$release_diarizer" \
    --frozen --no-dev --no-editable --compile-bytecode --quiet
  # The first import after an install takes ~30s (macOS checks the new native libraries), so pay
  # it here rather than in the first job. ~1s once it's warm.
  "$venv/bin/python" -c 'import torch, pyannote.audio' 2> /dev/null

  if [ "$(cat "$DIARIZER_MODEL_DIR/.revision" 2> /dev/null)" != "$PYANNOTE_REVISION" ]; then
    echo "diarizer: downloading pyannote/speaker-diarization-community-1@$PYANNOTE_REVISION"
    : "${HF_TOKEN:?is needed to download the pyannote model (Infisical /platform/huggingface)}"
    rm -rf "$DIARIZER_MODEL_DIR.part"
    "$venv/bin/hf" download pyannote/speaker-diarization-community-1 \
      --revision "$PYANNOTE_REVISION" --local-dir "$DIARIZER_MODEL_DIR.part" --quiet > /dev/null
    echo "$PYANNOTE_REVISION" > "$DIARIZER_MODEL_DIR.part/.revision"
    rm -rf "$DIARIZER_MODEL_DIR"
    mv "$DIARIZER_MODEL_DIR.part" "$DIARIZER_MODEL_DIR"
  fi
fi
