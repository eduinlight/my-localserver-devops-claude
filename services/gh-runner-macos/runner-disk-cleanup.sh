#!/bin/bash
set -uo pipefail

RDIR="$HOME/actions-runner"
WORK="$RDIR/_work"

log() { echo "$(date '+%F %T') $*"; }

log "before: $(df -h /System/Volumes/Data | awk 'NR==2 {print $3" used, "$4" free ("$5")"}')"

live_bin=$(basename "$(readlink "$RDIR/bin")")
live_ext=$(basename "$(readlink "$RDIR/externals")")
for d in "$RDIR"/bin.* "$RDIR"/externals.*; do
  [ -d "$d" ] || continue
  case "$(basename "$d")" in
    "$live_bin"|"$live_ext") ;;
    *) log "removing stale $(basename "$d")"; rm -rf "$d" ;;
  esac
done

find "$RDIR/_diag" -type f -mtime +7 -delete 2>/dev/null

if pgrep -f 'actions-runner/bin[^ ]*/Runner.Worker' >/dev/null; then
  log "job in progress, skipping workspace cleanup"
else
  find "$WORK/_temp" -mindepth 1 -maxdepth 1 -mmin +360 -exec rm -rf {} + 2>/dev/null
  rm -rf "$WORK/_update" "$WORK/_update.sh"
  for repo in "$WORK"/*/; do
    case "$(basename "$repo")" in
      _*) continue ;;
    esac
    if [ -z "$(find "$repo" -mtime -3 -print 2>/dev/null | head -1)" ]; then
      log "removing idle workspace $(basename "$repo")"
      rm -rf "$repo"
    fi
  done
  find "$HOME/Library/Developer/Xcode/DerivedData" -mindepth 1 -maxdepth 1 -mtime +3 -exec rm -rf {} + 2>/dev/null
  xcrun simctl delete unavailable 2>/dev/null
fi

log "after: $(df -h /System/Volumes/Data | awk 'NR==2 {print $3" used, "$4" free ("$5")"}')"
