#!/usr/bin/env bash
# Gate: the image must already have every Debian update published today (online):
#   tests/os-updates.sh <image>
# Runs `apt-get update` in the image, then simulates `apt-get upgrade` and `apt-get dist-upgrade`.
# Fails if `upgrade` would still install a package from Debian's own archive (Debian, Debian-Security:
# stable, stable-updates, stable-security): the build's os-updates stage did not run, or ran from the
# build cache. Third-party repositories (nginx.org, sury...) are not counted: their packages are pinned
# on purpose. What only `dist-upgrade` would do (a fix that needs a new package, a removal) is printed as
# a WARNING: the image keeps the official image's package list, a human decides.
# Shared with the other bases (../ruby-docker, ../node-docker, ...): keep the copies identical.
# Offline (tests/unit.sh): OS_UPDATES_FILE=<captured output> reads it instead of running the image.
set -euo pipefail

IMAGE="${1:?usage: tests/os-updates.sh <image>}"

if [ -n "${OS_UPDATES_FILE:-}" ]; then
    out="$(cat "$OS_UPDATES_FILE")"
else
    echo "==> os-updates.sh: ${IMAGE}"
    out="$(docker run --rm ${PLATFORM:+--platform "$PLATFORM"} --user 0 --entrypoint sh "$IMAGE" -c '
        apt-get update -qq -o APT::Update::Error-Mode=any >/dev/null || { echo "@@apt-get update failed"; exit 1; }
        echo "@@upgrade"; apt-get -s upgrade
        echo "@@dist-upgrade"; apt-get -s dist-upgrade' 2>&1)" || {
        printf '%s\n' "$out" | tail -5
        echo "  FAIL cannot check ${IMAGE} against Debian's archive (apt-get update failed?)"
        exit 1
    }
fi

# "Inst <pkg> [<installed>] (<candidate> <origin>[, <origin>...] [<arch>])" -> "<pkg> <installed> -> <candidate>"
# for the lines whose origins include Debian's archive.
debian_inst() {
    awk -v section="$1" '
        /^@@/ { in_section = ($0 == "@@" section); next }
        in_section && /^Inst / {
            origins = $0; sub(/^[^(]*\(/, "", origins); sub(/\[[^]]*\]\).*$/, "", origins)
            if (origins !~ /(^| |,)Debian(-Security)?:/) next
            installed = ($3 ~ /^\[/) ? $3 : "[none]"
            gsub(/[][]/, "", installed)
            candidate = origins; sub(/ .*/, "", candidate)
            print $2 " " installed " -> " candidate
        }
        in_section && /^Remv / { print $2 " removed" }' <<<"$out"
}

grep -qx '@@upgrade' <<<"$out" && grep -qx '@@dist-upgrade' <<<"$out" \
    || { printf '%s\n' "$out" | tail -5; echo "  FAIL unexpected apt-get output"; exit 1; }

pending="$(debian_inst upgrade)"
extra="$(comm -13 <(sort <<<"$pending") <(debian_inst dist-upgrade | sort) | sed '/^$/d')"

if [ -n "$extra" ]; then
    echo "  WARNING only dist-upgrade would apply (new or removed packages; not done, a human decides):"
    sed 's/^/    /' <<<"$extra"
fi
if [ -n "$pending" ]; then
    echo "  FAIL $(wc -l <<<"$pending" | tr -d ' ') Debian update(s) missing from the image:"
    sed 's/^/    /' <<<"$pending"
    exit 1
fi
echo "  ok   no Debian update pending"
