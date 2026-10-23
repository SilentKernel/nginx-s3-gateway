#!/usr/bin/env bash
# Resolves the version to build and prints it as a KEY=value line (build.sh evals it):
#   NGINX_VERSION   latest nginx ${NGINX_SERIES}.x of the official image on Docker Hub, among the
#                   versions also published as <version>-${DEBIAN} with the same digest (the image
#                   we build on is Debian ${DEBIAN}, not an older or newer Debian)
#
# Inputs (environment): NGINX_SERIES, DEBIAN (versions.env). Override: NGINX_VERSION (it must still
# be a published ${NGINX_SERIES}.x on ${DEBIAN}).
# Test hooks: NGINX_TAGS_JSON_FILE replaces the network call (one page), DOCKERHUB_API_URL points it
# elsewhere.
# Any doubt is a failure: nothing is printed and the exit code is non-zero.
set -euo pipefail

: "${NGINX_SERIES:?NGINX_SERIES is not set}"
: "${DEBIAN:?DEBIAN is not set}"

fail() { echo "resolve-versions: $*" >&2; exit 1; }

pages="$(mktemp -d)"
trap 'rm -rf "$pages"' EXIT

if [ -n "${NGINX_TAGS_JSON_FILE:-}" ]; then
    cp "$NGINX_TAGS_JSON_FILE" "$pages/1.json"
else
    # name= is a substring filter: "1.30." also matches 1.30.6-alpine, -perl, ... (filtered below),
    # more than one page of 100.
    url="${DOCKERHUB_API_URL:-https://hub.docker.com}/v2/repositories/library/nginx/tags?name=${NGINX_SERIES}.&page_size=100"
    n=0
    while [ -n "$url" ]; do
        n=$((n + 1))
        [ "$n" -le 20 ] || fail "more than 20 pages of tags"
        curl -fsSL --retry 3 --max-time 30 -o "$pages/$n.json" "$url" || fail "cannot reach Docker Hub"
        url="$(python3 -I -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except ValueError:
    sys.exit(0)   # reported by the parser below
print(d.get("next") or "" if isinstance(d, dict) else "")
' "$pages/$n.json")"
    done
fi

nginx_version="$(python3 -I -c '
import json, os, re, sys
pages, series, debian, wanted = sys.argv[1:5]
digests = {}
for f in sorted(os.listdir(pages)):
    try:
        d = json.load(open(os.path.join(pages, f)))
    except ValueError:
        sys.exit("Docker Hub did not return JSON")
    if not isinstance(d, dict) or not isinstance(d.get("results"), list):
        sys.exit("Docker Hub: " + str(d.get("message", d) if isinstance(d, dict) else d))
    digests.update({r.get("name"): r.get("digest") for r in d["results"]})
pattern = re.compile(r"%s\.[0-9]+" % re.escape(series))
found = [n for n in digests if n and pattern.fullmatch(n)
         and digests[n] and digests.get(n + "-" + debian) == digests[n]]
if wanted:
    print(wanted if wanted in found else "")
else:
    print(max(found, key=lambda v: tuple(int(x) for x in v.split("."))) if found else "")
' "$pages" "$NGINX_SERIES" "$DEBIAN" "${NGINX_VERSION:-}")" || fail "cannot read the nginx tags"

[[ "$nginx_version" =~ ^${NGINX_SERIES//./\\.}\.[0-9]+$ ]] \
    || fail "nginx '${nginx_version}' is not a published ${NGINX_SERIES}.x release on ${DEBIAN}${NGINX_VERSION:+ (asked: ${NGINX_VERSION})}"

echo "NGINX_VERSION=${nginx_version}"
