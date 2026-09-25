#!/bin/bash
# Uptime Kuma + Netdata, in their own compose project so the app stack's lifecycle cannot stop alerting.
# Usage: bash scripts/monitoring.sh up|down|status|logs
#
# Compose reads .env from the compose file's directory, not the repo root, so --env-file is explicit
# here: without it BIND_ADDR was ignored and the dashboards silently bound to 127.0.0.1 instead of
# the Tailscale address.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if command -v docker >/dev/null && ! docker info >/dev/null 2>&1 \
   && [ -z "${MON_SH_REEXEC:-}" ] && getent group docker | grep -q "\b$(id -un)\b" \
   && command -v sg >/dev/null; then
  export MON_SH_REEXEC=1
  exec sg docker -c "$(printf '%q ' bash "$0" "$@")"
fi

C=(docker compose --env-file "$ROOT/.env" -f "$ROOT/monitoring/compose.yaml")

case "${1:-status}" in
  up)     "${C[@]}" pull -q && "${C[@]}" up -d && sleep 5 && "${C[@]}" ps ;;
  down)   "${C[@]}" down ;;
  logs)   "${C[@]}" logs --tail "${2:-40}" ;;
  status)
    "${C[@]}" ps
    echo "== listening (must be the Tailscale address, not 0.0.0.0):"
    ss -ltn | grep -E ':(3001|19999) ' | awk '{print "  "$4}' || echo "  nothing"
    ;;
  *) echo "usage: $0 up|down|status|logs [n]"; exit 1 ;;
esac
