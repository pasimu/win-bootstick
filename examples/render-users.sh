#!/usr/bin/env bash
set -Eeuo pipefail

# Resolve paths relative to this script
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"

BOOTSTICK="${REPO_DIR}/create-bootstick.sh"

ENV_FILE="${SCRIPT_DIR}/company.env"
USERS_FILE="${SCRIPT_DIR}/users.tsv"
OUT_DIR="${SCRIPT_DIR}/autounattend-out"
mkdir -p "$OUT_DIR"

# Slugify for filenames: lowercase, spaces->_, non-alnum->-, squeeze/trim
_slug() {
  local s="${1:-}"
  s="${s,,}"
  s="${s//[[:space:]]/_}"
  s="${s//[^a-z0-9_.-]/-}"
  s="${s//__/_}"; s="${s//--/-}"
  s="${s##_}"; s="${s%%_}"
  s="${s#-}"; s="${s%-}"
  printf '%s' "$s"
}
_pad() { printf '%03d' "$1"; }

# Validate presence
[[ -f "$BOOTSTICK" ]] || { echo "Missing: $BOOTSTICK" >&2; exit 1; }
[[ -f "$ENV_FILE"  ]] || { echo "Missing: $ENV_FILE"  >&2; exit 1; }
[[ -f "$USERS_FILE" ]] || { echo "Missing: $USERS_FILE" >&2; exit 1; }

i=0

# Read raw lines; handle CRLF; preserve tabs
while IFS= read -r line || [[ -n "${line-}" ]]; do
  line="${line%$'\r'}"
  [[ -z "${line//[$'\t ']/}" ]] && continue
  [[ "${line}" == \#* ]] && continue

  if [[ "$line" != *$'\t'* ]]; then
    echo "WARN: no TAB found, skipping line: $line" >&2
    continue
  fi

  # Split into array on TAB; extra fields are preserved
  IFS=$'\t' read -r -a f <<< "$line"

  user="${f[0]}"
  display="${f[1]:-"$user"}"
  group="${f[2]:-}"
  password="${f[3]:-}"
  owner="${f[4]:-}"
  org="${f[5]:-}"
  lang="${f[6]:-}"
  tz="${f[7]:-}"
  pk="${f[8]:-}"

  ((++i))
  u="$(_slug "$user")"
  d="$(_slug "$display")"
  g="$(_slug "${group:-administratoren}")"

  out="${OUT_DIR}/$(_pad "$i")__${u}__${d}__${g}.autounattend.xml"

  (
    # Isolated environment for each user
    set -a; . "$ENV_FILE"; set +a

    # Per-user overrides
    LOCAL_USER_NAME="$user"
    LOCAL_USER_DISPLAYNAME="$display"
    LOCAL_USER_GROUP="${group:-${DEFAULT_GROUP:-Administratoren}}"
    LOCAL_USER_PASSWORD="$password"

    [[ -n "$owner" ]] && OWNER="$owner"
    [[ -n "$org"   ]] && ORG="$org"
    [[ -n "$lang"  ]] && WINLANG="$lang"
    [[ -n "$tz"    ]] && TIMEZONE="$tz"

    # Per-user product key overrides company default when present
    if [[ -n "$pk" ]]; then
      PRODUCT_KEY="$pk"
    fi

    "$BOOTSTICK" \
      --autounattend-out="$out"
  )
done < "$USERS_FILE"

echo "Wrote XMLs to: $OUT_DIR"

