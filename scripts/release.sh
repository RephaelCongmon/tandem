#!/bin/bash
# Publishes a new Tandem version. Every release gets a higher version and build number:
# bump → test → build → commit + tag → push → GitHub release with the app zip that the in-app
# updater ("Update Now") installs.
#
#   scripts/release.sh [patch|minor|major] ["Release notes in Markdown"]
#   scripts/release.sh minor --notes-file notes.md
#
# Without notes, the commit subjects since the previous release are used.
# RELEASE_COMMIT_TRAILER, if set, is appended to the release commit message.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PROJECT="App/project.yml"

PART="${1:-patch}"
[[ "$PART" =~ ^(patch|minor|major)$ ]] || { echo "usage: scripts/release.sh [patch|minor|major] [notes | --notes-file FILE]"; exit 2; }
NOTES="${2:-}"
if [[ "$NOTES" == "--notes-file" ]]; then NOTES="$(cat "${3:?missing notes file}")"; fi

command -v gh >/dev/null || { echo "The GitHub CLI (gh) is required: brew install gh && gh auth login"; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Sign in to GitHub first: gh auth login"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Commit or stash your changes first."; exit 1; }

CURRENT=$(sed -n 's/^ *MARKETING_VERSION: "\(.*\)"$/\1/p' "$PROJECT")
BUILD=$(sed -n 's/^ *CURRENT_PROJECT_VERSION: "\(.*\)"$/\1/p' "$PROJECT")
NEXT=$(python3 - "$CURRENT" "$PART" <<'PY'
import sys
parts = [int(p) for p in sys.argv[1].split(".")] + [0, 0, 0]
major, minor, patch = parts[:3]
kind = sys.argv[2]
if kind == "major": major, minor, patch = major + 1, 0, 0
elif kind == "minor": minor, patch = minor + 1, 0
else: patch += 1
print(f"{major}.{minor}.{patch}")
PY
)
NEXT_BUILD=$((BUILD + 1))
TAG="v$NEXT"
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "$TAG already exists."; exit 1; }
echo "▸ Tandem $CURRENT ($BUILD) → $NEXT ($NEXT_BUILD)"

restore() { git checkout -- "$PROJECT" 2>/dev/null || true; }
trap restore ERR
sed -i '' "s/MARKETING_VERSION: \"$CURRENT\"/MARKETING_VERSION: \"$NEXT\"/; s/CURRENT_PROJECT_VERSION: \"$BUILD\"/CURRENT_PROJECT_VERSION: \"$NEXT_BUILD\"/" "$PROJECT"

"$ROOT/scripts/test_all.sh"
"$ROOT/scripts/build-release.sh"
ZIP="dist/Tandem-$NEXT.zip"
DMG="dist/Tandem-$NEXT.dmg"
[[ -f "$ZIP" && -f "$DMG" ]] || { echo "The build didn't produce $ZIP and $DMG."; exit 1; }

if [[ -z "$NOTES" ]]; then
  PREVIOUS=$(git describe --tags --abbrev=0 --match 'v*' 2>/dev/null || true)
  RANGE=${PREVIOUS:+$PREVIOUS..HEAD}
  NOTES=$(git log --no-merges --pretty='- %s' ${RANGE:-HEAD} | grep -v '^- Release ' || true)
  [[ -n "$NOTES" ]] || NOTES="- Maintenance update"
fi

MESSAGE="Release $NEXT"
[[ -n "${RELEASE_COMMIT_TRAILER:-}" ]] && MESSAGE="$MESSAGE"$'\n\n'"$RELEASE_COMMIT_TRAILER"
git commit -q -m "$MESSAGE" -- "$PROJECT"
trap - ERR
git tag -a "$TAG" -m "Tandem $NEXT"
git push -q origin HEAD
git push -q origin "$TAG"
gh release create "$TAG" "$ZIP" "$DMG" --title "Tandem $NEXT" --notes "$NOTES" >/dev/null
echo "✓ Released Tandem $NEXT: $(gh release view "$TAG" --json url --jq .url)"
