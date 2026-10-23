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

# ---------------------------------------------------------------------------
# (d) build_upload_release.sh — the same uploader pointed at the mirror repo
# ---------------------------------------------------------------------------
t2=$(mktemp -d)
trap 'rm -rf "$t" "$t2"' EXIT
mkdir -p "$t2/bin" "$t2/build"
: > "$t2/build/one.apk"
: > "$t2/build/two.zip"
printf 'archive body\n' > "$t2/build.archive.md"
cat > "$t2/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [ "${1:-}" = "release" ] && [ "${2:-}" = "view" ]; then exit 1; fi
exit 0
STUB
chmod +x "$t2/bin/gh"
(
	cd "$t2" || exit 1
	export PATH="$t2/bin:$PATH" GH_LOG="$t2/gh.log"
	export GH_TOKEN=fake GITHUB_REPOSITORY=nullcpy/archive
	export RELEASE_TAG=260999 RELEASE_TITLE="Build No. 260999"
	export RELEASE_BODY_FILE=build.archive.md IS_PRERELEASE=true UPLOAD_FILES="./build/*"
	bash "$ROOT/.github/scripts/build_upload_release.sh" >/dev/null
	# Cross-repo target honoured, and the metadata the numbered step names.
	have gh.log "-R nullcpy/archive"
	grep -qE 'release create 260999 -t Build No\. 260999 -F build\.archive\.md --prerelease -R nullcpy/archive' gh.log \
		|| fail "create call missing title/body/prerelease: $(cat gh.log)"
	grep -qE 'release upload 260999 .*/one\.apk --clobber -R nullcpy/archive' gh.log \
		|| fail "assets not uploaded to the mirror repo: $(cat gh.log)"
	# Negative control: it uploaded the archive body, never the rvb build.md.
	hasnt gh.log "build.md"
)
echo "PASS: build_upload_release cross-repo mirror"

# ---------------------------------------------------------------------------
# (c) push_archive_manifest.sh — publish to the mirror repo's website branch
# ---------------------------------------------------------------------------
t3=$(mktemp -d)
trap 'rm -rf "$t" "$t2" "$t3"' EXIT
mkdir -p "$t3/temp/manifest" "$t3/bin"
printf '{"schema":1,"files":{}}\n' > "$t3/temp/manifest/build.json"
cat > "$t3/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "ARGS: $*" >> "$GH_LOG"
m=GET nx=0 path=""
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  a=${args[i]}
  if [ "$nx" = 1 ]; then m="$a"; nx=0; continue; fi
  if [ "$a" = "-X" ]; then nx=1; continue; fi
  case "$a" in repos/*) path="$a";; esac
done
base=${path%%\?*}
mode=${GH_STUB_MODE:-absent}
case "$base" in
  repos/nullcpy/archive) echo '{"default_branch":"main"}';;
  repos/nullcpy/archive/branches/website) { [ "$mode" = present ] && echo '{}'; } || exit 1;;
  repos/nullcpy/archive/git/ref/heads/main) echo '{"object":{"sha":"DEAD"}}';;
  repos/nullcpy/archive/git/refs) echo '{}';;
  repos/nullcpy/archive/contents/manifests/260999.json)
    if [ "$m" = GET ]; then { [ "$mode" = present ] && echo '{"sha":"OLD123"}'; } || exit 1
    else { [ "$mode" = fail ] && exit 1; }; echo '{"content":{"sha":"NEW456"}}'; fi;;
  *) echo '{}';;
esac
STUB
chmod +x "$t3/bin/gh"

run_push() { # $1 = stub mode; leaves combined output in $t3/out.<mode>, returns rc
	local out rc
	: > "$t3/gh.log"
	out=$( cd "$t3" && PATH="$t3/bin:$PATH" GH_LOG="$t3/gh.log" GH_TOKEN=fake \
		ARCHIVE_REPO=nullcpy/archive BUILD_TAG=260999 GH_STUB_MODE="$1" \
		bash "$ROOT/.github/scripts/push_archive_manifest.sh" 2>&1 )
	rc=$?
	printf '%s\n' "$out" > "$t3/out.$1"
	return $rc
}

# absent: no website branch and no existing manifest -> seed branch + create (no sha)
run_push absent || fail "push (absent) must exit 0"
have "$t3/gh.log" '-X POST repos/nullcpy/archive/git/refs'
grep -F 'PUT repos/nullcpy/archive/contents/manifests/260999.json' "$t3/gh.log" > "$t3/put" || fail "no manifest PUT (absent)"
have "$t3/put" 'message=chore: publish'
have "$t3/put" '-f content='
hasnt "$t3/put" '-f sha='

# present: branch and file exist -> do not re-create, update in place with the prior sha
run_push present || fail "push (present) must exit 0"
hasnt "$t3/gh.log" '-X POST repos/nullcpy/archive/git/refs'
grep -F 'PUT repos/nullcpy/archive/contents/manifests/260999.json' "$t3/gh.log" > "$t3/put" || fail "no manifest PUT (present)"
have "$t3/put" '-f sha=OLD123'
have "$t3/put" 'message=chore: update'

# fail: the PUT is rejected -> the publisher must stay non-fatal (fail-soft)
rcf=0
run_push fail || rcf=$?
[ "$rcf" = 0 ] || fail "push_archive_manifest did not fail soft (rc=$rcf)"
have "$t3/out.fail" '::warning::'

echo "PASS: push_archive_manifest website publish"

# ---------------------------------------------------------------------------
# (b) build_notify_telegram.sh — NOTES_FILE override and fallback
# ---------------------------------------------------------------------------
t4=$(mktemp -d)
trap 'rm -rf "$t" "$t2" "$t3" "$t4"' EXIT
mkdir -p "$t4/bin"
cat > "$t4/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
exit 0
STUB
chmod +x "$t4/bin/curl"
printf '### YouTube\n  * APK: [arm64](https://github.com/nullcpy/rvb/releases/download/260999/x.apk)\n' > "$t4/build.md"
printf '### YouTube\n  * APK: [arm64](https://github.com/nullcpy/archive/releases/download/260999/x.apk)\n' > "$t4/build.archive.md"

post_note() { # $1 = NOTES_FILE value; empty string leaves it unset
	local nf="$1"
	: > "$t4/curl.log"
	if [ -n "$nf" ]; then
		( cd "$t4" && PATH="$t4/bin:$PATH" CURL_LOG="$t4/curl.log" \
			TG_TOKEN=fake TG_CHAT_ID=-1001 TG_THREAD_ID=7 TG_CHAT_ID_BROADCAST=@bc \
			NEXT_VER_CODE=260999 TITLE_SUFFIX= NOTES_FILE="$nf" \
			bash "$ROOT/.github/scripts/build_notify_telegram.sh" >/dev/null 2>&1 )
	else
		( cd "$t4" && PATH="$t4/bin:$PATH" CURL_LOG="$t4/curl.log" \
			TG_TOKEN=fake TG_CHAT_ID=-1001 TG_THREAD_ID=7 TG_CHAT_ID_BROADCAST=@bc \
			NEXT_VER_CODE=260999 TITLE_SUFFIX= \
			bash "$ROOT/.github/scripts/build_notify_telegram.sh" >/dev/null 2>&1 )
	fi
}

# override to the archive note -> the mirror link is posted
post_note build.archive.md
have "$t4/curl.log" 'nullcpy/archive'
# unset -> fall back to build.md (rvb links) ...
post_note ''
have "$t4/curl.log" 'nullcpy/rvb'
hasnt "$t4/curl.log" 'nullcpy/archive'
# ... and a named-but-missing NOTES_FILE also falls back, never links a phantom
post_note 'build.does-not-exist.md'
have "$t4/curl.log" 'nullcpy/rvb'
hasnt "$t4/curl.log" 'nullcpy/archive'
echo "PASS: build_notify_telegram NOTES_FILE override"


