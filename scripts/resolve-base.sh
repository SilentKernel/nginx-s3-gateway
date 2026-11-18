#!/usr/bin/env bash
# Reads the nginx image this build starts FROM and prints it as KEY=value lines (build.sh evals them):
#   NGINX_BASE      ${NGINX_BASE_IMAGE}@<digest>: what ${NGINX_BASE_IMAGE}:${NGINX_BASE_TAG} serves now, pinned
#   NGINX_VERSION   the nginx it carries (its label io.silent.version), a ${NGINX_SERIES}.x
# The base is our own nginx-docker (../nginx-docker: nginx.org's packages, a drop-in for the official image,
# rebuilt every night), read fresh at each build: a new nginx 1.30.x lands here the night after nginx-docker
# publishes it, without waiting for Docker Hub.
#
# Inputs (environment): NGINX_BASE_IMAGE, NGINX_BASE_TAG, NGINX_SERIES, PLATFORM (versions.env).
#   NGINX_BASE_LOCAL=1       read the image of the local Docker engine instead of the registry (a proof on a
#                            Mac before the base is published); NGINX_BASE is then the tag itself, not pinned,
#                            and build.sh refuses to push.
# Test hook: NGINX_BASE_JSON_FILE replaces the registry call (the output of
# `docker buildx imagetools inspect <ref> --format '{{json .}}'`).
# Any doubt is a failure: nothing is printed and the exit code is non-zero.
set -euo pipefail

: "${NGINX_BASE_IMAGE:?NGINX_BASE_IMAGE is not set}"
: "${NGINX_BASE_TAG:?NGINX_BASE_TAG is not set}"
: "${NGINX_SERIES:?NGINX_SERIES is not set}"
PLATFORM="${PLATFORM:-linux/amd64}"
REF="${NGINX_BASE_IMAGE}:${NGINX_BASE_TAG}"

fail() { echo "resolve-base: $*" >&2; exit 1; }

if [ -n "${NGINX_BASE_LOCAL:-}" ]; then
    version="$(docker image inspect -f '{{ index .Config.Labels "io.silent.version" }}' "$REF" 2>/dev/null)" \
        || fail "no local image ${REF}"
    base="$REF"
else
    if [ -n "${NGINX_BASE_JSON_FILE:-}" ]; then
        json="$(cat "$NGINX_BASE_JSON_FILE")" || fail "cannot read ${NGINX_BASE_JSON_FILE}"
    else
        json="$(docker buildx imagetools inspect "$REF" --format '{{json .}}' 2>&1)" || fail "cannot read ${REF}: ${json}"
    fi
    read -r version digest < <(python3 -I -c '
import json, sys
try:
    d = json.loads(sys.argv[1])
except ValueError:
    sys.exit("the registry did not return JSON")
image = d.get("image") or {}
if "config" not in image:   # multi-platform index: one entry per platform
    image = image.get(sys.argv[2]) or {}
labels = (image.get("config") or {}).get("Labels") or {}
print(labels.get("io.silent.version") or "-", (d.get("manifest") or {}).get("digest") or "-")
' "$json" "$PLATFORM") || fail "cannot read what ${REF} serves"
    [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "${REF} has no manifest digest"
    base="${NGINX_BASE_IMAGE}@${digest}"
fi

[[ "$version" =~ ^${NGINX_SERIES//./\\.}\.[0-9]+$ ]] \
    || fail "${REF} announces nginx '${version}' (label io.silent.version), not a ${NGINX_SERIES}.x: is it our nginx-docker image?"

echo "NGINX_BASE=${base}"
echo "NGINX_VERSION=${version}"
