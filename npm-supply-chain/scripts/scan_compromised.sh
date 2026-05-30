#!/usr/bin/env bash
set -euo pipefail

# NPM Supply Chain Attack Scanner
# Usage: scan_compromised.sh [--lock-only] [--verbose] [dir1 dir2 ...]

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DATA_FILE="$SKILL_DIR/data/compromised-packages.tsv"

# Parse arguments
LOCK_ONLY=false
VERBOSE=false
DIRS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --lock-only) LOCK_ONLY=true; shift ;;
        --verbose) VERBOSE=true; shift ;;
        *) DIRS+=("$1"); shift ;;
    esac
done

# Default directories
if [[ ${#DIRS[@]} -eq 0 ]]; then
    DIRS=(/home/yhonda/js /home/yhonda/rust /home/yhonda/arduino)
fi

# Validate data file
if [[ ! -f "$DATA_FILE" ]]; then
    echo "ERROR: Compromised packages data file not found: $DATA_FILE"
    exit 1
fi

# Load compromised packages into arrays
declare -A COMP_SEV COMP_DESC COMP_URL
COMP_COUNT=0
while IFS=$'\t' read -r pkg ver sev desc url; do
    [[ -z "$pkg" || "$pkg" == \#* ]] && continue
    key="${pkg}@${ver}"
    COMP_SEV["$key"]="$sev"
    COMP_DESC["$key"]="$desc"
    COMP_URL["$key"]="$url"
    ((COMP_COUNT++)) || true
done < "$DATA_FILE"

echo "=== NPM Supply Chain Scan ==="
echo "Data: $COMP_COUNT compromised package versions tracked"
echo ""

# Counters
FOUND_CRITICAL=0
FOUND_HIGH=0
FOUND_MEDIUM=0
PROJECT_COUNT=0
NM_COUNT=0
LOCK_COUNT=0
FINDINGS=()

START_TIME=$(date +%s%N 2>/dev/null || date +%s)

# Collect scan targets
for dir in "${DIRS[@]}"; do
    [[ -d "$dir" ]] || continue
    [[ "$VERBOSE" == true ]] && echo "Scanning: $dir"

    # === 1. Scan node_modules ===
    if [[ "$LOCK_ONLY" == false ]]; then
        while IFS= read -r nm_dir; do
            ((NM_COUNT++)) || true
            [[ "$VERBOSE" == true ]] && echo "  node_modules: $nm_dir"
            for key in "${!COMP_SEV[@]}"; do
                pkg="${key%@*}"
                ver="${key#*@}"
                pkg_json="$nm_dir/$pkg/package.json"
                [[ -f "$pkg_json" ]] || continue
                installed_ver=$(grep -m1 '"version"' "$pkg_json" 2>/dev/null | sed 's/.*: *"\(.*\)".*/\1/' || true)
                if [[ "$installed_ver" == "$ver" ]]; then
                    sev="${COMP_SEV[$key]}"
                    finding="[$sev] ${key} INSTALLED"
                    finding+="\n  Location: $pkg_json"
                    finding+="\n  Detail: ${COMP_DESC[$key]}"
                    finding+="\n  Advisory: ${COMP_URL[$key]}"
                    finding+="\n  Action: cd $(dirname "$nm_dir") && npm install ${pkg}@latest"
                    FINDINGS+=("$sev|$finding")
                    case "$sev" in
                        CRITICAL) ((FOUND_CRITICAL++)) || true ;;
                        HIGH) ((FOUND_HIGH++)) || true ;;
                        MEDIUM) ((FOUND_MEDIUM++)) || true ;;
                    esac
                fi
            done
        done < <(find "$dir" -maxdepth 5 -name "node_modules" -type d -not -path "*/node_modules/*/node_modules" 2>/dev/null)
    fi

    # === 2. Scan lock files ===
    while IFS= read -r lockfile; do
        ((LOCK_COUNT++)) || true
        ((PROJECT_COUNT++)) || true
        basename_lock=$(basename "$lockfile")
        [[ "$VERBOSE" == true ]] && echo "  lock: $lockfile"

        for key in "${!COMP_SEV[@]}"; do
            pkg="${key%@*}"
            ver="${key#*@}"
            found=false

            case "$basename_lock" in
                package-lock.json)
                    if grep -q "\"$pkg\"" "$lockfile" 2>/dev/null; then
                        if grep -A5 "\"$pkg\"" "$lockfile" 2>/dev/null | grep -q "\"version\": \"$ver\""; then
                            found=true
                        fi
                    fi
                    ;;
                yarn.lock)
                    if grep -qE "\"?${pkg}@" "$lockfile" 2>/dev/null; then
                        if grep -A2 "${pkg}@" "$lockfile" 2>/dev/null | grep -q "version \"$ver\""; then
                            found=true
                        fi
                    fi
                    ;;
                pnpm-lock.yaml)
                    if grep -qE "/${pkg}/${ver}:|'${pkg}@${ver}':" "$lockfile" 2>/dev/null; then
                        found=true
                    fi
                    ;;
            esac

            if [[ "$found" == true ]]; then
                sev="${COMP_SEV[$key]}"
                finding="[$sev] ${key} in lock file"
                finding+="\n  Location: $lockfile"
                finding+="\n  Detail: ${COMP_DESC[$key]}"
                finding+="\n  Advisory: ${COMP_URL[$key]}"
                finding+="\n  Action: Verify installed version or regenerate lock file"
                FINDINGS+=("$sev|$finding")
                case "$sev" in
                    CRITICAL) ((FOUND_CRITICAL++)) || true ;;
                    HIGH) ((FOUND_HIGH++)) || true ;;
                    MEDIUM) ((FOUND_MEDIUM++)) || true ;;
                esac
            fi
        done
    done < <(find "$dir" -maxdepth 4 \( -name "package-lock.json" -o -name "yarn.lock" -o -name "pnpm-lock.yaml" \) -not -path "*/node_modules/*" 2>/dev/null)
done

END_TIME=$(date +%s%N 2>/dev/null || date +%s)
if [[ "$END_TIME" =~ ^[0-9]{10,}$ && "$START_TIME" =~ ^[0-9]{10,}$ ]]; then
    ELAPSED=$(( (END_TIME - START_TIME) / 1000000 ))
    TIME_STR="${ELAPSED}ms"
else
    TIME_STR="N/A"
fi

# Print findings sorted by severity
for sev_order in CRITICAL HIGH MEDIUM; do
    for f in "${FINDINGS[@]+"${FINDINGS[@]}"}"; do
        if [[ "$f" == "$sev_order|"* ]]; then
            echo -e "${f#*|}"
            echo ""
        fi
    done
done

# Summary
echo "--- Summary ---"
echo "Scanned: $PROJECT_COUNT projects, $NM_COUNT node_modules, $LOCK_COUNT lock files"

if [[ ${#FINDINGS[@]} -eq 0 ]]; then
    echo ""
    echo "All clean - no known compromised packages detected."
else
    echo "CRITICAL: $FOUND_CRITICAL"
    echo "HIGH:     $FOUND_HIGH"
    echo "MEDIUM:   $FOUND_MEDIUM"
fi

CLEAN=$((PROJECT_COUNT - FOUND_CRITICAL - FOUND_HIGH - FOUND_MEDIUM))
[[ $CLEAN -lt 0 ]] && CLEAN=0
echo "CLEAN:    $CLEAN projects"
echo ""
echo "Total scan time: $TIME_STR"
