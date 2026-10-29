#!/usr/bin/env bash
# Smoke test of a built unprivileged nginx-s3-gateway image: tests/smoke.sh <image>
# Versions, unprivileged layout, the server (healthy by its HEALTHCHECK, /tmp/drain, unhealthy
# without nginx), njs unit tests.
# Exits non-zero on the first failed check. Needs Docker on the host.
set -euo pipefail

TARGET="${1:?usage: tests/smoke.sh <image>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a
. "$ROOT/versions.env"
set +a

fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

# Expected version: what build.sh resolved (exported), else the image's label.
NGINX_VERSION="${NGINX_VERSION:-$(docker image inspect -f '{{ index .Config.Labels "dev.nginx-s3-gateway.nginx-version" }}' "$TARGET")}"
[ -n "$NGINX_VERSION" ] || fail "no expected nginx version (env or label)"

run() { docker run --rm --platform "$PLATFORM" --entrypoint "$1" "$TARGET" "${@:2}"; }

# 1. Versions and packages
actual="$(run nginx -v 2>&1 | sed -n 's|^nginx version: nginx/\([0-9.]*\).*|\1|p')"
[ "$actual" = "$NGINX_VERSION" ] || fail "nginx is '${actual}', expected ${NGINX_VERSION}"
lowest="$(printf '%s\n%s\n' "$MIN_NGINX_VERSION" "$actual" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)"
[ "$lowest" = "$MIN_NGINX_VERSION" ] || fail "nginx ${actual} is below the floor ${MIN_NGINX_VERSION}"
pass "nginx ${actual} (floor ${MIN_NGINX_VERSION})"

# Every nginx package (nginx, njs, xslt, ...) is built for that exact nginx.
pkgs="$(run dpkg-query -W -f '${db:Status-Abbrev} ${Package} ${Version}\n' 'nginx*' | sed -n 's/^ii  *//p')"
while read -r pkg ver; do
    case "$ver" in
        "${NGINX_VERSION}-"*|"${NGINX_VERSION}+"*) ;;
        *) fail "${pkg} ${ver} is not built for nginx ${NGINX_VERSION}" ;;
    esac
done <<<"$pkgs"
grep -q '^nginx-module-njs ' <<<"$pkgs" || fail "nginx-module-njs is not installed"
grep -q '^nginx-module-xslt ' <<<"$pkgs" || fail "nginx-module-xslt is not installed"
pass "packages match nginx ${NGINX_VERSION}: $(tr '\n' ' ' <<<"$pkgs")"

for m in ngx_http_js_module.so ngx_http_xslt_filter_module.so; do
    run test -f "/etc/nginx/modules/${m}" || fail "module ${m} missing"
done
pass "njs and xslt modules present"

# 2. Unprivileged layout
user="$(docker image inspect -f '{{.Config.User}}' "$TARGET")"
[ "$user" = nginx ] || fail "image USER is '${user}', expected nginx"
uid="$(run id -u)"
[ "$uid" != 0 ] || fail "runs as root"
pass "USER nginx (uid ${uid})"

grep -q '8080/tcp' <<<"$(docker image inspect -f '{{json .Config.ExposedPorts}}' "$TARGET")" || fail "8080/tcp not exposed"
conf="$(run cat /etc/nginx/nginx.conf)"
grep -q 'pid[[:space:]]*/tmp/nginx.pid' <<<"$conf" || fail "pid is not in /tmp"
grep -q 'proxy_temp_path /tmp/proxy_temp' <<<"$conf" || fail "proxy temp path is not in /tmp"
! grep -q '^user ' <<<"$conf" || fail "nginx.conf still has a user directive"
grep -q 'listen 8080;' <<<"$(run cat /etc/nginx/templates/default.conf.template)" || fail "template does not listen on 8080"
grep -q 'http://127.0.0.1:8080' <<<"$(run cat /etc/nginx/include/s3gateway.js)" || fail "s3gateway.js does not loop back to 8080"
pass "port 8080, pid and temp paths in /tmp, no user directive"

# Healthcheck (what docker rollout waits for): the exact configuration here, its behaviour in 3.
HC_EXPECTED='[CMD-SHELL test ! -f /tmp/drain && curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:8080/health || exit 1] 10s 3s 30s 1s 3'
hc="$(docker image inspect -f '{{with .Config.Healthcheck}}{{.Test}} {{.Interval}} {{.Timeout}} {{.StartPeriod}} {{.StartInterval}} {{.Retries}}{{else}}none{{end}}' "$TARGET")"
case "$hc" in none|"[NONE] "*) fail "no HEALTHCHECK in the image" ;; esac   # [NONE]: HEALTHCHECK NONE
[ "$hc" = "$HC_EXPECTED" ] || fail "HEALTHCHECK is [$hc], expected [$HC_EXPECTED]"
pass "HEALTHCHECK: /tmp/drain + curl :8080/health, every 10s (1s while starting), 3 retries"

# 3. The server itself, as the image user and as an arbitrary uid of group 0 (OpenShift-style)
env_args=(-e S3_BUCKET_NAME=smoke -e S3_SERVER=127.0.0.1 -e S3_SERVER_PORT=9000 -e S3_SERVER_PROTO=http
    -e S3_REGION=us-east-1 -e S3_STYLE=path -e ALLOW_DIRECTORY_LIST=false -e AWS_SIGS_VERSION=4
    -e AWS_ACCESS_KEY_ID=smoke -e AWS_SECRET_ACCESS_KEY=smoke)
cids=()
remove_containers() { local c; for c in ${cids[@]+"${cids[@]}"}; do docker rm -f "$c" >/dev/null 2>&1 || true; done; }
trap remove_containers EXIT

# wait_health <container> <status> <seconds>: until Docker reports that health status.
wait_health() {
    local cid="$1" want="$2" got=""
    for _ in $(seq 1 $(($3 * 2))); do
        got="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$cid")"
        [ "$got" = "$want" ] && return 0
        sleep 0.5
    done
    echo "health is [${got}] after $3 s, expected [${want}]; checks: $(docker inspect -f '{{with .State.Health}}{{json .Log}}{{end}}' "$cid" | tail -c 600)" >&2
    return 1
}

serve() {   # serve <description> [docker run options...]: the container id is left in $SERVED
    local what="$1" cid
    shift
    cid="$(docker run -d --platform "$PLATFORM" "$@" "${env_args[@]}" "$TARGET")"
    cids+=("$cid")
    SERVED="$cid"
    for _ in $(seq 1 30); do
        if [ "$(docker exec "$cid" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/health 2>/dev/null)" = 200 ]; then
            local owner
            owner="$(docker exec "$cid" stat -c %u /proc/1)"
            [ "$owner" != 0 ] || fail "${what}: nginx master runs as root"
            pass "${what}: /health 200 on :8080, master uid ${owner}"
            wait_health "$cid" healthy 15 || fail "${what}: never healthy with the image's HEALTHCHECK"
            pass "${what}: healthy"
            return 0
        fi
        if [ "$(docker inspect -f '{{.State.Running}}' "$cid")" != true ]; then
            docker logs "$cid" >&2
            fail "${what}: container exited"
        fi
        sleep 1
    done
    docker logs "$cid" >&2
    fail "${what}: /health never answered 200"
}

serve "as nginx"
serve "as uid 12345, group 0" --user 12345:0
serve "read-only root filesystem with tmpfs" --read-only --tmpfs /tmp --tmpfs /var/cache/nginx:uid=101,gid=0 --tmpfs /etc/nginx/conf.d:uid=101,gid=0

# The same healthcheck command, checked every second and unhealthy at the first failure: seconds
# instead of the 30 s the production timings need. Drain on the read-only layout (/tmp a tmpfs).
FAST=(--health-interval=1s --health-retries=1 --health-start-period=1ms)
serve "read-only, fast healthcheck timings" "${FAST[@]}" --read-only --tmpfs /tmp --tmpfs /var/cache/nginx:uid=101,gid=0 --tmpfs /etc/nginx/conf.d:uid=101,gid=0
docker exec "$SERVED" touch /tmp/drain
wait_health "$SERVED" unhealthy 10 || fail "still healthy with /tmp/drain: docker rollout could not drain it"
[ "$(docker exec "$SERVED" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/health)" = 200 ] \
    || fail "the gateway stopped serving while draining"
docker exec "$SERVED" rm /tmp/drain
wait_health "$SERVED" healthy 10 || fail "not healthy again once /tmp/drain is removed"
pass "/tmp/drain: unhealthy while it exists (gateway still serving), healthy again without it"

cid="$(docker run -d --platform "$PLATFORM" "${FAST[@]}" --entrypoint sleep "$TARGET" infinity)"
cids+=("$cid")
wait_health "$cid" unhealthy 10 || fail "healthy although nginx is not running: the HEALTHCHECK does not test the gateway"
pass "unhealthy when nginx does not run"

# 4. njs unit tests of upstream (test/unit), run by the image's own njs, as test.sh does
unit() {   # unit <file> [extra docker env...]
    docker run --rm --platform "$PLATFORM" -v "$ROOT/test/unit:/var/tmp:ro" --workdir /var/tmp \
        -e DEBUG=true -e S3_STYLE=virtual-v2 -e S3_SERVICE=s3 -e AWS_ACCESS_KEY_ID=unit_test \
        -e AWS_SECRET_ACCESS_KEY=unit_test -e S3_BUCKET_NAME=unit_test -e S3_SERVER=unit_test \
        -e S3_SERVER_PROTO=https -e S3_SERVER_PORT=443 -e S3_REGION=test-1 -e AWS_SIGS_VERSION=4 \
        "${@:2}" --entrypoint /usr/bin/njs "$TARGET" -t module -p /etc/nginx "/var/tmp/$1" >/dev/null \
        || fail "njs unit test $1 ${*:2}"
}
unit utils_test.js -e AWS_SESSION_TOKEN=unit_test
for t in awscredentials_test.js awssig2_test.js awssig4_test.js s3gateway_test.js; do
    unit "$t"
    unit "$t" -e AWS_SESSION_TOKEN=unit_test
done
pass "njs unit tests (test/unit, with and without session token)"

echo "all smoke checks passed for $TARGET"
