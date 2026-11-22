#!/bin/zsh
# Local neural TTS for voice mode: mlx-audio serving Kokoro-82M on :8880 (OpenAI-compatible /v1/audio/speech).
#   ./scripts/dev-tts.sh          # install (first run) + start in tmux session hermes-tts
#   ./scripts/dev-tts.sh stop
# Then Settings > Voice > Voice engine: Local server (defaults already point here).
# AIDEV-NOTE: misaki needs the spaCy en_core_web_sm wheel preinstalled; its runtime auto-download fails under uv
# venvs and the server then hangs the request forever (seen 2026-11-22). Warm render ~0.2 s per sentence on M-series.
set -euo pipefail
cd "$(dirname "$0")/.."
DIR=$PWD/dev/tts
SESSION=hermes-tts
if [[ ${1:-} == stop ]]; then tmux kill-session -t $SESSION 2>/dev/null && echo "stopped"; exit 0; fi

if [[ ! -x $DIR/venv/bin/mlx_audio.server ]]; then
  mkdir -p "$DIR"
  uv venv "$DIR/venv" -q --python 3.12
  VIRTUAL_ENV=$DIR/venv uv pip install -q 'mlx-audio[server]' 'misaki[en]' \
    'en_core_web_sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl'
fi

tmux kill-session -t $SESSION 2>/dev/null || true
tmux new-session -d -s $SESSION "$DIR/venv/bin/mlx_audio.server --host 127.0.0.1 --port 8880 2>&1 | tee $DIR/server.out"
for i in {1..60}; do curl -s -o /dev/null http://127.0.0.1:8880/v1/models && break; sleep 1; done
# Warm the model so the first spoken sentence isn't an 8 s cold start.
code=$(curl -s -m 180 -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8880/v1/audio/speech -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community/Kokoro-82M-bf16","voice":"af_heart","input":"Ready.","response_format":"wav"}')
echo "Kokoro TTS up on :8880 (warm=$code, tmux: $SESSION)"
