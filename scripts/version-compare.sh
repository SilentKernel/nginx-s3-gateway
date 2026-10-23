#!/usr/bin/env bash
# No-downgrade check: exits 0 when <candidate> >= <published> (dotted versions), 1 otherwise.
# An empty <published> (nothing pushed yet) always passes.
#   scripts/version-compare.sh <published> <candidate>
set -euo pipefail

published="${1-}"
candidate="${2:?usage: version-compare.sh <published> <candidate>}"

[ -z "$published" ] && exit 0
lowest="$(printf '%s\n%s\n' "$published" "$candidate" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)"
[ "$lowest" = "$published" ]
