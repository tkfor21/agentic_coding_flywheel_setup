#!/usr/bin/env bash
# mac-flywheel local tool (never proposed upstream).
#
# Freeze every installer in checksums.yaml to immutable bytes, so an install at a pinned commit downloads exactly
# what was reviewed, however much upstream moves. Joel's rule (2026-11-01): hold what is true at refresh time, and
# change pins only in a deliberate, manual bring-to-current.
#
#   GitHub raw on a branch    https://raw.githubusercontent.com/<o>/<r>/<branch>/<path>
#                          -> https://raw.githubusercontent.com/<o>/<r>/<40-hex commit>/<path>
#   GitHub latest release     https://github.com/<o>/<r>/releases/latest/download/<asset>
#                          -> https://github.com/<o>/<r>/releases/download/<tag>/<asset>
#   Anything else (vendor)    https://bun.sh/install, https://astral.sh/uv/install.sh, ...
#                          -> a reviewed copy in vendor/installers/<tool>.sh on this fork, fetched at a commit
#
# Modes:
#   hold     freeze at the bytes checksums.yaml already authorizes (find the commit, tag or live bytes whose sha256
#            equals the pinned one). Nothing new is trusted. A tool that can't be matched is reported and left as is.
#   refresh  bring-to-current: freeze at upstream's current bytes and record their new sha256. Review the diff
#            of every changed installer before committing.
#
# Usage (from the repository root):
#   scripts/mac-flywheel/freeze-installers.sh vendor [--mode hold|refresh]
#       Writes vendor/installers/<tool>.sh for every vendor-hosted entry that is not frozen yet. Commit and push.
#   scripts/mac-flywheel/freeze-installers.sh pin --vendor-repo <owner/repo> --vendor-ref <40-hex>
#                                                [--mode hold|refresh]
#       Rewrites the url/sha256 values in checksums.yaml in place. Vendored copies are fetched from
#       <vendor-repo> at <vendor-ref> (the pushed commit from the vendor step) and re-hashed.
#   Then regenerate the internal checksum ledger with `bun run generate` (packages/manifest) in an acfs-* guest.
#
# Needs bash 4+, curl, gh (authenticated), and sha256sum or shasum.
set -euo pipefail

CHECKSUMS_FILE="checksums.yaml"
VENDOR_DIR="vendor/installers"
MODE="hold"
VENDOR_REPO=""
VENDOR_REF=""

die() { printf 'freeze-installers: %s\n' "$*" >&2; exit 2; }

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

fetch() { # url dest
    curl --proto '=https' --proto-redir '=https' -fsSL --retry 2 -o "$2" "$1"
}

is_sha40() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }

# Classify a URL: prints "github_raw <o> <r> <ref> <path>", "release_latest <o> <r> <asset>",
# "release_tag", "vendored" or "vendor".
classify() {
    local url="$1" rest o r ref path
    if [[ "$url" =~ ^https://raw\.githubusercontent\.com/([^/]+)/([^/]+)/(.+)$ ]]; then
        o="${BASH_REMATCH[1]}"; r="${BASH_REMATCH[2]}"; rest="${BASH_REMATCH[3]}"
        if [[ "$rest" == refs/heads/* ]]; then
            rest="${rest#refs/heads/}"
        fi
        ref="${rest%%/*}"; path="${rest#*/}"
        if is_sha40 "$ref" && [[ "$path" == "$VENDOR_DIR/"* ]]; then
            printf 'vendored\n'
        else
            printf 'github_raw %s %s %s %s\n' "$o" "$r" "$ref" "$path"
        fi
    elif [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/releases/latest/download/([^/]+)$ ]]; then
        printf 'release_latest %s %s %s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    elif [[ "$url" =~ ^https://github\.com/[^/]+/[^/]+/releases/download/[^/]+/[^/]+$ ]]; then
        printf 'release_tag\n'
    else
        printf 'vendor\n'
    fi
}

# --- GitHub raw: find the commit to freeze at -------------------------------------------------------------------
freeze_github_raw() { # o r branch path pinned_sha -> prints "<commit> <sha256>" or returns 1
    local o="$1" r="$2" branch="$3" path="$4" pinned="$5" tmp head sha commit
    tmp="$(mktemp)"
    head="$(gh api "repos/$o/$r/commits/$branch" --jq .sha)" || { rm -f "$tmp"; return 1; }
    fetch "https://raw.githubusercontent.com/$o/$r/$head/$path" "$tmp" || { rm -f "$tmp"; return 1; }
    sha="$(sha256_of "$tmp")"
    if [[ "$MODE" == refresh || "$sha" == "$pinned" ]]; then
        rm -f "$tmp"; printf '%s %s\n' "$head" "$sha"; return 0
    fi
    # hold: the branch head has moved on; find the newest commit whose file bytes are the pinned ones.
    while read -r commit; do
        fetch "https://raw.githubusercontent.com/$o/$r/$commit/$path" "$tmp" 2>/dev/null || continue
        if [[ "$(sha256_of "$tmp")" == "$pinned" ]]; then
            rm -f "$tmp"; printf '%s %s\n' "$commit" "$pinned"; return 0
        fi
    done < <(gh api "repos/$o/$r/commits?sha=$branch&path=$path&per_page=100" --jq '.[].sha')
    rm -f "$tmp"
    return 1
}

# --- GitHub latest release: find the tag to freeze at -----------------------------------------------------------
freeze_release_latest() { # o r asset pinned_sha -> prints "<tag> <sha256>" or returns 1
    local o="$1" r="$2" asset="$3" pinned="$4" tag digest tmp
    if [[ "$MODE" == refresh ]]; then
        tag="$(gh api "repos/$o/$r/releases/latest" --jq .tag_name)" || return 1
    else
        tag="$(gh api "repos/$o/$r/releases?per_page=50" --jq \
            ".[] | select(any(.assets[]; .name == \"$asset\" and .digest == \"sha256:$pinned\")) | .tag_name" \
            | head -n1)"
        [[ -n "$tag" ]] || return 1
    fi
    tmp="$(mktemp)"
    fetch "https://github.com/$o/$r/releases/download/$tag/$asset" "$tmp" || { rm -f "$tmp"; return 1; }
    digest="$(sha256_of "$tmp")"; rm -f "$tmp"
    [[ "$MODE" == refresh || "$digest" == "$pinned" ]] || return 1
    printf '%s %s\n' "$tag" "$digest"
}

# Read checksums.yaml into parallel arrays: TOOLS, URLS, SHAS.
TOOLS=(); URLS=(); SHAS=()
read_checksums() {
    local line tool="" url=""
    while IFS= read -r line; do
        if [[ "$line" =~ ^\ \ ([a-z0-9_-]+):$ ]]; then
            tool="${BASH_REMATCH[1]}"; url=""
        elif [[ -n "$tool" && "$line" =~ ^\ \ \ \ url:\ \"([^\"]+)\"$ ]]; then
            url="${BASH_REMATCH[1]}"
        elif [[ -n "$tool" && -n "$url" && "$line" =~ ^\ \ \ \ sha256:\ \"([0-9a-f]{64})\"$ ]]; then
            TOOLS+=("$tool"); URLS+=("$url"); SHAS+=("${BASH_REMATCH[1]}")
            tool=""; url=""
        fi
    done < "$CHECKSUMS_FILE"
    [[ ${#TOOLS[@]} -gt 0 ]] || die "no entries parsed from $CHECKSUMS_FILE"
}

cmd_vendor() {
    local i tool url pinned kind tmp sha failed=0
    mkdir -p "$VENDOR_DIR"
    for i in "${!TOOLS[@]}"; do
        tool="${TOOLS[$i]}"; url="${URLS[$i]}"; pinned="${SHAS[$i]}"
        read -r kind _ <<< "$(classify "$url")"
        [[ "$kind" == vendor ]] || continue
        tmp="$(mktemp)"
        if ! fetch "$url" "$tmp"; then
            printf 'FAIL\t%s\tdownload failed: %s\n' "$tool" "$url"; failed=1; rm -f "$tmp"; continue
        fi
        sha="$(sha256_of "$tmp")"
        if [[ "$MODE" == hold && "$sha" != "$pinned" ]]; then
            printf 'HOLD-MISS\t%s\tlive %s != pinned %s (not vendored; review needed)\n' "$tool" "$sha" "$pinned"
            failed=1; rm -f "$tmp"; continue
        fi
        mv "$tmp" "$VENDOR_DIR/$tool.sh"; chmod 0644 "$VENDOR_DIR/$tool.sh"
        printf 'VENDORED\t%s\t%s\t%s\n' "$tool" "$sha" "$url"
    done
    return "$failed"
}

cmd_pin() {
    [[ -n "$VENDOR_REPO" ]] || die "pin needs --vendor-repo <owner/repo>"
    is_sha40 "$VENDOR_REF" || die "pin needs --vendor-ref <40-hex commit> (the pushed vendor commit)"
    local i tool url pinned kind o r ref path asset result new_url new_sha tmp failed=0
    local -A NEW_URL=() NEW_SHA=()
    for i in "${!TOOLS[@]}"; do
        tool="${TOOLS[$i]}"; url="${URLS[$i]}"; pinned="${SHAS[$i]}"
        read -r kind o r ref path <<< "$(classify "$url")"
        new_url="$url"; new_sha="$pinned"
        case "$kind" in
            github_raw)
                if is_sha40 "$ref"; then
                    printf 'FROZEN\t%s\talready at a commit\n' "$tool"
                elif result="$(freeze_github_raw "$o" "$r" "$ref" "$path" "$pinned")"; then
                    read -r ref new_sha <<< "$result"
                    new_url="https://raw.githubusercontent.com/$o/$r/$ref/$path"
                else
                    printf 'HOLD-MISS\t%s\tno commit on %s/%s@%s has the pinned bytes\n' "$tool" "$o" "$r" "$ref"
                    failed=1
                fi
                ;;
            release_latest)
                asset="$ref"
                if result="$(freeze_release_latest "$o" "$r" "$asset" "$pinned")"; then
                    read -r ref new_sha <<< "$result"
                    new_url="https://github.com/$o/$r/releases/download/$ref/$asset"
                else
                    printf 'HOLD-MISS\t%s\tno release of %s/%s has the pinned %s\n' "$tool" "$o" "$r" "$asset"
                    failed=1
                fi
                ;;
            vendor)
                new_url="https://raw.githubusercontent.com/$VENDOR_REPO/$VENDOR_REF/$VENDOR_DIR/$tool.sh"
                tmp="$(mktemp)"
                if fetch "$new_url" "$tmp"; then
                    new_sha="$(sha256_of "$tmp")"
                    if [[ "$MODE" == hold && "$new_sha" != "$pinned" ]]; then
                        printf 'HOLD-MISS\t%s\tvendored copy %s != pinned %s\n' "$tool" "$new_sha" "$pinned"
                        new_url="$url"; new_sha="$pinned"; failed=1
                    fi
                else
                    printf 'HOLD-MISS\t%s\tno vendored copy at %s\n' "$tool" "$new_url"
                    new_url="$url"; failed=1
                fi
                rm -f "$tmp"
                ;;
            vendored|release_tag)
                printf 'FROZEN\t%s\talready immutable\n' "$tool"
                ;;
        esac
        if [[ "$new_url" != "$url" ]]; then
            printf '%s\t%s\t%s\n' "$([[ "$new_sha" == "$pinned" ]] && echo PINNED || echo CHANGED)" "$tool" "$new_url"
        fi
        NEW_URL[$tool]="$new_url"; NEW_SHA[$tool]="$new_sha"
    done

    # Rewrite only the url/sha256 values, keeping every other byte of the file's shape.
    local out line cur=""
    out="$(mktemp)"
    while IFS= read -r line; do
        if [[ "$line" =~ ^\ \ ([a-z0-9_-]+):$ ]]; then
            cur="${BASH_REMATCH[1]}"
        elif [[ -n "$cur" && -n "${NEW_URL[$cur]:-}" && "$line" =~ ^\ \ \ \ url:\  ]]; then
            line="    url: \"${NEW_URL[$cur]}\""
        elif [[ -n "$cur" && -n "${NEW_SHA[$cur]:-}" && "$line" =~ ^\ \ \ \ sha256:\  ]]; then
            line="    sha256: \"${NEW_SHA[$cur]}\""
        fi
        printf '%s\n' "$line"
    done < "$CHECKSUMS_FILE" > "$out"
    mv "$out" "$CHECKSUMS_FILE"
    return "$failed"
}

[[ $# -ge 1 ]] || die "usage: freeze-installers.sh vendor|pin [--mode hold|refresh] [--vendor-repo o/r --vendor-ref sha]"
SUB="$1"; shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode) MODE="${2:-}"; shift 2 ;;
        --vendor-repo) VENDOR_REPO="${2:-}"; shift 2 ;;
        --vendor-ref) VENDOR_REF="${2:-}"; shift 2 ;;
        *) die "unknown argument: $1" ;;
    esac
done
[[ "$MODE" == hold || "$MODE" == refresh ]] || die "--mode must be hold or refresh"
[[ -f "$CHECKSUMS_FILE" ]] || die "run from the repository root ($CHECKSUMS_FILE not found)"
read_checksums
case "$SUB" in
    vendor) cmd_vendor ;;
    pin) cmd_pin ;;
    *) die "unknown subcommand: $SUB" ;;
esac
