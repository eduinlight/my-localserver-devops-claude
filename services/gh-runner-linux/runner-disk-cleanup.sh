#!/usr/bin/env bash
set -uo pipefail

log() { echo "$(date '+%F %T') $*"; }

runner_busy() {
  local name="$1"
  if [ "$name" = native ]; then
    pgrep -f '/opt/actions-runner/bin[^ ]*/Runner.Worker' >/dev/null
  else
    docker exec "$name" pgrep -f Runner.Worker >/dev/null 2>&1
  fi
}

clean_runner_root() {
  local name="$1" root="$2"
  local rdir="$root/actions-runner"
  [ -d "$rdir" ] || rdir="$root"
  local work="$rdir/_work"
  [ -d "$root/_work" ] && work="$root/_work"

  local live_bin live_ext
  live_bin=$(basename "$(readlink "$rdir/bin")")
  live_ext=$(basename "$(readlink "$rdir/externals")")
  for d in "$rdir"/bin.* "$rdir"/externals.*; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in
      "$live_bin"|"$live_ext") ;;
      *) log "$name: removing stale $(basename "$d")"; rm -rf "$d" ;;
    esac
  done

  find "$rdir/_diag" -type f -mtime +7 -delete 2>/dev/null

  if runner_busy "$name"; then
    log "$name: job in progress, skipping workspace cleanup"
    return
  fi

  [ -d "$work" ] || return
  find "$work/_temp" -mindepth 1 -maxdepth 1 -mmin +360 -exec rm -rf {} + 2>/dev/null
  rm -rf "$work/_update" "$work/_update.sh"
  for repo in "$work"/*/; do
    case "$(basename "$repo")" in
      _*) continue ;;
    esac
    if [ -z "$(find "$repo" -newermt '-3 days' -print -quit 2>/dev/null)" ]; then
      log "$name: removing idle workspace $(basename "$repo")"
      rm -rf "$repo"
    fi
  done
}

log "before: $(df -h / | awk 'NR==2 {print $3" used, "$4" free ("$5")"}')"

clean_runner_root native /opt/actions-runner
for vol in /var/lib/docker/volumes/gh-runner-docker_runner-home*/_data; do
  suffix=$(basename "$(dirname "$vol")" | sed -E 's/^gh-runner-docker_runner-home//')
  clean_runner_root "gh-runner-docker$suffix" "$vol"
done

for f in /var/lib/docker/containers/*/*-json.log; do
  if [ "$(stat -c %s "$f")" -gt $((200 * 1024 * 1024)) ]; then
    log "truncating $(du -h "$f" | cut -f1) log $(basename "$(dirname "$f")" | cut -c1-12)"
    truncate -s 0 "$f"
  fi
done

docker container prune -f --filter until=24h >/dev/null
docker image prune -af --filter until=48h | tail -1
docker builder prune -af --filter until=24h | tail -1
docker volume prune -f | tail -1

log "after: $(df -h / | awk 'NR==2 {print $3" used, "$4" free ("$5")"}')"
