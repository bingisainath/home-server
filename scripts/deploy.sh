#!/bin/bash
# Pull-based continuous deployment for the app.
#
# The laptop has no inbound ports — the tunnel is outbound-only — so nothing can push a deploy in.
# Instead this runs on a timer and asks: has origin/main moved, and did its CI pass? Only then does it
# rebuild. On any failure it puts the previous image back, confirms the site recovered, and pauses
# itself so a broken commit is not retried every few minutes.
#
# Deliberately app-only. Changes to this repo (compose, nginx, the tunnel) are not auto-deployed:
# they can take the site down in ways a health check cannot undo, and they are rare enough to do by hand.
set -uo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck disable=SC1091
[ -f "$ROOT/.env" ] && . "$ROOT/.env"

APP_REPO=${APP_REPO:-$HOME/github.com/pocket-drive}
BRANCH=${DEPLOY_BRANCH:-main}
REMOTE=${DEPLOY_REMOTE:-origin}
STATE=${DEPLOY_STATE:-$HOME/.local/state/pocket-deploy}
IMAGE_TAG=${IMAGE_TAG:-20.19.6-1}
HEALTH_LOCAL="http://127.0.0.1/api/health"
HEALTH_PUBLIC=${DEPLOY_HEALTH_PUBLIC:-https://drive.bingisainath.com/api/health}
HEALTH_TIMEOUT=${DEPLOY_HEALTH_TIMEOUT:-180}
REQUIRE_CI=${DEPLOY_REQUIRE_CI:-1}
# Only these paths justify a rebuild; docs, CI config and the mobile app do not touch the server.
DEPLOY_PATHS=${DEPLOY_PATHS:-'^(backend/|frontend/|package\.json|package-lock\.json|Dockerfile|\.dockerignore)'}

mkdir -p "$STATE"
log() { printf '%s %s\n' "$(date -u '+%H:%M:%S')" "$*"; }

notify() { # only if a bot is configured; a deploy notifier that needs babysitting is worse than none
  [ -n "${TELEGRAM_BOT_TOKEN:-}" ] && [ -n "${TELEGRAM_CHAT_ID:-}" ] || return 0
  curl -fsS -m 20 -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    -d "chat_id=$TELEGRAM_CHAT_ID" -d "text=$1" >/dev/null 2>&1 || true
}

# --- one deploy at a time ---
exec 9>"$STATE/lock"
flock -n 9 || { log "another deploy is running"; exit 0; }

[ -f "$STATE/paused" ] && exit 0   # a previous deploy failed; read the file, then delete it

command -v docker >/dev/null && docker info >/dev/null 2>&1 || { log "docker unavailable"; exit 1; }
cd "$APP_REPO" || { log "no repo at $APP_REPO"; exit 1; }

# --- is there anything new, and is it safe to touch? ---
git fetch --quiet "$REMOTE" "$BRANCH" || { log "git fetch failed"; exit 1; }
current=$(git rev-parse HEAD)
target=$(git rev-parse "$REMOTE/$BRANCH")
[ "$current" = "$target" ] && exit 0

branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" = "$BRANCH" ] || { log "on '$branch', not '$BRANCH'; leaving it alone"; exit 0; }
[ -z "$(git status --porcelain)" ] || { log "uncommitted changes here; not deploying"; exit 0; }

short=$(git rev-parse --short "$target")
subject=$(git log -1 --format='%s' "$target")

# --- CI gate: never deploy a commit GitHub has not finished checking ---
if [ "$REQUIRE_CI" = 1 ]; then
  slug=$(git remote get-url "$REMOTE" | sed -E 's#(git@|https://)github.com[:/]##; s#\.git$##')
  results=$(curl -fsS -m 30 "https://api.github.com/repos/$slug/commits/$target/check-runs" \
            | python3 -c "import json,sys; print(' '.join((r.get('conclusion') or 'pending') for r in json.load(sys.stdin).get('check_runs',[])))" 2>/dev/null)
  if [ -z "${results// /}" ]; then
    age=$(( $(date +%s) - $(git log -1 --format=%ct "$target") ))
    [ "$age" -gt 1800 ] && log "no CI checks for $short after $((age/60))m; not deploying" || log "waiting for CI on $short"
    exit 0
  fi
  for r in $results; do
    case "$r" in
      success|skipped|neutral) ;;
      pending|queued|in_progress) log "CI still running for $short"; exit 0 ;;
      *) if [ "$(cat "$STATE/ci-failed" 2>/dev/null)" != "$target" ]; then
           log "CI failed for $short ($r): $subject"; echo "$target" >"$STATE/ci-failed"
           notify "Deploy skipped: CI failed for $short — $subject"
         fi
         exit 0 ;;
    esac
  done
fi

changed=$(git diff --name-only HEAD "$target")
if ! grep -qE "$DEPLOY_PATHS" <<<"$changed"; then
  git merge --ff-only --quiet "$target" && log "synced to $short (nothing the server runs changed): $subject"
  exit 0
fi

log "deploying $short: $subject"
started=$(date +%s)

# --- a database snapshot first, so a bad migration is recoverable ---
DB=${DATA_DIR:-$HOME/cloud-storage}/cloud-drive.db
if [ -f "$DB" ]; then
  mkdir -p "$STATE/db"
  snap="$STATE/db/$(date -u +%Y%m%dT%H%M%SZ)-$short.db"
  python3 - "$DB" "$snap" <<'PY' || { log "database snapshot failed; aborting"; exit 1; }
import sqlite3, sys
src = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
dst = sqlite3.connect(sys.argv[2])
with dst: src.backup(dst)
src.close(); dst.close()
PY
  ls -1t "$STATE/db"/*.db 2>/dev/null | tail -n +6 | xargs -r rm -f
  log "database snapshotted"
fi

# --- keep the running image so a rollback does not have to rebuild ---
docker tag "pocket-drive:$IMAGE_TAG" "pocket-drive:previous" 2>/dev/null \
  && log "tagged the running image as :previous"

roll_back() { # reason
  log "ROLLING BACK: $1"
  git -C "$APP_REPO" reset --hard --quiet "$current"
  if docker image inspect "pocket-drive:previous" >/dev/null 2>&1; then
    docker tag "pocket-drive:previous" "pocket-drive:$IMAGE_TAG"
  fi
  ( cd "$ROOT" && APP_ENV_FILE=$ROOT/secrets/pocket-drive.env TUNNEL_CREDENTIALS=$ROOT/secrets/tunnel.json \
      TUNNEL_CONFIG=$ROOT/secrets/cloudflared.yml docker compose up -d --no-build ) >/dev/null 2>&1
  if wait_for "$HEALTH_LOCAL" 120; then log "rolled back to $(git -C "$APP_REPO" rev-parse --short HEAD), healthy"
  else log "STILL UNHEALTHY AFTER ROLLBACK — needs attention now"; fi
  { echo "$(date -u '+%FT%TZ') deploy paused"; echo "commit: $short $subject"; echo "reason: $1";
    echo; echo "Fix it, then: rm $STATE/paused"; } >"$STATE/paused"
  notify "Deploy FAILED and was rolled back: $short — $1"
  exit 1
}

wait_for() { # url seconds
  local i
  for ((i = 0; i < $2; i += 3)); do
    [ "$(curl -s -o /dev/null -m 10 -w '%{http_code}' -H 'Host: drive.bingisainath.com' "$1")" = 200 ] && return 0
    sleep 3
  done
  return 1
}

# --- take the new code and build it ---
git merge --ff-only --quiet "$target" || { log "cannot fast-forward to $short"; exit 1; }
cd "$ROOT"
export APP_ENV_FILE=$ROOT/secrets/pocket-drive.env TUNNEL_CREDENTIALS=$ROOT/secrets/tunnel.json TUNNEL_CONFIG=$ROOT/secrets/cloudflared.yml
DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0 docker compose build pocket-drive >"$STATE/build.log" 2>&1 \
  || roll_back "image build failed (see $STATE/build.log)"
log "image built"

docker compose up -d >"$STATE/up.log" 2>&1 || roll_back "compose up failed (see $STATE/up.log)"
wait_for "$HEALTH_LOCAL" "$HEALTH_TIMEOUT" || roll_back "the app did not answer $HEALTH_LOCAL in ${HEALTH_TIMEOUT}s"
log "app healthy locally"

# The tunnel is a separate failure domain from the app; check the public path too.
for ((i = 0; i < 60; i += 5)); do
  [ "$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$HEALTH_PUBLIC")" = 200 ] && break
  sleep 5
done
[ "$(curl -s -o /dev/null -m 15 -w '%{http_code}' "$HEALTH_PUBLIC")" = 200 ] \
  || roll_back "public $HEALTH_PUBLIC did not return 200"

log "deployed $short in $(( $(date +%s) - started ))s: $subject"
echo "$(date -u '+%FT%TZ') $short $subject" >>"$STATE/history.log"
rm -f "$STATE/ci-failed"
notify "Deployed $short — $subject"
