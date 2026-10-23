#!/usr/bin/env bash
# Vulnerability gate before a push (Trivy, pinned by digest; same file as frankenphp-docker):
#   tests/scan.sh <candidate> [<published>]
# Scans the candidate and, when given and present locally (tests/compare.sh pulled it), the
# published image, with the same vulnerability DB. Fails only on a fixable CRITICAL the candidate has
# and the published image has not (scripts/trivy-diff.py): the nightly must never publish a new
# fixable critical, but what production already has must not block a security update either.
# Fixable HIGH and what both images share are reported, with an ntfy alert. A scan that cannot run
# fails too: a gate that passes when its scanner is down is no gate.
# Writes trivy-report.json / trivy-report.txt (candidate) and trivy-published.json at the repo root
# (gitignored, CI artifacts).
set -uo pipefail

CANDIDATE="${1:?usage: tests/scan.sh <candidate> [<published>]}"
PUBLISHED="${2:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Pinned by digest, like in .gitlab-ci.yml (which sets it in CI): a tag alone can be re-pointed.
TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa}"
rm -f "$ROOT/trivy-report.json" "$ROOT/trivy-report.txt" "$ROOT/trivy-published.json"

echo "==> scan.sh: ${CANDIDATE} (baseline: ${PUBLISHED:-none})"
docker pull --quiet "$TRIVY_IMAGE" >/dev/null || { echo "  FAIL cannot pull ${TRIVY_IMAGE}"; exit 1; }

# Local images through the Docker socket; the vulnerability DB cached in a volume between runs.
trivy() {
    docker run --rm -v /var/run/docker.sock:/var/run/docker.sock -v trivy-cache:/root/.cache/trivy \
        -v "$ROOT:/out" "$TRIVY_IMAGE" "$@"
}
scan() {   # scan <image> <json name>; one retry: the DB download (empty cache) can fail transiently
    trivy image --quiet --image-src docker --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
        --format json --output "/out/$2" "$1" && return 0
    echo "  retry trivy on $1 in 30s" >&2
    sleep 30
    trivy image --quiet --image-src docker --scanners vuln --severity HIGH,CRITICAL --ignore-unfixed \
        --format json --output "/out/$2" "$1"
}

scan "$CANDIDATE" trivy-report.json || { echo "  FAIL trivy could not scan ${CANDIDATE}"; exit 1; }
trivy convert --scanners vuln --format table --output /out/trivy-report.txt /out/trivy-report.json >/dev/null 2>&1
cat "$ROOT/trivy-report.txt" 2>/dev/null

baseline=""
if [ -n "$PUBLISHED" ] && docker image inspect "$PUBLISHED" >/dev/null 2>&1; then
    scan "$PUBLISHED" trivy-published.json || { echo "  FAIL trivy could not scan ${PUBLISHED}"; exit 1; }
    baseline="$ROOT/trivy-published.json"
fi

python3 -I "$ROOT/scripts/trivy-diff.py" "$ROOT/trivy-report.json" "$baseline"
rc=$?

found="$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1]));
print(sum(len(r.get("Vulnerabilities") or []) for r in d.get("Results", [])))' "$ROOT/trivy-report.json")"
if [ "$rc" = 0 ] && [ "$found" != 0 ]; then
    "$ROOT/scripts/notify.sh" high "warning,mag" "nginx-s3-gateway: ${found} fixable HIGH/CRITICAL CVEs" \
        "In the candidate, none new and critical (pushed). See the trivy-report artifact; usually fixed by the next nightly rebuild."
fi
[ "$rc" = 0 ] && echo "==> scan.sh: passed" || echo "==> scan.sh: refused"
exit "$rc"
