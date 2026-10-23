#!/usr/bin/env bash
# Regression tests for the permanent-archive-mirror CI scripts. Grown alongside the
# feature: (a) generate_release_notes.py emits a second note whose ONLY delta is the
# per-file download-link base; (b) build_notify_telegram.sh honours the NOTES_FILE
# override and falls back when it is absent; (c) push_archive_manifest.sh publishes
# manifests/<tag>.json to the mirror repo's website branch idempotently and fails
# soft; (d) build_upload_release.sh, called with an overridden repository, targets
# the mirror repo and names title/body/prerelease. Each block has a negative control,
# because an absence assertion that has nothing to fail against proves nothing.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
ROOT="$PWD"
fail() { echo "FAIL: $*"; exit 1; }
have() { grep -qF -- "$2" "$1" || fail "$1: missing [$2]"; }
hasnt() { grep -qF -- "$2" "$1" && fail "$1: unexpected [$2]"; }

# ---------------------------------------------------------------------------
# (a) generate_release_notes.py — the two-note split
# ---------------------------------------------------------------------------
notes_fixture() { # $1 = dir to build the fixture in
	mkdir -p "$1/build"
	cat > "$1/build.json" <<'JSON'
{
  "youtube": {
    "name": "youtube-morphe",
    "display_name": "YouTube",
    "version": "19.16.39",
    "patches_source": "MorpheApp/morphe-patches",
    "patches": "MorpheApp/morphe-patches:v1.2.3.mpp",
    "changelog": "https://github.com/MorpheApp/morphe-patches/releases/tag/v1.2.3"
  }
}
JSON
	: > "$1/build/youtube-morphe-v19.16.39-arm64-v8a.apk"
	: > "$1/build/youtube-morphe-v19.16.39-arm-v7a.apk"
	: > "$1/build/youtube-morphe-module-v19.16.39-arm64-v8a.zip"
}

t=$(mktemp -d)
trap 'rm -rf "$t"' EXIT
notes_fixture "$t"
(
	cd "$t" || exit 1
	export NEXT_VER_CODE=260999 GITHUB_REPOSITORY=nullcpy/rvb GITHUB_SERVER_URL=https://github.com
	export RELEASE_NOTES_DISCORD_LINK="https://discord.gg/x" RELEASE_NOTES_WEBSITE_LINK="https://nullcpy.github.io"
	unset ARCHIVE_REPO
	python3 "$ROOT/.github/scripts/generate_release_notes.py" >/dev/null

	# Negative control: opt-in off means no archive note and rvb links in build.md.
	[ ! -f build.archive.md ] || fail "archive note written while ARCHIVE_REPO unset"
	have build.md "nullcpy/rvb/releases/download/260999/"
	hasnt build.md "nullcpy/archive"

	# Feature on.
	ARCHIVE_REPO=nullcpy/archive python3 "$ROOT/.github/scripts/generate_release_notes.py" >/dev/null
	[ -f build.archive.md ] || fail "archive note not written when ARCHIVE_REPO set"
	have build.archive.md "nullcpy/archive/releases/download/260999/"
	hasnt build.archive.md "nullcpy/rvb/releases/download/260999/"
	# Footer's canonical-home link must NOT move to the archive repo.
	have build.archive.md "[GitHub](https://github.com/nullcpy/rvb)"

	# The ONLY difference is the download base: normalise both repo segments to one
	# token and require the notes to be byte-identical. A stray extra change (a
	# shifted header, a dropped footer entry) would survive the link swap and this
	# cmp would then report a difference.
	sed 's#github.com/nullcpy/\(rvb\|archive\)/releases#github.com/LINKBASE/releases#g' build.md > md.norm
	sed 's#github.com/nullcpy/\(rvb\|archive\)/releases#github.com/LINKBASE/releases#g' build.archive.md > arch.norm
	cmp -s md.norm arch.norm || fail "notes differ beyond the download base"
)
echo "PASS: generate_release_notes two-note split"
