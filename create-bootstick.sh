#!/usr/bin/env bash
# shellcheck shell=bash

# COPYRIGHT NOTICE
# Copyright (c) 2025, Patrick Siegmund
# All rights reserved.
#
# @file     create-bootstick.sh
# @brief    Windows 10/11 UEFI boot USB creator (GPT, FAT32-first) with XML template
#
# @version  1.1.4
# @author   pasimu
# @date     2025-09-26

set -Eeuo pipefail
set -o errtrace
shopt -s inherit_errexit || true

_boot_err() {
  local st=$?
  local src="${BASH_SOURCE[1]:-$0}"; src="${src##*/}"
  local line="${BASH_LINENO[0]:-$LINENO}"
  printf 'ERR pre-init: exit=%d at %s:%s while: %s\n' "$st" "$src" "$line" "${BASH_COMMAND}" >&2
}
trap -- _boot_err  ERR

: "${LC_ALL:=C}"
export LC_ALL

###############################################################################
# Constants
###############################################################################

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_NAME="${SCRIPT_PATH##*/}"
SCRIPT_DIR="${SCRIPT_PATH%/*}"
[[ "$SCRIPT_DIR" == "$SCRIPT_PATH" ]] && SCRIPT_DIR="."
SCRIPT_DIR="$(cd -- "$SCRIPT_DIR" && pwd -P)"

VERSION="1.1.4"
declare -r SCRIPT_PATH SCRIPT_NAME SCRIPT_DIR VERSION

###############################################################################
# Configuration (defaults). Overridable via env or CLI.
###############################################################################

LOG_LEVEL="${LOG_LEVEL:-1}"
NON_INTERACTIVE="${NON_INTERACTIVE:-false}"
DRY_RUN="${DRY_RUN:-false}"
PRINT_CONFIG="${PRINT_CONFIG:-}"

MODE="${MODE:-main}"

DEVICE="${DEVICE:-}"
ISO="${ISO:-}"

TEMPLATES="${TEMPLATES:-${SCRIPT_DIR}/templates}"
TEMPLATE="${TEMPLATE:-${TEMPLATES}/xml/win11-autounattend.xml}"

AUTOUNATTEND="${AUTOUNATTEND:-false}"
AUTOUNATTEND_OUT="${AUTOUNATTEND_OUT:-}"
INSTALL_DISK_ID="${INSTALL_DISK_ID:-}"
HWREQ_SKIP="${HWREQ_SKIP:-false}"
OOBE_SKIP="${OOBE_SKIP:-false}"
AUTO_LOGON="${AUTO_LOGON:-false}"
PRIVACY_HARDEN="${PRIVACY_HARDEN:-false}"
PRODUCT_KEY="${PRODUCT_KEY:-}"
LOCAL_USER_NAME="${LOCAL_USER_NAME:-}"
LOCAL_USER_GROUP="${LOCAL_USER_GROUP:-}"
LOCAL_USER_PASSWORD="${LOCAL_USER_PASSWORD:-}"
LOCAL_USER_DISPLAYNAME="${LOCAL_USER_DISPLAYNAME:-}"
WINLANG="${WINLANG:-}"
TIMEZONE="${TIMEZONE:-}"
OWNER="${OWNER:-}"
ORG="${ORG:-}"

FAT_LABEL="${FAT_LABEL:-WINFAT}"
NTFS_LABEL="${NTFS_LABEL:-WINNTFS}"
FAT_END_MIB="${FAT_END_MIB:-1025}"

PL_NTFS="${PL_NTFS:-WINPAYLOAD}"
PL_FAT="${PL_FAT:-WINESP}"

P_NTFS=""
P_FAT=""

###############################################################################
# Helper Functions
###############################################################################

builtin printf '' >/dev/null

if printf '%(%F %T)T' -1 >/dev/null 2>&1; then
  _log_ts() { printf '[%(%F %T)T]' -1; }
else
  _log_ts() { printf '[%s]' "$(date +'%F %T')"; }
fi

_log() {
  local lvl="$1"; shift
  local -i cur force=0
  case "$lvl" in
    debug) cur=0;;
    info)  cur=1;;
    error) cur=2;;
    fatal) cur=3; force=1;;
    *)     cur=1;;
  esac
  (( !force && cur < LOG_LEVEL )) && return 0
  printf '%s %-5s %s\n' "$(_log_ts)" "${lvl^^}" "$*" >&2
}

_run() {
  if (( DRY_RUN )); then
    printf '+ %q' "$1" >&2; shift || true; printf ' %q' "$@" >&2; printf '\n' >&2
    return 0
  fi
  "$@"
}

_confirm() {
  local prompt="${1:-Proceed?}"
  if (( NON_INTERACTIVE )); then return 0; fi
  if [[ -t 0 && -t 1 ]]; then
    local ans
    read -r -p "$prompt [y/N] " ans < /dev/tty || true
    case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
  else
    return 0
  fi
}

_cleanup()  { _log info "Cleaning up"; [[ -n "${TMP_DIR:-}" ]] && rm -rf -- "$TMP_DIR"; _log debug "Cleanup end"; }
_die()      { _log fatal "$*"; exit 1; }

_on_err() {
  local -i st=$?
  local src="${BASH_SOURCE[1]:-$SCRIPT_NAME}"; src="${src##*/}"
  local -i line="${BASH_LINENO[0]:-$LINENO}"
  local func="${FUNCNAME[1]:-main}"
  local -a ps=( "${PIPESTATUS[@]:-}" )
  _log error "exit=$st at ${src}:${line} in ${func} while: ${BASH_COMMAND} pipe=${ps[*]:-}"
}

_on_exit() {
  _log info "Finalizing"
  if [[ -n "${LOCKFD-}" ]]; then
    exec {LOCKFD}>&- 2>/dev/null || true
  fi
  if [[ -n ${LOCKFILE-} && -e ${LOCKFILE-} ]]; then
    rm -f -- "$LOCKFILE" 2>/dev/null || true
  fi
  _cleanup
}

###############################################################################
# Workflow Functions (in call order; helpers kept above)
###############################################################################

_check_required_commands() {
  _log info "Checking required commands (mode: $MODE)"
  local -a required_commands

  case "$MODE" in
    xml-only)
      required_commands=(
        mktemp sed realpath readlink install mkdir
      )
      ;;
    main)
      required_commands=(
        mktemp lsblk sgdisk wipefs parted blockdev partprobe udevadm readlink
        mkfs.fat mkfs.ntfs mount rsync install sed realpath flock id sync mkdir
        findmnt stat sleep
      )
      ;;
    *)
      _die "Unknown MODE in _check_required_commands: $MODE"
      ;;
  esac

  local cmd
  for cmd in "${required_commands[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || _die "Missing command: $cmd"
  done
}

usage() {
  cat <<EOF
$SCRIPT_NAME — $VERSION
Windows 10/11 UEFI boot USB creator (GPT, FAT32-first) with XML template.

USAGE:
  sudo -E $SCRIPT_NAME [OPTIONS]

REQUIRED:
  --device=/dev/sdX                     Target USB block device (current: $DEVICE)
  --iso=/path/file.iso                  Windows ISO path (current: $ISO)

COMMON OPTIONS:
  --log-level=[debug|info|error|silent] (current: $LOG_LEVEL)
  --non-interactive[=true|false]        Disable prompts (current: $NON_INTERACTIVE)
  --dry-run[=true|false]                Print actions only (current: $DRY_RUN)
  --mode=[main|xml-only]                Select workflow (default: $MODE)

AUTOUNATTEND OPTIONS:
  --autounattend[=true|false]           Enable/Disable autounattend.xml installation (current: $AUTOUNATTEND)
  --autounattend-out=PATH               Output target (file or dir); enables XML-only mode
  --template=PATH                       Autounattend XML template (current: $TEMPLATE)
  --install-disk-id=<N>                 Wipe disk N and install there (Omit to disable - default)
  --bypass-hw-reqs[=true|false]         Bypass Windows 11 HW requirements (current: $HWREQ_SKIP)
  --oobe-skip[=true|false]              Skip OOBE steps in template (current: $OOBE_SKIP)
  --auto-logon[=true|false]             Enable/Disable auto logon (current: $AUTO_LOGON)
  --harden-privacy[=true|false]         Enable/Disable Windows Privacy hardening (current: $PRIVACY_HARDEN)
  --win-lang=TAG                        Install/UI language BCP-47 tag (current: $WINLANG)
  --product-key=KEY                     Product key (use generic/KMS if needed)
  --local-user-name=NAME                Local account name (current: $LOCAL_USER_NAME)
  --local-user-group=GROUP              Local account group (current: $LOCAL_USER_GROUP)
  --local-user-password=PASS            Local account password (current: ${LOCAL_USER_PASSWORD:+(set)})
  --local-user-displayname=NAME         Local account displayname (current: $LOCAL_USER_DISPLAYNAME)
  --timezone=TZ                         Windows timezone ID (current: $TIMEZONE)
  --owner=NAME                          Registered owner (current: $OWNER)
  --org=NAME                            Registered organization (current: $ORG)

ADVANCED:
  --fat-size-mib=N                      End of FAT32 ESP in MiB (current: $FAT_END_MIB)
  --fat-label=LBL                       FAT32 label (current: $FAT_LABEL)
  --ntfs-label=LBL                      NTFS label (current: $NTFS_LABEL)
  --pl-fat=NAME                         FAT32 partlabel (current: $PL_FAT)
  --pl-ntfs=NAME                        NTFS partlabel (current: $PL_NTFS)

FLAGS:
  -D, --list-devices
  -V, --version
  -h, --help

ENV OVERRIDES:
  You may export any option name in uppercase (e.g., LOG_LEVEL=debug).

EXAMPLES:
  Create a bootable stick
  sudo -E ./create-bootstick.sh --device=/dev/sdb --iso=~/Downloads/isos/Win11_24H2_German_x64.iso

  Advanced autounattend.xml installation (using environment file in script dir)
  ( set -a; . "./environments/default.env"; set +a; sudo -E ./create-bootstick.sh --device=/dev/sdb )

  Generate only autounattend.xml from a template
  ( set -a; . "./environments/full-auto.env"; set +a; ./create-bootstick.sh --template=./templates/xml/win11-autounattend.xml --autounattend-out=./autounattend.xml )

  4. Batch rendering with company.env, user list and product keys
  This example generates multiple 'autounattend.xml' files using a shared environment file and a tab-separated user list.
  ./examples/render-users.sh
EOF
}

_parse_args() {
  _log info "Parsing arguments"
  POSITIONALS=()
  while (($#)); do
    local a="$1"; shift || true
    if [[ $a == --* && $a != *=* && $# -gt 0 && ${1} != -* ]]; then a="$a=$1"; shift || true; fi
    case "$a" in
      --mode=*)                   MODE=${a#*=};;
      --device=*)                 DEVICE=${a#*=};;
      --iso=*)                    ISO=${a#*=};;
      --autounattend=*)           AUTOUNATTEND=${a#*=};;
      --autounattend-out=*)       AUTOUNATTEND_OUT=${a#*=};;
      --bypass-hw-reqs=*)         HWREQ_SKIP=${a#*=};;
      --oobe-skip=*)              OOBE_SKIP=${a#*=};;
      --auto-logon=*)             AUTO_LOGON=${a#*=};;
      --harden-privacy=*)         PRIVACY_HARDEN=${a#*=};;
      --template=*)               TEMPLATE=${a#*=};;
      --install-disk-id=*)        INSTALL_DISK_ID=${a#*=};;
      --win-lang=*)               WINLANG=${a#*=};;
      --product-key=*)            PRODUCT_KEY=${a#*=};;
      --local-user-name=*)        LOCAL_USER_NAME=${a#*=};;
      --local-user-group=*)       LOCAL_USER_GROUP=${a#*=};;
      --local-user-password=*)    LOCAL_USER_PASSWORD=${a#*=};;
      --local-user-displayname=*) LOCAL_USER_DISPLAYNAME=${a#*=};;
      --timezone=*)               TIMEZONE=${a#*=};;
      --owner=*)                  OWNER=${a#*=};;
      --org=*)                    ORG=${a#*=};;
      --fat-size-mib=*)           FAT_END_MIB=${a#*=};;
      --fat-label=*)              FAT_LABEL=${a#*=};;
      --ntfs-label=*)             NTFS_LABEL=${a#*=};;
      --pl-fat=*)                 PL_FAT=${a#*=};;
      --pl-ntfs=*)                PL_NTFS=${a#*=};;
      --dry-run)                  DRY_RUN=1;;
      --dry-run=*)                DRY_RUN=${a#*=};;
      --non-interactive)          NON_INTERACTIVE=1;;
      --non-interactive=*)        NON_INTERACTIVE=${a#*=};;
      --log-level=*)              LOG_LEVEL=${a#*=}; _normalize_loglevel;;
      --silent)                   LOG_LEVEL=3;;
      --list-devices|-D)          lsblk -dno NAME,SIZE,RM,MODEL | sed 's/^/\/dev\//'; exit 0;;
      --version|-V)               printf '%s %s\n' "$SCRIPT_NAME" "$VERSION"; exit 0;;
      --help|-h)                  usage; exit 0;;
      --)                         POSITIONALS+=("$@"); break;;
      -*)                         _die "Unknown option: $a";;
      *)                          POSITIONALS+=("$a");;
    esac
  done
}

_normalize_bools() {
  _log info "Normalizing booleans"
  local v
  for v in NON_INTERACTIVE DRY_RUN AUTOUNATTEND HWREQ_SKIP OOBE_SKIP AUTO_LOGON PRIVACY_HARDEN; do
    case "${!v,,}" in
      1|true|yes|on)     printf -v "$v" 1 ;;
      0|false|no|off|'') printf -v "$v" 0 ;;
      *) _die "Invalid boolean for $v: ${!v}" ;;
    esac
  done
}

_normalize_loglevel() {
  _log info "Normalizing log level"
  case "${LOG_LEVEL,,}" in
    debug)  LOG_LEVEL=0;;
    info)   LOG_LEVEL=1;;
    error)  LOG_LEVEL=2;;
    silent) LOG_LEVEL=3;;
    [0-3])  :;;
    *)      _die "Invalid LOG_LEVEL: $LOG_LEVEL";;
  esac
}

_normalize_mode() {
  AUTOUNATTEND_OUT="$(_expand_path "${AUTOUNATTEND_OUT}")"

  case "$MODE" in
    main|xml-only) :;;
    *) _die "Invalid MODE: $MODE (expected main|xml-only)";;
  esac

  [[ -n "$AUTOUNATTEND_OUT" ]] && MODE="xml-only"

  if [[ "$MODE" == "xml-only" ]]; then
    AUTOUNATTEND=1
    if [[ -z "$AUTOUNATTEND_OUT" ]]; then
      AUTOUNATTEND_OUT="$SCRIPT_DIR/autounattend.xml"
    elif [[ -d "$AUTOUNATTEND_OUT" || "$AUTOUNATTEND_OUT" == */ ]]; then
      AUTOUNATTEND_OUT="${AUTOUNATTEND_OUT%/}/autounattend.xml"
    fi
  fi
}

_print_config() {
  _log info "Printing configuration"
  {
    printf '  SCRIPT_NAME=%s\n'             "$SCRIPT_NAME"
    printf '  SCRIPT_DIR=%s\n'              "$SCRIPT_DIR"
    printf '  VERSION=%s\n'                 "$VERSION"
    printf '  LOG_LEVEL=%s\n'               "$LOG_LEVEL"
    printf '  NON_INTERACTIVE=%s\n'         "$NON_INTERACTIVE"
    printf '  DRY_RUN=%s\n'                 "$DRY_RUN"
    printf '  MODE=%s\n'                    "$MODE"
    printf '  DEVICE=%s\n'                  "$DEVICE"
    printf '  ISO=%s\n'                     "$ISO"
    printf '  TEMPLATES=%s\n'               "$TEMPLATES"
    printf '  TEMPLATE=%s\n'                "$TEMPLATE"
    printf '  AUTOUNATTEND=%s\n'            "$AUTOUNATTEND"
    printf '  AUTOUNATTEND_OUT=%s\n'        "${AUTOUNATTEND_OUT:-}"
    printf '  HWREQ_SKIP=%s\n'              "$HWREQ_SKIP"
    printf '  OOBE_SKIP=%s\n'               "$OOBE_SKIP"
    printf '  PRODUCT_KEY=%s\n'             "${PRODUCT_KEY:+(set)}"
    printf '  LOCAL_USER_NAME=%s\n'         "$LOCAL_USER_NAME"
    printf '  LOCAL_USER_GROUP=%s\n'        "$LOCAL_USER_GROUP"
    printf '  LOCAL_USER_PASSWORD=%s\n'     "${LOCAL_USER_PASSWORD:+(set)}"
    printf '  LOCAL_USER_DISPLAYNAME=%s\n'  "$LOCAL_USER_DISPLAYNAME"
    printf '  WINLANG=%s\n'                 "$WINLANG"
    printf '  TIMEZONE=%s\n'                "$TIMEZONE"
    printf '  OWNER=%s\n'                   "$OWNER"
    printf '  ORG=%s\n'                     "$ORG"
    printf '  FAT_LABEL=%s\n'               "$FAT_LABEL"
    printf '  NTFS_LABEL=%s\n'              "$NTFS_LABEL"
    printf '  FAT_END_MIB=%s\n'             "$FAT_END_MIB"
    printf '  PL_FAT=%s\n'                  "$PL_FAT"
    printf '  PL_NTFS=%s\n'                 "$PL_NTFS"
    printf '  P_FAT=%s\n'                   "${P_FAT:-}"
    printf '  P_NTFS=%s\n'                  "${P_NTFS:-}"
  } >&2
}

_init() {
  _log info "Initializing"
  umask 077
  TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${SCRIPT_NAME%%.*}.XXXXXX")"; : "${TMP_DIR:?}"
  RUN_DIR="$TMP_DIR/mnt"
  MNT_ISO="$RUN_DIR/iso"
  MNT_FAT="$RUN_DIR/fat"
  MNT_NTFS="$RUN_DIR/ntfs"
  _run mkdir -p "$RUN_DIR" "$MNT_ISO" "$MNT_FAT" "$MNT_NTFS"
  declare -r RUN_DIR MNT_ISO MNT_FAT MNT_NTFS

  if [[ "$MODE" == "main" ]]; then
    LOCKFILE="/tmp/${SCRIPT_NAME}.$(basename "$DEVICE" | tr / _).${EUID}.lock"
    exec {LOCKFD}> "$LOCKFILE"
    flock -n "$LOCKFD" || _die "Another instance of $SCRIPT_NAME is running"
  fi

  if (( LOG_LEVEL == 0 )); then
    : "${BASH_XTRACEFD:=2}"
    if printf '%(%s)T' -1 >/dev/null 2>&1; then
      export PS4='+ $(printf "%(%F %T)T" -1) $$ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]}: '
    else
      export PS4='+ ${SECONDS} $$ ${BASH_SOURCE##*/}:${LINENO}:${FUNCNAME[0]}: '
    fi
    set -x
  fi
  
  (( PRINT_CONFIG == 0 )) || _print_config
}

_is_bcp47_canonical() {
  _log info "Checking BCP-47 language tag"
  [[ $WINLANG =~ ^[a-z]{2,3}(-[A-Z][a-z]{3})?(-([A-Z]{2}|[0-9]{3}))?$ ]]
}

_expand_path() {
  local p="${1/#\~/$HOME}"
  realpath -m -- "$p" 2>/dev/null || { printf '%s\n' "$p"; _log debug "Expand path end (fallback)"; return 0; }
}

_is_nonneg_int() {
  case "$1" in 
    (''|*[!0-9]*) return 1;;
    (*) return 0;;
  esac;
}

_validate_template_inputs() {
  (( AUTOUNATTEND == 0 )) && return
  _log info "Validating autounattend inputs"
  TEMPLATE="$(_expand_path "$TEMPLATE")"
  [[ -f "$TEMPLATE" && -r "$TEMPLATE" ]] || _die "Template not readable: $TEMPLATE"
  [[ -z $WINLANG ]]         || _is_bcp47_canonical "$WINLANG"    || _die "$WINLANG is not canonical BCP-47"
  [[ -z $INSTALL_DISK_ID ]] || _is_nonneg_int "$INSTALL_DISK_ID" || _die "$INSTALL_DISK_ID is negative"
}

_validate_inputs() {
  _log info "Validating inputs"
  DEVICE="$(_expand_path "$DEVICE")"
  ISO="$(_expand_path "$ISO")"
  [[ -b "$DEVICE" ]]   || _die "Device not found: $DEVICE"
  [[ -r "$ISO" ]]      || _die "ISO not readable: $ISO"

  [[ ${#FAT_LABEL}  -le 11 ]] || _die "FAT32 label must be <= 11 chars"
  [[ ${#NTFS_LABEL} -le 32 ]] || _die "NTFS label must be <= 32 chars"

  [[ -r "$ISO" ]] || _die "ISO not readable: $ISO"
}

_refuse_system_disk() {
  local sysdev
  sysdev="$(findmnt -no SOURCE / | sed 's/[0-9]*$//')" || return

  local pk
  pk="$(lsblk -ndo PKNAME -- "$sysdev" || true)"
  if [[ -n "$pk" ]]; then sysdev="/dev/$pk"; fi

  local rm_flag
  rm_flag=$(lsblk -rno RM --nodeps -- "$DEVICE" 2>/dev/null) || rm_flag=0
  [[ -z $rm_flag ]] && rm_flag=0
  [[ "$DEVICE" != "$sysdev" ]] || _die "Refusing to operate on system disk: $DEVICE"
  [[ "$rm_flag" == "1" ]] || _log info "Warning: $DEVICE is not marked removable (RM=$rm_flag)"
}

_min_size_check() {
  local -i size_mib req_mib iso_mib
  size_mib="$(($(blockdev --getsize64 "$DEVICE")/1024/1024))"
  iso_mib="$(($(stat -c '%s' "$ISO")/1024/1024))"
  req_mib=$(( FAT_END_MIB + iso_mib + 256 ))
  (( size_mib >= req_mib )) || _die "Device too small: ${size_mib}MiB < ${req_mib}MiB"
}

_show_plan() {
  _log info "Showing plan"
  lsblk -o NAME,SIZE,RM,MODEL,MOUNTPOINT "$DEVICE" || true

  printf "\n  GPT layout: #1 FAT32 ESP (%s,%s) 1MiB..%sMiB" "$PL_FAT" "$FAT_LABEL" "$FAT_END_MIB"
  printf "\n              #2 NTFS (%s,%s) %sMiB..end\n" "$PL_NTFS" "$NTFS_LABEL" "$FAT_END_MIB"
}

_wipe_signatures() {
  _log info "Wiping signatures"
  for p in "${DEVICE}"?*; do
    [[ -e "$p" ]] || continue
    _run umount "$p" 2>/dev/null || true
  done
  _run umount "$MNT_ISO" "$MNT_FAT" "$MNT_NTFS" 2>/dev/null || true
  _run sgdisk -Z "$DEVICE"
  _run wipefs -a "$DEVICE"
}

_partition_gpt() {
  _log info "Partitioning GPT"
  _run parted -s -a optimal "$DEVICE" mklabel gpt
  _run parted -s "$DEVICE" mkpart "$PL_FAT" fat32 1MiB "${FAT_END_MIB}MiB"
  _run parted -s "$DEVICE" mkpart "$PL_NTFS" ntfs "${FAT_END_MIB}MiB" 100%
  _run parted "$DEVICE" unit B print
  _run sync
  _run blockdev --rereadpt "$DEVICE" 2>/dev/null || true
  _run partprobe "$DEVICE" 2>/dev/null || true
  _run udevadm settle 2>/dev/null || true

  if [[ "$DEVICE" =~ [0-9]$ ]]; then
    P_FAT="${DEVICE}p1"
    P_NTFS="${DEVICE}p2"
  else
    P_FAT="${DEVICE}1"
    P_NTFS="${DEVICE}2"
  fi
  _log info "Partitions ready: FAT32(ESP)=$P_FAT NTFS=$P_NTFS"
}

_format_filesystems() {
  _log info "Formatting filesystems"
  [[ -n "$P_NTFS" && -n "$P_FAT" ]] || _die "Partition nodes not set"
  _run mkfs.fat -F32 -n "$FAT_LABEL"  "$P_FAT"
  _run mkfs.ntfs -Q -L "$NTFS_LABEL" "$P_NTFS"
}

_mount_all() {
  _log info "Mounting filesystems"
  _run mount -o ro,loop,nosuid,nodev,noexec "$ISO" "$MNT_ISO"
  _run mount -o uid="$(id -u)",gid="$(id -g)",umask=022,nosuid,nodev "$P_FAT" "$MNT_FAT"
  _run mount -o uid="$(id -u)",gid="$(id -g)",umask=022,nosuid,nodev,big_writes,prealloc "$P_NTFS" "$MNT_NTFS"
}

_copy_payload() {
  _log info "Copying payload"
  _run rsync -r --info=progress2 --exclude sources --delete-before --no-perms --no-owner --no-group \
             "$MNT_ISO/" "$MNT_FAT/"

  _run mkdir -p "$MNT_FAT/sources"
  _run install -m 0644 "$MNT_ISO/sources/boot.wim" "$MNT_FAT/sources/"

  _run rsync -r --whole-file --no-inc-recursive --info=progress2 --delete-before \
             --no-perms --no-owner --no-group "$MNT_ISO/" "$MNT_NTFS/"
}

_sed_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"; s="${s//\//\\/}"; s="${s//&/\\&}"
  printf '%s' "$s"
}

_build_autounattend_sed_script() {
  local sed_script
  sed_script="$(mktemp "$TMP_DIR/autounattend.sed.XXXXXX")" || return 1

  _toggle_pi() {
    local name="$1" on="$2"
    if (( on )); then
      {
        echo "/<[?]BEGIN_${name}[?]>/d"
        echo "/<[?]END_${name}[?]>/d"
      } >>"$sed_script"
    else
      echo "/<[?]BEGIN_${name}[?]>/,/<[?]END_${name}[?]>/d" >>"$sed_script"
    fi
  }

  # Section toggles
  local on
  on=0; [[ -n ${WINLANG-}         ]] && on=1; _toggle_pi LANG           "$on"
  on=0; [[ -n ${INSTALL_DISK_ID-} ]] && on=1; _toggle_pi DISK_SELECTION "$on"
  on=0; [[ -n ${PRODUCT_KEY-}     ]] && on=1; _toggle_pi PRODUCT_KEY    "$on"
  on=0; [[ -n ${OWNER-}           ]] && on=1; _toggle_pi OWNER          "$on"
  on=0; [[ -n ${ORG-}             ]] && on=1; _toggle_pi ORG            "$on"
  on=0; [[ -n ${TIMEZONE-}        ]] && on=1; _toggle_pi TIMEZONE       "$on"
  on=0; [[ -n ${LOCAL_USER_NAME-}        \
        && -n ${LOCAL_USER_GROUP-}       \
        && -n ${LOCAL_USER_PASSWORD-}    \
        && -n ${LOCAL_USER_DISPLAYNAME-} \
        ]] && on=1; _toggle_pi LOCAL_USER "$on"
  
  _toggle_pi HWREQ_SKIP     $(( HWREQ_SKIP     ? 1 : 0 ))
  _toggle_pi OOBE_SKIP      $(( OOBE_SKIP      ? 1 : 0 ))
  _toggle_pi AUTO_LOGON     $(( AUTO_LOGON     ? 1 : 0 ))
  _toggle_pi PRIVACY_HARDEN $(( PRIVACY_HARDEN ? 1 : 0 ))

  # Placeholder substitutions
  while IFS=, read -r placeholder var; do
    [[ -z ${!var-} ]] && continue
    printf 's/%s/%s/g\n' "$placeholder" "$(_sed_escape "${!var}")" >>"$sed_script"
  done <<'EOF'
__INSTALL_DISK_ID__,INSTALL_DISK_ID
__PRODUCT_KEY__,PRODUCT_KEY
__LOCAL_USER_NAME__,LOCAL_USER_NAME
__LOCAL_USER_GROUP__,LOCAL_USER_GROUP
__LOCAL_USER_PASSWORD__,LOCAL_USER_PASSWORD
__LOCAL_USER_DISPLAYNAME__,LOCAL_USER_DISPLAYNAME
__LANG__,WINLANG
__TIMEZONE__,TIMEZONE
__OWNER__,OWNER
__ORG__,ORG
EOF

  printf '%s\n' "$sed_script"
}

_render_autounattend() {
  local sed_script tmp_out
  sed_script=$(_build_autounattend_sed_script) || return 1
  tmp_out="$(mktemp "$TMP_DIR/autounattend.XXXXXX")" || return 1

  local _x=${-//[^x]/}
  if [[ -n $_x ]]; then set +x; fi
  if (( DRY_RUN )); then
    printf '+ sed -f %q -- %q > %q\n' "$sed_script" "$TEMPLATE" "$tmp_out" >&2
  else
    sed -f "$sed_script" -- "$TEMPLATE" >"$tmp_out"
  fi
  if [[ -n $_x ]]; then set -x; fi

  local d dir
  for d in "$@"; do
    dir="${d%/*}"; [[ "$dir" == "$d" ]] && dir="."
    _run install -D -m 0644 -- "$tmp_out" "$d"
  done
}

_install_autounattend() {
  (( AUTOUNATTEND == 0 )) && return 0

  if [[ "$MODE" == "xml-only" ]]; then
    [[ -n "$AUTOUNATTEND_OUT" ]] || _die "xml-only mode requires --autounattend-out=<path>"
    _log info "Installing autounattend (xml-only)"
    local dst_local="$AUTOUNATTEND_OUT"
    _render_autounattend "$dst_local"
  else
    _log info "Installing autounattend to NTFS and FAT"
    local dst_ntfs="$MNT_NTFS/autounattend.xml"
    local dst_fat="$MNT_FAT/autounattend.xml"
    _render_autounattend "$dst_ntfs" "$dst_fat"
  fi
}

_sync_finish() {
  _log info "Syncing data"
  _run sync -f "$MNT_FAT" || true
  _run sync -f "$MNT_NTFS" || true
  _run blockdev --flushbufs "$DEVICE" 2>/dev/null || true
}

_unmount_all() {
  _log info "Unmounting filesystems"
  _run umount "$MNT_FAT" 2>/dev/null || true
  _run umount "$MNT_NTFS" 2>/dev/null || true
  _run umount "$MNT_ISO"  2>/dev/null || true
}

main() {
  _log info "Starting workflow"
  _init
  _validate_template_inputs
  _validate_inputs
  _refuse_system_disk
  _min_size_check
  _show_plan

  if ! _confirm "This will ERASE all data on $DEVICE. Continue?"; then
    _die "Aborted by user."
  fi

  _wipe_signatures
  _partition_gpt
  _format_filesystems
  _mount_all
  _copy_payload
  _install_autounattend
  _sync_finish
  _unmount_all

  _log info "Done. You can safely remove the USB."
  return 0
}

main_xml_only() {
  _log info "Starting workflow (XML-only)"
  _init
  _validate_template_inputs
  _install_autounattend

  return 0
}

###############################################################################
# Program entry
###############################################################################

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  _parse_args "$@"
  _normalize_bools
  _normalize_loglevel
  _normalize_mode
  _check_required_commands

  declare -ri LOG_LEVEL NON_INTERACTIVE DRY_RUN

  trap -- _on_err  ERR
  trap -- _on_exit EXIT INT TERM

  case "$MODE" in
    main)
      (( EUID == 0 )) || _die "Run as root: sudo -E $SCRIPT_NAME ..."
      main "${POSITIONALS[@]}"
      ;;
    xml-only)
      main_xml_only "${POSITIONALS[@]}"
      ;;
  esac
fi

