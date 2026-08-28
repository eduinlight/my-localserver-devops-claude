#!/usr/bin/env bash
set -euo pipefail

cd /home/runner/actions-runner

RUNNER_URL="${RUNNER_URL:?RUNNER_URL is required}"
RUNNER_NAME="${RUNNER_NAME:-gh-runner-docker}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted,Linux,X64,docker,homelab}"
RUNNER_EPHEMERAL="${RUNNER_EPHEMERAL:-false}"

fetch_registration_token() {
  if [ -z "${ACCESS_TOKEN:-}" ]; then
    return 1
  fi

  local scope
  case "$RUNNER_URL" in
    *github.com/*/*) scope="repos/$(printf '%s' "$RUNNER_URL" | sed 's#https://github.com/##')" ;;
    *)               scope="orgs/$(printf '%s' "$RUNNER_URL" | sed 's#https://github.com/##')" ;;
  esac

  curl -fsSL -X POST \
    -H "Authorization: Bearer ${ACCESS_TOKEN}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/${scope}/actions/runners/registration-token" \
    | jq -r .token
}

if [ ! -f .runner ]; then
  TOKEN="$(fetch_registration_token || true)"
  TOKEN="${TOKEN:-${RUNNER_TOKEN:-}}"

  if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
    echo "no registration token available: set ACCESS_TOKEN (a PAT) or RUNNER_TOKEN" >&2
    exit 1
  fi

  config_args=(
    --unattended
    --url "$RUNNER_URL"
    --token "$TOKEN"
    --name "$RUNNER_NAME"
    --labels "$RUNNER_LABELS"
    --work /home/runner/_work
    --replace
  )

  if [ "$RUNNER_EPHEMERAL" = "true" ]; then
    config_args+=(--ephemeral)
  fi

  ./config.sh "${config_args[@]}"
fi

exec ./run.sh
