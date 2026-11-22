#!/bin/zsh
# Runs a throwaway local Hermes (API server :8642 + dashboard :9119) backed by LM Studio, for developing the app.
#   HERMES_SRC=/path/to/hermes-agent ./scripts/dev-hermes.sh        # start (idempotent; restarts)
#   ./scripts/dev-hermes.sh stop
# State lives in dev/hermes-home (git-ignored). Keys are generated once into dev/hermes-home/.env (0600);
# the app reads them from there via "Use local dev server" in onboarding.
# AIDEV-NOTE: HERMES_HOME is isolated on purpose; never point this at ~/.hermes.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$PWD
HOME_DIR=$ROOT/dev/hermes-home
SRC=${HERMES_SRC:?set HERMES_SRC to a hermes-agent checkout with venv/ installed}
MODEL=${HERMES_DEV_MODEL:-ternary-bonsai-27b-mlx}
SESSION=hermes-dev

if [[ ${1:-} == stop ]]; then tmux kill-session -t $SESSION 2>/dev/null && echo "stopped"; exit 0; fi

# Local fixes for upstream bugs (see patches/). Applied once (this modifies $SRC's working tree).
for p in "$ROOT"/patches/hermes-agent-*.patch(N); do
  if git -C "$SRC" apply --check "$p" 2>/dev/null; then git -C "$SRC" apply "$p" && echo "applied $(basename $p) to $SRC"
  elif git -C "$SRC" apply --reverse --check "$p" 2>/dev/null; then :   # already applied
  else echo "WARNING: $(basename $p) does not apply to $SRC (checkout drifted?); starting UNPATCHED" >&2; fi
done

mkdir -p "$HOME_DIR"; chmod 700 "$HOME_DIR"
if [[ ! -f $HOME_DIR/.env ]]; then
  umask 077
  cat > "$HOME_DIR/.env" <<EOF
API_SERVER_KEY=hk_$(openssl rand -hex 24)
HERMES_DASHBOARD_SESSION_TOKEN=dt_$(openssl rand -hex 24)
LM_API_KEY=lm-studio
EOF
fi
[[ -f $HOME_DIR/config.yaml ]] || cat > "$HOME_DIR/config.yaml" <<EOF
model:
  default: "$MODEL"
  provider: "lmstudio"
  base_url: "http://127.0.0.1:1234/v1"
  context_length: 65536
platforms:
  api_server:
    enabled: true
    host: 127.0.0.1
    port: 8642
EOF

set -a; source "$HOME_DIR/.env"; set +a
tmux kill-session -t $SESSION 2>/dev/null || true
sleep 1
# Refuse to "succeed" against someone else's server (e.g. a real ~/.hermes instance) on our ports.
for port in 8642 9119; do
  if lsof -nP -iTCP:$port -sTCP:LISTEN >/dev/null 2>&1; then
    echo "Port $port is already in use by another process; stop it first (lsof -nP -iTCP:$port -sTCP:LISTEN)." >&2; exit 1
  fi
done
ENVS=(-e HERMES_HOME="$HOME_DIR" -e API_SERVER_KEY="$API_SERVER_KEY" -e HERMES_DASHBOARD_SESSION_TOKEN="$HERMES_DASHBOARD_SESSION_TOKEN")
tmux new-session -d -s $SESSION -n gateway "${ENVS[@]}" "$SRC/venv/bin/hermes gateway 2>&1 | tee $HOME_DIR/gateway.out"
tmux new-window -t $SESSION -n dashboard "${ENVS[@]}" "$SRC/venv/bin/hermes dashboard --no-open --port 9119 2>&1 | tee $HOME_DIR/dashboard.out"

for i in {1..60}; do
  a=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8642/health || true)
  b=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9119/api/health || true)
  [[ $a == 200 && $b == 200 ]] && { echo "Hermes dev up: api :8642, dashboard :9119 (tmux: $SESSION)"; exit 0; }
  sleep 1
done
echo "Timed out (api=$a dashboard=$b). See $HOME_DIR/*.out"; exit 1
