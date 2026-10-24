#!/usr/bin/env bash

MODULE_TEMPLATE_DIR="module"
CWD=$(pwd)
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"
DL_SRCS=("cache_repo" "direct" "github" "archive" "apkmirror" "uptodown" "apkpure" "apkcombo")
BUILD_JSON_FILE="build.json"
PATCH_OUTPUT=""

# Prioritize GH_TOKEN / APKS_REPO_TOKEN for cross-repo private access, falling back to GITHUB_TOKEN
_api_token="${GH_TOKEN:-${APKS_REPO_TOKEN:-${GITHUB_TOKEN:-}}}"
if [ -z "$_api_token" ] && command -v gh >/dev/null 2>&1; then
	_api_token=$(gh auth token 2>/dev/null || true)
fi
if [ -n "$_api_token" ]; then 
	GH_HEADER="Authorization: token ${_api_token}" 
else 
	GH_HEADER="" 
fi

NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
OS=$(uname -o)
DEFAULT_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36"

# Signing identity. There is deliberately no default here. CI supplies it: build.yml
# passes the KEYSTORE_* secrets to install_keystore.sh, which writes the two store
# files and exports RVB_KEYSTORE_PASS / RVB_KEY_ALIAS. A local build must set all
# four itself (see require_signing_identity below and the table in
# docs/build-engine.md#signing-and-identity).
#
# Two stores because the consumers read different keystore formats, one key pair:
#   RVB_KEYSTORE (BKS)     - ReVanced CLI calls KeyStore.getInstance("BKS", "BC")
#                            and loads the file as BKS, so this store has to be BKS
#                            for it. Morphe would also take JKS/PKCS12 (it sniffs
#                            the format and converts), but the CLI flows share this
#                            variable, so the stricter consumer decides.
#   RVB_KEYSTORE_P12 (P12)  - apksigner (--ks) and LSPatch, which load through
#                            KeyStore.getDefaultType(), i.e. PKCS12 on a modern JDK.
# NPatch also reads BKS - and it is the only consumer that asks the *JVM* for the
# BKS type (single-argument getInstance("BKS")), which is why the runner-level
# BouncyCastle install is gated on NPatch alone. ReVanced and Morphe ship their own
# BC provider and need nothing installed.
# One alias, and the engine has a single RVB_KEYSTORE_PASS it passes as both store
# and key password, so the two files must be built that way.
RVB_KEYSTORE="${RVB_KEYSTORE-}"
RVB_KEYSTORE_P12="${RVB_KEYSTORE_P12-}"
RVB_KEYSTORE_PASS="${RVB_KEYSTORE_PASS-}"
RVB_KEY_ALIAS="${RVB_KEY_ALIAS-}"

# Refuse before the first download instead of after patching: every build path
# signs (the CLI --keystore flags, apksigner on merged bundles, -k for the xposed
# flows), so a missing identity is a whole-run problem, not a per-app one. It used
# to fall back to the keystore committed by the repo template, whose private key is
# public - any fork could then produce signature-compatible "updates" for builds
# published here. Signing with someone else's key is not a default to keep.
require_signing_identity() {
	local bad=0 v
	for v in RVB_KEYSTORE RVB_KEYSTORE_P12 RVB_KEYSTORE_PASS RVB_KEY_ALIAS; do
		if [ -z "${!v-}" ]; then epr "$v is not set"; bad=1; fi
	done
	if [ -n "${RVB_KEYSTORE-}" ] && [ ! -f "$RVB_KEYSTORE" ]; then epr "keystore not found: $RVB_KEYSTORE"; bad=1; fi
	if [ -n "${RVB_KEYSTORE_P12-}" ] && [ ! -f "$RVB_KEYSTORE_P12" ]; then epr "keystore not found: $RVB_KEYSTORE_P12"; bad=1; fi
	# The password is interpolated into an eval'd command line (and into single
	# quotes for the -k arguments), so anything outside [0-9A-Za-z] would either
	# split the argument or terminate it early.
	if [ -n "${RVB_KEYSTORE_PASS-}" ] && [[ "$RVB_KEYSTORE_PASS" =~ [^0-9A-Za-z] ]]; then
		epr "RVB_KEYSTORE_PASS must be alphanumeric: it is embedded in eval'd CLI arguments"
		bad=1
	fi
	if [ -n "${RVB_KEY_ALIAS-}" ] && [[ "$RVB_KEY_ALIAS" =~ [^0-9A-Za-z_.-] ]]; then
		epr "RVB_KEY_ALIAS must not contain characters that break eval'd CLI arguments"
		bad=1
	fi
	if [ "$bad" -ne 0 ]; then
		epr "no usable signing identity - in CI set KEYSTORE_B64, KEYSTORE_P12_B64, KEYSTORE_PASSWORD and KEY_ALIAS; locally export RVB_KEYSTORE, RVB_KEYSTORE_P12, RVB_KEYSTORE_PASS and RVB_KEY_ALIAS"
		return 1
	fi
	return 0
}

# Instafel fallbacks (used when the CLI manifest lacks a commit hash, and
# when a config omits included-patches). Overridable without code edits.
RVB_INSTAFEL_FALLBACK_COMMIT="${RVB_INSTAFEL_FALLBACK_COMMIT:-8e4756f}"
RVB_INSTAFEL_DEFAULT_PATCHES="${RVB_INSTAFEL_DEFAULT_PATCHES:-unlock_developer_options remove_snooze_warning remove_ads amoled_theme instafel}"

# Morphe bundle passthrough: when the CLI tool is morphe-desktop, the freshly
# downloaded stock is a bundle format (.xapk/.apkm/.apks), and this switch is
# on, the bundle is kept as the cache artifact (instead of apkeditor-merging
# it) and passed to morphe directly — morphe merges bundles natively, and some
# APKs misbehave after apkeditor's rewrite+re-sign. Set
# RVB_MORPHE_PASSTHROUGH=false to revert to the old merge-at-download flow.
RVB_MORPHE_PASSTHROUGH="${RVB_MORPHE_PASSTHROUGH:-true}"

declare -gA __PREBUILTS_CACHE__
declare -g __PREBUILTS_RESULT=""
declare -gA __PATCHES_LIST_CACHE__
declare -gA __PATCH_VER_CACHE__
declare -gA __PKG_VERS_CACHE__
declare -gA __DL_RESP_CACHE__
declare -gA __EFF_PATCH_VER_CACHE__

# Patcher tool registry: resolve_patcher() + PATCHER_* flags.
# RVB_PATCHERS_SH lets the trace harness point at it when utils.sh is sourced
# from a process substitution (same trick as scripts/cf_get.py lookup below).
_RVB_PATCHERS_SH="${RVB_PATCHERS_SH:-${CWD}/.github/scripts/patchers.sh}"
[ ! -f "$_RVB_PATCHERS_SH" ] && [ -n "${BASH_SOURCE[0]:-}" ] && _RVB_PATCHERS_SH="$(dirname "$(dirname "${BASH_SOURCE[0]}")")/.github/scripts/patchers.sh"
if [ -f "$_RVB_PATCHERS_SH" ]; then
	# shellcheck disable=SC1090
	source "$_RVB_PATCHERS_SH"
else
	echo "FATAL: patcher registry not found at $_RVB_PATCHERS_SH" >&2
	exit 1
fi

toml_file_to_json() {
	local f="$1"
	if [ ! -f "$f" ]; then return 1; fi
	if [[ "$f" == *.toml ]]; then
		local res=""
		if [ -n "${TOML-}" ] && [ -x "$TOML" ] 2>/dev/null; then
			if res=$("$TOML" --output json --file "$f" . 2>/dev/null) && [ -n "$res" ]; then
				echo "$res"
				return 0
			fi
		fi
		if command -v python3 >/dev/null 2>&1 || command -v python >/dev/null 2>&1; then
			local py_bin="python3"
			command -v python3 >/dev/null 2>&1 || py_bin="python"
			if res=$("$py_bin" -c "
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        import sys; sys.exit(1)
import json, sys
print(json.dumps(tomllib.load(open(sys.argv[1], 'rb'))))
" "$f" 2>/dev/null) && [ -n "$res" ]; then
				echo "$res"
				return 0
			fi
		fi
		if command -v yq >/dev/null 2>&1; then
			if res=$(yq -o=json eval '.' "$f" 2>/dev/null) && [ -n "$res" ]; then
				echo "$res"
				return 0
			fi
		fi
		abort "Neither python (tomllib/tomli) nor yq is available to parse $f"
	elif [[ "$f" == *.json ]]; then
		cat "$f"
	else
		abort "config extension not supported: $f"
	fi
}

toml_merge_configs() {
	local files=("$@")
	local jsons=()
	for f in "${files[@]}"; do
		[ -f "$f" ] || continue
		local file_json
		file_json=$(toml_file_to_json "$f") || continue

		local propagated
		propagated=$(jq '
			(to_entries | map(select(.value | type != "object")) | from_entries) as $defaults |
			map_values(
				if type == "object" then
					($defaults + .)
				else . end
			)
		' <<<"$file_json")
		jsons+=("$propagated")
	done

	if [ ${#jsons[@]} -eq 0 ]; then
		echo "{}"
	else
		printf '%s\n' "${jsons[@]}" | jq -s 'add // {}'
	fi
}

toml_prep() {
	if [ ! -f "$1" ]; then return 1; fi
	__TOML__=$(toml_file_to_json "$1") || abort "failed to parse config file: $1"
}
toml_get_table_names() { jq -r -e 'to_entries[] | select(.value | type == "object") | .key' <<<"$__TOML__" | tr -d '\r'; }
toml_get_table_main() { jq -r -e 'to_entries | map(select(.value | type != "object")) | from_entries' <<<"$__TOML__"; }
toml_get_table() { jq -r -e ".\"${1}\"" <<<"$__TOML__"; }
toml_get() {
	local op quote_placeholder=$'\001'
	op=$(jq -r ".\"${2}\" | values" <<<"$1")
	if [ "$op" ]; then
		op="${op#"${op%%[![:space:]]*}"}"
		op="${op%"${op##*[![:space:]]}"}"
		op=${op//\\\'/$quote_placeholder}
		op=${op//"''"/$quote_placeholder}
		op=${op//"'"/'"'}
		op=${op//$quote_placeholder/$'\''}
		echo "$op"
	else return 1; fi
}

pr() { echo >&2 -e "\033[0;32m[+] ${1}\033[0m"; }
epr() {
	echo >&2 -e "\033[0;31m[-] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::error::utils.sh [-] ${1}\n"; fi
}
wpr() {
	echo >&2 -e "\033[0;33m[!] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::warning::utils.sh [!] ${1}\n"; fi
}
abort() {
	epr "ABORT: ${1-}"
	if [ "${RVB_CHILD-}" = 1 ]; then
		trap - SIGTERM SIGINT EXIT
		exit 1
	fi
	rm -rf ./${TEMP_DIR}/*tmp.* ./${TEMP_DIR}/*/*tmp.* ./${TEMP_DIR}/*-temporary-files ./${TEMP_DIR}/*.apk-temporary-files ./*-temporary-files
	trap - SIGTERM SIGINT EXIT
	exit 1
}

failure_slug() {
	printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//'
}

write_build_failure_descriptor() {
	[ -n "${TEMP_DIR:-}" ] || return 0
	local dir="$TEMP_DIR/failures"
	mkdir -p "$dir" 2> /dev/null || return 0
	jq -n --arg type "build_failed" --arg app "$2" --arg version "$3" \
		--arg vc "$4" --arg arch "$5" --arg patches_src "$6" \
		'{type:$type, app:$app, version:$version, vc:$vc, arch:$arch, patches_src:$patches_src}' \
		> "$dir/$1.json" 2> /dev/null || true
}

write_dl_failure_descriptor() {
	[ -n "${TEMP_DIR:-}" ] || return 0
	local dir="$TEMP_DIR/failures"
	mkdir -p "$dir" 2> /dev/null || return 0
	jq -n --arg type "dl_exhausted" --arg app "$2" --arg version "$3" \
		--arg vc "$4" --arg arch "$5" --arg pkg "$6" \
		'{type:$type, app:$app, version:$version, vc:$vc, arch:$arch, pkg:$pkg}' \
		> "$dir/$1_dl.json" 2> /dev/null || true
}

write_no_patches_failure_descriptor() {
	[ -n "${TEMP_DIR:-}" ] || return 0
	local dir="$TEMP_DIR/failures"
	mkdir -p "$dir" 2> /dev/null || return 0
	jq -n --arg type "no_compatible_patches" --arg app "$2" --arg tried "$3" \
		--arg version "$4" --arg vc "$5" --arg arch "$6" --arg patches_src "$7" --arg pkg "$8" \
		'{type:$type, app:$app, tried:$tried, version:$version, vc:$vc, arch:$arch, patches_src:$patches_src, pkg:$pkg}' \
		> "$dir/$1_np.json" 2> /dev/null || true
}

java() {
	local -a java_env=(PATH="$PATH" HOME="$HOME" LANG="${LANG:-en_US.UTF-8}")
	[ -n "${XDG_DATA_HOME:-}" ] && java_env+=(XDG_DATA_HOME="$XDG_DATA_HOME")
	env -i "${java_env[@]}" java --enable-native-access=ALL-UNNAMED "$@";
}

source_release_api_base() {
	local host=${1,,} src=$2 encoded
	case "$host" in
		github) echo "https://api.github.com/repos/${src}/releases" ;;
		codeberg) echo "https://codeberg.org/api/v1/repos/${src}/releases" ;;
		gitlab)
			encoded=$(jq -nr --arg v "$src" '$v | @uri')
			echo "https://gitlab.com/api/v4/projects/${encoded}/releases"
			;;
		*) return 1 ;;
	esac
}

source_release_list_url() {
	local host=${1,,} src=$2 base
	base=$(source_release_api_base "$host" "$src") || return 1
	case "$host" in
	codeberg) echo "${base}?limit=50" ;;
	*) echo "${base}?per_page=100" ;;
	esac
}

source_release_web_url() {
	local host=${1,,} src=$2 tag=$3
	case "$host" in
		github) echo "https://github.com/${src}/releases/tag/${tag}" ;;
		codeberg) echo "https://codeberg.org/${src}/releases/tag/${tag}" ;;
		gitlab) echo "https://gitlab.com/${src}/-/releases/${tag}" ;;
		*) return 1 ;;
	esac
}

source_release_tag_api() {
	local host=${1,,} src=$2 tag=$3 base
	base=$(source_release_api_base "$host" "$src") || return 1
	case "$host" in
		github | codeberg) echo "${base}/tags/${tag}" ;;
		gitlab) echo "${base}/${tag}" ;;
		*) return 1 ;;
	esac
}

source_release_assets_json() {
	local host=${1,,}
	case "$host" in
		github | codeberg) jq -e '[.assets[]? | select(.name | (endswith("asc") or endswith("json")) | not)]' ;;
		gitlab) jq -e '[.assets.links[]? | select(.name | (endswith("asc") or endswith("json")) | not)]' ;;
		*) return 1 ;;
	esac
}

source_release_asset_url() {
	local host=${1,,}
	case "$host" in
		github) jq -r '.url' ;;
		codeberg) jq -r '.browser_download_url // .url' ;;
		gitlab) jq -r '.direct_asset_url // .url' ;;
		*) return 1 ;;
	esac
}

source_release_pick_from_list() {
	local host=${1,,} mode=$2
	case "$host" in
		github | codeberg)
			if [ "$mode" = beta ]; then
				jq -e -c 'map(select(.prerelease == true and .draft != true and .tag_name != null and .tag_name != "")) | sort_by(.published_at // .created_at // "") | reverse | .[0] // empty'
			else
				jq -e -c 'map(select(.prerelease != true and .draft != true and .tag_name != null and .tag_name != "")) | sort_by(.published_at // .created_at // "") | reverse | .[0] // empty'
			fi
			;;
		gitlab)
			if [ "$mode" = beta ]; then
				jq -e -c 'map(select(.tag_name != null and .tag_name != "" and (.tag_name | test("(?i)(dev|alpha|beta|rc)")))) | sort_by(.released_at // .created_at // "") | reverse | .[0] // empty'
			else
				jq -e -c 'map(select(.tag_name != null and .tag_name != "" and (.tag_name | test("(?i)(dev|alpha|beta|rc)") | not))) | sort_by(.released_at // .created_at // "") | reverse | .[0] // empty'
			fi
			;;
		*) return 1 ;;
	esac
}

get_apkeditor() {
	if [ -f "$TEMP_DIR/apkeditor.jar" ]; then return 0; fi
	local api_resp dl_url
	api_resp=$(gh_req "https://api.github.com/repos/REAndroid/APKEditor/releases/latest" -) || true
	dl_url=$(echo "$api_resp" | jq -r '.assets[]? | select(.name | endswith(".jar")) | .browser_download_url' | head -1) || true
	if [ -z "$dl_url" ] || [ "$dl_url" = "null" ]; then
		dl_url="https://github.com/REAndroid/APKEditor/releases/download/V1.4.9/APKEditor-1.4.9.jar"
	fi
	gh_dl "$TEMP_DIR/apkeditor.jar" "$dl_url" >/dev/null || return 1
}

get_prebuilts() {
	local cache_key="${1}_${2}_${3}_${4}_${5}_${6}"
	if [ -n "${__PREBUILTS_CACHE__["$cache_key"]:-}" ]; then
		__PREBUILTS_RESULT="${__PREBUILTS_CACHE__["$cache_key"]}"
		return 0
	fi
	local result
	if ! result=$(_get_prebuilts "$@"); then return 1; fi
	__PREBUILTS_CACHE__["$cache_key"]="$result"
	__PREBUILTS_RESULT="$result"
}

rv_release_dir() {
	local slug=${2,,}
	slug=${slug//\//__}
	printf '%s/%s__%s-rv' "$TEMP_DIR" "${1,,}" "$slug"
}

_release_channel_of() {
	case "${1,,}" in
	stable) echo stable ;;
	beta) echo beta ;;
	*) echo "" ;;
	esac
}

_patch_source_state_tag() {
	local file="${RVB_PATCH_SOURCES_JSON:-state/patch_sources.json}"
	[ -f "$file" ] || return 0
	jq -r --arg repo "${1,,}" --arg host "${2:-github}" --arg ch "$3" '
		to_entries
		| map(select(.value | type == "object"))
		| map(select(((.value.repo // .key) | ascii_downcase) == $repo))
		| map(select(((.value.host // "github") | ascii_downcase) == $host))
		| (.[0].value // {}) as $e
		| if $e.blocked == true then "" else ($e[$ch] // "") end
	' "$file"
}

_patch_source_state_blocked() {
	local file="${RVB_PATCH_SOURCES_JSON:-state/patch_sources.json}"
	[ -f "$file" ] || return 1
	jq -e --arg repo "${1,,}" --arg host "${2:-github}" '
		to_entries
		| map(select(.value | type == "object"))
		| map(select(((.value.repo // .key) | ascii_downcase) == $repo))
		| map(select(((.value.host // "github") | ascii_downcase) == $host))
		| (.[0].value.blocked // false)
	' "$file" >/dev/null
}

_get_prebuilts() {
	local cli_host=$1 cli_src=$2 cli_ver=$3 patches_host_list=$4 patches_src_list=$5 patches_ver_list=$6
	resolve_patcher "$cli_src"
	
	local first_patch_src
	first_patch_src=$(list_args "$patches_src_list" | tr -d \"\' | head -n 1)
	local prebuilts_header_printed=false

	local first_patch_host
	first_patch_host=$(list_args "$patches_host_list" | tr -d \"\' | head -n 1)
	local cl_dir
	cl_dir=$(rv_release_dir "$first_patch_host" "$first_patch_src")
	[ -d "$cl_dir" ] || mkdir "$cl_dir"

	local host=$cli_host src=$cli_src tag="CLI" ver=${cli_ver} fprefix="cli"
	host=${host,,}
	if ! isoneof "$host" github gitlab codeberg; then abort "source host '$host' is not supported"; fi

	local grab_cl=false
	local dir
	dir=$(rv_release_dir "$host" "$src")
	[ -d "$dir" ] || mkdir "$dir"

	local rv_rel release resp tag_name matches asset name url channel
	rv_rel=$(source_release_list_url "$host" "$src") || return 1
	channel=$(_release_channel_of "$ver")
	if [ "$channel" = beta ]; then
		resp=$(source_release_req "$host" "$rv_rel" -) || return 1
		release=$(source_release_pick_from_list "$host" beta <<<"$resp") || true
		ver=$(jq -r '.tag_name' <<<"$release") || true
		if [ -z "$ver" ] || [ "$ver" = "null" ]; then
			ver=$(jq -e -r '.[].tag_name' <<<"$resp" | get_highest_ver) || return 1
			release=""
		fi
	fi
	if [ "$channel" = stable ]; then
		resp=$(source_release_req "$host" "$rv_rel" -) || return 1
		release=$(source_release_pick_from_list "$host" stable <<<"$resp") || return 1
	elif [ -z "${release:-}" ]; then
		rv_rel=$(source_release_tag_api "$host" "$src" "$ver") || return 1
		release=$(source_release_req "$host" "$rv_rel" -) || return 1
	fi
	tag_name=$(jq -r '.tag_name' <<<"$release") || return 1
	name_ver=$tag_name

	local file
	file=$(find "$dir" -name "*${fprefix}-${name_ver#v}.*" -type f 2>/dev/null | head -1)
	if [ -z "$file" ]; then
		matches=$(source_release_assets_json "$host" <<<"$release") || return 1
		if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
			local matches_new
			matches_new=$(jq -e -r 'map(select(.name | test("\\.(jar|zip)$"; "i")))' <<<"$matches" 2>/dev/null) || true
			if [ -n "$matches_new" ] && [ "$(jq 'length' <<<"$matches_new")" -ge 1 ]; then
				matches=$matches_new
			fi
		fi
		if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
			local matches_new
			matches_new=$(jq -e -r 'map(select(.name | contains("-dev") | not))' <<<"$matches")
			if [ "$(jq 'length' <<<"$matches_new")" -eq 1 ]; then
				matches=$matches_new
			fi
		fi
		if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
			local matches_new
			matches_new=$(jq -e -r 'map(select(.name | contains("debug") | not))' <<<"$matches")
			if [ "$(jq 'length' <<<"$matches_new")" -ge 1 ]; then
				matches=$matches_new
			fi
		fi
		if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
			local matches_new
			matches_new=$(jq --arg ver "${name_ver#v}" -e -r 'map(select(.name | contains($ver)))' <<<"$matches")
			if [ "$(jq 'length' <<<"$matches_new")" -ge 1 ]; then
				matches=$matches_new
			fi
		fi
		if [ "$(jq 'length' <<<"$matches")" -eq 0 ]; then
			epr "No asset was found"
			return 1
		elif [ "$(jq 'length' <<<"$matches")" -ne 1 ]; then
			wpr "More than 1 asset was found for this release. Falling back to the first one found..."
		fi
		asset=$(jq -r ".[0]" <<<"$matches")
		url=$(source_release_asset_url "$host" <<<"$asset")
		name=$(jq -r .name <<<"$asset")
		file="${dir}/${name}"
		if [ "$prebuilts_header_printed" != true ]; then pr "Getting prebuilts (${first_patch_src%/*})" >&2; prebuilts_header_printed=true; fi
		if [ "$host" = github ]; then
			gh_dl "$file" "$url" >&2 || return 1
		else
			pr "Getting '$file' from '$url'"
			_req "$url" "$file" -H "Accept: application/octet-stream" >&2 || return 1
		fi
		echo "$tag: $(cut -d/ -f1 <<<"$src")/${name}  " >>"${cl_dir}/changelog.md"
	else
		grab_cl=false
		name=$(basename "$file")
		tag_name=$(cut -d'-' -f3- <<<"$name")
		tag_name=v${tag_name%.*}
	fi

	echo -n "$file "

	local IFS=$'\n'
	local p_srcs=($(list_args "$patches_src_list" | tr -d \"\'))
	local p_hosts=($(list_args "$patches_host_list" | tr -d \"\'))
	local p_vers=($(list_args "$patches_ver_list" | tr -d \"\'))
	unset IFS
	for i in "${!p_srcs[@]}"; do
		local host="${p_hosts[$i]:-${p_hosts[0]}}"
		local src="${p_srcs[$i]}"
		local ver="${p_vers[$i]:-${p_vers[0]}}"
		
		host=${host,,}
		if ! isoneof "$host" github gitlab codeberg; then abort "source host '$host' is not supported"; fi
		local tag="Patches" fprefix="patches"
		local grab_cl=true
		
		local rv_rel resp tag_name matches asset name url release=""
		local dir
		dir=$(rv_release_dir "$host" "$src")
		[ -d "$dir" ] || mkdir "$dir"
		
		rv_rel=$(source_release_list_url "$host" "$src") || return 1
		local channel snap_tag
		if _patch_source_state_blocked "$src" "$host"; then
			epr "Patch source '$src' is blocked in the watcher state (repository gone, taken down or inaccessible); not building this app"
			return 1
		fi
		channel=$(_release_channel_of "$ver")
		if [ -n "$channel" ]; then
			snap_tag=$(_patch_source_state_tag "$src" "$host" "$channel")
			if [ -n "$snap_tag" ]; then
				pr "Resolved '$src' ($channel) to '$snap_tag' from state snapshot" >&2
				ver="$snap_tag"
				channel=""
			fi
		fi
		if [ "$channel" = beta ]; then
			resp=$(source_release_req "$host" "$rv_rel" -) || return 1
			release=$(source_release_pick_from_list "$host" beta <<<"$resp") || true
			ver=$(jq -r '.tag_name' <<<"$release") || true
			if [ -z "$ver" ] || [ "$ver" = "null" ]; then
				ver=$(jq -e -r '.[].tag_name' <<<"$resp" | get_highest_ver) || return 1
				release=""
			fi
		fi
		if [ "$channel" = stable ]; then
			resp=$(source_release_req "$host" "$rv_rel" -) || return 1
			release=$(source_release_pick_from_list "$host" stable <<<"$resp") || return 1
		elif [ -z "${release:-}" ]; then
			rv_rel=$(source_release_tag_api "$host" "$src" "$ver") || return 1
			release=$(source_release_req "$host" "$rv_rel" -) || return 1
		fi
		tag_name=$(jq -r '.tag_name' <<<"$release") || return 1
		name_ver=$tag_name

		local file
		file=$(find "$dir" -name "*${fprefix}-${name_ver#v}.*" -type f 2>/dev/null | head -1)
		if [ -z "$file" ]; then
			matches=$(source_release_assets_json "$host" <<<"$release") || return 1
			if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
				local matches_new
				matches_new=$(jq -e -r --arg re "$PATCHER_BUNDLE_RE" 'map(select(.name | test($re; "i")))' <<<"$matches") || true
				if [ -n "$matches_new" ] && [ "$(jq 'length' <<<"$matches_new")" -ge 1 ]; then
					matches=$matches_new
				fi
			fi
			if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
				local matches_new
				matches_new=$(jq -e -r 'map(select(.name | contains("-dev") | not))' <<<"$matches")
				if [ "$(jq 'length' <<<"$matches_new")" -eq 1 ]; then
					matches=$matches_new
				fi
			fi
			if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
				local matches_new
				matches_new=$(jq -e -r 'map(select(.name | contains("debug") | not))' <<<"$matches")
				if [ "$(jq 'length' <<<"$matches_new")" -ge 1 ]; then
					matches=$matches_new
				fi
			fi
			if [ "$(jq 'length' <<<"$matches")" -gt 1 ]; then
				local matches_new
				matches_new=$(jq --arg ver "${name_ver#v}" -e -r 'map(select(.name | contains($ver)))' <<<"$matches")
				if [ "$(jq 'length' <<<"$matches_new")" -ge 1 ]; then
					matches=$matches_new
				fi
			fi
			if [ "$(jq 'length' <<<"$matches")" -eq 0 ]; then
				epr "No asset was found"
				return 1
			elif [ "$(jq 'length' <<<"$matches")" -ne 1 ]; then
				wpr "More than 1 asset was found for this release. Falling back to the first one found..."
			fi
			asset=$(jq -r ".[0]" <<<"$matches")
			url=$(source_release_asset_url "$host" <<<"$asset")
			name=$(jq -r .name <<<"$asset")
			file="${dir}/${name}"
			if [ "$prebuilts_header_printed" != true ]; then pr "Getting prebuilts (${first_patch_src%/*})" >&2; prebuilts_header_printed=true; fi
			if [ "$host" = github ]; then
				gh_dl "$file" "$url" >&2 || return 1
			else
				pr "Getting '$file' from '$url'"
				_req "$url" "$file" -H "Accept: application/octet-stream" >&2 || return 1
			fi
			echo "$tag: $(cut -d/ -f1 <<<"$src")/${name}  " >>"${cl_dir}/changelog.md"
		else
			grab_cl=false
			name=$(basename "$file")
		fi

		echo "$tag_name" > "${dir}/tag_name.txt"
		echo "$tag_name" > "${file}.tag"

		if [ "$grab_cl" = true ]; then
			local cl_url
			if cl_url=$(source_release_web_url "$host" "$src" "$tag_name"); then
				echo -e "[Changelog](${cl_url})\n" >>"${cl_dir}/changelog.md"
			fi
		fi
		if [ "$REMOVE_RV_INTEGRATIONS_CHECKS" = true ]; then
			local extensions_ext
			extensions_ext=$(unzip -l "${file}" "extensions/shared.*" | grep -o "shared\..*") extensions_ext="${extensions_ext#*.}"
			if ! (
				mkdir -p "${file}-zip" || return 1
				unzip -qo "${file}" -d "${file}-zip" || return 1
				java -cp "${BIN_DIR}/paccer.jar:${BIN_DIR}/dexlib2.jar" com.jhc.Main "${file}-zip/extensions/shared.${extensions_ext}" "${file}-zip/extensions/shared-patched.${extensions_ext}" || return 1
				mv -f "${file}-zip/extensions/shared-patched.${extensions_ext}" "${file}-zip/extensions/shared.${extensions_ext}" || return 1
				rm "${file}" || return 1
				cd "${file}-zip" || abort
				zip -0rq "${CWD}/${file}" . || return 1
			) >&2; then
				echo >&2 "Patching revanced-integrations failed"
			fi
			rm -r "${file}-zip" || :
		fi
		
		echo -n "$file "
	done
	echo
}

set_prebuilts() {
	APKSIGNER="${BIN_DIR}/apksigner.jar"
	local arch
	arch=$(uname -m)
	if [ "$arch" = aarch64 ]; then arch=arm64; elif [ "${arch:0:5}" = "armv7" ]; then arch=arm; fi
	HTMLQ="${BIN_DIR}/htmlq/htmlq-${arch}"
	if [ ! -x "$HTMLQ" ] && command -v htmlq >/dev/null 2>&1; then HTMLQ="htmlq"; fi
	AAPT2="${BIN_DIR}/aapt2/aapt2-${arch}"
	if [ ! -x "$AAPT2" ] && command -v aapt2 >/dev/null 2>&1; then AAPT2="aapt2"; fi
	TOML="${BIN_DIR}/toml/tq-${arch}"
	if [ ! -x "$TOML" ] && command -v tq >/dev/null 2>&1; then TOML="tq"; fi

	local sdk_root="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
	if [ -n "$sdk_root" ] && [ -d "$sdk_root/build-tools" ]; then
		local latest_bt
		latest_bt=$(ls -1d "$sdk_root"/build-tools/* 2>/dev/null | sort -V | tail -1)
		if [ -n "$latest_bt" ] && [ -f "$latest_bt/lib/apksigner.jar" ]; then
			APKSIGNER="$latest_bt/lib/apksigner.jar"
		fi
		if [ ! -x "$AAPT2" ] && [ -n "$latest_bt" ] && [ -x "$latest_bt/aapt2" ]; then
			AAPT2="$latest_bt/aapt2"
		fi
	fi
}

_req() {
	local ip="$1" op="$2"
	shift 2
	local dlp="$op"
	local _req_lock=""
	if [ "$op" != - ]; then
		if [ -f "$op" ]; then return; fi
		if command -v flock >/dev/null 2>&1; then
			mkdir -p "${TEMP_DIR}/dllocks"
			exec 204>"${TEMP_DIR}/dllocks/$(tr -cs 'a-zA-Z0-9._-' '_' <<<"$op").lock"
			flock -x 204
			_req_lock=1
			if [ -f "$op" ]; then exec 204>&-; return 0; fi
		fi
		dlp="$(dirname "$op")/tmp.$(basename "$op")"
		if [ -f "$dlp" ]; then
			local wait_c=0
			while [ -f "$dlp" ] && [ $wait_c -lt 300 ]; do 
				sleep 1
				wait_c=$((wait_c+1))
			done
			if [ -f "$op" ]; then return 0; fi
		fi
	fi
	if ! curl -L -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" \
		--connect-timeout 10 --retry 1 --max-time "${RVB_DL_MAX_TIME:-1800}" \
		--speed-limit 1024 --speed-time 120 \
		--fail -s -S "$@" "$ip" -o "$dlp"; then
		epr "Request failed: $ip"
		if [ "$dlp" != - ]; then rm -f "$dlp"; fi
		if [ -n "$_req_lock" ]; then exec 204>&-; fi
		return 1
	fi
	if [ "$dlp" != - ]; then
		mv -f "$dlp" "$op"
	fi
	if [ -n "$_req_lock" ]; then exec 204>&-; fi
}
req() { _req "$1" "$2" -H "User-Agent: ${DEFAULT_UA}"; }
gh_req() { _req "$1" "$2" -H "$GH_HEADER"; }
source_release_req() {
	local host=${1,,} url=$2 out=${3:--}
	case "$host" in
		github) gh_req "$url" "$out" ;;
		codeberg)
			if [ -n "${CODEBERG_TOKEN-}" ]; then
				_req "$url" "$out" -H "Accept: application/json" -H "Authorization: token ${CODEBERG_TOKEN}"
			else
				_req "$url" "$out" -H "Accept: application/json"
			fi
			;;
		gitlab)
			_req "$url" "$out" -H "Accept: application/json"
			;;
		*) req "$url" "$out" ;;
	esac
}
gh_dl() {
	if [ ! -f "$1" ]; then
		pr "Getting '$1' from '$2'"
		_req "$2" "$1" -H "$GH_HEADER" -H "Accept: application/octet-stream"
	fi
}

log() { echo -e "$1  " >>"build.md"; }
get_highest_ver() {
	local vers valid_vers=""
	vers=$(tee)
	
	while IFS= read -r v; do
		if [ -n "$v" ] && semver_validate "$v"; then
			valid_vers+="${v}"$'\n'
		fi
	done <<<"$vers"
	
	if [ -n "$valid_vers" ]; then
		sort -s -t- -k1,1Vr <<<"$valid_vers" | head -1
	else
		sort -s -t- -k1,1Vr <<<"$vers" | head -1
	fi
}
sort_vers() {
	local vers valid_vers=""
	vers=$(tee)
	
	while IFS= read -r v; do
		if [ -n "$v" ] && semver_validate "$v"; then
			valid_vers+="${v}"$'\n'
		fi
	done <<<"$vers"
	
	if [ -n "$valid_vers" ]; then
		sort -s -t- -k1,1Vr <<<"$valid_vers" | head -2
	else
		sort -s -t- -k1,1Vr <<<"$vers" | head -2
	fi
}
semver_validate() {
	local a="${1%%[-+_ (]*}"
	a="${a#v}"
	a="${a#V}"
	local ac="${a//[.0-9]/}"
	[ -n "$a" ] && [ ${#ac} = 0 ]
}
get_patch_last_supported_ver() {
	local cache_key="${1}_${2}_${3:-}_${4:-}_${5:-}_${6:-}_${7:-}_${8:-}"
	if [ -n "${__PATCH_VER_CACHE__["$cache_key"]:-}" ]; then
		echo "${__PATCH_VER_CACHE__["$cache_key"]}"
		return 0
	fi
	local result
	if ! result=$(_get_patch_last_supported_ver "$@"); then return 1; fi
	__PATCH_VER_CACHE__["$cache_key"]="$result"
	echo "$result"
}

_get_patch_last_supported_ver() {
	local list_patches=$1 pkg_name=$2 inc_sel=${3:-} _exc_sel=${4:-} _exclusive=${5:-} cli_source=${6:-} cli_jar=${7:-} patches_jar=${8:-}
	local op
	if [ "$inc_sel" ]; then
		local _vs="" _ev=""
		if _ev=$(_effective_patch_versions "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source" named "$inc_sel"); then
			_vs=$(cut -f1 <<<"$_ev" | sed -e '/^$/d' -e '/^Any$/d' | sort | uniq -c | sort -k1,1nr | awk '
					NR==1 { max=$1; print $2; next }
					$1==max { print $2 }
				' | sort_vers) || _vs=""
		fi
		if [ -n "$_vs" ]; then
			echo "$_vs"
			return
		fi
	fi
	op=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source") || return 1
	op=$(sed -n '/Most common compatible versions:/,$p' <<<"$op" | sed '1d' | awk '{$1=$1}1')
	if [ "$op" = "Any" ]; then return; fi
	pcount=$(head -1 <<<"$op") pcount=${pcount#*(} pcount=${pcount% *}
	if [ -z "$pcount" ]; then
		return
	fi
	grep -F "($pcount patch" <<<"$op" | sed 's/ (.* patch.*//' | sed 's/ \[.*//' | sort_vers || return 1
}

get_patch_exp_ver() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 cli_source=$4
	local list_stable list_all

	list_stable=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source" "") || return 1
	list_all=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source" "-x") || return 1

	list_stable=$(sed -n '/Most common compatible versions:/,$p' <<<"$list_stable" | sed '1d' | awk '{print $1}')
	list_all=$(sed -n '/Most common compatible versions:/,$p' <<<"$list_all" | sed '1d' | awk '{print $1}')

	local exp_versions=""
	for ver in $list_all; do
		if [ -n "$ver" ] && ! echo "$list_stable" | grep -qFx "$ver"; then
			exp_versions+="$ver"$'\n'
		fi
	done

	if [ -n "$exp_versions" ]; then
		sort_vers <<<"$exp_versions"
	fi
}

get_patch_version_code() {
	local raw_op="$1" version="$2" arch="${3:-}"
	local abi
	abi=$(_abi_token_of_arch "$arch")

	local line="" l
	while IFS= read -r l; do
		if [[ "$l" =~ ^[[:space:]]*${version//./\\.}[[:space:]] ]]; then
			line="$l"
			break
		fi
	done <<<"$raw_op"

	if [[ "$line" =~ \[versionCodes:[[:space:]]*([^]]+)\] ]]; then
		local vcodes="${BASH_REMATCH[1]}"
		vcodes="${vcodes^^}"
		vcodes="${vcodes//-/_}"
		if [ -n "$abi" ]; then
			if [[ "$vcodes" =~ ${abi}=([0-9]+) ]]; then
				echo "${BASH_REMATCH[1]}"
				return 0
			fi
			return 1
		elif [[ "$vcodes" =~ =([0-9]+) ]]; then
			echo "${BASH_REMATCH[1]}"
			return 0
		fi
	fi
	return 1
}

parse_arch_mapping() {
	local mapping="${1:-}" arch="${2:-}"
	if [[ "$mapping" != *":"* ]]; then
		echo "$mapping"
		return 0
	fi
	local matched="" entry
	local old_ifs="$IFS"
	IFS='|'
	for entry in $mapping; do
		if [[ "$entry" =~ ^[[:space:]]*([^:]+)[[:space:]]*:[[:space:]]*(.*)$ ]]; then
			local e_arch="${BASH_REMATCH[1]//[[:space:]]/}"
			local e_val="${BASH_REMATCH[2]}"
			e_val="${e_val//[ \'\";\r\n]/}"
			if [ "${e_arch,,}" = "${arch,,}" ]; then
				matched="$e_val"
				break
			fi
		fi
	done
	IFS="$old_ifs"
	echo "$matched"
}

_cache_all_archs_present() {
	local ver=$1 validate=${2:-no} raw_ver=${3:-$1}
	local arch arch_f check_apk
	for arch in "${arch_list[@]}"; do
		arch_f="${arch// /}"
		_cache_probe_apk "$ver" "$arch_f" "$raw_ver"
		check_apk="$_CACHE_CHECK_APK"
		if [ -z "$check_apk" ]; then
			return 1
		elif [ "$validate" = validate ] && [ -n "$_CACHE_VC" ]; then
			local cached_vc
			cached_vc=$(_meta_field_of "$check_apk" versionCode) || cached_vc=""
			if [ -n "$cached_vc" ] && [ "$cached_vc" != "$_CACHE_VC" ]; then
				pr "Cached APK for '$pkg_name' has versionCode '$cached_vc', but target requires '$_CACHE_VC'. Cache invalidated."
				[ "$check_apk" != "$_CACHE_ALL_APK" ] && rm -f "$check_apk"
				return 1
			fi
		fi
	done
	for arch in "${arch_list[@]}"; do
		_cache_touch_apks "$ver" "${arch// /}"
	done
	return 0
}

_cache_target_vc() {
	local target
	target=$(parse_arch_mapping "${args[version_code]:-}" "$2")
	if [ -z "$target" ] || [ "$target" = "auto" ]; then
		target=""
		if [ -n "$1" ] && [ -n "$cli_jar" ] && [ -n "$patches_jar" ]; then
			local raw_vers
			if raw_vers=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "${args[cli_source]:-}" "$cli_lv_extra"); then
				target=$(get_patch_version_code "$raw_vers" "$1" "$2" || true)
			fi
			if [ -z "$target" ]; then
				target=$(_patch_arch_verdict "$1" "$2" || true)
			fi
		fi
	fi
	echo "$target"
}

_cache_probe_apk() {
	local ver=$1 arch=$2 raw_ver=${3:-$1}
	local vc check_apk=""
	vc=$(_cache_target_vc "$raw_ver" "$arch")
	local vc_infix="${vc:+-$vc}"
	local stock_apk="${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-${arch}.apk"
	local all_apk="${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.apk"
	[ -f "$stock_apk" ] && check_apk="$stock_apk"
	[ -z "$check_apk" ] && [ -f "$all_apk" ] && check_apk="$all_apk"
	if [ -z "$check_apk" ] && [ "${_CACHE_BUNDLE_OK:-false}" = true ]; then
		local bx bpath
		for bx in xapk apkm apks; do
			bpath="${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-${arch}.${bx}"
			[ -f "$bpath" ] || bpath="${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.${bx}"
			if [ -f "$bpath" ]; then check_apk="$bpath"; all_apk="$bpath"; break; fi
		done
	fi
	_CACHE_VC="$vc"
	_CACHE_CHECK_APK="$check_apk"
	_CACHE_ALL_APK="$all_apk"
}

_cache_touch_apks() {
	local ver=$1 arch=$2
	local vc; vc=$(_cache_target_vc "$ver" "$arch")
	local vc_infix="${vc:+-$vc}"
	local f
	for f in "${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-${arch}.apk" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.apk" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-${arch}.xapk" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-${arch}.apkm" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-${arch}.apks" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.xapk" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.apkm" \
		"${apk_cache_dir}/${pkg_name}-${ver}${vc_infix}-all.apks"; do
		[ -f "$f" ] && touch "$f" 2>/dev/null || true
	done
}

patches_list_versions() {
	local cache_key="${1}_${2}_${3}_${4}_${5:-}"
	if [ -n "${__PATCH_VER_CACHE__["$cache_key"]:-}" ]; then
		echo "${__PATCH_VER_CACHE__["$cache_key"]}"
		return 0
	fi
	local result
	if ! result=$(_patches_list_versions "$@"); then return 1; fi
	__PATCH_VER_CACHE__["$cache_key"]="$result"
	echo "$result"
}

_patches_list_versions() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 cli_source=$4 extra_args=${5:-} op
	resolve_patcher "$cli_source"
	if [ "$PATCHER_HAS_PATCH_LIST" = false ]; then
		echo ""
		return 0
	fi

	local p_jars=($(echo "$patches_jar" | tr ' ' '\n' | grep -v '^$'))

	local p_args=""
	for j in "${p_jars[@]}"; do
		p_args+="$PATCHER_LIST_BUNDLE_ARG '$j' "
	done
	if ! op=$(eval java -jar "'$cli_jar'" $PATCHER_LIST_VERSIONS_SUB $PATCHER_LIST_B $p_args-f "'$pkg_name'" "$extra_args" 2>&1); then
		epr "Could not list versions $cli_jar: '$op'"
		return 1
	fi
	echo "$op"
}

_group_patch_names() {
	local n
	while IFS= read -r n; do
		[ -z "$n" ] && continue
		printf "'%s' " "$n"
	done
}

_all_patch_names() {
	local op
	[ "${PATCHER_HAS_PATCH_LIST:-false}" = true ] || return 1
	if ! op=$(patches_list "$1" "$2" "$3" "$4"); then return 1; fi
	printf '%s\n' "$op" | grep -iE '^[[:space:]]*Name:' \
		| sed -E 's/^[[:space:]]*Name:[[:space:]]*//I' | sed 's/[[:space:]]*$//'
}

_applied_from_result() {
	[ -f "$1" ] || return 0
	jq -c '[.appliedPatches[]? | if type=="object" then .name else . end | select(. != null)]' "$1" 2>/dev/null || :
}

_failed_from_result() {
	[ -f "$1" ] || return 0
	jq -r '[.failedPatches[]? | if type=="object" then (.name // .patch // tostring) else . end] | join(", ")' "$1" 2>/dev/null || :
}

patches_list() {
	local cache_key="${1}_${2}_${3}_${4}"
	if [ -n "${__PATCHES_LIST_CACHE__["$cache_key"]:-}" ]; then
		echo "${__PATCHES_LIST_CACHE__["$cache_key"]}"
		return 0
	fi
	local result
	if ! result=$(_patches_list "$@"); then return 1; fi
	__PATCHES_LIST_CACHE__["$cache_key"]="$result"
	echo "$result"
}

_instafel_shadow_core() {
	local cli_jar=$1 patches_jar=$2; shift 2
	local -a extra_dirs=("$@")
	local cli_dir cli_commit d j j_base
	local _cp="cp"
	cp --version 2>/dev/null | grep -q GNU && _cp="cp --remove-destination"
	cli_dir=$(dirname "$cli_jar")
	cli_commit=$(unzip -p "$cli_jar" META-INF/MANIFEST.MF 2>/dev/null | sed -n 's/^Patcher-Cli-Commit: //p' | tr -d '\r')
	[ -z "$cli_commit" ] && cli_commit="$RVB_INSTAFEL_FALLBACK_COMMIT"
	for j in $(echo "$patches_jar" | tr ' ' '\n' | grep -v '^$'); do
		j_base=$(basename "$j")
		$_cp "$j" "$cli_dir/$j_base" 2>/dev/null || :
		$_cp "$j" "$j_base" 2>/dev/null || :
		for d in "${extra_dirs[@]}"; do $_cp "$j" "$d/$j_base" 2>/dev/null || :; done
		$_cp "$j" "$cli_dir/ifl-patcher-core-${cli_commit}.jar" 2>/dev/null || :
		$_cp "$j" "ifl-patcher-core-${cli_commit}.jar" 2>/dev/null || :
		for d in "${extra_dirs[@]}"; do $_cp "$j" "$d/ifl-patcher-core-${cli_commit}.jar" 2>/dev/null || :; done
		if [ "$cli_commit" != "$RVB_INSTAFEL_FALLBACK_COMMIT" ]; then
			$_cp "$j" "$cli_dir/ifl-patcher-core-${RVB_INSTAFEL_FALLBACK_COMMIT}.jar" 2>/dev/null || :
			$_cp "$j" "ifl-patcher-core-${RVB_INSTAFEL_FALLBACK_COMMIT}.jar" 2>/dev/null || :
			for d in "${extra_dirs[@]}"; do $_cp "$j" "$d/ifl-patcher-core-${RVB_INSTAFEL_FALLBACK_COMMIT}.jar" 2>/dev/null || :; done
		fi
	done
}

_patches_list() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 cli_source=$4 op
	resolve_patcher "$cli_source"
	if [ "$PATCHER_FLOW" = xposed-module ]; then
		echo "Name: xposed-module-dummy"
		return 0
	fi
	local p_jars=($(echo "$patches_jar" | tr ' ' '\n' | grep -v '^$'))
	if [ "$PATCHER_FLOW" = instafel-workflow ]; then
		_instafel_shadow_core "$cli_jar" "$patches_jar"
		local ifl_xdg
		ifl_xdg=$(mktemp -d "${TMPDIR:-/tmp}/ifl-xdg.XXXXXX" 2>/dev/null) || ifl_xdg=""
		local op_rc=0
		if [ -n "$ifl_xdg" ]; then
			op=$(eval "XDG_DATA_HOME='$ifl_xdg' java -jar '$cli_jar' list" 2>&1) || op_rc=$?
			rm -rf "$ifl_xdg" 2>/dev/null || :
		else
			op=$(eval java -jar "'$cli_jar'" list 2>&1) || op_rc=$?
		fi
		if [ "$op_rc" -ne 0 ]; then
			epr "Could not get patches list $cli_jar: '$op'"
			return 1
		fi
		echo "$op"
		return 0
	fi
	if [ "$PATCHER_KIND" = morphe ]; then
		local p_args_morphe=""
		for j in "${p_jars[@]}"; do
			p_args_morphe+="--patches '$j' "
		done
		if ! op=$(eval java -jar "'$cli_jar'" list-patches $p_args_morphe -f "'$pkg_name'" --with-versions --with-packages -x 2>&1); then
			epr "Could not get patches list $cli_jar: '$op'"
			return 1
		fi
	else
		local p_args_revanced=""
		for j in "${p_jars[@]}"; do
			p_args_revanced+="-p '$j' "
		done
		if ! op=$(eval java -jar "'$cli_jar'" list-patches -b $p_args_revanced --packages --versions --options --filter-package-name="'$pkg_name'" 2>&1); then
			epr "Could not get patches list $cli_jar: '$op'"
			return 1
		fi
	fi
	echo "$op"
}

_ver_key() { local v=${1// /}; v="${v#v}"; v="${v#V}"; printf '%s' "$v"; }

_abi_token_of_arch() {
	case "${1,,}" in
		arm64-v8a | arm64) echo "ARM64_V8A" ;;
		arm-v7a | armeabi-v7a | arm) echo "ARMEABI_V7A" ;;
		x86_64) echo "X86_64" ;;
		x86) echo "X86" ;;
		*) echo "" ;;
	esac
}

_effective_patch_versions() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 cli_source=$4 mode=${5:-named} inc=${6:-}
	[ -n "$cli_jar" ] && [ -n "$patches_jar" ] && [ -n "$pkg_name" ] || return 1
	resolve_patcher "$cli_source"
	[ "${PATCHER_HAS_PATCH_LIST:-false}" = true ] || return 1

	local key="${mode}|${cli_jar}|${patches_jar}|${pkg_name}|${cli_source}|${inc}"
	local cached="${__EFF_PATCH_VER_CACHE__["$key"]:-}"
	if [ -n "$cached" ]; then
		[ "$cached" = "@fail" ] && return 1
		[ "$cached" = "@none" ] && return 2
		printf '%s\n' "$cached"
		return 0
	fi

	local listing out
	if [ "$mode" = named ]; then
		[ -n "$inc" ] || { __EFF_PATCH_VER_CACHE__["$key"]="@fail"; return 1; }
		if ! listing=$(patches_list "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source"); then
			__EFF_PATCH_VER_CACHE__["$key"]="@fail"
			return 1
		fi
		local names
		names=$(list_args "${inc//|/ }" | sed -e "s/^'//" -e "s/'\$//" -e 's/^"//' -e 's/"$//')
		out=$(printf '%s\n__RVB_EFF_NAMES__\n%s\n' "$names" "$listing" | awk -v sent="__RVB_EFF_NAMES__" '
			function flush(  i, v) {
				if (active) {
					if (anyv) printf "Any\t\n"
					for (i = 1; i <= nv; i++) { v = vers[i]; printf "%s\t%s\n", v, abis[v] }
				}
				nv = 0; delete vers; delete abis; anyv = 0; sect = ""; active = 0
			}
			{ t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t) }
			!named { if (t == sent) named = 1; else if (t != "") want[t] = 1; next }
			t ~ /^Name:/ {
				flush(); nm = substr(t, 6); sub(/^[ \t]+/, "", nm); sub(/[ \t]+$/, "", nm)
				active = (nm in want); next
			}
			t ~ /^(INFO: )?Index:/ { flush(); next }
			t ~ /^Compatible versions:/ { if (active) sect = "ver"; next }
			t ~ /^Version codes:/ { if (active) sect = "vc"; next }
			t ~ /^(Enabled|Description|Options|Requires|Version|Compatible packages|Min version|UUID|Author|Package name):/ { sect = ""; next }
			!active { next }
			sect == "ver" && t == "Any" { anyv = 1; next }
			sect == "ver" && t ~ /^[vV]?[0-9]/ { gsub(/[ \t]/, "", t); sub(/^[vV]/, "", t); nv++; vers[nv] = t; next }
			sect == "vc" && t ~ /^[vV]?[0-9][^:]*: .*=/ {
				p = index(t, ":"); v = substr(t, 1, p - 1); r = substr(t, p + 1)
				gsub(/[ \t]/, "", v); sub(/^[vV]/, "", v)
				gsub(/,/, " ", r); gsub(/[ \t]+/, " ", r); sub(/^ /, "", r); sub(/ $/, "", r)
				found = 0
				for (i = 1; i <= nv; i++) if (vers[i] == v) { found = 1; break }
				if (!found) { nv++; vers[nv] = v }
				abis[v] = (abis[v] == "" ? r : abis[v] " " r)
				next
			}
			END { flush() }')
	else
		if ! listing=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source" "$PATCHER_LIST_X"); then
			__EFF_PATCH_VER_CACHE__["$key"]="@fail"
			return 1
		fi
		[ -n "$listing" ] || { __EFF_PATCH_VER_CACHE__["$key"]="@fail"; return 1; }
		out=$(awk '
			function trimv(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
			{ t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t) }
			t == "" { next }
			t ~ /^INFO:/ { next }
			t ~ /^Most common compatible versions:/ { next }
			t ~ /^Package name:/ { next }
			t == "Any" { printf "Any\t\n"; next }
			t !~ /^[vV]?[0-9]/ { next }
			{
				abis = ""; q = index(t, "[versionCodes:")
				if (q) {
					r = substr(t, q + 14)
					if (sub(/\].*/, "", r)) { gsub(/,/, " ", r); gsub(/[ \t]+/, " ", r); sub(/^ /, "", r); sub(/ $/, "", r); abis = r }
				}
				v = substr(t, 1, q ? q - 1 : length(t))
				sub(/ \(.*$/, "", v); v = trimv(v); gsub(/[ \t]/, "", v); sub(/^[vV]/, "", v)
				if (v == "") next
				printf "%s\t%s\n", v, abis
			}' <<<"$listing")
	fi

	if [ -z "$out" ]; then
		__EFF_PATCH_VER_CACHE__["$key"]="@none"
		return 2
	fi
	__EFF_PATCH_VER_CACHE__["$key"]="$out"
	printf '%s\n' "$out"
}

_effective_arch_verdict() {
	local tab=$1 ver arch=$3 abi
	ver=$(_ver_key "$2")
	abi=$(_abi_token_of_arch "$arch")
	[ -z "$abi" ] && return 0
	awk -F'\t' -v ver="$ver" -v abi="$abi" '
		function canon(s) { gsub(/-/, "_", s); return toupper(s) }
		$1 != ver { next }
		{
			total++
			if ($2 == "") { uncon = 1; next }
			n = split($2, tok, " ")
			for (i = 1; i <= n; i++) {
				if (tok[i] == "") continue
				t = tok[i]; sub(/[,;]+$/, "", t)
				p = index(t, "=")
				if (p < 2) continue
				k = canon(substr(t, 1, p - 1)); val = substr(t, p + 1)
				if (val !~ /^[0-9]+$/) continue
				seen[k] = 1
				if (k in code) { if (code[k] != val) code[k] = "@amb" } else code[k] = val
			}
			constrained++
		}
		END {
			if (total == 0) exit 0
			if (!constrained || uncon) exit 0
			if (!(canon(abi) in seen)) exit 1
			if (code[canon(abi)] != "" && code[canon(abi)] != "@amb") printf "%s", code[canon(abi)]
			exit 0
		}' <<<"$tab"
}

_table_has_version() { awk -F'\t' -v ver="$2" '$1 == ver { found = 1 } END { exit !found }' <<<"$1"; }

_patch_arch_verdict() {
	local tab v
	v=$(_ver_key "$1")
	if [ -n "${args[included_patches]:-}" ]; then
		tab=$(_effective_patch_versions "$cli_jar" "$patches_jar" "$pkg_name" "${args[cli_source]:-}" named "${args[included_patches]}") || tab=""
		if [ -n "$tab" ] && _table_has_version "$tab" "$v"; then
			_effective_arch_verdict "$tab" "$v" "$2"
			return $?
		fi
	fi
	tab=$(_effective_patch_versions "$cli_jar" "$patches_jar" "$pkg_name" "${args[cli_source]:-}" default) || tab=""
	[ -n "$tab" ] && _table_has_version "$tab" "$v" || return 0
	_effective_arch_verdict "$tab" "$v" "$2"
}

_candidate_arch_verdict() {
	local vc="" cand v
	v=$(_ver_key "$1")
	if vc=$(_patch_arch_verdict "$1" "$2"); then
		printf '%s' "$vc"
		return 0
	fi
	for cand in $3; do
		cand=$(_ver_key "$cand")
		if [ -z "$cand" ] || [ "$cand" = "$v" ]; then continue; fi
		if _patch_arch_verdict "$cand" "$2" > /dev/null 2>&1; then
			return 1
		fi
	done
	pr "No supported version declares a '$2' build; trying v${v} and letting the artifact bytes decide."
	return 0
}

has_compatible_patches() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 version=$4 cli_source=$5
	local inc_patches=${6:-}
	resolve_patcher "$cli_source"
	if [ "$PATCHER_ANY_VERSION" = true ]; then
		return 0
	fi
	[ -z "$cli_jar" ] || [ -z "$patches_jar" ] || [ -z "$pkg_name" ] || [ -z "$version" ] && return 0

	local ver_clean
	ver_clean=$(_ver_key "$version")

	local _named="" _default="" _default_rc=0
	if [ -n "$inc_patches" ]; then
		_named=$(_effective_patch_versions "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source" named "$inc_patches") || _named=""
	fi
	_default=$(_effective_patch_versions "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source" default) || _default_rc=$?

	local _tbl tv
	for _tbl in "$_named" "$_default"; do
		[ -n "$_tbl" ] || continue
		while IFS=$'\t' read -r tv _; do
			[ -z "$tv" ] && continue
			[ "$tv" = "Any" ] && return 0
			[ "$tv" = "$ver_clean" ] && return 0
		done <<<"$_tbl"
	done

	if [ "$_default_rc" = 1 ]; then
		return 0
	fi

	if [ "$PATCHER_KIND" = morphe ] && [ -n "$patches_jar" ]; then
		local op_list
		if op_list=$(patches_list "$cli_jar" "$patches_jar" "$pkg_name" "$cli_source"); then
			local unp
			unp=$(awk -v pkg="$pkg_name" 'BEGIN{pat="^[[:space:]]*Package name:[[:space:]]*" pkg "[[:space:]]*$"}
				function flush(){if (seen && !pins && name != "") print name "\t" en}
				{if ($0 ~ /^INFO: Index:/ || $0 ~ /^[[:space:]]*Index:/) {flush(); name=""; en=""; seen=0; pins=0}
					else if ($0 ~ /^[[:space:]]*Name:/) {name=$0; sub(/^[[:space:]]*Name:[[:space:]]*/, "", name); sub(/[[:space:]]+$/, "", name)}
					else if ($0 ~ /^[[:space:]]*Enabled:/) {en=($0 ~ /true/) ? "true" : "false"}
					else if ($0 ~ /^[[:space:]]*Package name:/) {seen=($0 ~ pat); pins=0}
					else if ($0 ~ /^[[:space:]]*Compatible versions:/ && seen) pins=1}
				END{flush()}' <<<"$op_list")
			if [ -n "$unp" ]; then
				local -a inc_names=()
				local n uname uen
				while IFS= read -r n; do
					n="${n#"${n%%[![:space:]]*}"}"
					n="${n%"${n##*[![:space:]]}"}"
					n=${n#\'}; n=${n%\'}; n=${n#\"}; n=${n%\"}
					[ -n "$n" ] && inc_names+=("$n")
				done <<<"$(list_args "${inc_patches//|/ }")"
				if [ ${#inc_names[@]} -gt 0 ]; then
					local match=false
					while IFS=$'\t' read -r uname uen; do
						[ -z "$uname" ] && continue
						for n in "${inc_names[@]}"; do
							if [ "$n" = "$uname" ]; then match=true; break; fi
						done
						[ "$match" = true ] && break
					done <<<"$unp"
					if [ "$match" = true ]; then return 0; fi
					wpr "Only version-unpinned patches found in '$pkg_name' bundle ($(cut -f1 <<<"$unp" | paste -sd ',' -)); none of included-patches matches them, so nothing would be applied."
					return 1
				fi
				if awk -F'\t' '$2 == "true"{found=1} END{exit !found}' <<<"$unp"; then
					return 0
				fi
				wpr "Only version-unpinned patches found in '$pkg_name' bundle ($(cut -f1 <<<"$unp" | paste -sd ',' -)), but none is default-enabled and no included-patches are configured."
				return 1
			fi
		fi
	fi

	return 1
}

isoneof() {
	local i=$1 v
	shift
	for v; do [ "$v" = "$i" ] && return 0; done
	return 1
}

_bundle_ext_of() {
	local ext="${1##*.}"
	case "${ext,,}" in xapk|apkm|apks) echo "${ext,,}" ;; *) return 1 ;; esac
}

_bundle_keep_regex_for_arch() {
	case "$1" in
		arm64-v8a) echo 'arm64_v8a' ;;
		arm-v7a) echo 'armeabi' ;;
		x86_64) echo 'x86_64' ;;
		x86) echo 'x86(?!_)' ;;
		*) echo '' ;;
	esac
}

_trim_bundle_for_arch() {
	local src=$1 dst=$2 arch=$3
	cp -f "$src" "$dst" || return 1
	local keep; keep=$(_bundle_keep_regex_for_arch "$arch")
	[ -z "$keep" ] && return 0
	local -a drop=()
	local name
	while IFS= read -r name; do
		[[ "$name" == *.apk ]] || continue
		name="${name##*/}"
		[[ "$name" == base.apk ]] && continue
		[[ "$name" =~ config\.(arm64_v8a|armeabi[_-]v7a|armeabi|x86_64|x86|mips|mips64)([._-]|\.apk$) ]] || continue
		if ! grep -qP "$keep" <<<"$name"; then drop+=("$name"); fi
	done < <(unzip -Z1 "$src" 2>/dev/null)
	if [ ${#drop[@]} -gt 0 ]; then
		zip -q -d "$dst" "${drop[@]}" 2>/dev/null || return 1
	fi
	return 0
}

_bundle_extract_base() {
	if unzip -p "$1" base.apk > "$2" 2>/dev/null && [ -s "$2" ]; then
		return 0
	fi
	local largest
	largest=$(unzip -l "$1" 2>/dev/null | awk '/\.apk$/{if ($1>max){max=$1; name=$NF}} END{print name}')
	[ -n "$largest" ] || { rm -f "$2"; return 1; }
	unzip -p "$1" "$largest" > "$2" 2>/dev/null && [ -s "$2" ]
}

_meta_field_of() {
	local file=$1 field=$2
	local probe="$file" tmp=""
	if _bundle_ext_of "$file" >/dev/null 2>&1; then
		tmp="${TEMP_DIR}/meta_probe_$$.apk"
		_bundle_extract_base "$file" "$tmp" || { rm -f "$tmp"; return 1; }
		probe="$tmp"
	fi
	local v="" _tool
	for _tool in "${AAPT2:-}" aapt2 aapt; do
		[ -z "$_tool" ] && continue
		if ! command -v "$_tool" >/dev/null 2>&1 && [ ! -x "$_tool" ]; then
			continue
		fi
		case "$field" in
			package)
				[[ "$_tool" == *"aapt2"* ]] && v=$("$_tool" dump packagename "$probe" 2>/dev/null | tr -d '\r\n')
				[ -z "$v" ] && v=$("$_tool" dump badging "$probe" 2>/dev/null | grep -oP "package: name='\K[^']+" | head -1)
				;;
			versionCode) v=$("$_tool" dump badging "$probe" 2>/dev/null | grep -oP "versionCode='\K[^']+" | head -1) ;;
			versionName) v=$("$_tool" dump badging "$probe" 2>/dev/null | grep -oP "versionName='\K[^']+" | head -1) ;;
		esac
		[ -n "$v" ] && break
	done
	[ -n "$tmp" ] && rm -f "$tmp"
	[ -n "$v" ] && echo "$v"
}

merge_splits() {
	local bundle=$1 output=$2
	local _ms_lock="${TEMP_DIR}/mergesplits.$(tr -c 'a-zA-Z0-9._-' '_' <<<"$output").lock"
	if command -v flock >/dev/null 2>&1; then
		exec 201>"$_ms_lock"
		flock -x 201
	fi
	_merge_splits_locked "$bundle" "$output"
	local _ms_ret=$?
	exec 201>&-
	return $_ms_ret
}

_merge_splits_locked() {
	local bundle=$1 output=$2
	if unzip -l "$bundle" 2>/dev/null | grep -q '^[[:space:]]*[0-9].*AndroidManifest\.xml$'; then
		pr "Downloaded bundle is actually a standard APK. Bypassing merge."
		mv -f "$bundle" "$output"
		return 0
	fi
	local apk_count
	apk_count=$(unzip -l "$bundle" 2>/dev/null | grep -c '\.apk$' || true)
	if [ "$apk_count" -le 1 ] && unzip -l "$bundle" 2>/dev/null | grep -q '^[[:space:]]*[0-9].*base\.apk$'; then
		pr "Extracting base.apk from bundle"
		unzip -p "$bundle" base.apk > "${output}-merge-tmp" || { rm -f "${output}-merge-tmp"; return 1; }
		mv -f "${output}-merge-tmp" "$output"
		return 0
	fi
	pr "Merging splits"
	get_apkeditor || return 1
	if ! OP=$(java -jar "$TEMP_DIR/apkeditor.jar" merge -i "$bundle" -o "${output}-merge-tmp.unsigned" -clean-meta -f 2>&1); then
		epr "APKEditor error: $OP"
		rm -f "${output}-merge-tmp.unsigned"
		return 1
	fi
	if ! OP=$(java -jar "$APKSIGNER" sign --ks "$RVB_KEYSTORE_P12" --ks-pass pass:$RVB_KEYSTORE_PASS --key-pass pass:$RVB_KEYSTORE_PASS --ks-key-alias "$RVB_KEY_ALIAS" \
		--out "${output}-merge-tmp" "${output}-merge-tmp.unsigned"); then
		epr "apksigner error: $OP"
		rm -f "${output}-merge-tmp.unsigned" "${output}-merge-tmp"
		return 1
	fi
	mv -f "${output}-merge-tmp" "$output" || return 1
	rm "${output}.idsig" "${output}-merge-tmp.unsigned" 2>/dev/null || :
	return 0
}

_cf_cffi_download() {
	local url=$1 dest=$2 referer=${3:-}
	local py_cmd=""
	if command -v python3 >/dev/null 2>&1; then
		py_cmd="python3"
	elif command -v python >/dev/null 2>&1; then
		py_cmd="python"
	fi
	[ -z "$py_cmd" ] && return 2
	local py_script="${CWD}/scripts/cf_get.py"
	[ ! -f "$py_script" ] && [ -n "${BASH_SOURCE[0]:-}" ] && py_script="$(dirname "${BASH_SOURCE[0]}")/cf_get.py"
	[ ! -f "$py_script" ] && return 2

	"$py_cmd" "$py_script" download "$url" "$dest" "$referer" "$TEMP_DIR/cookie.txt"
}

_fallback_get(){
	local url=$1
	html=$(curl -L -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" --connect-timeout 10 --retry 1 -s -f "$url" -H "User-Agent: ${DEFAULT_UA}") || return 1
	if [[ "$html" == *"Attention Required!"* || "$html" == *"Just a moment..."* || "$html" == *"Please Wait... | Cloudflare"* || "$html" == *"Verify you are human"* ]]; then
		return 1
	fi
	__CF_GET_VIA__="curl"
	CF_COOKIES=""
	user_agent="${DEFAULT_UA}"
}

_cf_cffi_get() {
	local url=$1
	local py_cmd=""
	if command -v python3 >/dev/null 2>&1; then
		py_cmd="python3"
	elif command -v python >/dev/null 2>&1; then
		py_cmd="python"
	fi
	[ -z "$py_cmd" ] && return 2
	local py_script="${CWD}/scripts/cf_get.py"
	[ ! -f "$py_script" ] && [ -n "${BASH_SOURCE[0]:-}" ] && py_script="$(dirname "${BASH_SOURCE[0]}")/cf_get.py"
	[ ! -f "$py_script" ] && return 2

	local cffi_res
	__CF_GET_VIA__=""
	rm -f "$TEMP_DIR/cf_source.txt" 2> /dev/null
	if cffi_res=$("$py_cmd" "$py_script" "$url" "$TEMP_DIR/cookie.txt" 2> /dev/null); then
		html="$cffi_res"
		if [ -f "$TEMP_DIR/cf_source.txt" ]; then
			__CF_GET_VIA__="$(head -1 "$TEMP_DIR/cf_source.txt" 2> /dev/null || true)"
		fi
		if [ -f "$TEMP_DIR/cf_ua.txt" ]; then
			user_agent="$(cat "$TEMP_DIR/cf_ua.txt" 2>/dev/null || echo "${DEFAULT_UA}")"
		else
			user_agent="${DEFAULT_UA}"
		fi
		if [ -f "$TEMP_DIR/cf_cookies.txt" ]; then
			export CF_COOKIES="$(cat "$TEMP_DIR/cf_cookies.txt" 2>/dev/null || echo "")"
		else
			CF_COOKIES=""
		fi
		return 0
	else
		return 1
	fi
}

_unqueued_cf_get() {
	_cf_cffi_get "$@" && return 0
	_fallback_get "$@" && return 0

	if [[ "${__SILENT_CF_GET__:-false}" != true ]]; then
		epr "All methods failed for: $1"
	fi
	return 1
}

_cf_get() {
	mkdir -p "$TEMP_DIR"
	local lock=$TEMP_DIR/cf_get.lock
	exec 200>"$lock"
	if command -v flock >/dev/null 2>&1; then
		flock -x 200
	fi
	trap 'exec 200>&-' RETURN EXIT INT TERM
	_unqueued_cf_get "$@"
}

patch_apk() {
	local stock_input=$1 patched_apk=$2 patcher_args=$3 cli_jar=$4 patches_jar=$5 cli_source=$6
	local per_bundle_ed="${7:-}"
	local tmp_dir="${CWD}/${patched_apk}-temporary-files"
	local IFS=$'\n'
	local p_jars=($(echo "$patches_jar" | tr ' ' '\n' | grep -v '^$'))
	unset IFS

	local cli_source_l="${cli_source,,}"
	resolve_patcher "$cli_source"
	if [ "$PATCHER_FLOW" = xposed-module ]; then
		local p_args_modules=""
		for j in "${p_jars[@]}"; do
			p_args_modules+=" -m '$j'"
		done
		local ks_args="" ks_file="$RVB_KEYSTORE_P12"
		if [ "${PATCHER_SIGNING:-false}" = true ]; then
			if [ "${PATCHER_KEYSTORE_FORMAT:-pkcs12}" = bks ]; then
				ks_file="$RVB_KEYSTORE"
			fi
			if [ -z "$ks_file" ] || [ ! -f "$ks_file" ]; then
				epr "No signing keystore for '$cli_source' (want a $PATCHER_KEYSTORE_FORMAT store; have RVB_KEYSTORE='$RVB_KEYSTORE' RVB_KEYSTORE_P12='$RVB_KEYSTORE_P12')"
				return 1
			fi
			ks_args=" -k '$ks_file' '$RVB_KEYSTORE_PASS' '$RVB_KEY_ALIAS' '$RVB_KEYSTORE_PASS'"
		fi
		mkdir -p "$tmp_dir"
		local cmd="java -jar '$cli_jar' -o '$tmp_dir'$p_args_modules$ks_args $patcher_args '$stock_input'"
		pr "$cmd"
		PATCH_OUTPUT=$(eval "$cmd" 2>&1)
		local ret=$?
		echo "$PATCH_OUTPUT"
		if [ $ret -eq 0 ]; then
			local npatch_out
			npatch_out=$(find "$tmp_dir" -type f -name "*.apk" | head -n 1)
			if [ -n "$npatch_out" ] && [ -f "$npatch_out" ]; then
				mv "$npatch_out" "$patched_apk"
				rm -rf "$tmp_dir"
				return 0
			fi
		fi
		rm "$patched_apk" 2>/dev/null || :
		rm -rf "$tmp_dir"
		return 1
	fi

	if [ "$PATCHER_FLOW" = instafel-workflow ]; then
		local rel_tmp_dir="${patched_apk}-temporary-files"
		mkdir -p "$rel_tmp_dir"
		local ifl_xdg="$rel_tmp_dir/xdg-data"
		mkdir -p "$ifl_xdg"
		_instafel_shadow_core "$cli_jar" "$patches_jar" "$rel_tmp_dir"

		local expected_base
		expected_base=$(basename "$stock_input" .apk)
		[ -n "$expected_base" ] && [ -d "$expected_base" ] && rm -rf "$expected_base" 2>/dev/null || :

		local init_cmd="XDG_DATA_HOME='$ifl_xdg' java -jar '$cli_jar' init '$stock_input'"
		pr "$init_cmd"
		local init_op
		init_op=$(eval "$init_cmd" 2>&1)
		pr "$init_op"

		local wdir=""
		if [ -n "$expected_base" ] && [ -d "$expected_base" ] && [ -f "$expected_base/project.json" ]; then
			wdir="$expected_base"
		elif [ -n "$expected_base" ] && [ -d "$rel_tmp_dir/$expected_base" ] && [ -f "$rel_tmp_dir/$expected_base/project.json" ]; then
			wdir="$rel_tmp_dir/$expected_base"
		else
			local proj_file
			proj_file=$(find "$rel_tmp_dir" . -maxdepth 3 -type f -name "project.json" 2>/dev/null | grep "$expected_base" | head -1)
			[ -z "$proj_file" ] && proj_file=$(find "$rel_tmp_dir" . -maxdepth 3 -type f -name "project.json" 2>/dev/null | head -1)
			if [ -n "$proj_file" ]; then
				wdir=$(dirname "$proj_file")
				wdir="${wdir#./}"
			fi
		fi

		if [ -z "$wdir" ] || [ ! -d "$wdir" ]; then
			epr "Instafel init failed to create project working directory for '$stock_input'."
			rm -rf "$rel_tmp_dir" 2>/dev/null || :
			return 1
		fi

		local patches_to_run=""
		if [ -n "$per_bundle_ed" ]; then
			patches_to_run=$(_ed_names "$per_bundle_ed" | paste -sd " " -)
		fi
		if [ -z "$patches_to_run" ]; then
			patches_to_run="$RVB_INSTAFEL_DEFAULT_PATCHES"
		fi

		local run_cmd="XDG_DATA_HOME='$ifl_xdg' java -jar '$cli_jar' run '$wdir' $patches_to_run"
		pr "$run_cmd"
		PATCH_OUTPUT=$(eval "$run_cmd" 2>&1)
		echo "$PATCH_OUTPUT"

		local build_cmd="XDG_DATA_HOME='$ifl_xdg' java -jar '$cli_jar' build '$wdir'"
		pr "$build_cmd"
		local build_op
		build_op=$(eval "$build_cmd" 2>&1)
		echo "$build_op"
		PATCH_OUTPUT+=$'\n'"$build_op"

		local built_apk=""
		if echo "$patches_to_run" | grep -qwi "clone"; then
			built_apk=$(find "$wdir/build" "$wdir" "$rel_tmp_dir" -maxdepth 5 -type f -name "*.apk" 2>/dev/null | grep -v "$stock_input" | grep -iE "/clone|_c_" | head -n 1)
			if [ -z "$built_apk" ]; then
				echo "[-] ERROR: Clone build was requested but no clone APK was generated!"
				rm -rf "$rel_tmp_dir" "$wdir" 2>/dev/null || :
				return 1
			fi
		else
			built_apk=$(find "$wdir/build" "$wdir" "$rel_tmp_dir" -maxdepth 5 -type f -name "*.apk" 2>/dev/null | grep -v "$stock_input" | head -n 1)
		fi
		if [ -n "$built_apk" ] && [ -f "$built_apk" ]; then
			mv "$built_apk" "$patched_apk"
			rm -rf "$rel_tmp_dir" "$wdir" 2>/dev/null || :
			return 0
		else
			rm -f "$patched_apk" 2>/dev/null || :
			rm -rf "$rel_tmp_dir" "$wdir" 2>/dev/null || :
			return 1
		fi
	fi

	local stage_jar="$cli_jar" stage_dir=""
	if [ "${PATCHER_KIND:-}" = morphe ]; then
		local sbase
		sbase=$(basename "$cli_jar")
		stage_dir="${TEMP_DIR}/morphe-stage-$(basename "$patched_apk" .apk)-$$"
		if mkdir -p "$stage_dir" && cp -f "$cli_jar" "${stage_dir}/${sbase}"; then
			stage_jar="${stage_dir}/${sbase}"
		else
			wpr "Could not stage a private morphe JAR copy; using the shared one"
			stage_dir=""
		fi
	fi

	local base_cmd="java -jar '$stage_jar' patch '$stock_input' -t '$tmp_dir' -o '$patched_apk' --keystore=$RVB_KEYSTORE \
--keystore-entry-password=$RVB_KEYSTORE_PASS --keystore-password=$RVB_KEYSTORE_PASS --signer=$RVB_KEY_ALIAS --keystore-entry-alias=$RVB_KEY_ALIAS"

	PATCH_RESULT_FILE=""
	if [ "${PATCHER_KIND:-}" = morphe ]; then
		if mkdir -p "${TEMP_DIR}/patch_results" 2>/dev/null; then
			PATCH_RESULT_FILE="${TEMP_DIR}/patch_results/$(basename "$patched_apk" .apk).json"
			rm -f "$PATCH_RESULT_FILE" 2>/dev/null || :
			base_cmd+=" -r '$PATCH_RESULT_FILE'"
		else
			wpr "Could not create the patch-result directory; falling back to parsing CLI output"
		fi
	fi

	local -a ed_parts=()
	if [ -n "$per_bundle_ed" ]; then
		local IFS='|'
		read -ra ed_parts <<< "$per_bundle_ed"
		unset IFS
	fi

	local p_args_long="" p_args_short=""
	if [ "$PATCHER_BUNDLE_ED_PER_BUNDLE" = true ]; then
		for ((i=0; i<${#p_jars[@]}; i++)); do
			local j="${p_jars[$i]}"
			local ed="${ed_parts[$i]:-}"
			p_args_long+=" --patches '$j'${ed}"
			p_args_short+=" -p '$j'${ed}"
		done
		local cmd_long="${base_cmd}${p_args_long} $patcher_args"
		local cmd_short="${base_cmd}${p_args_short} $patcher_args"
	else
		for j in "${p_jars[@]}"; do
			p_args_long+=" --patches '$j'"
			p_args_short+=" -p '$j'"
		done
		local all_ed="${ed_parts[*]}"
		local cmd_long="${base_cmd}${p_args_long} ${all_ed} $patcher_args"
		local cmd_short="${base_cmd}${p_args_short} ${all_ed} $patcher_args"
	fi

	local cli_name=$(basename "$cli_jar")
	if [ "${cli_name::8}" = revanced ]; then
		cmd_long+=" -b"
		cmd_short+=" -b"
	fi

	if [ "$OS" = Android ]; then
		cmd_long+=" --custom-aapt2-binary='${AAPT2}'"
		cmd_short+=" --custom-aapt2-binary='${AAPT2}'"
	fi

	pr "$cmd_long"
	PATCH_OUTPUT=$(eval "$cmd_long" 2>&1)
	local ret=$?

	if [ $ret -ne 0 ] && echo "$PATCH_OUTPUT" | grep -Eq "Unknown option: '--patches'|Unmatched argument|Missing required argument"; then
		pr "Fallback to short syntax (-p)..."
		rm -rf "$tmp_dir" 2>/dev/null
		pr "$cmd_short"
		PATCH_OUTPUT=$(eval "$cmd_short" 2>&1)
		ret=$?
	fi

	if [ -n "$stage_dir" ]; then rm -rf "$stage_dir"; fi

	echo "$PATCH_OUTPUT"
	if [ $ret -eq 0 ] && [ -f "$patched_apk" ]; then
		return 0
	else
		rm "$patched_apk" 2>/dev/null || :
		return 1
	fi
}

check_sig() {
	local file=$1 pkg_name=$2
	local sig
	if grep -q "$pkg_name" sig.txt; then
		sig=$(java -jar "$APKSIGNER" verify --print-certs "$file" | grep ^Signer | grep SHA-256 | tail -1 | awk '{print $NF}')
		echo "$pkg_name signature: ${sig}"
		grep -qFx "$sig $pkg_name" sig.txt
	fi
}

resolve_slug() {
	local val="${1:-}"
	[ -z "$val" ] && return 0
	local slug
	slug=$(echo "$val" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-+|-+$//g')
	echo "$slug"
}

write_build_info() {
	local key=$1 arch=$2 ext=$3 name=$4 version=$5 patches=$6 changelog=$7
	local pkg_name=${8:-${pkg_name:-}}
	local display_name=${9:-${app_name:-${key}}}
	local patches_source=${10:-${args[patches_src]:-}}
	local brand=${11:-${args[brand]:-}}
	local variant=${12:-${args[variant]:-}}
	local sub_variant=${13:-${args[sub_variant]:-}}
	local arch_token="$arch"
	local arch_orig="${args[arch]// /}"
	if [ "$arch_orig" != "auto" ]; then ext="${arch}${ext}"; arch=""; fi
	local applied_json=""
	if [ -n "${PATCH_RESULT_FILE:-}" ]; then
		applied_json=$(_applied_from_result "$PATCH_RESULT_FILE")
		if [ -n "$applied_json" ] && [ "$applied_json" != "[]" ]; then
			local failed_list
			failed_list=$(_failed_from_result "$PATCH_RESULT_FILE")
			[ -n "$failed_list" ] && wpr "Morphe reported failed patches for '$key': $failed_list"
		elif [ -n "$applied_json" ]; then
			wpr "Morphe result file for '$key' lists no applied patches (schema change?)"
			applied_json=""
		fi
	fi
	if [ -z "$applied_json" ]; then
		applied_json=$(printf '%s\n' "$PATCH_OUTPUT" | grep -oP '(?<=INFO: ")[^"\n]+(?=" succeeded)|(?<=INFO: Applied: ).*|(?<=I: Patch \x27)[^\x27]+(?=\x27 loaded)' | jq -R -s -c 'split("\n") | map(select(length > 0))' 2>/dev/null || true)
	fi
	[[ "$applied_json" != \[* ]] && applied_json='[]'

	if [ "$applied_json" != "[]" ] && [ -n "${args[included_patches]:-}" ]; then
		local inc_name missing_inc=""
		while IFS= read -r inc_name; do
			inc_name="${inc_name#\'}"; inc_name="${inc_name%\'}"
			inc_name="${inc_name#\"}"; inc_name="${inc_name%\"}"
			[ -z "$inc_name" ] && continue
			printf '%s' "$applied_json" | jq -e --arg n "$inc_name" 'index($n) != null' >/dev/null 2>&1 \
				|| missing_inc+=" '$inc_name'"
		done <<<"$(list_args "${args[included_patches]//|/ }")"
		[ -n "$missing_inc" ] && wpr "Requested but not reported as applied for '$key':$missing_inc"
	fi

	if [ "$applied_json" = "[]" ] && [ -n "$PATCH_OUTPUT" ] && [ "${PATCHER_FLOW:-}" = cli-patch ]; then
		wpr "No applied patches parsed from ${PATCHER_KIND:-cli-patch} CLI output for '$key' — catalog may show an empty patch list."
	fi
	local frag_dir="${TEMP_DIR}/build_info" fid
	mkdir -p "$frag_dir"
	fid=$(tr -cs 'a-zA-Z0-9._-' '-' <<<"${key}|${arch}|${ext}")
	fid="${fid%%-}"; fid="${fid##-}"
	jq -n --arg key "$key" \
		--arg ext "$ext" \
		--arg arch "$arch" \
		--arg arch_token "$arch_token" \
		--arg name "$name" \
		--arg version "$version" \
		--arg patches "$patches" \
		--arg changelog "$changelog" \
		--arg pkg_name "$pkg_name" \
		--arg display_name "$display_name" \
		--arg patches_source "$patches_source" \
		--arg brand "$brand" \
		--arg variant "$variant" \
		--arg sub_variant "$sub_variant" \
		--argjson applied "$applied_json" \
		'{ ($key): {
			exts: [$ext],
			name: $name,
			arch: $arch,
			arch_token: $arch_token,
			version: $version,
			patches: $patches,
			changelog: $changelog,
			package_name: $pkg_name,
			display_name: $display_name,
			patches_source: $patches_source,
			brand: $brand,
			variant: $variant,
			sub_variant: $sub_variant,
			applied_patches: $applied
		} }' >"${frag_dir}/${fid}.$$.json"
}

content_hash() {
	local py=""
	if command -v python3 >/dev/null 2>&1; then
		py="python3"
	elif command -v python >/dev/null 2>&1; then
		py="python"
	fi
	[ -n "$py" ] || { printf ''; return 1; }
	"$py" "${CWD}/.github/scripts/content_hash.py" "$1" 2>/dev/null || printf ''
}

_dedup_recorded_hash() {
	local sf="state/build_content_hashes.json"
	[ -f "$sf" ] || return 0
	jq -r --arg chan "$1" --arg key "$2" '(.[$chan][$key] // "")' "$sf" 2>/dev/null || true
}

_dedup_record_hash() {
	[ -n "${RVB_HASH_APPEND:-}" ] || return 0
	printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$RVB_HASH_APPEND" 2>/dev/null || true
}

_dedup_store_hash() {
	local sf="state/build_content_hashes.json" tmp
	mkdir -p "${sf%/*}" 2>/dev/null || return 0
	[ -f "$sf" ] || echo '{}' >"$sf"
	tmp="${sf}.tmp.$$"
	if jq --arg chan "$1" --arg key "$2" --arg hash "$3" \
		'.[$chan][$key] = $hash' "$sf" >"$tmp" 2>/dev/null; then
		mv -f "$tmp" "$sf"
	else
		rm -f "$tmp"
	fi
}

_dedup_write_unchanged() {
	local dir="${RVB_UNCHANGED_DIR:-${TEMP_DIR}/unchanged}" slug
	mkdir -p "$dir" 2>/dev/null || return 0
	slug=$(failure_slug "$1")
	local f="$dir/$slug.json" tmp
	[ -f "$f" ] || echo '{}' >"$f"
	tmp="${f}.tmp.$$"
	if jq --arg type "unchanged" --arg app "$2" --arg version "$3" --arg arch "$4" \
		--arg key "$5" --arg hash "$6" \
		'. + {type:$type, app:$app, version:$version, arch:$arch, key:$key, hash:$hash}' \
		"$f" >"$tmp" 2>/dev/null; then
		mv -f "$tmp" "$f"
	else
		rm -f "$tmp"
	fi
}

check_duplicate_build() {
	[ "${RVB_DEDUP_MODE:-log}" != "off" ] || return 1
	[ -n "${GITHUB_REPOSITORY:-}" ] || return 1
	[ "${PATCHER_HASH_DEDUP_ELIGIBLE:-false}" = true ] || return 1
	local chan="${10:-${args[dup_channel]:-}}" key="$2" hash rec
	case "$chan" in stable | beta) ;; *) return 1 ;; esac
	hash=$(content_hash "$1")
	if [ -z "$hash" ]; then
		wpr "No content hash for '$key' (python3 unavailable or unreadable APK) — publishing."
		return 1
	fi
	rec=$(_dedup_recorded_hash "$chan" "$key")
	if [ -n "$rec" ] && [ "$rec" = "$hash" ]; then
		if [ "${RVB_DEDUP_MODE:-log}" = enforce ]; then
			pr "Unchanged build: '$key' matches published content hash — skipping release."
			_dedup_write_unchanged "$3" "$4" "$5" "$6" "$key" "$hash"
			return 0
		fi
		pr "Dedup [log]: '$key' identical to published hash ${rec} (would skip)."
		return 1
	fi
	if [ "${RVB_DEDUP_MODE:-log}" = enforce ]; then
		_dedup_store_hash "$chan" "$key" "$hash"
	fi
	_dedup_record_hash "$chan" "$key" "$hash"
	return 1
}

merge_build_info() {
	local frag_dir="${TEMP_DIR}/build_info"
	[ -d "$frag_dir" ] || return 0
	local files=()
	mapfile -t files < <(find "$frag_dir" -maxdepth 1 -type f -name '*.json' | sort)
	if [ ${#files[@]} -eq 0 ]; then
		rm -rf "$frag_dir"
		return 0
	fi
	jq -s '
		reduce .[] as $f ({};
			($f | to_entries[0]) as $e |
			(if .[$e.key] == null then .[$e.key] = $e.value
			else
				.[$e.key].exts = ((.[$e.key].exts + $e.value.exts) | unique) |
				reduce (["name","arch","version","patches","changelog","package_name","display_name","patches_source","brand","variant","sub_variant"][]) as $k (.;
					if ((.[$e.key][$k] // "") == "") and (($e.value[$k] // "") != "")
					then .[$e.key][$k] = $e.value[$k] else . end) |
				if ((.[$e.key].applied_patches | length) == 0) and (($e.value.applied_patches | length) > 0)
				then .[$e.key].applied_patches = $e.value.applied_patches else . end
			end)
			| .[$e.key].archVersion = ((.[$e.key].archVersion // {}) + {($e.value.arch_token // "all"): ($e.value.version // "")})
			| .[$e.key].archApplied  = ((.[$e.key].archApplied  // {}) + {($e.value.arch_token // "all"): ($e.value.applied_patches // [])})
		)
	' "${files[@]}" >"${BUILD_JSON_FILE}.merge-tmp" && mv -f "${BUILD_JSON_FILE}.merge-tmp" "$BUILD_JSON_FILE"
	rm -rf "$frag_dir"
}

verify_downloaded_apk() {
	local stock_apk=$1
	local pkg_name=$2
	local dl_p=$3
	local sig_op

	if _bundle_ext_of "$stock_apk" >/dev/null 2>&1; then
		local tmpb="${TEMP_DIR}/verify_base_$$.apk"
		if ! _bundle_extract_base "$stock_apk" "$tmpb"; then
			epr "Cannot extract base.apk from bundle $stock_apk"
			rm -f "$tmpb"
			return 1
		fi
		if ! sig_op=$(check_sig "$tmpb" "$pkg_name" 2>&1); then
			epr "Signature mismatch on base.apk of $stock_apk: $sig_op. Rejecting download from $dl_p..."
			rm -f "$tmpb"
			return 1
		fi
		rm -f "$tmpb"
		return 0
	fi
	
	if [ -f "${stock_apk%.apk}.apkm" ]; then
		rm -rf "${stock_apk}-zip" || :
		unzip -j "${stock_apk%.apk}.apkm" -d "${stock_apk}-zip" >/dev/null
		if [ -f "${stock_apk}-zip/base.apk" ]; then
			if ! sig_op=$(check_sig "${stock_apk}-zip/base.apk" "$pkg_name" 2>&1); then
				epr "Signature mismatch on base.apk: $sig_op. Rejecting download from $dl_p..."
				rm -rf "${stock_apk}-zip" || :
				return 1
			fi
		else
			for a in "${stock_apk}"-zip/*.apk; do
				if ! sig_op=$(check_sig "$a" "$pkg_name" 2>&1); then
					epr "Signature mismatch on $a: $sig_op. Rejecting download from $dl_p..."
					rm -rf "${stock_apk}-zip" || :
					return 1
				fi
				break
			done
		fi
		rm -rf "${stock_apk}-zip" || :
	else
		if ! sig_op=$(check_sig "$stock_apk" "$pkg_name" 2>&1); then
			epr "Signature mismatch on $stock_apk: $sig_op. Rejecting download from $dl_p..."
			return 1
		fi
	fi
	return 0
}

_artifact_abis() {
	local names
	names=$(unzip -l "$1" 2>/dev/null) || return 1
	printf '%s\n' "$names" | awk 'NF >= 4 { p = $4; for (i = 5; i <= NF; i++) p = p " " $i; print p }' | {
		while IFS= read -r n; do
			case "$n" in
				lib/arm64-v8a/*) echo arm64-v8a ;;
				lib/armeabi-v7a/*) echo arm-v7a ;;
				lib/x86_64/*) echo x86_64 ;;
				lib/x86/*) echo x86 ;;
				*config.arm64_v8a.apk) echo arm64-v8a ;;
				*config.armeabi_v7a.apk | *config.armeabi-v7a.apk | *config.armeabi.apk) echo arm-v7a ;;
				*config.x86_64.apk) echo x86_64 ;;
				*config.x86.apk) echo x86 ;;
			esac
		done
	} | LC_ALL=C sort -u | grep . || :
}

check_is_universal() {
	local abis
	abis=$(_artifact_abis "$1") || return 1
	[ -z "$abis" ] && return 0
	printf '%s\n' "$abis" | grep -qx arm64-v8a && printf '%s\n' "$abis" | grep -qx arm-v7a
}

_cache_arch_key() {
	local abis n
	abis=$(_artifact_abis "$1") || { printf '%s' "$2"; return 0; }
	check_is_universal "$1" && { printf 'all'; return 0; }
	n=$(printf '%s\n' "$abis" | grep -c .)
	[ "$n" = 1 ] && { printf '%s' "$abis"; return 0; }
	printf '%s' "$2"
}

_abis_satisfies() {
	local arch=${2:-}; arch=${arch// /}
	case "$arch" in all | universal | auto | "") return 0 ;; esac
	[ -z "${1// /}" ] && return 0
	tr ' \n' '\n\n' <<<"$1" | grep -qxF -- "$arch"
}

_artifact_satisfies_arch() {
	local abis
	abis=$(_artifact_abis "$1" 2>/dev/null) || return 0
	_abis_satisfies "$abis" "${2:-}"
}

_dlurl_sha() { printf '%s' "$1" | sha1sum | cut -d' ' -f1; }

_dlurl_index_lookup() {
	local url=$1 arch=${2:-} key abis="" path=""
	key="${TEMP_DIR}/urlindex/keys/$(_dlurl_sha "$url")"
	[ -f "$key" ] || return 0
	IFS=$'\t' read -r abis path < "$key" 2>/dev/null || true
	if [ -z "$path" ] || [ ! -f "$path" ]; then return 0; fi
	if _abis_satisfies "$abis" "$arch"; then printf '%s' "$path"; else printf 'REJECT'; fi
}

_dlurl_index_record() {
	local url=$1 art=$2
	[ -f "$art" ] || return 0
	local sha ext keysdir="${TEMP_DIR}/urlindex/keys" blobsdir="${TEMP_DIR}/urlindex/blobs"
	sha=$(_dlurl_sha "$url"); ext="${art##*.}"
	mkdir -p "$keysdir" "$blobsdir" 2>/dev/null || return 0
	local blob="$blobsdir/$sha.$ext"
	cp -f "$art" "$blob" 2>/dev/null || return 0
	local abis joined
	abis=$(_artifact_abis "$art" 2>/dev/null) || abis=""
	joined=$(tr '\n' ' ' <<<"$abis" | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')
	printf '%s\t%s\n' "$joined" "$blob" > "$keysdir/$sha.tmp.$$" \
		&& mv -f "$keysdir/$sha.tmp.$$" "$keysdir/$sha"
}

_app_versions_json_ver() {
	local app_versions_file="state/app_versions.json"
	[ -f "$app_versions_file" ] || return 0
	local t_pure="${1% (arm64-v8a)}"
	t_pure="${t_pure% (arm-v7a)}"
	jq -r --arg t "$t_pure" 'to_entries | map(select(.key | startswith("_") | not)) | map(select(.value.keys != null and (.value.keys | index($t)))) | .[0].value.version // empty' "$app_versions_file"
}

_resolve_list_and_version() {
	local cli_jar=$1 patches_jar=$2 pkg_name=$3 table=$4 say_pkg=${5:-false}
	if [ -z "$list_patches" ]; then
		[ "$say_pkg" = true ] && pr "Package name of '${table}' is '$pkg_name'"
		list_patches=$(patches_list "$cli_jar" "$patches_jar" "$pkg_name" "${args[cli_source]}") || return 1
	fi
	if [ "$PATCHER_HAS_PATCH_LIST" = true ]; then
		if ! grep -Fq "$pkg_name" <<<"$list_patches"; then
			epr "No app-specific patches found for '$pkg_name'. Skipping completely."
			return 2
		fi
	fi
	if [ -z "$resolved_version" ]; then
		if [ "$version_mode" = auto ]; then
			if ! resolved_version=$(get_patch_last_supported_ver "$list_patches" "$pkg_name" \
				"${args[included_patches]:-}" "${args[excluded_patches]:-}" "${args[exclusive_patches]:-}" "${args[cli_source]:-}" "$cli_jar" "$patches_jar"); then
				epr "get_patch_last_supported_ver failed for '$pkg_name'"
				return 2
			fi
			if [ -z "$resolved_version" ]; then
				local json_ver
				json_ver=$(_app_versions_json_ver "$table")
				if [ -n "$json_ver" ]; then
					pr "Patches advertise no version for '$pkg_name'; using watcher version '$json_ver'"
					resolved_version="$json_ver"
				fi
			fi
		elif [ "$version_mode" = exp ]; then
			if [ "$PATCHER_EXP_VERSION_UNSUPPORTED" = true ]; then
				wpr "ReVanced CLI does not support experimental versions."
				return 2
			fi
			if ! resolved_version=$(get_patch_exp_ver "$cli_jar" "$patches_jar" "$pkg_name" "${args[cli_source]}"); then
				epr "get_patch_exp_ver failed"
			fi
			if [ -z "$resolved_version" ]; then
				epr "No exp version found for '$pkg_name', skipping."
				return 2
			fi
		elif isoneof "$version_mode" latest beta; then
			:
		else
			resolved_version=$version_mode
		fi
	fi
	return 0
}

build_rv() {
	eval "declare -A args=${1#*=}"
	local version="${args[version]:-}" pkg_name="${args[pkg_name]:-}"
	
	if [ -z "$pkg_name" ]; then
		if [ -n "${args[github_dlurl]}" ] && [[ "${args[github_dlurl]}" == *"releases/tag/"* ]]; then
			local tmp="${args[github_dlurl]%/}"
			pkg_name="${tmp##*/}"
		elif [ -n "${args[archive_dlurl]}" ] && [[ "${args[archive_dlurl]}" == *"apks/"* ]]; then
			local tmp="${args[archive_dlurl]%/}"
			pkg_name="${tmp##*/}"
		fi
	fi
	local cli_jar="${args[cli]}"
	local patches_jar="${args[ptjar]}"
	local mode_arg=${args[build_mode]} version_mode=${args[version]}
	local app_name=${args[app_name]}
	local app_name_l
	app_name_l=$(resolve_slug "$app_name")
	[ -z "$app_name_l" ] && { app_name_l=${app_name,,}; app_name_l=${app_name_l// /-}; }
	local table=${args[table]}
	local dl_from=${args[dl_from]}
	local arch=${args[arch]}
	local arch_f="${arch// /}"
	local arch_list=("$arch_f")
	[ "$arch_f" = "auto" ] && arch_list=("all" "arm64-v8a" "arm-v7a")

	local IFS=$'\n'
	local p_jars_arr=($(echo "${args[ptjar]}" | tr ' ' '\n' | grep -v '^$'))
	unset IFS
	local n_bundles=${#p_jars_arr[@]}
	local -a p_srcs_arr=(${args[patches_sources_all]:-})

	local -a per_bundle_ed_args=()
	local exc_str="${args[excluded_patches]}"
	local inc_str="${args[included_patches]}"

	if [ "${args[inclusive_patches]:-false}" = true ]; then
		local -a incl_exc=()
		if [[ "$exc_str" == *"|"* ]]; then
			IFS='|' read -ra incl_exc <<< "$exc_str"
		else
			incl_exc=("$exc_str")
		fi
		local incl_bi incl_names incl_drop incl_out incl_join="" incl_n
		for ((incl_bi=0; incl_bi<n_bundles; incl_bi++)); do
			if ! incl_names=$(_all_patch_names "$cli_jar" "${p_jars_arr[$incl_bi]}" "$pkg_name" "${args[cli_source]:-}"); then
				abort "ERROR: inclusive-patches for '$table' needs a CLI that lists its patches; '${args[cli_source]:-}' gave none. Use included-patches for this source."
			fi
			incl_drop=$(list_args "${incl_exc[$incl_bi]:-${incl_exc[0]:-}}" | sed -e "s/^'//" -e "s/'\$//" -e 's/^"//' -e 's/"$//')
			incl_out=$(printf '%s\n' "$incl_names" | grep -vxF -f <(printf '%s\n' "$incl_drop") | _group_patch_names)
			incl_out="${incl_out%"${incl_out##*[![:space:]]}"}"
			if [ -z "$incl_out" ]; then
				abort "ERROR: inclusive-patches for '$table' resolved to no patch names from '${p_srcs_arr[$incl_bi]:-}'."
			fi
			incl_n=$(printf '%s\n' "$incl_names" | grep -c .)
			pr "inclusive-patches: '$table' -> $incl_n patches from '${p_srcs_arr[$incl_bi]:-}'"
			[ "$incl_bi" -gt 0 ] && incl_join+=" | "
			incl_join+="$incl_out"
		done
		inc_str="$incl_join"
		args[included_patches]="$incl_join"
	fi

	if [[ "$exc_str" == *"|"* ]] || [[ "$inc_str" == *"|"* ]]; then
		local -a exc_parts=() inc_parts=()
		IFS='|' read -ra exc_parts <<< "$exc_str"
		IFS='|' read -ra inc_parts <<< "$inc_str"
		
		for ((bi=0; bi<n_bundles; bi++)); do
			local bundle_ed=""
			local bp_exc="${exc_parts[$bi]:-}"
			local bp_inc="${inc_parts[$bi]:-}"
			bp_exc=$(echo "$bp_exc" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
			bp_inc=$(echo "$bp_inc" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
			if [ -n "$bp_exc" ]; then bundle_ed+=" $(join_args "$bp_exc" -d)"; fi
			if [ -n "$bp_inc" ]; then bundle_ed+=" $(join_args "$bp_inc" -e)"; fi

			local is_exclusive=false
			if [ "${args[exclusive_patches]}" = "true" ]; then
				is_exclusive=true
			elif [ "${args[exclusive_patches]}" != "false" ] && [ -n "${args[exclusive_patches]}" ]; then
				local current_src="${p_srcs_arr[$bi]:-}"
				local -a exc_srcs=($(list_args "${args[exclusive_patches]}" | tr -d \"\'))
				[ ${#exc_srcs[@]} -eq 0 ] && exc_srcs=("${args[exclusive_patches]}")
				for esrc in "${exc_srcs[@]}"; do
					if [ "$esrc" = "$current_src" ]; then
						is_exclusive=true
						break
					fi
				done
			fi
			if [ "$is_exclusive" = true ]; then
				local all_patches_op
				if all_patches_op=$(patches_list "$cli_jar" "${p_jars_arr[$bi]}" "$pkg_name" "${args[cli_source]}"); then
					local all_patches=()
					mapfile -t all_patches < <(echo "$all_patches_op" | grep -iE '^[[:space:]]*Name:' | sed -E 's/^[[:space:]]*Name:[[:space:]]*//I' | sed 's/[[:space:]]*$//')
					
					local new_bp_exc="$bp_exc"
					local -a current_bp_inc=()
					bp_inc=$(echo "$bp_inc" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
					if [ -n "$bp_inc" ]; then
						while IFS= read -r p; do
							[ -n "$p" ] && current_bp_inc+=("$p")
						done <<< "$(list_args "$bp_inc" | sed -e "s/^'//" -e "s/'$//" -e 's/^"//' -e 's/"$//')"
					fi
					
					for p_name in "${all_patches[@]}"; do
						local found=false
						for inc_p in "${current_bp_inc[@]}"; do
							if [ "$p_name" = "$inc_p" ]; then
								found=true
								break
							fi
						done
						if [ "$found" = false ]; then
							new_bp_exc+=" '$p_name'"
						fi
					done
					bp_exc="$new_bp_exc"
					
					bundle_ed=""
					bp_exc=$(echo "$bp_exc" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
					if [ -n "$bp_exc" ]; then bundle_ed+=" $(join_args "$bp_exc" -d)"; fi
					if [ -n "$bp_inc" ]; then bundle_ed+=" $(join_args "$bp_inc" -e)"; fi
				else
					epr "FATAL: Failed to fetch patch list for exclusive bundle '${p_jars_arr[$bi]}'. Cannot safely apply per-bundle exclusivity."
					return 1
				fi
			fi
			per_bundle_ed_args+=("$bundle_ed")
		done
	else
		local global_ed=""
		if [ -n "$exc_str" ]; then global_ed+=" $(join_args "$exc_str" -d)"; fi
		if [ -n "$inc_str" ]; then global_ed+=" $(join_args "$inc_str" -e)"; fi
		
		for ((bi=0; bi<n_bundles; bi++)); do
			local bundle_ed="$global_ed"
			local is_exclusive=false
			if [ "${args[exclusive_patches]}" = "true" ]; then
				is_exclusive=true
			elif [ "${args[exclusive_patches]}" != "false" ] && [ -n "${args[exclusive_patches]}" ]; then
				local current_src="${p_srcs_arr[$bi]:-}"
				local -a exc_srcs=($(list_args "${args[exclusive_patches]}" | tr -d \"\'))
				[ ${#exc_srcs[@]} -eq 0 ] && exc_srcs=("${args[exclusive_patches]}")
				for esrc in "${exc_srcs[@]}"; do
					if [ "$esrc" = "$current_src" ]; then
						is_exclusive=true
						break
					fi
				done
			fi
			[ "$is_exclusive" = true ] && bundle_ed+=" --exclusive"
			per_bundle_ed_args+=("$bundle_ed")
		done
	fi

	local p_patcher_args=()
	if isoneof "$version_mode" latest beta || [ "$version_mode" != "auto" -a "$version_mode" != "exp" ]; then
		p_patcher_args+=("-f")
	fi

	local tried_dl=()
	local list_patches=""
	local apk_cache_dir="${APK_CACHE_DIR:-${TEMP_DIR}/apks}"
	local apk_dl_dir="${TEMP_DIR}/apks_dl"
	mkdir -p "$apk_cache_dir" "$apk_dl_dir"

	local skip_dl_source_check=false
	local resolved_version=""
	local get_latest_ver=false
	local cli_source_l="${args[cli_source]:-}"
	cli_source_l="${cli_source_l,,}"
	resolve_patcher "${args[cli_source]:-}"
	local cli_lv_extra="$PATCHER_LIST_X"
	local MORPHE_PASSTHROUGH_ACTIVE=false
	local _CACHE_BUNDLE_OK=false
	local morphe_bundle_path=""
	if [ "$PATCHER_KIND" = morphe ] && [ "$RVB_MORPHE_PASSTHROUGH" = true ]; then
		MORPHE_PASSTHROUGH_ACTIVE=true
		_CACHE_BUNDLE_OK=true
	fi

	if [ -n "$pkg_name" ]; then
		list_patches=""
		local _rstatus=0
		_resolve_list_and_version "$cli_jar" "$patches_jar" "$pkg_name" "$table" false || _rstatus=$?
		if [ "$_rstatus" = 1 ]; then return 1; fi
		if [ "$_rstatus" = 2 ]; then return 0; fi
	fi

	local all_resolved_versions=()
	if [ -n "$resolved_version" ]; then
		mapfile -t all_resolved_versions <<<"$resolved_version"
	else
		all_resolved_versions=("")
	fi

	local final_stock_apk=""
	local final_all_apk=""
	local final_version=""
	local _no_patch_versions=""
	local _dl_attempted=""
	
	for curr_resolved_version in "${all_resolved_versions[@]}"; do
		resolved_version="$curr_resolved_version"
		skip_dl_source_check=false
		get_latest_ver=false
		tried_dl=()
		dl_from=""
			if [ -n "$pkg_name" ]; then
				if [ -n "$resolved_version" ]; then
					local version_f=${resolved_version// /}
					version_f=${version_f#v}
					if _cache_all_archs_present "$version_f" validate "$resolved_version"; then
						pr "Found all required architectures for '$pkg_name' (v$version_f) in cache. Skipping download!"
						skip_dl_source_check=true
						version="$resolved_version"
					fi
				else
					local cached_apks=($(find "$apk_cache_dir" -name "${pkg_name}-*.apk" -type f 2>/dev/null || true))
					if [ ${#cached_apks[@]} -gt 0 ]; then
						local cached_versions=""
						for capk in "${cached_apks[@]}"; do
							local bname=$(basename "$capk")
							local v=${bname#${pkg_name}-}
							v=${v%.apk}
							v=${v%-arm64-v8a}
							v=${v%-arm-v7a}
							v=${v%-x86_64}
							v=${v%-x86}
							v=${v%-all}
							v=${v%-universal}
							if [[ "$v" =~ ^(.*)-([0-9]+)$ ]]; then
								v="${BASH_REMATCH[1]}"
							fi
							cached_versions+="$v"$'
'
						done
						local dyn_ver
						if dyn_ver=$(echo "$cached_versions" | get_highest_ver) && [ -n "$dyn_ver" ]; then
							if _cache_all_archs_present "$dyn_ver"; then
								pr "Discovered highest version (v$dyn_ver) for '$pkg_name' in cache. Skipping download!"
								skip_dl_source_check=true
								version="$dyn_ver"
								resolved_version="$dyn_ver"
							fi
						fi
					fi
				fi
			fi

		if [ "$skip_dl_source_check" = false ]; then
		if [ -n "${UPLOAD_APKS_REPO:-}" ] && [ -n "$pkg_name" ]; then
			args[cache_repo_dlurl]="https://github.com/${UPLOAD_APKS_REPO}/releases/tag/${pkg_name}"
		fi
			for dl_p in "${DL_SRCS[@]}"; do
				if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
				
				if [ -z "$resolved_version" ]; then
					if [ "$dl_p" = "archive" ] || [ "$dl_p" = "cache_repo" ]; then
						continue
					fi
				fi

				if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}"; then
					args[${dl_p}_dlurl]=""
					if [ "$dl_p" = "cache_repo" ] && [ "${__CACHE_REPO_MISS__:-false}" = true ]; then
						pr "No cached release for '${pkg_name:-$table}' on ${UPLOAD_APKS_REPO} yet; using the live sources."
					else
						epr "ERROR: Could not get response for ${table} in ${dl_p}"
					fi
					continue
				fi
				
				if [ -z "$pkg_name" ]; then
					if ! pkg_name=$(get_"${dl_p}"_pkg_name) || [ -z "$pkg_name" ]; then
						args[${dl_p}_dlurl]=""
						epr "ERROR: Could not scrape pkg_name for ${table} in ${dl_p}"
						continue
					fi
				fi
				
				tried_dl+=("$dl_p")
				dl_from=$dl_p
				break
			done

			if [ -z "$dl_from" ]; then
				epr "ERROR: No valid download source found for ${table}."
				write_dl_failure_descriptor "$(failure_slug "$table")" "$table" \
					"${resolved_version:-$version_mode}" \
					"$(parse_arch_mapping "${args[version_code]:-}" "${arch_f:-}")" \
					"$arch_f" "$pkg_name"
				return 0
			fi

			if [ -z "$pkg_name" ]; then
				epr "ERROR: Could not determine pkg_name for ${table}."
				return 0
			fi
			
			local _rstatus=0
			_resolve_list_and_version "$cli_jar" "$patches_jar" "$pkg_name" "$table" true || _rstatus=$?
			if [ "$_rstatus" = 1 ]; then return 1; fi
			if [ "$_rstatus" = 2 ]; then return 0; fi
			
			version="$resolved_version"
			[ -z "$version" ] && get_latest_ver=true
			if [ $get_latest_ver = true ]; then
				if [ "$version_mode" = beta ]; then __AAV__="true"; else __AAV__="false"; fi
				local vers_cache_key="${dl_from}_${args[${dl_from}_dlurl]}_${pkg_name:-default}_${__AAV__}"
				if [ -n "${__PKG_VERS_CACHE__["$vers_cache_key"]:-}" ]; then
					pkgvers="${__PKG_VERS_CACHE__["$vers_cache_key"]}"
				else
					pkgvers=$(get_"${dl_from}"_vers)
					__PKG_VERS_CACHE__["$vers_cache_key"]="$pkgvers"
				fi
				version=$(get_highest_ver <<<"$pkgvers") || version=$(head -1 <<<"$pkgvers")
			fi
		else
			pr "Package name of '${table}' is '$pkg_name'"
			pr "Skipping download source check, APKs for version '$version' found in cache."
		fi
		if [ -z "$version" ]; then
			epr "empty version, not building ${table}."
			continue
		fi

		if [ "$mode_arg" = module ]; then
			build_mode_arr=(module)
		elif [ "$mode_arg" = apk ]; then
			build_mode_arr=(apk)
		elif [ "$mode_arg" = both ]; then
			build_mode_arr=(apk module)
		fi

		pr "Choosing version '${version}' for ${table}"
		local version_f=${version// /}
		version_f=${version_f#v}

		if ! has_compatible_patches "$cli_jar" "$patches_jar" "$pkg_name" "$version_f" "${args[cli_source]:-}" "${args[included_patches]:-}"; then
			wpr "No compatible patches found in '${args[patches_src]:-${args[cli_source]:-}}' for '$pkg_name' v${version_f}. Skipping ${table}."
			_no_patch_versions+=" ${version_f}"
			continue
		fi

		local _tbl_vc=""
		if [ "$arch_f" != "all" ] && [ "$arch_f" != "auto" ] && [ "$arch_f" != "universal" ]; then
			if ! _tbl_vc=$(_candidate_arch_verdict "$version_f" "$arch_f" "${all_resolved_versions[*]}"); then
				wpr "Version '${version_f}' of '$pkg_name' declares no '${arch_f}' build in '${args[patches_src]:-${args[cli_source]:-}}'. Skipping ${table}."
				_no_patch_versions+=" ${version_f}"
				continue
			fi
		fi

		write_build_failure_descriptor "$(failure_slug "$table")" "$table" "$version_f" \
			"$(parse_arch_mapping "${args[version_code]:-}" "$arch_f")" \
			"$arch_f" "${args[patches_src]:-${args[cli_source]:-}}"

		for arch in "${arch_list[@]}"; do
			arch_f="${arch// /}"
			local target_version_code
			target_version_code=$(parse_arch_mapping "${args[version_code]:-}" "$arch_f")
			if [ -z "$target_version_code" ] || [ "$target_version_code" = "auto" ]; then
				target_version_code=""
				if [ -n "$version" ] && [ -n "$cli_jar" ] && [ -n "$patches_jar" ]; then
					local raw_vers
					if raw_vers=$(patches_list_versions "$cli_jar" "$patches_jar" "$pkg_name" "${args[cli_source]:-}" "$cli_lv_extra"); then
						target_version_code=$(get_patch_version_code "$raw_vers" "$version" "$arch_f" || true)
					fi
					if [ -z "$target_version_code" ]; then
						target_version_code="${_tbl_vc:-}"
						if [ -z "$target_version_code" ]; then
							target_version_code=$(_patch_arch_verdict "$version_f" "$arch_f" || true)
						fi
					fi
				fi
			fi
			if [ -n "$target_version_code" ]; then
				pr "Target version code for '$pkg_name' (v${version}, arch: ${arch_f}): $target_version_code"
			fi

			local vc_infix="${target_version_code:+-${target_version_code}}"
			local _apk_lock_held=""
			if command -v flock >/dev/null 2>&1; then
				mkdir -p "${TEMP_DIR}/apkslocks"
				exec 203>"${TEMP_DIR}/apkslocks/${pkg_name}-${version_f}${vc_infix}.lock"
				flock -x 203
				_apk_lock_held=1
			fi
			local cached_stock_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.apk"
			local cached_all_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-all.apk"
			local stock_apk="$cached_stock_apk"
			local all_apk="$cached_all_apk"
			local cached_bundle_apk=""
			if [ "$_CACHE_BUNDLE_OK" = true ]; then
				local bx _bp
				for bx in xapk apkm apks; do
					_bp="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.${bx}"
					[ -f "$_bp" ] || _bp="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-all.${bx}"
					if [ -f "$_bp" ]; then cached_bundle_apk="$_bp"; break; fi
				done
			fi
			if [ -n "$cached_bundle_apk" ]; then
				stock_apk="$cached_bundle_apk"
				all_apk="$cached_bundle_apk"
			elif [ -f "$all_apk" ]; then
				stock_apk="$all_apk"
			fi

			local check_apk=""
			[ -f "$stock_apk" ] && check_apk="$stock_apk"
			[ -z "$check_apk" ] && [ -f "$all_apk" ] && check_apk="$all_apk"
			if [ -n "$check_apk" ] && [ -n "$target_version_code" ]; then
				local cached_vc
				cached_vc=$(_meta_field_of "$check_apk" versionCode) || true
				if [ -n "$cached_vc" ] && [ "$cached_vc" != "$target_version_code" ]; then
					pr "Cached APK for '$pkg_name' has versionCode '$cached_vc', but target requires '$target_version_code'. Cache invalidated."
					[ "$check_apk" != "$all_apk" ] && rm -f "$check_apk"
					stock_apk=""
					all_apk=""
				fi
			fi

			if [ ! -f "$stock_apk" ]; then
				stock_apk="${apk_dl_dir}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.apk"
				all_apk="${apk_dl_dir}/${pkg_name}-${version_f}${vc_infix}-all.apk"

				for dl_p in "${DL_SRCS[@]}"; do
					if [ -z "${args[${dl_p}_dlurl]}" ]; then continue; fi
					_dl_attempted=1
					pr "Downloading '${table}' from '${dl_p}'"
					if ! isoneof $dl_p "${tried_dl[@]}"; then
						if ! get_${dl_p}_resp "${args[${dl_p}_dlurl]}"; then
							epr "ERROR: Could not get '${table}' from '${dl_p}'"
							continue
						fi
					fi
					if ! dl_${dl_p} "${args[${dl_p}_dlurl]}" "$version" "$stock_apk" "$arch" "${args[dpi]}" "$get_latest_ver" "$target_version_code"; then
						pr "ERROR: Could not download '${table}' from '${dl_p}' with version '${version}', arch '${arch}', dpi '${args[dpi]}'"
						rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
						continue
					fi
					if ! unzip -l "$stock_apk" >/dev/null 2>&1; then
						epr "ERROR: Downloaded file from ${dl_p} is not a valid zip archive (Cloudflare block or bad file)!"
						rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
						continue
					fi
					if ! unzip -l "$stock_apk" 2>/dev/null | grep -q '^[[:space:]]*[0-9].*AndroidManifest\.xml$'; then
						pr "WARNING: ${stock_apk} does not contain AndroidManifest.xml at root. Attempting to extract as bundle (XAPK/APKS/APKM)..."
						mv "$stock_apk" "${stock_apk}.bundle"
						if [ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" = true ]; then
							mv -f "${stock_apk}.bundle" "${stock_apk%.apk}.xapk"
							stock_apk="${stock_apk%.apk}.xapk"
						else
							if ! merge_splits "${stock_apk}.bundle" "$stock_apk"; then
								epr "ERROR: Failed to extract/merge bundle"
								rm -f "${stock_apk}.bundle" "$stock_apk"
								continue
							fi
							rm -f "${stock_apk}.bundle"
						fi
					fi

					local aapt_cmd="aapt"
					if ! command -v aapt >/dev/null 2>&1; then
						if [ -n "${ANDROID_SDK_ROOT:-}" ]; then
							aapt_cmd=$(ls -1 $ANDROID_SDK_ROOT/build-tools/*/aapt 2>/dev/null | tail -1) || true
						fi
						if [ ! -x "$aapt_cmd" ] && [ -n "${AAPT2:-}" ] && [ -x "$AAPT2" ]; then
							aapt_cmd="$AAPT2"
						fi
					fi
					if [ -n "$aapt_cmd" ] && [ -x "$aapt_cmd" ]; then
						local downloaded_pkg downloaded_ver downloaded_vc
						downloaded_pkg=$(_meta_field_of "$stock_apk" package) || true
						downloaded_ver=$(_meta_field_of "$stock_apk" versionName) || true
						
						if [ -z "$downloaded_pkg" ]; then
							epr "ERROR: Downloaded file is not a valid APK or aapt failed to parse it. Rejecting..."
							rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
							continue
						fi

						if [ "$downloaded_pkg" != "$pkg_name" ] && [[ "$pkg_name" == *.* ]]; then
							epr "ERROR: Downloaded APK package name ($downloaded_pkg) does not match expected ($pkg_name). Rejecting..."
							rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
							continue
						fi

						if [ -n "$target_version_code" ]; then
							downloaded_vc=$(_meta_field_of "$stock_apk" versionCode) || true
							if [ -z "$downloaded_vc" ]; then
								epr "ERROR: Expected version code $target_version_code for '$pkg_name' but aapt read none from the downloaded file (dump badging produced nothing). Rejecting..."
								rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
								continue
							elif [ "$downloaded_vc" != "$target_version_code" ]; then
								epr "ERROR: Downloaded APK version code ($downloaded_vc) does not match expected ($target_version_code). Rejecting..."
								rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
								continue
							fi
						fi

						if [ -n "$downloaded_ver" ] && [[ "$dl_p" == "direct" ]]; then
							if [ "$version" != "$downloaded_ver" ]; then
								pr "Updating version from '${version}' to '${downloaded_ver}' based on APK info"
								version="$downloaded_ver"
								version_f=${version// /}
								version_f=${version_f#v}
								
								local new_stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.apk"
								mv "$stock_apk" "$new_stock_apk"
								stock_apk="$new_stock_apk"
								cached_stock_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-${arch_f}.apk"
								cached_all_apk="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-all.apk"
							fi
						fi
					fi
					local _vapk="$stock_apk"
					if ! verify_downloaded_apk "$_vapk" "$pkg_name" "$dl_p"; then
						rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
						continue
					fi

					local _abi_file="$stock_apk" _abx
					for _abx in xapk apkm apks; do
						[ -f "${stock_apk%.apk}.${_abx}" ] && { _abi_file="${stock_apk%.apk}.${_abx}"; break; }
					done
					if ! _artifact_satisfies_arch "$_abi_file" "$arch"; then
						wpr "Downloaded artifact from '${dl_p}' does not carry '$arch' (found: $(tr '\n' ' ' <<<"$(_artifact_abis "$_abi_file" 2>/dev/null)")); skipping source"
						rm -f "$stock_apk" "${stock_apk%.apk}".* "${stock_apk}".*
						continue
					fi

					break
				done
				local _be
				if [ "${MORPHE_PASSTHROUGH_ACTIVE:-false}" = true ]; then
					if _be=$(_bundle_ext_of "$stock_apk"); then
						morphe_bundle_path="$stock_apk"
					else
						for bx in xapk apkm apks; do
							local candidate=""
							if [ -f "${stock_apk%.apk}.${bx}" ]; then
								candidate="${stock_apk%.apk}.${bx}"
							elif [ -f "${stock_apk}.${bx}" ]; then
								candidate="${stock_apk}.${bx}"
							fi
							if [ -n "$candidate" ]; then
								if unzip -l "$candidate" >/dev/null 2>&1; then
									if [ "$candidate" = "${stock_apk}.${bx}" ]; then
										mv -f "${stock_apk}.${bx}" "${stock_apk%.apk}.${bx}" 2>/dev/null || true
										candidate="${stock_apk%.apk}.${bx}"
									fi
									morphe_bundle_path="$candidate"
									break
								else
									wpr "Corrupt bundle sidecar found and removed: $candidate"
									rm -f "$candidate"
								fi
							fi
						done
					fi
					if [ -n "$morphe_bundle_path" ]; then
						[ "$morphe_bundle_path" != "$stock_apk" ] && rm -f "$stock_apk"
						for _bx in xapk apkm apks; do
							[ -f "${stock_apk%.apk}.${_bx}" ] && [ "${stock_apk%.apk}.${_bx}" != "$morphe_bundle_path" ] && rm -f "${stock_apk%.apk}.${_bx}"
							[ -f "${stock_apk}.${_bx}" ] && [ "${stock_apk}.${_bx}" != "$morphe_bundle_path" ] && rm -f "${stock_apk}.${_bx}"
						done
						stock_apk="$morphe_bundle_path"
						all_apk=""
					fi
				fi
				if [ -f "$stock_apk" ] && [ -z "$morphe_bundle_path" ] && [ ! -f "$all_apk" ] && [[ "$arch" != "all" && "$arch" != "universal" ]]; then
					if check_is_universal "$stock_apk"; then
						mv -f "$stock_apk" "$all_apk"
						if [ -f "${stock_apk%.apk}.apkm" ]; then
							mv -f "${stock_apk%.apk}.apkm" "${all_apk%.apk}.apkm"
						fi
						stock_apk="$all_apk"
					fi
				fi
				
				if [ -f "$stock_apk" ]; then
					local _sync_bext
					if _sync_bext=$(_bundle_ext_of "$stock_apk"); then
						local _bkey cached_bundle
						_bkey=$(_cache_arch_key "$stock_apk" "$arch_f")
						cached_bundle="${apk_cache_dir}/${pkg_name}-${version_f}${vc_infix}-${_bkey}.${_sync_bext}"
						if [ "$_bkey" != all ] && [ "$_bkey" != "$arch_f" ]; then
							wpr "Bundle fetched for '$table' carries '$_bkey' but '$arch' was requested; caching under its own key"
						fi
						cp -f "$stock_apk" "$cached_bundle"
						stock_apk="$cached_bundle"
						all_apk="$cached_bundle"
					elif [ "$stock_apk" = "$all_apk" ]; then
						cp -f "$all_apk" "$cached_all_apk"
						stock_apk="$cached_all_apk"
						all_apk="$cached_all_apk"
					else
						cp -f "$stock_apk" "$cached_stock_apk"
						stock_apk="$cached_stock_apk"
						all_apk=""
					fi
				fi

				if [ -f "$stock_apk" ] && [ -n "${UPLOAD_APKS_REPO:-}" ] && [ "$dl_p" != "archive" ] && [ "$dl_p" != "cache_repo" ]; then
					pr "Uploading newly downloaded APKs to ${UPLOAD_APKS_REPO}..."
					local _ua_file="$stock_apk" _ua_ok="" _ua_att
					[ -n "$all_apk" ] && [ -f "$all_apk" ] && _ua_file="$all_apk"
					for _ua_att in 1 2 3; do
						if { gh release view "$pkg_name" --repo "$UPLOAD_APKS_REPO" >/dev/null 2>&1 || \
							gh release create "$pkg_name" --repo "$UPLOAD_APKS_REPO" --title "$pkg_name" --notes ""; } && \
							gh release upload "$pkg_name" "$_ua_file" --repo "$UPLOAD_APKS_REPO" --clobber; then
							_ua_ok=1
							break
						fi
						[ "$_ua_att" -lt 3 ] && { wpr "Cache upload for $pkg_name failed (attempt $_ua_att/3), retrying..."; sleep $((_ua_att * 3)); }
					done
					[ -n "$_ua_ok" ] || wpr "Failed to view/create/upload release $pkg_name on $UPLOAD_APKS_REPO after 3 attempts"
				fi
			else
				pr "Found APK in cache: ${stock_apk}. Skipping download!"
			fi
			if [ -n "$_apk_lock_held" ]; then exec 203>&-; fi
			if [ -f "$stock_apk" ]; then break; fi
		done
		if [ ! -f "$stock_apk" ]; then
			epr "ERROR: Could not download '${table}' for version $resolved_version"
			continue
		fi

		if [ -f "$stock_apk" ]; then
			final_stock_apk="$stock_apk"
			final_all_apk="${all_apk:-}"
			final_version="$version"
			break
		fi
	done

	stock_apk="$final_stock_apk"
	all_apk="$final_all_apk"
	version="$final_version"
	
	if [ ! -f "$stock_apk" ]; then
		if [ -z "$_dl_attempted" ] && [ -n "$_no_patch_versions" ]; then
			local _tried_versions
			_tried_versions=$(printf '%s' "${_no_patch_versions# }" | tr -s ' ' ',')
			epr "ERROR: No supported version of '${table}' has patches to apply from '${args[patches_src]:-${args[cli_source]:-}}' (tried: ${_tried_versions})."
			write_no_patches_failure_descriptor "$(failure_slug "$table")" "$table" \
				"$_tried_versions" \
				"${resolved_version:-$version_mode}" "$(parse_arch_mapping "${args[version_code]:-}" "${arch_f:-}")" \
				"${arch_f:-}" "${args[patches_src]:-${args[cli_source]:-}}" "$pkg_name"
			return 0
		fi
		epr "ERROR: Could not download '${table}' after trying all supported versions."
		write_dl_failure_descriptor "$(failure_slug "$table")" "$table" \
			"${resolved_version:-$version_mode}" \
			"$(parse_arch_mapping "${args[version_code]:-}" "${arch_f:-}")" \
			"${arch_f:-}" "$pkg_name"
		return 0
	fi

	touch "$stock_apk" 2>/dev/null || true
	[ -f "${stock_apk%.apk}.apkm" ] && touch "${stock_apk%.apk}.apkm" 2>/dev/null || true
	[ -n "${all_apk:-}" ] && [ -f "$all_apk" ] && touch "$all_apk" 2>/dev/null || true

	echo "${pkg_name}-${version_f}" >> "$TEMP_DIR/used_versions.txt"

	local sig_op
	if _bundle_ext_of "$stock_apk" >/dev/null 2>&1; then
		local tmpb="${TEMP_DIR}/stockcheck_base_$$.apk"
		if ! _bundle_extract_base "$stock_apk" "$tmpb"; then
			epr "Cannot extract base.apk from bundle $stock_apk"
			rm -f "$tmpb"
			return 0
		fi
		if ! sig_op=$(check_sig "$tmpb" "$pkg_name" 2>&1); then
			epr "Not building $table, apk signature mismatch 'base.apk' in $stock_apk: $sig_op"
			rm -f "$tmpb"
			return 0
		fi
		rm -f "$tmpb"
	elif [ -f "${stock_apk%.apk}.apkm" ]; then
		rm -rf "${stock_apk}-zip" || :
		unzip -j "${stock_apk%.apk}.apkm" -d "${stock_apk}-zip" >/dev/null
		if [ -f "${stock_apk}-zip/base.apk" ]; then
			if ! sig_op=$(check_sig "${stock_apk}-zip/base.apk" "$pkg_name" 2>&1); then
				epr "Not building $table, apk signature mismatch 'base.apk': $sig_op"
				return 0
			fi
		else
			for a in "${stock_apk}"-zip/*.apk; do
				if ! sig_op=$(check_sig "$a" "$pkg_name" 2>&1); then
					epr "Not building $table, apk signature mismatch '$a': $sig_op"
					return 0
				fi
				break
			done
		fi
		rm -rf "${stock_apk}-zip" || :
	else
		if ! sig_op=$(check_sig "$stock_apk" "$pkg_name" 2>&1); then
			epr "Not building $table, apk signature mismatch '$stock_apk': $sig_op"
			return 0
		fi
	fi

	local microg_patches=()
	local microg_default_enabled=()
	while IFS=$'\t' read -r p_name p_enabled; do
		[ -z "$p_name" ] && continue
		microg_patches+=("$p_name")
		microg_default_enabled+=("$p_enabled")
	done < <(awk '
		BEGIN { RS=""; FS="\n" }
		{
			pname = ""
			enabled = ""
			for (i=1; i<=NF; i++) {
				if ($i ~ /^Name: /) {
					pname = substr($i, 7)
					gsub(/\r/, "", pname)
				}
				if ($i ~ /^Enabled: /) {
					enabled = substr($i, 10)
					gsub(/\r/, "", enabled)
				}
			}
			if (tolower(pname) ~ /gmscore|microg/) {
				print pname "\t" (enabled == "true" ? "true" : "false")
			}
		}
	' <<<"$list_patches")

	local patcher_args patched_apk build_mode
	local brand_val="${args[brand]:-}"
	local brand_slug=""
	[ -n "$brand_val" ] && brand_slug=$(resolve_slug "$brand_val")

	local variant_val="${args[variant]:-}"
	local variant_slug=""
	[ -n "$variant_val" ] && variant_slug=$(resolve_slug "$variant_val")

	local sub_variant_val="${args[sub_variant]:-}"
	local sub_variant_slug=""
	[ -n "$sub_variant_val" ] && sub_variant_slug=$(resolve_slug "$sub_variant_val")

	local file_prefix="${app_name_l}"
	[ -n "$brand_slug" ] && file_prefix+="-${brand_slug}"
	[ -n "$variant_slug" ] && [ "$variant_slug" != "default" ] && file_prefix+="-${variant_slug}"
	[ -n "$sub_variant_slug" ] && file_prefix+="-${sub_variant_slug}"

	local patches_ref="${args[patches_ref]}"
	local changelog_url="${args[changelog_url]}"
	if [ "${args[patcher_args]}" ]; then p_patcher_args+=("${args[patcher_args]}"); fi
	for build_mode in "${build_mode_arr[@]}"; do
		patcher_args=("${p_patcher_args[@]}")
		local -a cur_per_bundle_ed_args=("${per_bundle_ed_args[@]}")
		pr "Building '${table}' in '$build_mode' mode"
		if [ ${#microg_patches[@]} -gt 0 ] || [ ${#build_mode_arr[@]} -gt 1 ]; then
			patched_apk="${TEMP_DIR}/${file_prefix}-${version_f}-${arch_f}-${build_mode}.apk"
		else
			patched_apk="${TEMP_DIR}/${file_prefix}-${version_f}-${arch_f}.apk"
		fi
		if [ ${#microg_patches[@]} -gt 0 ]; then
			for idx in "${!microg_patches[@]}"; do
				local p="${microg_patches[$idx]}"
				local is_def_enabled="${microg_default_enabled[$idx]}"
				if [ "$build_mode" = apk ]; then
					if [ "$is_def_enabled" = "true" ]; then
						for ((bi=0; bi<n_bundles; bi++)); do
							if [[ "${cur_per_bundle_ed_args[$bi]}" != *"-d \"$p\""* && \
							      "${cur_per_bundle_ed_args[$bi]}" != *"-d '$p'"* && \
							      "${cur_per_bundle_ed_args[$bi]}" != *"-d $p"* && \
							      "${cur_per_bundle_ed_args[$bi]}" != *"-e \"$p\""* && \
							      "${cur_per_bundle_ed_args[$bi]}" != *"-e '$p'"* && \
							      "${cur_per_bundle_ed_args[$bi]}" != *"-e $p"* ]]; then
								cur_per_bundle_ed_args[$bi]+=" -e \"$p\""
							fi
						done
					fi
				elif [ "$build_mode" = module ]; then
					patcher_args=("${patcher_args[@]//-[ei] \'$p\'/}")
					patcher_args=("${patcher_args[@]//-[ei] \"$p\"/}")
					patcher_args=("${patcher_args[@]//-[ei] $p/}")
					for ((bi=0; bi<n_bundles; bi++)); do
						cur_per_bundle_ed_args[$bi]="${cur_per_bundle_ed_args[$bi]//-e \'$p\'/}"
						cur_per_bundle_ed_args[$bi]="${cur_per_bundle_ed_args[$bi]//-e \"$p\"/}"
						cur_per_bundle_ed_args[$bi]="${cur_per_bundle_ed_args[$bi]//-e $p/}"
						if [[ "${cur_per_bundle_ed_args[$bi]}" != *"-d \"$p\""* && \
						      "${cur_per_bundle_ed_args[$bi]}" != *"-d '$p'"* && \
						      "${cur_per_bundle_ed_args[$bi]}" != *"-d $p"* ]]; then
							cur_per_bundle_ed_args[$bi]+=" -d \"$p\""
						fi
					done
				fi
			done
		fi
		if [ "$build_mode" = module ] && [ -n "$PATCHER_MOUNT_ARG" ]; then
			patcher_args+=("$PATCHER_MOUNT_ARG")
		fi

		local stock_apk_to_patch
		local _pt_bext=""
		if [ -n "$morphe_bundle_path" ] || _pt_bext=$(_bundle_ext_of "$stock_apk"); then
			[ -z "$_pt_bext" ] && _pt_bext=xapk
			stock_apk_to_patch="${TEMP_DIR}/${file_prefix}-${version_f}-${arch_f}.stripped.${_pt_bext}"
			if [ ! -f "$stock_apk_to_patch" ]; then
				if [ "$arch_f" = "all" ] || [ "$arch_f" = "universal" ]; then
					cp -f "$stock_apk" "$stock_apk_to_patch"
				else
					_trim_bundle_for_arch "$stock_apk" "$stock_apk_to_patch" "$arch_f" || {
						epr "Failed to trim bundle for $arch_f"
						rm -f "$stock_apk_to_patch"
						return 0
					}
				fi
			fi
		else
		stock_apk_to_patch="${TEMP_DIR}/${file_prefix}-${version_f}-${arch_f}.stripped.apk"
		if [ ! -f "$stock_apk_to_patch" ]; then
			cp -f "$stock_apk" "$stock_apk_to_patch"
			if [ "$arch" = "arm64-v8a" ]; then
				zip -d "$stock_apk_to_patch" "lib/armeabi-v7a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "arm-v7a" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "x86" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/armeabi-v7a/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "x86_64" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/armeabi-v7a/*" "lib/x86/*" >/dev/null 2>&1 || :
			else
				zip -d "$stock_apk_to_patch" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			fi
		fi
		fi

		local per_bundle_ed_joined=""
		for ((bi=0; bi<n_bundles; bi++)); do
			[ $bi -gt 0 ] && per_bundle_ed_joined+="|"
			per_bundle_ed_joined+="${cur_per_bundle_ed_args[$bi]}"
		done

		local apk_output="${BUILD_DIR}/${file_prefix}-v${version_f}-${arch_f}.apk"
		if [ "${NORB:-}" != true ] || { [ ! -f "$patched_apk" ] && [ ! -f "$apk_output" ]; }; then
			if ! patch_apk "$stock_apk_to_patch" "$patched_apk" "${patcher_args[*]}" "${args[cli]}" "${args[ptjar]}" "${args[cli_source]}" "$per_bundle_ed_joined"; then
				epr "Building '${table}' failed!"
				return 0
			fi
		fi

		if [ "$build_mode" = apk ] || [ ${#build_mode_arr[@]} -eq 1 ]; then
			local _dedup_apk="$patched_apk"
			[ -f "$_dedup_apk" ] || _dedup_apk="$apk_output"
			if [ -f "$_dedup_apk" ] &&
				check_duplicate_build "$_dedup_apk" "${file_prefix}-v${version_f}-${arch_f}" \
					"$table" "$app_name" "$version_f" "$arch_f"; then
				return 0
			fi
		fi

		local final_pkg_name="${args[patched_pkg_name]:-}"
		if [ -z "$final_pkg_name" ]; then
			local target_apk_to_check=""
			[ -f "$patched_apk" ] && target_apk_to_check="$patched_apk"
			[ -z "$target_apk_to_check" ] && [ -f "$apk_output" ] && target_apk_to_check="$apk_output"

			if [ -n "$target_apk_to_check" ]; then
				local aapt_tool=""
				if [ -n "${AAPT2:-}" ] && { [ -x "$AAPT2" ] || command -v "$AAPT2" >/dev/null 2>&1; }; then
					aapt_tool="$AAPT2"
				elif command -v aapt2 >/dev/null 2>&1; then
					aapt_tool="aapt2"
				elif command -v aapt >/dev/null 2>&1; then
					aapt_tool="aapt"
				fi

				if [ -n "$aapt_tool" ]; then
					local detected_pkg=""
					if [[ "$aapt_tool" == *"aapt2"* ]]; then
						detected_pkg=$("$aapt_tool" dump packagename "$target_apk_to_check" 2>/dev/null | tr -d '\r\n' || true)
					fi
					[ -z "$detected_pkg" ] && detected_pkg=$("$aapt_tool" dump badging "$target_apk_to_check" 2>/dev/null | grep -oP "package: name='\K[^']+" | head -1 || true)
					if [ -n "$detected_pkg" ]; then
						if [ "$detected_pkg" != "$pkg_name" ]; then
							pr "Detected modified package ID in manifest: '$pkg_name' -> '$detected_pkg'"
						fi
						final_pkg_name="$detected_pkg"
					fi
				fi
			fi
		fi
		final_pkg_name="${final_pkg_name:-$pkg_name}"

		if [ "$build_mode" = apk ]; then
			if [ "${NORB:-}" != true ] || { [ ! -f "$patched_apk" ] && [ ! -f "$apk_output" ]; }; then
				mv -f "$patched_apk" "$apk_output"
			else
				cp -f "$patched_apk" "$apk_output"
			fi
			pr "Built ${table} (non-root): '${apk_output}'"
			write_build_info "${table% (*}" "${arch_f}" ".apk" "${file_prefix}" "$version_f" "$patches_ref" "$changelog_url" "$final_pkg_name" "${app_name}" "${args[patches_src]}" "${brand_val}" "${variant_val}" "${sub_variant_val}"
			continue
		fi
		local base_template
		base_template=$(mktemp -d -p "$TEMP_DIR")
		cp -a $MODULE_TEMPLATE_DIR/. "$base_template"
		local upj
		upj=$(update_json_path "${args[module_prop_name]}" "${DEF_AUTHOR_NAME:-nullcpy}")

		module_config "$base_template" "$final_pkg_name" "$version_f" "$arch"

		local patches_ver
		patches_ver="${patches_jar%% *}"; patches_ver="${patches_ver##*-}"
		local brand_display="${args[brand]:-}"
		[ -n "${args[variant]:-}" ] && [ "${args[variant]}" != "Default" ] && brand_display+=" ${args[variant]}"
		[ -n "${args[sub_variant]:-}" ] && brand_display+=" ${args[sub_variant]}"
		brand_display="${brand_display#" "}"
		module_prop \
			"${args[module_prop_name]}" \
			"${app_name} ${brand_display}" \
			"${version_f} (patches ${patches_ver})" \
			"${DEF_AUTHOR_NAME:-nullcpy}" \
			"${app_name} ${brand_display} module" \
			"https://raw.githubusercontent.com/${GITHUB_REPOSITORY-}/update/${upj}" \
			"$base_template"

		local module_output="${file_prefix}-module-v${version_f}-${arch_f}.zip"
		pr "Packing module ${table}"
		cp -f "$patched_apk" "${base_template}/base.apk"

		if [ "${args[include_stock]}" != "disable" ]; then
			mkdir -p "${base_template}/stock/"
			local _stk_bext=""
			_bundle_ext_of "$stock_apk" >/dev/null 2>&1 && _stk_bext=1
			if [ "${args[include_stock]}" = "merged" ]; then
				if [ -n "$_stk_bext" ]; then
					local _mod_stock="${TEMP_DIR}/${file_prefix}-${version_f}-stock-merged.apk"
					merge_splits "$stock_apk" "$_mod_stock" >/dev/null 2>&1 || {
						epr "Failed to merge bundle for module stock"
						return 0
					}
					cp -f "$_mod_stock" "${base_template}/stock/base.apk"
					rm -f "$_mod_stock"
				else
					cp -f "$stock_apk" "${base_template}/stock/base.apk"
				fi
			elif [ "${args[include_stock]}" = "split" ]; then
				local _split_src=""
				if [ -n "$_stk_bext" ]; then _split_src="$stock_apk"
				elif [ -f "${stock_apk%.apk}.apkm" ]; then _split_src="${stock_apk%.apk}.apkm"
				elif [ -f "${stock_apk}.apkm" ]; then _split_src="${stock_apk}.apkm"
				fi
				if [ -z "$_split_src" ]; then
					epr "Cannot include as 'split' because stock apk of $table_name is not a bundle"
					return 0
				fi
				if [ "$arch" = "arm64-v8a" ]; then
					unzip -j "$_split_src" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -x '*armeabi_v7a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				elif [ "$arch" = "arm-v7a" ]; then
					unzip -j "$_split_src" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -x '*arm64_v8a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				elif [ "$arch" = "x86" ]; then
					unzip -j "$_split_src" '*.apk' -x '*x86_64.apk' -x '*arm64_v8a.apk' -x '*armeabi_v7a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				elif [ "$arch" = "x86_64" ]; then
					unzip -j "$_split_src" '*.apk' -x '*x86.apk' -x '*arm64_v8a.apk' -x '*armeabi_v7a.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				else
					unzip -j "$_split_src" '*.apk' -x '*x86_64.apk' -x '*x86.apk' -d "${base_template}/stock/" >/dev/null 2>&1
				fi
			fi
		fi

		pushd >/dev/null "$base_template" || abort "Module template dir not found"
		zip -"$COMPRESSION_LEVEL" -FSqr "${CWD}/${BUILD_DIR}/${module_output}" .
		popd >/dev/null || :
		pr "Built ${table} (root): '${BUILD_DIR}/${module_output}'"
		write_build_info "${table% (*}" "${arch_f}" ".zip" "${file_prefix}" "$version_f" "$patches_ref" "$changelog_url" "$final_pkg_name" "${app_name}" "${args[patches_src]}" "${brand_val}" "${variant_val}" "${sub_variant_val}"
	done
}

list_args() { tr -d '\t\r' <<<"$1" | tr -s ' ' | sed "s/' '/'\\n'/g" | sed 's/" "/"\n"/g' | sed 's/\([^"]\)"\([^"]\)/\1'\''\2/g' | grep -v '^$' || :; }

_ed_names() {
	local IFS=$' \t\n' w
	eval "set -- $1" || return 1
	for w in "$@"; do
		case "$w" in -e | -d) continue ;; esac
		printf '%s\n' "$w"
	done
}

join_args() {
	local n
	list_args "$1" | while IFS= read -r n; do
		n=${n#\'}; n=${n%\'}; n=${n#\"}; n=${n%\"}
		[ -z "$n" ] && continue
		printf "%s '%s'\n" "$2" "$(printf '%s' "$n" | sed "s/'/'\\\\''/g")"
	done | paste -sd " " - || :
}

module_config() {
	local ma=""
	if [ "$4" = "arm64-v8a" ]; then
		ma="arm64"
	elif [ "$4" = "arm-v7a" ]; then
		ma="arm"
	fi
	echo "PKG_NAME=$2
PKG_VER=$3
MODULE_ARCH=$ma" >"$1/config"
}

update_json_path() {
	local mpn=${1,,} author=${2,,} chan=stable arch=""
	case $mpn in
		*-arm64) arch="-arm64"; mpn=${mpn%-arm64} ;;
		*-arm) arch="-arm"; mpn=${mpn%-arm} ;;
	esac
	if [[ $mpn == *-beta ]]; then
		chan="beta"
		mpn=${mpn%-beta}
	fi
	[ -n "$author" ] && mpn=${mpn%-$author}
	echo "$chan/${mpn}${arch}.json"
}

module_prop() {
	echo "id=${1}
name=${2}
version=v${3}
versionCode=${NEXT_VER_CODE}
author=${4}
description=${5}" >"${7}/module.prop"

	if [ "$ENABLE_MODULE_UPDATE" = true ]; then echo "updateJson=${6}" >>"${7}/module.prop"; fi
}
