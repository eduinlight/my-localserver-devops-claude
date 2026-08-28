#!/usr/bin/env bash
# Installs the PAT that lets a runner register itself unattended.
#
# entrypoint.sh prefers ACCESS_TOKEN and exchanges it for a fresh registration token on every
# start, so a runner whose volume is gone comes back on its own instead of restart-looping on
# "no registration token available". Already-registered runners never read it — they use the
# .credentials in their volume — so installing this changes nothing about day-to-day operation.
#
# Reads the token from stdin, never argv, so it stays out of shell history and the process list:
#
#   ssh root@192.168.0.15
#   pct exec 124 -- bash -c 'read -rs T && printf %s "$T" | /opt/gh-runner-docker/set-runner-pat.sh'
#
# The PAT needs exactly one scope: classic `admin:org`, or fine-grained with the organisation
# permission "Self-hosted runners: read and write". Do not reuse a broad personal token —
# anything here is readable by any job (the Docker socket is mounted, so a job can read these
# files through a container regardless of their mode).
set -euo pipefail

ORG="${ORG:-eduinlight-org}"
DIR="${DIR:-/opt/gh-runner-docker}"

TOKEN="$(cat)"
TOKEN="${TOKEN%%[[:space:]]}"
[[ -n "$TOKEN" ]] || { echo "set-runner-pat: no token on stdin" >&2; exit 2; }

code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/orgs/${ORG}/actions/runners/registration-token")"

if [[ "$code" != "201" ]]; then
  echo "set-runner-pat: token rejected (HTTP $code) — needs admin:org on ${ORG}. Nothing written." >&2
  exit 1
fi
echo "set-runner-pat: token accepted by ${ORG} (HTTP 201)"

for f in "$DIR/.env" "$DIR/runners.env"; do
  [[ -f "$f" ]] && cp -a "$f" "$f.bak-$(date +%F)"
  # The expired RUNNER_TOKEN lines are dropped; ACCESS_TOKEN supersedes them.
  printf 'ACCESS_TOKEN=%s\n' "$TOKEN" > "$f"
  chown admin:admin "$f"
  chmod 0600 "$f"
  echo "set-runner-pat: wrote $f"
done

echo
echo "Recreate the containers so the new value is baked into their config:"
echo "  cd $DIR && docker compose up -d"
echo
echo "Compose injects env_file at *create* time, so a running container keeps whatever token"
echo "it was created with. Until you recreate, the recovery path still holds the old value."
echo "Already-registered runners never read it either way — it only matters when one has to"
echo "register from scratch."
