#!/usr/bin/env bash
# Pushes a branch to GitLab (origin, where CI runs) and then to the GitHub backup when the repository
# has one. The canonical copy lives in deploy-automation/tools/git-push.sh; tools/normalize-remotes.sh
# installs it in every project as git-push.sh.
#   ./git-push.sh            current branch
#   ./git-push.sh <branch>   that branch
set -euo pipefail

branch="${1:-$(git branch --show-current)}"
[ -n "$branch" ] || { echo "not on a branch (detached HEAD): pass the branch name" >&2; exit 1; }

origin="$(git remote get-url origin 2>/dev/null || true)"
case "$origin" in
    *git.developpeur-freelance.io*) ;;
    *) echo "origin is not GitLab (${origin:-missing}): run deploy-automation/tools/normalize-remotes.sh" >&2; exit 1 ;;
esac

git push origin "$branch"
if git remote get-url github >/dev/null 2>&1; then
    git push github "$branch"
else
    echo "no 'github' remote: pushed to GitLab only (add the backup with deploy-automation/tools/normalize-remotes.sh)" >&2
fi
