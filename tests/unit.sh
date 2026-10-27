#!/usr/bin/env bash
# Unit tests of the scripts in scripts/: offline, no Docker, a few seconds. Needs python3 and curl.
#   tests/unit.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIX="$ROOT/tests/fixtures"
FAILED=0

pass() { echo "ok   $*"; }
bad() { echo "FAIL $*" >&2; FAILED=1; }

# Runs the resolver offline on the fixture, with extra VAR=value assignments.
resolve() {
    env -i PATH="$PATH" NGINX_SERIES=1.30 DEBIAN=trixie NGINX_TAGS_JSON_FILE="$FIX/nginx-tags.json" \
        "$@" "$ROOT/scripts/resolve-versions.sh" 2>&1
}

expect_ok() {   # <name> <expected output> <command...>
    local name="$1" expected="$2" out
    shift 2
    if out="$("$@")" && [ "$out" = "$expected" ]; then pass "$name"; else bad "$name: got [$out]"; fi
}

expect_fail() {   # <name> <expected message part> <command...>
    local name="$1" msg="$2" out
    shift 2
    if out="$("$@")"; then bad "$name: succeeded with [$out]"
    elif [[ "$out" == *"$msg"* ]]; then pass "$name"
    else bad "$name: failed, but with [$out]"; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"; [ -z "${server_pid:-}" ] || kill "$server_pid" 2>/dev/null || true' EXIT

echo "--- resolve-versions.sh"
expect_ok "latest 1.30.x with a same-digest -trixie tag (1.30.10 > 1.30.9; not 1.30.11 without trixie, not 1.30.12 with another trixie digest, not 1.300.1, not -alpine)" \
    "NGINX_VERSION=1.30.10" resolve
expect_ok "NGINX_VERSION override: a published version is accepted" "NGINX_VERSION=1.30.9" resolve NGINX_VERSION=1.30.9
expect_fail "NGINX_VERSION override: unpublished version" "(asked: 1.30.99)" resolve NGINX_VERSION=1.30.99
expect_fail "NGINX_VERSION override: no trixie variant" "(asked: 1.30.11)" resolve NGINX_VERSION=1.30.11
expect_fail "NGINX_VERSION override: outside the series" "(asked: 1.300.1)" resolve NGINX_VERSION=1.300.1
expect_fail "another Debian: nothing matches" "not a published 1.30.x release on bullseye" resolve DEBIAN=bullseye
expect_ok "another Debian with a match" "NGINX_VERSION=1.30.11" resolve DEBIAN=bookworm NGINX_SERIES=1.30 \
    NGINX_TAGS_JSON_FILE="$FIX/nginx-tags.json" NGINX_VERSION=1.30.11
expect_fail "series without any release" "not a published 1.31.x release" resolve NGINX_SERIES=1.31
echo '{"count": 0, "next": null, "results": []}' > "$tmp/none.json"
expect_fail "empty tag list" "is not a published 1.30.x" resolve NGINX_TAGS_JSON_FILE="$tmp/none.json"
echo '<html>maintenance</html>' > "$tmp/html.json"
expect_fail "answer is not JSON" "Docker Hub did not return JSON" resolve NGINX_TAGS_JSON_FILE="$tmp/html.json"
echo '{"message": "too many requests"}' > "$tmp/limit.json"
expect_fail "Docker Hub error object (rate limit)" "Docker Hub: too many requests" resolve NGINX_TAGS_JSON_FILE="$tmp/limit.json"

echo "--- version-compare.sh (no-downgrade)"
cmp() { "$ROOT/scripts/version-compare.sh" "$@" && echo allowed || echo refused; }
expect_ok "1.30.5 -> 1.30.6 allowed" allowed cmp 1.30.5 1.30.6
expect_ok "1.30.6 -> 1.30.5 refused" refused cmp 1.30.6 1.30.5
expect_ok "1.30.9 -> 1.30.10 allowed (numeric, not lexical)" allowed cmp 1.30.9 1.30.10
expect_ok "1.30.10 -> 1.30.9 refused (numeric, not lexical)" refused cmp 1.30.10 1.30.9
expect_ok "same version allowed (nightly rebuild)" allowed cmp 1.30.6 1.30.6
expect_ok "nothing published yet allowed" allowed cmp "" 1.30.6

echo "--- trivy-diff.py (vulnerability gate)"
vuln() { printf '{"VulnerabilityID": "%s", "PkgName": "%s", "Severity": "%s", "FixedVersion": "9"}' "$@"; }
printf '{"Results": [{"Vulnerabilities": [%s, %s]}]}' "$(vuln CVE-1 libssl3 CRITICAL)" "$(vuln CVE-2 curl HIGH)" > "$tmp/t-pub.json"
printf '{"Results": [{"Vulnerabilities": [%s]}]}' "$(vuln CVE-1 libssl3 CRITICAL)" > "$tmp/t-same.json"
printf '{"Results": [{"Vulnerabilities": [%s, %s]}]}' "$(vuln CVE-1 libssl3 CRITICAL)" "$(vuln CVE-3 libxml2 CRITICAL)" > "$tmp/t-new.json"
printf '{"Results": [{"Target": "x", "Vulnerabilities": null}]}' > "$tmp/t-clean.json"
td() { python3 -I "$ROOT/scripts/trivy-diff.py" "$@" 2>&1; }
expect_ok "a CRITICAL the published image already has: pass" \
    "$(printf '  info candidate: 1 fixable CRITICAL, 0 fixable HIGH\n  info 1 fixable HIGH/CRITICAL of the published image fixed by the candidate\n  ok   no fixable CRITICAL the published image does not already have')" \
    td "$tmp/t-same.json" "$tmp/t-pub.json"
expect_fail "a new fixable CRITICAL: refused" "CVE-3 in libxml2 (fixed in 9)" td "$tmp/t-new.json" "$tmp/t-pub.json"
expect_ok "clean candidate: pass" \
    "$(printf '  info candidate: 0 fixable CRITICAL, 0 fixable HIGH\n  info 2 fixable HIGH/CRITICAL of the published image fixed by the candidate\n  ok   no fixable CRITICAL the published image does not already have')" \
    td "$tmp/t-clean.json" "$tmp/t-pub.json"
expect_ok "nothing published yet: report only" \
    "$(printf '  info candidate: 2 fixable CRITICAL, 0 fixable HIGH\n  info no published image to compare with: report only')" \
    td "$tmp/t-new.json" ""

echo "--- served-ids.py (post-push check)"
expect_ok "single manifest: top digest and config digest" "$(printf 'sha256:top\nsha256:cfg')" \
    python3 -I "$ROOT/scripts/served-ids.py" sha256:top '{"config": {"digest": "sha256:cfg"}}' linux/amd64
expect_ok "index: asks for the amd64 child" "need-child sha256:amd" \
    python3 -I "$ROOT/scripts/served-ids.py" sha256:top \
    '{"manifests": [{"digest": "sha256:arm", "platform": {"os": "linux", "architecture": "arm64"}}, {"digest": "sha256:amd", "platform": {"os": "linux", "architecture": "amd64"}}]}' linux/amd64
expect_ok "--digest: the human-readable block of an old buildx gives the top digest" "sha256:f2b3670d7396b5df0e0e613842405e847850baa247c7468e229f57dd392d8462" \
    sh -c 'printf "Name:      r\nMediaType: m\nDigest:    sha256:f2b3670d7396b5df0e0e613842405e847850baa247c7468e229f57dd392d8462\n" | python3 -I "$1" --digest' _ "$ROOT/scripts/served-ids.py"
expect_ok "--digest: the JSON of .Manifest" "sha256:f2b3670d7396b5df0e0e613842405e847850baa247c7468e229f57dd392d8462" \
    sh -c 'printf "{\"mediaType\": \"m\", \"digest\": \"sha256:f2b3670d7396b5df0e0e613842405e847850baa247c7468e229f57dd392d8462\"}" | python3 -I "$1" --digest' _ "$ROOT/scripts/served-ids.py"
expect_fail "--digest: an answer without a digest is refused" "no top-level digest" \
    sh -c 'printf "Name:      r\n" | python3 -I "$1" --digest 2>&1' _ "$ROOT/scripts/served-ids.py"
expect_fail "a top that is not a digest is refused" "the top digest is not a digest" \
    sh -c 'python3 -I "$1" "Name:      r" "{\"config\": {\"digest\": \"sha256:cfg\"}}" linux/amd64 2>&1' _ "$ROOT/scripts/served-ids.py"

echo "--- notify.sh"
expect_ok "no NTFY_TOPIC: skipped, exit 0" "notify: NTFY_TOPIC not set, skipped: t" \
    env -u NTFY_TOPIC "$ROOT/scripts/notify.sh" high warning t m

# A local stand-in for ntfy (POST) and Docker Hub (GET, two pages), recording each request.
port="$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')"
python3 -I - "$port" "$tmp/requests.jsonl" <<'PY' &
import http.server, json, sys
port, log = int(sys.argv[1]), sys.argv[2]
def tag(n, d): return {"name": n, "digest": "sha256:" + d * 64}
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode()
        with open(log, "a") as f:
            f.write(json.dumps({"path": self.path, "headers": dict(self.headers), "body": body}) + "\n")
        self.send_response(200); self.end_headers(); self.wfile.write(b"{}")
    def do_GET(self):
        with open(log + ".get", "a") as f:
            f.write(self.path + "\n")
        if self.path.startswith("/v2/repositories/library/nginx/tags"):
            if "page=2" in self.path:
                d = {"next": None, "results": [tag("1.30.8", "c"), tag("1.30.8-trixie", "c")]}
            else:
                d = {"next": "http://127.0.0.1:%d/v2/repositories/library/nginx/tags?name=1.30.&page_size=100&page=2" % port,
                     "results": [tag("1.30.7", "a"), tag("1.30.7-trixie", "a")]}
            body = json.dumps(d).encode()
        else:
            body = b"{}"
        self.send_response(200); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
server_pid=$!
for _ in $(seq 1 50); do curl -s -o /dev/null "http://127.0.0.1:$port/" 2>/dev/null && break; sleep 0.1; done

# env -i: in CI, CI_PIPELINE_URL (and maybe NTFY_TOKEN) are already set and would leak in.
env -i PATH="$PATH" NTFY_URL="http://127.0.0.1:$port" NTFY_TOPIC=nginx-test NTFY_TOKEN=tk_secret \
    CI_PIPELINE_URL=https://git.example/p/1 "$ROOT/scripts/notify.sh" urgent "rotating_light" "Build failed" "smoke test failed" >/dev/null
env -i PATH="$PATH" NTFY_URL="http://127.0.0.1:$port" NTFY_TOPIC=nginx-test "$ROOT/scripts/notify.sh" default "" "No token" "plain" >/dev/null
if python3 -I - "$tmp/requests.jsonl" <<'PY'
import json, sys
r = [json.loads(l) for l in open(sys.argv[1])]
assert len(r) == 2, r
a, b = r
assert a["path"] == "/nginx-test", a
assert a["headers"]["Title"] == "Build failed" and a["headers"]["Priority"] == "urgent", a
assert a["headers"]["Tags"] == "rotating_light" and a["headers"]["Click"] == "https://git.example/p/1", a
assert a["headers"]["Authorization"] == "Bearer tk_secret" and a["body"] == "smoke test failed", a
assert "Authorization" not in b["headers"] and "Click" not in b["headers"] and b["body"] == "plain", b
PY
then pass "topic, title, priority, tags, click URL, bearer token and body sent; no token header without NTFY_TOKEN"
else bad "notify request content"; fi

echo "--- resolve-versions.sh over HTTP (local Docker Hub stand-in, two pages)"
expect_ok "follows next: the newest is on page 2" "NGINX_VERSION=1.30.8" \
    env -i PATH="$PATH" NGINX_SERIES=1.30 DEBIAN=trixie DOCKERHUB_API_URL="http://127.0.0.1:$port" "$ROOT/scripts/resolve-versions.sh"
if [ "$(cat "$tmp/requests.jsonl.get" | grep -c '^/v2/repositories/library/nginx/tags?name=1.30.&page_size=100')" = 2 ]; then
    pass "Docker Hub requests: name=1.30. filter, pages of 100, both pages fetched"
else bad "Docker Hub requests: $(tr '\n' ' ' < "$tmp/requests.jsonl.get")"; fi

kill "$server_pid"; wait "$server_pid" 2>/dev/null || true; server_pid=""
expect_fail "Docker Hub unreachable" "cannot reach Docker Hub" \
    resolve NGINX_TAGS_JSON_FILE= DOCKERHUB_API_URL="http://127.0.0.1:$port"
expect_ok "ntfy unreachable: exit 0, error only logged" "" \
    env NTFY_URL="http://127.0.0.1:$port" NTFY_TOPIC=t "$ROOT/scripts/notify.sh" high x t m

# tests/os-updates.sh on captured `apt-get -s upgrade / dist-upgrade` outputs (tests/fixtures/apt/;
# pending.txt is python-docker's published image of 24 Oct 2026, before CVE-2026-111497's libbrotli1 fix).
osu() { env OS_UPDATES_FILE="$FIX/apt/$1.txt" "$ROOT/tests/os-updates.sh" image 2>&1; }
expect_fail "os-updates: Debian security updates pending -> refused" "FAIL 7 Debian update(s) missing" osu pending
expect_fail "os-updates: names the package and both versions" "libbrotli1 1.1.0-2+b7 -> 1.1.0-2+deb13u1" osu pending
expect_fail "os-updates: stable-updates counts too" "tzdata 2026c-0+deb13u1 -> 2026e-0+deb13u1" osu pending
expect_ok "os-updates: nothing pending -> accepted" "  ok   no Debian update pending" osu clean
expect_ok "os-updates: a third-party repository (nginx.org) is not counted" "  ok   no Debian update pending" osu third-party
expect_ok "os-updates: what only dist-upgrade would do is a warning" "$(printf '%s\n' \
    "  WARNING only dist-upgrade would apply (new or removed packages; not done, a human decides):" \
    "    libfoo-common none -> 1.0-1+deb13u1" "    libfoo-old1 removed" "    libfoo1 1.0-1 -> 1.0-1+deb13u1" \
    "  ok   no Debian update pending")" osu kept-back
printf 'Err:1 http://deb.debian.org/debian trixie InRelease\n' >"$tmp/apt-broken.txt"
expect_fail "os-updates: an apt output without both simulations -> refused" "FAIL unexpected apt-get output" \
    env OS_UPDATES_FILE="$tmp/apt-broken.txt" "$ROOT/tests/os-updates.sh" image

if [ "$FAILED" = 0 ]; then echo "all unit tests passed"; else echo "unit tests FAILED" >&2; exit 1; fi
