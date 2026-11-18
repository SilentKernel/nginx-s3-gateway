#!/usr/bin/env bash
# Smoke test of a built unprivileged nginx-s3-gateway image: tests/smoke.sh <image>
# Versions, unprivileged layout, the server in front of MinIO (healthy by its HEALTHCHECK, /tmp/drain, the DEEP
# /health: 503 and unhealthy with wrong keys or S3 gone, healthy again when it is back, S3's own status in its log
# line; S3 reached over IPv4 only when its name also has an IPv6 address; unhealthy without nginx), njs unit tests.
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
HC_EXPECTED='[CMD-SHELL test ! -f /tmp/drain && curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:8080/health || exit 1] 30s 3s 30s 1s 3'
hc="$(docker image inspect -f '{{with .Config.Healthcheck}}{{.Test}} {{.Interval}} {{.Timeout}} {{.StartPeriod}} {{.StartInterval}} {{.Retries}}{{else}}none{{end}}' "$TARGET")"
case "$hc" in none|"[NONE] "*) fail "no HEALTHCHECK in the image" ;; esac   # [NONE]: HEALTHCHECK NONE
[ "$hc" = "$HC_EXPECTED" ] || fail "HEALTHCHECK is [$hc], expected [$HC_EXPECTED]"
pass "HEALTHCHECK: /tmp/drain + curl :8080/health, every 30s (1s while starting), 3 retries"
docker image inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$TARGET" | grep -qx 'HEALTH_CACHE_VALID=5m' \
    || fail "HEALTH_CACHE_VALID is not 5m in the image: the deep /health would ask the bucket too often"
pass "deep /health keeps S3's answer 5 minutes (HEALTH_CACHE_VALID=5m): the bucket is not asked every second"

# 3. The server itself, as the image user and as an arbitrary uid of group 0 (OpenShift-style), in front of a real S3
# (MinIO, the integration test's pinned image, bucket `smoke`): /health is DEEP, it asks S3 (200 only when S3 answers)
MINIO_IMAGE="${MINIO_IMAGE:-pgsty/minio:RELEASE.2026-08-04T00-00-00Z@sha256:b6bfe7239bfc83fb90d31612d9704d86039dd714f7904b3f1ad68f211e602372}"
SNET="s3gw-smoke-$$"
SNET6="s3gw-smoke6-$$"   # the IPv6 case below
cids=()
remove_containers() { local c; for c in ${cids[@]+"${cids[@]}"}; do docker rm -f "$c" >/dev/null 2>&1 || true; done; docker network rm "$SNET" "$SNET6" >/dev/null 2>&1 || true; }
trap remove_containers EXIT
docker network create "$SNET" >/dev/null
minio="$(docker run -d --network "$SNET" --network-alias minio -e MINIO_ROOT_USER=smokeuser -e MINIO_ROOT_PASSWORD=smokepassword \
    -e MINIO_REGION_NAME=us-east-1 -e MINIO_BROWSER=off "$MINIO_IMAGE" minio server /data)"
cids+=("$minio")
for _ in $(seq 1 30); do docker exec "$minio" curl -fsS -o /dev/null http://127.0.0.1:9000/minio/health/live 2>/dev/null && break; sleep 1; done
docker exec "$minio" sh -c 'mc alias set t http://127.0.0.1:9000 smokeuser smokepassword >/dev/null && mc mb t/smoke >/dev/null' || fail "MinIO: bucket smoke"
s3_env=(-e S3_BUCKET_NAME=smoke -e S3_SERVER=minio -e S3_SERVER_PORT=9000 -e S3_SERVER_PROTO=http
    -e S3_REGION=us-east-1 -e S3_STYLE=path -e ALLOW_DIRECTORY_LIST=false -e AWS_SIGS_VERSION=4
    -e AWS_ACCESS_KEY_ID=smokeuser -e AWS_SECRET_ACCESS_KEY=smokepassword -e HEALTH_CACHE_VALID=2s)
# (HEALTH_CACHE_VALID: 2 s here instead of the image's 5m, so S3 stopping shows within seconds)
env_args=(--network "$SNET" "${s3_env[@]}")

# health_log <container> <extended regex> <seconds>: until a /health line of the access log matches. The line ends
# with what S3 itself answered (log_format health): s3=<status> cache=<cache status> s3_time=<seconds>.
health_log() {
    for _ in $(seq 1 $(($3 * 2))); do
        docker logs "$1" 2>&1 | grep -F '"GET /health ' | grep -qE -- "$2" && return 0
        sleep 0.5
    done
    echo "no /health log line matches [$2] after $3 s; the last ones:" >&2
    docker logs "$1" 2>&1 | grep -F '"GET /health ' | tail -3 >&2
    return 1
}

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

# The /health log line says what S3 answered: 404 (no object `health`: the healthy answer) when S3 was asked, and
# the kept answer in between (cache HIT, S3 not asked).
health_log "$SERVED" ' 200 [0-9]+ .* s3=404 cache=(MISS|EXPIRED) s3_time=[0-9.]+$' 5 \
    || fail "no s3= in the /health log line of a healthy gateway (want: 200 ... s3=404 cache=MISS|EXPIRED s3_time=...)"
health_log "$SERVED" ' 200 [0-9]+ .* s3=- cache=HIT s3_time=-$' 5 \
    || fail "/health log: no line for the kept answer (want: 200 ... s3=- cache=HIT)"
pass "/health log: S3's own answer (s3=404 when asked, s3=- cache=HIT for the kept answer)"

# IPv4 only. Production: the container has no IPv6 (net.ipv6.conf.all.disable_ipv6=1 in every stack) and the S3 name
# has an A and an AAAA record. nginx's own resolver took both, the IPv6 peer could never connect (errno 99), was set
# aside for 10 s, and one slow IPv4 answer in that window left "no live upstreams" (2026-11-18). Here: MinIO joins a
# second network that has IPv6, under the name minio6 (A + AAAA in Docker's DNS), and a gateway without IPv6 serves
# 20 requests that each ask S3 (objects that do not exist: nothing kept). Never skipped: a Docker that cannot create
# an IPv6 network fails this test.
docker network create --ipv6 --subnet "fd53:33:$(printf '%x' $(($$ % 65536)))::/64" "$SNET6" >/dev/null \
    || fail "IPv6: Docker could not create a network with IPv6 (needed to give the S3 name an AAAA record)"
docker network connect --alias minio6 "$SNET6" "$minio"
minio_v6="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$SNET6\").GlobalIPv6Address}}" "$minio")"
[ -n "$minio_v6" ] || fail "IPv6: MinIO got no IPv6 address on ${SNET6}: the test would prove nothing"
cid="$(docker run -d --platform "$PLATFORM" --network "$SNET6" --sysctl net.ipv6.conf.all.disable_ipv6=1 \
    "${s3_env[@]}" -e S3_SERVER=minio6 "$TARGET")"
cids+=("$cid")
for _ in $(seq 1 30); do c="$(docker exec "$cid" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/health 2>/dev/null || true)"; [ "$c" = 200 ] && break; sleep 1; done
[ "$c" = 200 ] || { docker logs "$cid" >&2; fail "IPv6: /health answered [$c] on the gateway without IPv6 (want 200)"; }
codes=""
for i in $(seq 1 20); do codes="${codes} $(docker exec "$cid" curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:8080/no-such-object-${i}")"; done
[ "$(tr ' ' '\n' <<<"$codes" | grep -c '^404$')" = 20 ] || fail "IPv6: 20 requests for missing objects answered [${codes} ] (want 20 x 404)"
v6_lines="$(docker logs "$cid" 2>&1 | grep -E 'connect\(\) to \[|temporarily disabled|no live upstreams' || true)"
[ -z "$v6_lines" ] || { head -4 <<<"$v6_lines" | cut -c1-220 >&2; fail "IPv6: the gateway tried S3 over IPv6 (${minio_v6}) although its container has none: resolver without ipv6=off"; }
pass "IPv4 only: S3 name with an IPv6 address (${minio_v6}), container without IPv6: 20 requests, no IPv6 try, no peer set aside"

# DEEP: /health asks S3. Wrong keys: 503 and unhealthy (docker rollout keeps the old copy); S3 gone: 503 once the
# cached answer expires, unhealthy; S3 back: 200, healthy again
cid="$(docker run -d --platform "$PLATFORM" "${FAST[@]}" "${env_args[@]}" -e AWS_SECRET_ACCESS_KEY=wrong-secret "$TARGET")"
cids+=("$cid")
for _ in $(seq 1 30); do c="$(docker exec "$cid" curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8080/health 2>/dev/null || true)"; [ "$c" = 503 ] && break; sleep 1; done
[ "$c" = 503 ] || fail "deep health: /health answered [$c] with a wrong secret key (want 503)"
wait_health "$cid" unhealthy 15 || fail "deep health: healthy with a wrong secret key"
health_log "$cid" ' 503 [0-9]+ .* s3=403 ' 5 || fail "/health log: no s3=403 with a wrong secret key (S3's refusal must show)"
pass "deep /health: a wrong secret key -> 503, unhealthy, s3=403 in its log line"
docker stop -t 1 "$minio" >/dev/null
for _ in $(seq 1 15); do c="$(docker exec "$SERVED" curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8080/health 2>/dev/null || true)"; [ "$c" = 503 ] && break; sleep 1; done
[ "$c" = 503 ] || fail "deep health: /health answered [$c] with S3 stopped (want 503)"
wait_health "$SERVED" unhealthy 15 || fail "deep health: still healthy with S3 stopped"
health_log "$SERVED" ' 503 [0-9]+ .* s3=(502|504)' 5 || fail "/health log: no s3=502 or s3=504 with S3 stopped"
docker start "$minio" >/dev/null
for _ in $(seq 1 30); do docker exec "$minio" curl -fsS -o /dev/null http://127.0.0.1:9000/minio/health/live 2>/dev/null && break; sleep 1; done
wait_health "$SERVED" healthy 20 || fail "deep health: not healthy again once S3 is back"
pass "deep /health: S3 stopped -> 503, unhealthy, s3=502|504 in its log line; S3 back -> healthy"

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
