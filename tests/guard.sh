#!/usr/bin/env bash
# Negative test of the build guard in Dockerfile.oss: building on an nginx below the floor must FAIL.
# Cheap: an older 1.30.x base, the build stops at the guard (nothing pushed, nothing tagged).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
set -a
. ./versions.env
set +a

# 1.30.1 is a published 1.30.x, below any floor this series will have.
OLD=1.30.1
export NGINX_VERSION="$OLD" TAGS="nginx-s3-guard-test:must-not-exist"

log="$(mktemp)"
trap 'rm -f "$log"' EXIT
if docker buildx bake --progress=plain unprivileged >"$log" 2>&1; then
    echo "FAIL: the image was built on nginx ${OLD} (floor ${MIN_NGINX_VERSION}): the version guard did not fire" >&2
    exit 1
fi
if ! grep -q "refusing to build a vulnerable image" "$log"; then
    tail -30 "$log" >&2
    echo "FAIL: the build failed, but not because of the version guard" >&2
    exit 1
fi
grep -E "nginx ${OLD//./\\.}, floor" "$log" | tail -1
echo "ok   the guard refuses nginx ${OLD} (floor ${MIN_NGINX_VERSION})"
