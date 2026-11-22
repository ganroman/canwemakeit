#!/usr/bin/env bash
set -euo pipefail

base_url="${1:-http://127.0.0.1:8080}"
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

curl --fail --silent --show-error --max-time 15 "$base_url/healthz" | grep -qx 'ok'
curl --fail --silent --show-error --max-time 15 -D "$test_dir/headers" "$base_url/" > "$test_dir/page"
grep -q 'Can we make it' "$test_dir/page"
grep -qi '^Content-Security-Policy:' "$test_dir/headers"
grep -Eqi '^X-Robots-Tag:[[:space:]]*noindex,[[:space:]]*nofollow[[:space:]]*$' "$test_dir/headers"
grep -q '<meta name="robots" content="noindex, nofollow">' "$test_dir/page"
for asset in styles.css tokens.css favicon.svg; do
    curl --fail --silent --show-error --max-time 15 -D "$test_dir/asset-headers" "$base_url/$asset" > "$test_dir/$asset"
    test -s "$test_dir/$asset"
    grep -Eqi '^X-Robots-Tag:[[:space:]]*noindex,[[:space:]]*nofollow[[:space:]]*$' "$test_dir/asset-headers"
done
status=$(curl --silent --show-error --max-time 15 -D "$test_dir/error-headers" -o "$test_dir/not-found" -w '%{http_code}' "$base_url/__deployment_missing_page__")
test "$status" = 404
grep -q 'Nothing here' "$test_dir/not-found"
grep -Eqi '^X-Robots-Tag:[[:space:]]*noindex,[[:space:]]*nofollow[[:space:]]*$' "$test_dir/error-headers"
echo 'Homepage, health endpoint, assets, security and no-index headers, and custom 404 passed.'
