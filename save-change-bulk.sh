#!/bin/bash
# =============================================================
#  save-change-bulk.sh
#  Bulk Save Changes — LiteSpeed Cache
#  Version : 1.0.1
#  Note    : ปรับปรุงการค้นหา Scan cPanel ให้เจอทุก Account
# =============================================================

LOG_FILE="/var/log/lscwp-save-changes-bulk.log"
LOCK_FILE="${LOG_FILE}.lock"
RESULT_DIR="/tmp/lscwp-save-bulk-$$"
RAM_PER_JOB_MB=200
WP_TIMEOUT=30

log() {
    local DATE=$(date '+%Y-%m-%d %H:%M:%S')
    echo "$1"
    ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
}

cleanup() {
    wait
    rm -rf "$RESULT_DIR"
    rm -f "$LOCK_FILE"
}
trap cleanup EXIT

mkdir -p "$RESULT_DIR"
START_TIME=$(date +%s)

if ! command -v wp &>/dev/null; then
    log "❌ ERROR: ไม่พบ WP-CLI"
    exit 1
fi

CPU_CORES=$(nproc)
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
MAX_JOBS_BY_RAM=$(( TOTAL_RAM_MB / RAM_PER_JOB_MB ))

if [ "$CPU_CORES" -lt "$MAX_JOBS_BY_RAM" ]; then
    MAX_JOBS=$CPU_CORES
else
    MAX_JOBS=$MAX_JOBS_BY_RAM
fi

[ "$MAX_JOBS" -lt 1 ] && MAX_JOBS=1
[ "$MAX_JOBS" -gt 20 ] && MAX_JOBS=20

log "======================================"
log " BULK SAVE CHANGES (LiteSpeed Cache)"
log " เริ่มเวลา      : $(date '+%Y-%m-%d %H:%M:%S')"
log " Auto MAX_JOBS : $MAX_JOBS"
log "======================================"

# ─── ค้นหา WordPress ทุกเว็บ (เหมือน cloudflare script) ──────
declare -A _SEEN
DIRS=()

# แหล่งที่ 1: WHM — /etc/trueuserdomains
if [[ -f /etc/trueuserdomains ]]; then
    while IFS=' ' read -r _dom _usr _rest; do
        _usr="${_usr%:}"
        [[ -z "$_usr" ]] && continue
        _uhome=$(getent passwd "$_usr" 2>/dev/null | cut -d: -f6)
        [[ -d "$_uhome" ]] || continue
        while IFS= read -r -d '' _wpc; do
            _d="$(dirname "$_wpc")/"
            [[ -z "${_SEEN[$_d]+_}" ]] && { _SEEN[$_d]=1; DIRS+=("$_d"); }
        done < <(find "$_uhome" -maxdepth 5 -name "wp-config.php" -print0 2>/dev/null)
    done < /etc/trueuserdomains
fi

# แหล่งที่ 2: Scan /home /home2 /home3 /home4 /home5 /usr/home
for _base in /home /home2 /home3 /home4 /home5 /usr/home; do
    [[ -d "$_base" ]] || continue
    while IFS= read -r -d '' _wpc; do
        _d="$(dirname "$_wpc")/"
        [[ -z "${_SEEN[$_d]+_}" ]] && { _SEEN[$_d]=1; DIRS+=("$_d"); }
    done < <(find "$_base" -maxdepth 5 -name "wp-config.php" -print0 2>/dev/null)
done

TOTAL=${#DIRS[@]}
log "พบ WordPress ทั้งหมด: $TOTAL เว็บ"
log "======================================"

save_site() {
    local dir="$1"
    local COUNT="$2"
    local TOTAL="$3"
    local SITE UNIQ
    SITE=$(echo "$dir" | sed 's|/home[0-9]*/||;s|/$||')
    UNIQ="${BASHPID}_$(date +%s%N)"
    local LABEL="[$COUNT/$TOTAL] $SITE"

    [[ "$dir" =~ /public_html/$ ]] && return

    _log() {
        local DATE=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$1"
        ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
    }

    local _wp
    _wp() {
        timeout "$WP_TIMEOUT" wp --path="$dir" "$@" --allow-root 2>/dev/null
    }

    if [ ! -d "$RESULT_DIR" ]; then return; fi

    # เช็ค Plugin Active ไหม
    if ! _wp plugin is-active litespeed-cache; then
        _log "⏭  SKIP (LiteSpeed ไม่ Active): $LABEL"
        touch "${RESULT_DIR}/skipped_${UNIQ}" 2>/dev/null
        return
    fi

    # Trigger LiteSpeed เหมือนกด Save Changes + Purge
    if _wp litespeed-option set cache 1; then
        _wp litespeed-purge all 2>/dev/null
        _log "✅ Done: $LABEL"
        touch "${RESULT_DIR}/success_${UNIQ}" 2>/dev/null
    else
        _log "❌ FAILED: $LABEL"
        touch "${RESULT_DIR}/failed_${UNIQ}" 2>/dev/null
    fi
}

export -f save_site
export LOG_FILE LOCK_FILE RESULT_DIR WP_TIMEOUT

declare -a PIDS=()
COUNT=0
for dir in "${DIRS[@]}"; do
    COUNT=$(( COUNT + 1 ))
    save_site "$dir" "$COUNT" "$TOTAL" &
    PIDS+=($!)
    if (( ${#PIDS[@]} >= MAX_JOBS )); then
        wait "${PIDS[0]}"
        PIDS=("${PIDS[@]:1}")
    fi
done
for pid in "${PIDS[@]}"; do wait "$pid"; done

END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

SUCCESS=$(find "$RESULT_DIR" -name "success_*" 2>/dev/null | wc -l)
FAILED=$(find "$RESULT_DIR" -name "failed_*" 2>/dev/null | wc -l)
SKIPPED=$(find "$RESULT_DIR" -name "skipped_*" 2>/dev/null | wc -l)

log "======================================"
log " สรุปผลรวม"
log " รวมทั้งหมด   : $TOTAL เว็บ"
log " ✅ สำเร็จ     : $SUCCESS เว็บ"
log " ❌ ไม่สำเร็จ  : $FAILED เว็บ"
log " ⏭  ข้าม       : $SKIPPED เว็บ"
log " เวลาที่ใช้    : $(( ELAPSED / 60 )) นาที $(( ELAPSED % 60 )) วินาที"
log " Log อยู่ที่   : $LOG_FILE"
log "======================================"
