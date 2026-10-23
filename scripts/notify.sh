#!/usr/bin/env bash
# Sends a notification to our ntfy server. Never fails the caller: a broken notification must not
# turn a good build red, nor hide the real error of a bad one.
#   scripts/notify.sh <priority> <tags> <title> <message>
# priority: min, low, default, high, urgent. tags: ntfy tags/emojis, comma separated.
# Environment: NTFY_TOPIC (unset = do nothing, e.g. local builds), NTFY_URL
# (default https://notif.developpeur-freelance.io), NTFY_TOKEN (optional access token),
# CI_PIPELINE_URL (optional, opened when the notification is tapped).

priority="${1:-default}" tags="${2:-}" title="${3:-nginx-s3-gateway}" message="${4:-}"

if [ -z "${NTFY_TOPIC:-}" ]; then
    echo "notify: NTFY_TOPIC not set, skipped: ${title}"
    exit 0
fi

args=(-fsS -o /dev/null --max-time 10
    -H "Title: ${title}"
    -H "Priority: ${priority}"
    -H "Tags: ${tags}"
    --data-binary "${message}")
[ -n "${CI_PIPELINE_URL:-}" ] && args+=(-H "Click: ${CI_PIPELINE_URL}")
[ -n "${NTFY_TOKEN:-}" ] && args+=(-H "Authorization: Bearer ${NTFY_TOKEN}")

if curl "${args[@]}" "${NTFY_URL:-https://notif.developpeur-freelance.io}/${NTFY_TOPIC}"; then
    echo "notify: sent: ${title}"
else
    echo "notify: could not reach ntfy (ignored): ${title}" >&2
fi
exit 0
