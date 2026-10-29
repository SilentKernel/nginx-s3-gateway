#!/usr/bin/env bash
# Builds the unprivileged nginx-s3-gateway image (IMAGE in versions.env) for production (amd64),
# tests it, and pushes it to our registry only with --push (no Docker Hub copy).
#
#   ./build.sh                      build + every gate, nothing pushed
#   ./build.sh --push               the same, then push the tags to our registry
#   NGINX_VERSION=1.30.5 ./build.sh a given version (rollback, reproduction)
#
# The version is the latest nginx ${NGINX_SERIES}.x on Docker Hub (scripts/resolve-versions.sh).
# Dockerfile.oss refuses an nginx below MIN_NGINX_VERSION and pins the njs/xslt modules to that exact
# nginx; --push refuses to publish a version older than the moving tag serves.
#
# Tags: <ver>-unprivileged-YYYYMMDD (never overwritten, for rollbacks),
# <ver>-unprivileged (latest build of that version), ${NGINX_SERIES}-unprivileged (moving, what
# production uses) and latest.
#
# Before anything is pushed, the candidate must pass: tests/smoke.sh (versions, packages, unprivileged
# layout, startup as nginx / arbitrary uid / read-only, njs unit tests), tests/os-updates.sh (no
# Debian update pending), tests/integration.sh
# (upstream's HTTP API suite against MinIO, every configuration of test.sh), tests/negative.sh (the
# gates still catch broken images) and tests/scan.sh (no new fixable CRITICAL CVE). tests/guard.sh
# runs as its own CI job. The candidate lives under a private local name until the push: another
# build on the same Docker engine pulling the public tags cannot swap it, and after the push the
# registry must serve exactly the tested image. (Same structure as frankenphp-docker's build.sh.)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

PUSH=0
for arg in "$@"; do
    case "$arg" in
        --push) PUSH=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

set -a
# shellcheck source=versions.env
. ./versions.env
set +a

if [ "$PUSH" = 1 ] && [ -d .git ] && [ -n "$(git status --porcelain)" ]; then
    echo "refusing to push from a dirty working tree: the pushed image would match no commit" >&2
    exit 1
fi
SOURCE_COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo none)"

echo "==> resolving nginx ${NGINX_SERIES}.x (${DEBIAN})"
resolved="$("$ROOT/scripts/resolve-versions.sh")"
eval "$resolved"
export NGINX_VERSION

TODAY="$(date -u +%Y%m%d)"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
TAG_MOVING="${IMAGE}:${NGINX_SERIES}-unprivileged"
# Every tag of repository $1; the moving tag and latest last.
tags_of() { printf '%s\n' "$1:${NGINX_VERSION}-unprivileged-${TODAY}" "$1:${NGINX_VERSION}-unprivileged" "$1:${NGINX_SERIES}-unprivileged" "$1:latest"; }
CANDIDATE="nginx-s3-gateway-candidate:$(date -u +%Y%m%d%H%M%S)-$$"
trap 'docker image rm "$CANDIDATE" >/dev/null 2>&1 || true' EXIT

# What the moving tag of our registry serves today: "<nginx> <manifest digest>" from its labels, or
# "- -" if it was never pushed.
published_info() {
    local out
    if ! out="$(docker buildx imagetools inspect "$TAG_MOVING" --format '{{json .}}' 2>&1)"; then
        case "$out" in
            *"not found"*|*"NOT_FOUND"*|*"MANIFEST_UNKNOWN"*) echo "- -"; return 0 ;;
            *) echo "cannot read ${TAG_MOVING}: ${out}" >&2; return 1 ;;
        esac
    fi
    python3 -I -c '
import json, sys
d = json.loads(sys.argv[1])
image = d.get("image") or {}
if "config" not in image:   # multi-platform index: one entry per platform
    image = image.get(sys.argv[2]) or next(iter(image.values()))
labels = image.get("config", {}).get("Labels") or {}
print(labels.get("dev.nginx-s3-gateway.nginx-version") or "-", d.get("manifest", {}).get("digest") or "-")
' "$out" "$PLATFORM"
}

PUBLISHED_NGINX="" PUBLISHED_DIGEST=""
if read -r PUBLISHED_NGINX PUBLISHED_DIGEST < <(published_info); then
    [ "$PUBLISHED_NGINX" = - ] && PUBLISHED_NGINX=""
    [ "$PUBLISHED_DIGEST" = - ] && PUBLISHED_DIGEST=""
    echo "==> ${TAG_MOVING} serves nginx ${PUBLISHED_NGINX:-none}"
elif [ "$PUSH" = 1 ]; then
    echo "cannot read the published version" >&2
    exit 1
else
    echo "==> cannot read ${TAG_MOVING} (not logged in?): no comparison with the published image"
fi
if [ "$PUSH" = 1 ]; then
    "$ROOT/scripts/version-compare.sh" "$PUBLISHED_NGINX" "$NGINX_VERSION" \
        || { echo "refusing to push nginx ${NGINX_VERSION}: ${TAG_MOVING} already serves ${PUBLISHED_NGINX}" >&2; exit 1; }
fi

# Built under the private candidate name only: the public tags are set right before the push.
TAGS="$CANDIDATE"
export TAGS SOURCE_COMMIT BUILD_DATE

echo "==> building nginx ${NGINX_VERSION} (floor ${MIN_NGINX_VERSION}), ${PLATFORM}"
# --pull refreshes nginx:${NGINX_VERSION} (docker-library rebuilds it on Debian updates, but not
# always soon); Dockerfile.oss's os-updates stage (never cached) applies the Debian updates published
# since; --load puts the result in the local engine for the tests.
docker buildx bake --pull --load unprivileged

CANDIDATE_ID="$(docker image inspect -f '{{.Id}}' "$CANDIDATE")"
echo "==> candidate ${CANDIDATE} (${CANDIDATE_ID})"

echo "==> smoke test"
"$ROOT/tests/smoke.sh" "$CANDIDATE"
echo "==> Debian updates (none may be pending)"
"$ROOT/tests/os-updates.sh" "$CANDIDATE"
echo "==> integration test (upstream API suite against MinIO)"
"$ROOT/tests/integration.sh" "$CANDIDATE"
echo "==> negative tests (the gates catch broken images)"
"$ROOT/tests/negative.sh" "$CANDIDATE"
PUBLISHED_REF=""
if [ -n "$PUBLISHED_DIGEST" ]; then
    PUBLISHED_REF="${IMAGE}@${PUBLISHED_DIGEST}"
    docker pull --quiet --platform "$PLATFORM" "$PUBLISHED_REF" >/dev/null \
        || { echo "cannot pull the published image ${PUBLISHED_REF}" >&2; exit 1; }
fi
echo "==> vulnerability gate (no new fixable CRITICAL against the published image)"
"$ROOT/tests/scan.sh" "$CANDIDATE" ${PUBLISHED_REF:+"$PUBLISHED_REF"}

# Every identifier of the image the registry serves for <tag> (index, platform manifest, config):
# the tested image ID must be one of them, whatever image store the local engine uses.
served_ids() {
    local tag="$1" top raw out child
    # {{json .Manifest}}, never {{.Manifest.Digest}}: older buildx versions print their
    # human-readable block for any format starting with {{.Manifest (served-ids.py --digest reads both)
    top="$(docker buildx imagetools inspect "$tag" --format '{{json .Manifest}}' | python3 -I "$ROOT/scripts/served-ids.py" --digest)" || return 1
    raw="$(docker buildx imagetools inspect "$tag" --raw)" || return 1
    out="$(python3 -I "$ROOT/scripts/served-ids.py" "$top" "$raw" "$PLATFORM")" || return 1
    if [[ "$out" == need-child\ * ]]; then
        child="$(docker buildx imagetools inspect "${tag%:*}@${out#need-child }" --raw)" || return 1
        out="$(python3 -I "$ROOT/scripts/served-ids.py" "$top" "$raw" "$PLATFORM" "$child")" || return 1
    fi
    printf '%s\n' "$out"
}

# Pushes <tag> from the tested image, then checks the registry serves exactly that image.
push_tested() {
    local tag="$1" ids
    docker tag "$CANDIDATE_ID" "$tag"
    docker push "$tag"
    ids="$(served_ids "$tag")" || { echo "cannot read ${tag} back from the registry" >&2; exit 1; }
    if ! grep -qxF "$CANDIDATE_ID" <<<"$ids"; then
        echo "registry serves $(tr '\n' ' ' <<<"$ids")for ${tag}, not the tested image ${CANDIDATE_ID}" >&2
        exit 1
    fi
    echo "ok   ${tag} is the tested image (${CANDIDATE_ID})"
}

if [ "$PUSH" = 1 ]; then
    echo "==> pushing to ${IMAGE} (moving tag and latest last)"
    while read -r tag; do push_tested "$tag"; done < <(tags_of "$IMAGE")
    if [ "$PUBLISHED_NGINX" != "$NGINX_VERSION" ]; then
        # A new version to roll out: the important channel (NTFY_TOPIC_NEWBASE), not NTFY_TOPIC.
        NTFY_TOPIC="${NTFY_TOPIC_NEWBASE:-}" "$ROOT/scripts/notify.sh" default "package,arrow_up" \
            "New nginx-s3-gateway: nginx ${NGINX_VERSION}" \
            "${TAG_MOVING} moved from nginx ${PUBLISHED_NGINX:-none}. Pull it and restart the gateways."
    fi
else
    docker tag "$CANDIDATE_ID" "${IMAGE}:${NGINX_VERSION}-unprivileged"
    docker tag "$CANDIDATE_ID" "$TAG_MOVING"
    echo "==> not pushed (run with --push); tagged locally: ${IMAGE}:${NGINX_VERSION}-unprivileged, ${TAG_MOVING}"
fi
