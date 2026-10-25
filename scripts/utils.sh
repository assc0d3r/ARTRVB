#!/usr/bin/env bash
# ==============================================================================
# Core Utility Functions for Build & CI/CD Pipeline (`scripts/utils.sh`)
# ==============================================================================

# Prevent multiple inclusions and ensure safe sourcing under strict modes
[[ -n "${_UTILS_SH_LOADED:-}" ]] && return 0
_UTILS_SH_LOADED=1

# Generates a normalized, lowercase hyphen-separated slug for file naming and identifiers
failure_slug() {
    local input="${1:-unknown}"
    echo "$input" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g' | sed -E 's/^-+|-+$//g'
}

# Records detailed failure metadata into JSON format for post-build reporting
write_build_failure_descriptor() {
    local app_name="${1:-unknown}"
    local version="${2:-unknown}"
    local reason="${3:-unknown}"
    local output_dir="${BUILD_FAILURE_DIR:-.failures}"
    
    mkdir -p "$output_dir" 2>/dev/null || true
    local slug
    slug="$(failure_slug "$app_name")"
    local timestamp
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    cat <<EOF > "$output_dir/${slug}_failure.json"
{
  "app_name": "$app_name",
  "version": "$version",
  "reason": "$reason",
  "timestamp": "$timestamp"
}
EOF
}

# Retrieves the previously recorded content hash for duplicate-build suppression
_dedup_recorded_hash() {
    local channel="${1:-default}"
    local key="${2:-}"
    local state_file="state/build_content_hashes.json"

    if [[ -f "$state_file" ]] && command -v jq &>/dev/null; then
        jq -r --arg c "$channel" --arg k "$key" '.[$c][$k] // empty' "$state_file" 2>/dev/null
    fi
}

# Stores the current content hash for duplicate-build suppression
_dedup_store_hash() {
    local channel="${1:-default}"
    local key="${2:-}"
    local hash_val="${3:-}"
    local state_file="state/build_content_hashes.json"

    mkdir -p "$(dirname "$state_file")" 2>/dev/null || true
    
    if ! [[ -f "$state_file" ]]; then
        echo '{}' > "$state_file"
    fi

    if command -v jq &>/dev/null; then
        local tmp
        tmp=$(mktemp)
        if jq --arg c "$channel" --arg k "$key" --arg h "$hash_val" '.[$c][$k] = $h' "$state_file" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$state_file"
        else
            rm -f "$tmp"
        fi
    fi
}

# Safely strips non-ARM64 ABI directories and strips debug symbols from native binaries
_strip_apk_abis() {
    local target_dir="${1:-}"
    
    if [[ -z "$target_dir" || ! -d "$target_dir" ]]; then
        echo "Error: Invalid or missing target directory for ABI stripping." >&2
        return 1
    }

    # Remove non-arm64 ABI directories if present under lib/
    find "$target_dir" -type d -path "*/lib/*" ! -name "arm64-v8a" -exec rm -rf {} + 2>/dev/null || true

    # Run llvm-strip on all shared libraries if available
    if command -v llvm-strip &>/dev/null; then
        find "$target_dir" -type f -name "*.so" -exec llvm-strip --strip-unneeded {} + 2>/dev/null || true
    elif command -v strip &>/dev/null; then
        find "$target_dir" -type f -name "*.so" -exec strip --strip-unneeded {} + 2>/dev/null || true
    fi
}
