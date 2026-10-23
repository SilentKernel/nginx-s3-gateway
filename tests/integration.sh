#!/usr/bin/env bash
# Integration test of a built unprivileged image against a real S3 server:
#   tests/integration.sh <image>
# Upstream's HTTP API suite (test/integration/test_api.sh) on the same configurations as test.sh,
# but safe on a shared runner: private Docker network, unique container names, random localhost
# port, test data copied to a temporary directory (test.sh writes into test/data). MinIO is the
# community build pgsty/minio (MinIO no longer publishes images), pinned by digest; its mc loads the
# data. INTEGRATION_QUICK=1 runs one configuration only (tests/negative.sh).
# On failure, the containers' logs are saved in test-logs/.
set -euo pipefail

TARGET="${1:?usage: tests/integration.sh <image>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a
. "$ROOT/versions.env"
set +a
MINIO_IMAGE="${MINIO_IMAGE:-pgsty/minio:RELEASE.2026-08-04T00-00-00Z@sha256:b6bfe7239bfc83fb90d31612d9704d86039dd714f7904b3f1ad68f211e602372}"
MINIO_USER=AKIAIOSFODNN7EXAMPLE
MINIO_PASSWORD=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

id="ngt-${CI_JOB_ID:-local}-$$"
net="$id" minio="${id}-minio" gw="${id}-gw"
work="$(mktemp -d)"
save_logs() {
    mkdir -p "$ROOT/test-logs"
    docker logs "$minio" >"$ROOT/test-logs/${id}-minio.log" 2>&1 || true
    docker logs "$gw" >"$ROOT/test-logs/${id}-gateway.log" 2>&1 || true
}
cleanup() {
    [ "$1" = 0 ] || save_logs
    docker rm -f "$gw" "$minio" >/dev/null 2>&1 || true
    docker network rm "$net" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap 'cleanup $?' EXIT

# Test data, with the file test.sh writes at run time (not in git: it breaks Windows checkouts).
cp -R "$ROOT/test" "$work/test"
echo 'We are but selling water next to a river.' > "$work/test/data/bucket-1/a/%@!*()=\$#^&|.txt"

docker network create "$net" >/dev/null
# bucket-1.minio: virtual-host style requests (S3_STYLE=virtual-v2, the compose file's default).
docker run -d --name "$minio" --network "$net" --network-alias minio --network-alias bucket-1.minio \
    -e MINIO_ROOT_USER="$MINIO_USER" -e MINIO_ROOT_PASSWORD="$MINIO_PASSWORD" -e MINIO_REGION_NAME=us-east-1 \
    -e MINIO_DOMAIN=minio -e MINIO_BROWSER=off "$MINIO_IMAGE" minio server /data >/dev/null
for _ in $(seq 1 30); do
    docker exec "$minio" curl -fsS -o /dev/null http://127.0.0.1:9000/minio/health/live 2>/dev/null && break
    sleep 1
done
docker exec "$minio" curl -fsS -o /dev/null http://127.0.0.1:9000/minio/health/live || fail "MinIO did not start"

loader="$(docker create --network "$net" --entrypoint sh "$MINIO_IMAGE" -c '
    set -e
    mc alias set t http://minio:9000 "$0" "$1" >/dev/null
    mc mb t/bucket-1 >/dev/null
    for f in /load/*; do mc cp -r "$f" t/bucket-1 >/dev/null; done
    mc ls -r t/bucket-1 | wc -l' "$MINIO_USER" "$MINIO_PASSWORD")"
# Copied in rather than bind-mounted: works whatever the Docker host can see. /load = bucket-1's content.
docker cp "$work/test/data/bucket-1" "${loader}:/load" >/dev/null \
    || { docker rm -f "$loader" >/dev/null; fail "cannot copy the test data"; }
objects="$(docker start -a "$loader")" || { docker rm -f "$loader" >/dev/null; fail "cannot load the test data"; }
docker rm -f "$loader" >/dev/null
pass "MinIO up, ${objects// /} objects loaded in bucket-1"

# One configuration: integration <sigs> <dir list> <index page> <append slash> <strip> <prefix>
integration() {
    local what="sigv$1 list=$2 index=$3 slash=$4 strip='$5' prefix='$6'" port
    docker rm -f "$gw" >/dev/null 2>&1 || true
    docker run -d --name "$gw" --network "$net" --platform "$PLATFORM" -p 127.0.0.1::8080 \
        -e S3_BUCKET_NAME=bucket-1 -e AWS_ACCESS_KEY_ID="$MINIO_USER" -e AWS_SECRET_ACCESS_KEY="$MINIO_PASSWORD" \
        -e S3_SERVER=minio -e S3_SERVER_PORT=9000 -e S3_SERVER_PROTO=http -e S3_REGION=us-east-1 \
        -e DEBUG=true -e S3_STYLE=virtual-v2 -e S3_SERVICE=s3 \
        -e AWS_SIGS_VERSION="$1" -e ALLOW_DIRECTORY_LIST="$2" -e PROVIDE_INDEX_PAGE="$3" \
        -e APPEND_SLASH_FOR_POSSIBLE_DIRECTORY="$4" -e STRIP_LEADING_DIRECTORY_PATH="$5" \
        -e PREFIX_LEADING_DIRECTORY_PATH="$6" \
        -e PROXY_CACHE_MAX_SIZE=10g -e PROXY_CACHE_SLICE_SIZE=1m -e PROXY_CACHE_INACTIVE=60m \
        -e PROXY_CACHE_VALID_OK=1h -e PROXY_CACHE_VALID_NOTFOUND=1m -e PROXY_CACHE_VALID_FORBIDDEN=30s \
        "$TARGET" >/dev/null
    port="$(docker port "$gw" 8080/tcp | head -1 | sed 's/.*://')"
    for _ in $(seq 1 30); do
        [ "$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/health" 2>/dev/null)" = 200 ] && break
        [ "$(docker inspect -f '{{.State.Running}}' "$gw")" = true ] || { docker logs "$gw" >&2; fail "${what}: gateway exited"; }
        sleep 1
    done
    if ! bash "$work/test/integration/test_api.sh" "http://127.0.0.1:${port}" "$work/test" "$1" "$2" "$3" "$4" "$5" "$6" \
        >"$work/api.log" 2>&1; then
        tail -40 "$work/api.log" >&2
        fail "${what}: test_api.sh failed"
    fi
    # As test.sh: the gateway really signed with the configured version.
    local signed
    signed="$(docker logs "$gw" 2>&1 | grep -c "AWS Signatures Version: v$1\|AWS v$1 Auth" || true)"
    [ "$signed" -ge 3 ] || fail "${what}: gateway did not sign with v$1 (${signed} log lines)"
    pass "$what ($(grep -c . "$work/api.log") lines of test_api.sh output)"
}

# Same configurations as test.sh.
integration 4 0 0 0 "" ""
if [ "${INTEGRATION_QUICK:-0}" != 1 ]; then
    integration 2 0 0 0 "" ""
    integration 2 1 0 0 "" ""
    integration 2 0 1 0 "" ""
    integration 2 1 1 1 "" ""
    integration 4 1 0 1 "" ""
    integration 4 0 1 1 "" ""
    integration 2 0 0 0 /my-bucket ""
    integration 4 0 0 0 "" /b
    integration 4 0 0 0 /tostrip /b
    integration 2 0 0 0 "" /b
fi

echo "all integration tests passed for $TARGET"
