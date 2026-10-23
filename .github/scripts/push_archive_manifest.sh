#!/bin/bash
set -euo pipefail

# Publish this build's manifest to the permanent archive repo's `website` branch so
# a download site can be generated from nullcpy/archive without touching rvb's own
# website branch. The mirror is numbered-only — it has no rolling stable/beta, so
# there is no cumulative archive/<channel>.json and no live-existence filter here,
# only the immutable per-build manifests/<tag>.json. The manifest carries no download
# URLs (originBuild names the build tag), so the exact same bytes rvb uses are valid
# in the archive repo; nothing is re-keyed.
#
# Fail-soft on purpose (repo rule 9): a metadata push must never turn a good build
# red — the next build converges. Gated upstream on the archive mirror having landed.
#
# Env: ARCHIVE_REPO (owner/name), BUILD_TAG (this release's tag), GH_TOKEN (PAT with
#      contents:write on ARCHIVE_REPO). Reads: temp/manifest/build.json.
# gh performs the cross-repo write because GITHUB_TOKEN cannot reach another repo.

REPO="${ARCHIVE_REPO:-}"
TAG="${BUILD_TAG:-}"
MANIFEST="temp/manifest/build.json"
BRANCH="website"
PATH_JSON="manifests/${TAG}.json"

skip() { echo "${1:-}"; exit 0; }
trap 'echo "::warning::archive manifest push failed (next build converges)"; exit 0' ERR

if [ -z "$REPO" ] || [ -z "$TAG" ]; then
	skip "ARCHIVE_REPO or BUILD_TAG not set — skipping archive manifest push."
fi
if [ ! -f "$MANIFEST" ]; then
	skip "No $MANIFEST present — skipping archive manifest push."
fi
if [ -z "${GH_TOKEN:-}" ]; then
	skip "GH_TOKEN not set — skipping archive manifest push."
fi

# 1. Ensure the website branch exists. Only when it is absent do we resolve the
#    default branch head and create it, so a steady-state run costs one API call.
if ! gh api "repos/$REPO/branches/$BRANCH" >/dev/null 2>&1; then
	DEFAULT=$(gh api "repos/$REPO" | jq -r '.default_branch')
	SHA=$(gh api "repos/$REPO/git/ref/heads/$DEFAULT" | jq -r '.object.sha')
	gh api -X POST "repos/$REPO/git/refs" -f "ref=refs/heads/$BRANCH" -f "sha=$SHA" >/dev/null
	echo "Created $BRANCH branch on $REPO from $DEFAULT."
fi

# 2. Read the existing blob sha (404 -> create). Under pipefail a missing file makes
#    this pipeline fail, so the || pins an empty value rather than tripping ERR.
OLD_SHA=$(gh api "repos/$REPO/contents/${PATH_JSON}?ref=${BRANCH}" 2>/dev/null | jq -r '.sha // ""') || OLD_SHA=""

CONTENT=$(base64 "$MANIFEST" | tr -d '\n')
if [ -n "$OLD_SHA" ]; then
	gh api -X PUT "repos/$REPO/contents/$PATH_JSON" \
		-f "message=chore: update $BRANCH manifest for build $TAG [skip ci]" \
		-f "branch=$BRANCH" -f "content=$CONTENT" -f "sha=$OLD_SHA" >/dev/null
	echo "Updated $PATH_JSON on $REPO#$BRANCH."
else
	gh api -X PUT "repos/$REPO/contents/$PATH_JSON" \
		-f "message=chore: publish $BRANCH manifest for build $TAG [skip ci]" \
		-f "branch=$BRANCH" -f "content=$CONTENT" >/dev/null
	echo "Published $PATH_JSON on $REPO#$BRANCH."
fi
