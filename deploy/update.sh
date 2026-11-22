#!/usr/bin/env bash
# Run by the systemd timer, or manually under flock. Only trusted main commits run here.
set -euo pipefail

# Define the whole update before executing it: checking out a new commit can replace this file.
update_site() {
    cd "$(dirname "${BASH_SOURCE[0]}")/.."
    local repo_url='https://github.com/ganroman/canwemakeit.git'
    local api_url='https://api.github.com/repos/ganroman/canwemakeit/actions/workflows/deploy.yml/runs?branch=main&event=push&per_page=1'
    local run sha remote_sha previous_revision previous_image

    mkdir -p .deploy
    # One public API request per poll. No GitHub token or inbound server port is needed.
    run=$(curl --fail --silent --show-error --connect-timeout 10 --max-time 30 \
        -H 'Accept: application/vnd.github+json' "$api_url" | python3 -c '
import json, sys
runs = json.load(sys.stdin).get("workflow_runs", [])
if runs and runs[0]["status"] == "completed" and runs[0]["conclusion"] == "success":
    print(runs[0]["head_sha"])
')
    if [[ -z "$run" ]]; then
        echo 'Latest main build is not successful yet; keeping the current site.'
        return 0
    fi
    sha="$run"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid GitHub commit identifier.' >&2; return 1; }
    if [[ -f .deploy/deployed-sha ]] && [[ "$(cat .deploy/deployed-sha)" = "$sha" ]]; then
        echo "Already deployed $sha."
        return 0
    fi
    if [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
        echo 'Server checkout contains local changes; refusing to overwrite them.' >&2
        return 1
    fi

    git fetch --no-tags "$repo_url" main
    remote_sha=$(git rev-parse FETCH_HEAD)
    if [[ "$remote_sha" != "$sha" ]]; then
        echo 'A newer main commit is waiting for checks; keeping the current site.'
        return 0
    fi
    previous_revision=$(git rev-parse HEAD)
    previous_image=$(docker image inspect canwemakeit-homepage:local --format '{{.Id}}' 2>/dev/null || true)
    if [[ -n "$previous_image" ]]; then
        docker image tag "$previous_image" canwemakeit-homepage:previous
    fi
    git checkout --detach "$sha"

    # Build first: the existing containers continue serving while the candidate builds.
    if docker compose build --pull homepage && \
       docker compose run --rm --no-deps gateway caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile && \
       docker compose up -d --no-build --force-recreate --wait --wait-timeout 120 homepage gateway && \
       bash deploy/check-site.sh; then
        printf '%s\n' "$sha" > .deploy/deployed-sha.tmp
        mv .deploy/deployed-sha.tmp .deploy/deployed-sha
        echo "Deployed $sha successfully."
    else
        echo "Deployment of $sha failed; restoring the previous checkout and image." >&2
        git checkout --detach "$previous_revision"
        if [[ -n "$previous_image" ]]; then
            docker image tag "$previous_image" canwemakeit-homepage:local
            docker compose up -d --no-build --force-recreate --wait --wait-timeout 120 homepage gateway
            bash deploy/check-site.sh
        fi
        return 1
    fi
}

update_site
