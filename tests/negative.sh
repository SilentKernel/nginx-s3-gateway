#!/usr/bin/env bash
# Negative tests: the gates must refuse broken variants of the candidate.
#   tests/negative.sh <candidate>
# Each variant is a one-layer image derived from the candidate (cheap, nothing is compiled), under a
# private name removed afterwards. A gate that passes a broken image is a broken gate: this fails.
set -euo pipefail

CANDIDATE="${1:?usage: tests/negative.sh <candidate>}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
set -a
. "$ROOT/versions.env"
set +a
# smoke.sh compares with what build.sh resolved, else the label (kept by the variants).
NGINX_VERSION="${NGINX_VERSION:-$(docker image inspect -f '{{ index .Config.Labels "dev.nginx-s3-gateway.nginx-version" }}' "$CANDIDATE")}"
export NGINX_VERSION

prefix="nginx-s3-negative-$$"
log="$(mktemp)"
# variant runs in $(...): the images are found back by their private name.
trap 'rm -f "$log"; docker image ls -q --filter "reference=${prefix}:*" | sort -u | xargs docker image rm -f >/dev/null 2>&1 || true' EXIT

variant() {   # variant <name> <Dockerfile lines after FROM>
    local tag="${prefix}:$1"
    printf 'FROM %s\n%s\n' "$CANDIDATE" "$2" | docker build --quiet --platform "$PLATFORM" -t "$tag" - >/dev/null
    echo "$tag"
}

refused() {   # refused <description> <expected message part> <command...>
    local what="$1" msg="$2"
    shift 2
    if "$@" >"$log" 2>&1; then
        tail -20 "$log" >&2
        echo "FAIL: ${what}: the gate passed it" >&2
        exit 1
    fi
    if ! grep -qF -- "$msg" "$log"; then
        tail -20 "$log" >&2
        echo "FAIL: ${what}: refused, but not for the expected reason (${msg})" >&2
        exit 1
    fi
    echo "ok   refused: ${what}"
}

refused "image running as root" "image USER is 'root'" \
    "$ROOT/tests/smoke.sh" "$(variant root 'USER root')"
refused "image without the njs module" "ngx_http_js_module.so missing" \
    "$ROOT/tests/smoke.sh" "$(variant no-njs 'USER root
RUN rm /etc/nginx/modules/ngx_http_js_module.so
USER nginx')"
refused "image listening on port 80" "template does not listen on 8080" \
    "$ROOT/tests/smoke.sh" "$(variant port-80 'USER root
RUN sed -i "s/listen 8080;/listen 80;/" /etc/nginx/templates/default.conf.template
USER nginx')"
refused "other nginx version than expected" "expected 0.0.1" \
    env NGINX_VERSION=0.0.1 "$ROOT/tests/smoke.sh" "$CANDIDATE"
# A wrong signature: the njs unit tests must catch it, and so must the real S3 server.
sigv4_broken="$(variant sigv4-broken 'USER root
RUN sed -i "s/AWS4-HMAC-SHA256/AWS4-HMAC-SHA1/g" /etc/nginx/include/awssig4.js
USER nginx')"
refused "broken AWS v4 signature (njs unit tests)" "njs unit test awssig4_test.js" \
    "$ROOT/tests/smoke.sh" "$sigv4_broken"
refused "broken AWS v4 signature (integration against MinIO)" "test_api.sh failed" \
    env INTEGRATION_QUICK=1 "$ROOT/tests/integration.sh" "$sigv4_broken"

# Healthcheck: removed, retimed, or answering without looking at the gateway. The curl wrappers lie
# only to the healthcheck (the one call with --max-time); smoke.sh's own requests get the real curl.
curl_wrapper() {   # curl_wrapper <exit code for the healthcheck>: Dockerfile lines
    cat <<EOF
USER root
RUN printf '#!/bin/sh\\ncase " \$* " in *" --max-time "*) exit $1;; esac\\nexec /usr/bin/curl "\$@"\\n' > /usr/local/bin/curl && chmod +x /usr/local/bin/curl
USER nginx
EOF
}
refused "image without HEALTHCHECK" "no HEALTHCHECK in the image" \
    "$ROOT/tests/smoke.sh" "$(variant no-healthcheck 'HEALTHCHECK NONE')"
refused "HEALTHCHECK on port 80, every 5 minutes" "HEALTHCHECK is [[CMD-SHELL curl" \
    "$ROOT/tests/smoke.sh" "$(variant healthcheck-80 'HEALTHCHECK --interval=5m CMD curl -fsS -o /dev/null http://127.0.0.1/health || exit 1')"
refused "healthcheck passing without the gateway" "healthy although nginx is not running" \
    "$ROOT/tests/smoke.sh" "$(variant always-healthy "$(curl_wrapper 0)")"
refused "healthcheck that never passes" "never healthy with the image's HEALTHCHECK" \
    "$ROOT/tests/smoke.sh" "$(variant never-healthy "$(curl_wrapper 7)")"

# Debian updates not applied: an old trixie snapshot (pinned by digest, so it always has pending
# updates) must be refused by tests/os-updates.sh, and the candidate accepted.
OLD_TRIXIE=debian:trixie-20250811@sha256:6d87375016340817ac2391e670971725a9981cfc24e221c47734681ed0f6c0f5
refused "Debian updates missing (trixie of 11 Aug 2025)" "Debian update(s) missing" \
    "$ROOT/tests/os-updates.sh" "$OLD_TRIXIE"
if "$ROOT/tests/os-updates.sh" "$CANDIDATE" >"$log" 2>&1; then echo "ok   the candidate passes os-updates.sh"
else tail -5 "$log" >&2; echo "FAIL: the candidate itself is refused by os-updates.sh" >&2; exit 1; fi

echo "all negative tests passed: every broken variant was refused"
