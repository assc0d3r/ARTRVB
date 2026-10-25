#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob

# Engine is run with repo root as CWD (workflows, CI scripts) but lives beside
# utils.sh under scripts/; source the sibling explicitly. The path is also
# handed to pooled children (parallel-jobs) through RVB_UTILS_SH.
RVB_UTILS_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/utils.sh"
source "$RVB_UTILS_SH"
echo '{}' > "$BUILD_JSON_FILE"

trap "abort" INT

if [ "${1-}" = "clean" ]; then
	rm -r "$TEMP_DIR" "$BUILD_DIR" build.md
	exit 0
fi

jq --version >/dev/null || abort "\`jq\` is not installed. install it with 'apt install jq' or equivalent"
java --version >/dev/null || abort "\`java\` is not installed. install it with 'apt install openjdk-21-jre' or equivalent"
zip --version >/dev/null || abort "\`zip\` is not installed. install it with 'apt install zip' or equivalent"
require_signing_identity || abort "cannot build without a signing identity (see 'Signing and identity' in docs/build-engine.md)"

set_prebuilts

vtf() { if ! isoneof "${1}" "true" "false"; then abort "ERROR: '${1}' is not a valid option for '${2}': only true or false is allowed"; fi; }

# -- Main config --
toml_prep "${1:-config.toml}" || abort "could not find config file '${1:-config.toml}'\n\tUsage: $0 <config.toml>"
main_config_t=$(toml_get_table_main)
COMPRESSION_LEVEL=$(toml_get "$main_config_t" compression-level) || COMPRESSION_LEVEL="9"

RVB_DEDUP_MODE="${RVB_DEDUP_MODE:-log}"
if ! isoneof "$RVB_DEDUP_MODE" off log enforce; then
	abort "ERROR: RVB_DEDUP_MODE '$RVB_DEDUP_MODE' is not a valid option: only 'off', 'log' or 'enforce' are allowed"
fi
pr "RVB_DEDUP_MODE: $RVB_DEDUP_MODE"
REMOVE_RV_INTEGRATIONS_CHECKS=$(toml_get "$main_config_t" remove-rv-integrations-checks) || REMOVE_RV_INTEGRATIONS_CHECKS="false"
DEF_PATCHES_VER=$(toml_get "$main_config_t" patches-version) || DEF_PATCHES_VER="stable"

[ "$DEF_PATCHES_VER" = "both" ] && { if [[ "${1:-}" == *"beta"* ]]; then DEF_PATCHES_VER="beta"; else DEF_PATCHES_VER="stable"; fi; }
DEF_CLI_VER=$(toml_get "$main_config_t" cli-version) || DEF_CLI_VER="stable"
DEF_PATCHES_SRC=$(toml_get "$main_config_t" patches-source) || DEF_PATCHES_SRC="MorpheApp/morphe-patches"
DEF_PATCHES_SRC_HOST=$(toml_get "$main_config_t" patches-source-host) || DEF_PATCHES_SRC_HOST="github"
DEF_CLI_SRC=$(toml_get "$main_config_t" cli-source) || DEF_CLI_SRC="MorpheApp/morphe-desktop"
DEF_CLI_SRC_HOST=$(toml_get "$main_config_t" cli-source-host) || DEF_CLI_SRC_HOST="github"
DEF_BRAND=$(toml_get "$main_config_t" brand) || DEF_BRAND=""
DEF_VARIANT=$(toml_get "$main_config_t" variant) || DEF_VARIANT=""
DEF_SUB_VARIANT=$(toml_get "$main_config_t" sub-variant) || DEF_SUB_VARIANT=""
DEF_DPI=$(toml_get "$main_config_t" dpi) || DEF_DPI="nodpi anydpi auto"
DEF_ARCH=$(toml_get "$main_config_t" arch) || DEF_ARCH="both"
DEF_BUILD_MODE=$(toml_get "$main_config_t" build-mode) || DEF_BUILD_MODE="apk"
DEF_AUTHOR_NAME=$(toml_get "$main_config_t" author) || DEF_AUTHOR_NAME="nullcpy"
DEF_AUTHOR_PAGE=$(toml_get "$main_config_t" author-page) || DEF_AUTHOR_PAGE="github.com/nullcpy/rvb"

PAR_JOBS="${PARALLEL_JOBS:-1}"
[[ "$PAR_JOBS" =~ ^[0-9]+$ ]] || { epr "PARALLEL_JOBS '$PAR_JOBS' is not a number; falling back to 1"; PAR_JOBS=1; }
((PAR_JOBS < 1)) && PAR_JOBS=1
((PAR_JOBS > 8)) && { wpr "capping parallel-jobs at 8 (runner is 4-core/16GB)"; PAR_JOBS=8; }
pr "PARALLEL_JOBS: $PAR_JOBS"
mkdir -p "$TEMP_DIR" "$BUILD_DIR"

FAILURES_DIR="$TEMP_DIR/failures"
rm -rf "$FAILURES_DIR"
mkdir -p "$FAILURES_DIR"

UNCHANGED_DIR="$TEMP_DIR/unchanged"
rm -rf "$UNCHANGED_DIR"
mkdir -p "$UNCHANGED_DIR"
RVB_UNCHANGED_DIR="$UNCHANGED_DIR"

rm -rf "$TEMP_DIR/hashes"
mkdir -p "$TEMP_DIR/hashes"
RVB_HASH_APPEND="$TEMP_DIR/hashes/append.$$.tsv"
export RVB_DEDUP_MODE RVB_UNCHANGED_DIR RVB_HASH_APPEND

_attach_failure_log() {
	local slug; slug=$(failure_slug "$1")
	[ -f "$FAILURES_DIR/$slug.json" ] || return 0
	cp "$2" "$FAILURES_DIR/$slug.log" 2>/dev/null || true
}

_clear_failure_record() {
	local slug; slug=$(failure_slug "$1")
	rm -f "$FAILURES_DIR/$slug.json" "$FAILURES_DIR/$slug.log" 2>/dev/null || true
}

: >build.md
ENABLE_MODULE_UPDATE=$(toml_get "$main_config_t" enable-module-update) || ENABLE_MODULE_UPDATE=true
if [ "$ENABLE_MODULE_UPDATE" = true ] && [ -z "${GITHUB_REPOSITORY-}" ]; then
	pr "You are building locally. Module updates will not be enabled."
	ENABLE_MODULE_UPDATE=false
fi
if ((COMPRESSION_LEVEL > 9)) || ((COMPRESSION_LEVEL < 0)); then abort "compression-level must be within 0-9"; fi

rm -rf module/bin/*/tmp.*
for file in "$TEMP_DIR"/*/changelog.md; do
	[ -f "$file" ] && : >"$file"
done

mkdir -p ${MODULE_TEMPLATE_DIR}/bin/arm64 ${MODULE_TEMPLATE_DIR}/bin/arm ${MODULE_TEMPLATE_DIR}/bin/x86 ${MODULE_TEMPLATE_DIR}/bin/x64
echo "${DEF_AUTHOR_NAME}${DEF_AUTHOR_PAGE:+ ($DEF_AUTHOR_PAGE)}" > "${MODULE_TEMPLATE_DIR}/maintainer.txt"

QUEUE_DIR="$TEMP_DIR/queue"
declare -gA JOB_PID=() JOB_LABEL=() JOB_LOG=() JOB_RC=()
JOB_SEQ=0

if ((PAR_JOBS > 1)); then
	mkdir -p "$QUEUE_DIR"
	export RVB_UTILS_SH COMPRESSION_LEVEL ENABLE_MODULE_UPDATE DEF_AUTHOR_NAME REMOVE_RV_INTEGRATIONS_CHECKS

	_reap_done() {
		local id rc
		for id in "${!JOB_PID[@]}"; do
			if [ ! -f "${JOB_RC[$id]}" ]; then
				kill -0 "${JOB_PID[$id]}" 2>/dev/null && continue
				echo 137 >"${JOB_RC[$id]}"
			fi
			rc=$(cat "${JOB_RC[$id]}" 2>/dev/null) || rc=1
			if [ -n "${GITHUB_REPOSITORY:-}" ]; then echo "::group::Building ${JOB_LABEL[$id]}"; fi
			cat "${JOB_LOG[$id]}" 2>/dev/null
			if [ -n "${GITHUB_REPOSITORY:-}" ]; then echo "::endgroup::"; fi
			if [ "$rc" = 0 ]; then
				_clear_failure_record "${JOB_LABEL[$id]}"
			else
				epr "Build failed for ${JOB_LABEL[$id]} (exit$rc)"
				_attach_failure_log "${JOB_LABEL[$id]}" "${JOB_LOG[$id]}"
			fi
			rm -f "${JOB_LOG[$id]}" "${JOB_RC[$id]}"
			unset "JOB_PID[$id]" "JOB_LABEL[$id]" "JOB_LOG[$id]" "JOB_RC[$id]"
		done
		return 0
	}
	_wait_slot() {
		while ((${#JOB_PID[@]} >= PAR_JOBS)); do
			_reap_done
			((${#JOB_PID[@]} < PAR_JOBS)) && break
			wait -n >/dev/null 2>&1 || true
			sleep 1
		done
		return 0
	}
	_enqueue_build() {
		_wait_slot
		local id=$((JOB_SEQ + 1))
		JOB_SEQ=$id
		(
			set +e
			RVB_CHILD=1 bash -c 'set -euo pipefail; shopt -s nullglob; source "$RVB_UTILS_SH"; set_prebuilts; build_rv "$1"' _ "$1" \
				>"$QUEUE_DIR/$id.log" 2>&1
			echo $? >"$QUEUE_DIR/$id.rc"
		) &
		JOB_PID[$id]=$!
		JOB_LABEL[$id]="$2"
		JOB_LOG[$id]="$QUEUE_DIR/$id.log"
		JOB_RC[$id]="$QUEUE_DIR/$id.rc"
	}
	_kill_jobs() {
		local p
		for p in "${JOB_PID[@]}"; do
			pkill -P "$p" 2>/dev/null || true
			kill "$p" 2>/dev/null || true
		done
		return 0
	}
	trap 'pr "Interrupted — stopping ${#JOB_PID[@]} in-flight job(s)"; _kill_jobs; abort' INT
fi

_run_build() {
	if ((PAR_JOBS <= 1)); then
		local _slug _log
		_slug=$(failure_slug "$1")
		_log="$FAILURES_DIR/$_slug.log"
		if [ -n "${GITHUB_REPOSITORY:-}" ]; then echo "::group::Building $1"; fi
		if build_rv "$2" 2>&1 | tee "$_log"; then
			_clear_failure_record "$1"
		else
			epr "Build failed for $1"
			_attach_failure_log "$1" "$_log"
		fi
		if [ -n "${GITHUB_REPOSITORY:-}" ]; then echo "::endgroup::"; fi
	else
		_enqueue_build "$2" "$1"
	fi
	return 0
}

for table_name in $(toml_get_table_names); do
	if [ -z "$table_name" ]; then continue; fi
	t=$(toml_get_table "$table_name")
	enabled=$(toml_get "$t" enabled) || enabled=true
	vtf "$enabled" "enabled"
	if [ "$enabled" = false ]; then continue; fi

	declare -A app_args
	patches_src=$(toml_get "$t" patches-source) || patches_src=$DEF_PATCHES_SRC
	patches_src_host=$(toml_get "$t" patches-source-host) || patches_src_host=$DEF_PATCHES_SRC_HOST
	patches_ver=$(toml_get "$t" patches-version) || patches_ver=$DEF_PATCHES_VER
	[ "$patches_ver" = "both" ] && { if [[ "${1:-}" == *"beta"* ]] || [ "$DEF_PATCHES_VER" = "beta" ]; then patches_ver="beta"; else patches_ver="stable"; fi; }
	dup_channel=stable
	if [[ "${1:-}" == *"beta"* ]] || [ "$DEF_PATCHES_VER" = "beta" ] || [ "$patches_ver" = "beta" ]; then
		dup_channel=beta
	fi
	cli_src=$(toml_get "$t" cli-source) || cli_src=$DEF_CLI_SRC
	cli_src_host=$(toml_get "$t" cli-source-host) || cli_src_host=$DEF_CLI_SRC_HOST
	cli_ver=$(toml_get "$t" cli-version) || cli_ver=$DEF_CLI_VER
	if ! isoneof "$cli_src_host" github gitlab codeberg; then abort "ERROR: cli-source-host '$cli_src_host' is not a valid option for '$table_name': only 'github', 'gitlab' or 'codeberg' is allowed"; fi
	resolve_patcher "$cli_src"

	IFS=$'\n'
	p_srcs=($(list_args "$patches_src" | tr -d \"\')); [ ${#p_srcs[@]} -eq 0 ] && p_srcs=("$patches_src")
	p_hosts=($(list_args "$patches_src_host" | tr -d \"\')); [ ${#p_hosts[@]} -eq 0 ] && p_hosts=("$patches_src_host")
	p_vers=($(list_args "$patches_ver" | tr -d \"\')); [ ${#p_vers[@]} -eq 0 ] && p_vers=("$patches_ver")
	unset IFS
	for h in "${p_hosts[@]}"; do
		if ! isoneof "$h" github gitlab codeberg; then abort "ERROR: patches-source-host '$h' is not a valid option for '$table_name': only 'github', 'gitlab' or 'codeberg' is allowed"; fi
	done

	if ! get_prebuilts "$cli_src_host" "$cli_src" "$cli_ver" "$patches_src_host" "$patches_src" "$patches_ver"; then
		epr "Could not get prebuilts"
		continue
	fi
	read -r -a __pb <<< "$__PREBUILTS_RESULT"
	cli_jar=${__pb[0]}
	patches_jar_all="${__pb[*]:1}"
	__pb_patches=("${__pb[@]:1}")
	app_args[cli]=$cli_jar
	app_args[ptjar]=$patches_jar_all
	app_args[cli_source]=$cli_src
	app_args[patches_sources_all]="${p_srcs[*]}"

	patches_ref_all="" changelog_url_all=""
	for i in "${!p_srcs[@]}"; do
		psrc="${p_srcs[$i]}"
		phost="${p_hosts[$i]:-${p_hosts[0]}}"
		pfile="${__pb_patches[$i]:-}"
		if [ -n "$pfile" ]; then
			pdir=$(dirname "$pfile")
			pfilename=${pfile##*/}
			
			if [ -f "${pfile}.tag" ]; then
				ptag=$(cat "${pfile}.tag")
			elif [ -f "${pdir}/tag_name.txt" ]; then
				ptag=$(cat "${pdir}/tag_name.txt")
			else
				pver_actual=${pfilename#*-}; pver_actual=${pver_actual%.*}
				ptag="v${pver_actual#v}"
			fi
			
			patches_ref_all+="${psrc%%/*}/${pfilename} "
			if cl_url=$(source_release_web_url "$phost" "$psrc" "$ptag"); then
				changelog_url_all+="${cl_url} "
			fi
		fi
	done
	app_args[patches_src]=${p_srcs[0]}
	app_args[dup_channel]="$dup_channel"
	app_args[patches_ref]="${patches_ref_all% }"
	app_args[changelog_url]="${changelog_url_all% }"
	app_args[brand]=$(toml_get "$t" brand) || app_args[brand]="${DEF_BRAND:-${p_srcs[0]%%/*}}"
	app_args[variant]=$(toml_get "$t" variant) || app_args[variant]="$DEF_VARIANT"
	app_args[sub_variant]=$(toml_get "$t" sub-variant) || app_args[sub_variant]="$DEF_SUB_VARIANT"

	app_args[excluded_patches]=$(toml_get "$t" excluded-patches) || app_args[excluded_patches]=""
	if [ -n "${app_args[excluded_patches]}" ] && [[ ${app_args[excluded_patches]} != *'"'* ]]; then abort "patch names inside excluded-patches must be quoted"; fi
	app_args[included_patches]=$(toml_get "$t" included-patches) || app_args[included_patches]=""
	if [ -n "${app_args[included_patches]}" ] && [[ ${app_args[included_patches]} != *'"'* ]]; then abort "patch names inside included-patches must be quoted"; fi
	app_args[exclusive_patches]=$(toml_get "$t" exclusive-patches) || app_args[exclusive_patches]=false
	app_args[inclusive_patches]=$(toml_get "$t" inclusive-patches) || app_args[inclusive_patches]=false
	if ! isoneof "${app_args[inclusive_patches]}" true false; then
		abort "ERROR: inclusive-patches '${app_args[inclusive_patches]}' for '$table_name' must be true or false (unlike exclusive-patches it takes no patch-source list)"
	fi
	if [ "${app_args[inclusive_patches]}" = true ] && [ "${app_args[exclusive_patches]}" != false ]; then
		abort "ERROR: inclusive-patches and exclusive-patches are opposites; set only one for '$table_name'"
	fi
	app_args[version]=$(toml_get "$t" version) || app_args[version]="auto"
	app_args[version_code]=$(toml_get "$t" version-code) || app_args[version_code]=""
	app_args[app_name]=$(toml_get "$t" app-name) || app_args[app_name]=$table_name
	app_args[patcher_args]=$(toml_get "$t" patcher-args) || app_args[patcher_args]=""
	app_args[table]=$table_name
	app_args[build_mode]=$(toml_get "$t" build-mode) || app_args[build_mode]="$DEF_BUILD_MODE"
	if ! isoneof "${app_args[build_mode]}" both apk module; then
		abort "ERROR: build-mode '${app_args[build_mode]}' is not a valid option for '${table_name}': only 'both', 'apk' or 'module' is allowed"
	fi
	app_args[include_stock]=$(toml_get "$t" include-stock) && {
		if ! isoneof "${app_args[include_stock]}" disable merged split; then
			abort "ERROR: include-stock '${app_args[include_stock]}' is not a valid option for '${table_name}': only 'disable', 'merged' or 'split' is allowed"
		fi
	} || app_args[include_stock]=merged

	for dl_from in "${DL_SRCS[@]}"; do
		if app_args[${dl_from}_dlurl]=$(toml_get "$t" "${dl_from}-dlurl"); then
			app_args[${dl_from}_dlurl]=${app_args[${dl_from}_dlurl]%/}
			app_args[${dl_from}_dlurl]=${app_args[${dl_from}_dlurl]%download}
			app_args[${dl_from}_dlurl]=${app_args[${dl_from}_dlurl]%/}
			app_args[dl_from]=${dl_from}
		else
			app_args[${dl_from}_dlurl]=""
		fi
	done
	if [ -z "${app_args[dl_from]-}" ]; then abort "ERROR: no 'dlurl' option was set for '$table_name'. (${DL_SRCS[*]})"; fi
	app_args[arch]=$(toml_get "$t" arch) || app_args[arch]="$DEF_ARCH"
	if ! isoneof "${app_args[arch]}" "auto" "both" "all" "arm64-v8a" "arm-v7a" "x86_64" "x86"; then
		abort "wrong arch '${app_args[arch]}' for '$table_name'"
	fi

	app_args[pkg_name]=$(toml_get "$t" pkg-name) || app_args[pkg_name]=""
	app_args[patched_pkg_name]=$(toml_get "$t" patched-pkg-name) || app_args[patched_pkg_name]=""
	app_args[dpi]=$(toml_get "$t" dpi) || app_args[dpi]="$DEF_DPI"
	app_args[github_regex]=$(toml_get "$t" github-regex) || app_args[github_regex]=""
	app_args[github_release_regex]=$(toml_get "$t" github-release-regex) || app_args[github_release_regex]=""
	table_name_f=${table_name,,}
	table_name_f=${table_name_f// /-}
	app_args[module_prop_name]=$(toml_get "$t" module-prop-name) || app_args[module_prop_name]="${table_name_f}-${DEF_AUTHOR_NAME}"

	if { [[ "${1:-}" == *"beta"* ]] || [ "${DEF_PATCHES_VER:-}" = "beta" ] || [ "${patches_ver:-}" = "beta" ]; } && [[ "${app_args[module_prop_name]}" != *"-beta"* ]]; then
		app_args[module_prop_name]="${app_args[module_prop_name]}-beta"
	fi

	if [ "${app_args[arch]}" = both ]; then
		module_prop_name_b=${app_args[module_prop_name]}
		app_args[table]="$table_name (arm64-v8a)"
		app_args[arch]="arm64-v8a"
		app_args[module_prop_name]="${module_prop_name_b}-arm64"
		_run_build "${app_args[table]}" "$(declare -p app_args)"
		app_args[table]="$table_name (arm-v7a)"
		app_args[arch]="arm-v7a"
		app_args[module_prop_name]="${module_prop_name_b}-arm"
		_run_build "${app_args[table]}" "$(declare -p app_args)"
	else
		if [ "${app_args[arch]}" = "arm64-v8a" ]; then
			app_args[module_prop_name]="${app_args[module_prop_name]}-arm64"
		elif [ "${app_args[arch]}" = "arm-v7a" ]; then
			app_args[module_prop_name]="${app_args[module_prop_name]}-arm"
		fi
		_run_build "${app_args[table]}" "$(declare -p app_args)"
	fi
done

while ((PAR_JOBS > 1 && ${#JOB_PID[@]} > 0)); do
	_reap_done
	((${#JOB_PID[@]} > 0)) || break
	wait -n >/dev/null 2>&1 || true
	sleep 1
done

# ==============================================================================
# OPTIMIZATION: Native Library Stripping (llvm-strip) & ABI Cleanup
# ==============================================================================
echo "=== [OPTIMIZATION] Stripping Native Libraries & Cleaning ABIs ==="

LLVM_STRIP=""
if command -v llvm-strip >/dev/null 2>&1; then
  LLVM_STRIP="$(command -v llvm-strip)"
elif command -v x86_64-linux-gnu-llvm-strip >/dev/null 2>&1; then
  LLVM_STRIP="$(command -v x86_64-linux-gnu-llvm-strip)"
fi

find "$TEMP_DIR" -type d -name "lib" 2>/dev/null | while read -r LIB_DIR; do
  rm -rf "$LIB_DIR/armeabi-v7a" "$LIB_DIR/x86" "$LIB_DIR/x86_64" "$LIB_DIR/mips" "$LIB_DIR/mips64"

  if [ -n "$LLVM_STRIP" ]; then
    find "$LIB_DIR/arm64-v8a" -name "*.so" -exec "$LLVM_STRIP" --strip-unneeded {} + 2>/dev/null || true
  fi
done

merge_build_info
rm -rf temp/tmp.* "$TEMP_DIR"/*-merge-tmp* "$TEMP_DIR"/*/*-merge-tmp* "$QUEUE_DIR" "$TEMP_DIR/dllocks" "$TEMP_DIR/apkslocks" "$TEMP_DIR/urlindex" "${TEMP_DIR}"/morphe-stage-*
if [ -z "$(ls -A1 "${BUILD_DIR}")" ]; then
	if [ -n "$(ls -A1 "$UNCHANGED_DIR" 2>/dev/null)" ]; then
		pr "No new artifacts — every build identical to published; nothing to release."
		: >"$UNCHANGED_DIR/all.txt"
		exit 0
	fi
	abort "All builds failed."
fi

if command -v python3 >/dev/null 2>&1; then
	python3 .github/scripts/generate_release_notes.py
fi

pr "Done"
