#!/bin/bash

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

DIRS=()
for dir in /home/*/public_html/*/; do
    if [ -f "${dir}wp-config.php" ]; then
        DIRS+=("$dir")
    fi
done

TOTAL=${#DIRS[@]}
log "พบ WordPress ทั้งหมด: $TOTAL เว็บ"
log "======================================"

save_site() {
    local dir="$1"
    local LOG_FILE="$2"
    local LOCK_FILE="$3"
    local RESULT_DIR="$4"
    local WP_TIMEOUT="$5"
    local SITE=$(echo "$dir" | awk -F'/' '{print $5"/"$7}')
    local UNIQUE="${BASHPID}_$(date +%s%N)"

    _log() {
        local DATE=$(date '+%Y-%m-%d %H:%M:%S')
        echo "$1"
        ( flock 200; echo "[$DATE] $1" >> "$LOG_FILE" ) 200>"$LOCK_FILE"
    }

    _wp() {
        timeout "$WP_TIMEOUT" wp --path="$dir" "$@" --allow-root 2>/dev/null
    }

    if [ ! -d "$RESULT_DIR" ]; then return; fi

    # เช็ค Plugin Active ไหม
    if ! _wp plugin is-active litespeed-cache; then
        _log "⏭  SKIP (LiteSpeed ไม่ Active): $SITE"
        touch "${RESULT_DIR}/skipped_${UNIQUE}" 2>/dev/null
        return
    fi

    # ✅ Trigger LiteSpeed เหมือนกด Save Changes ในหน้า LiteSpeed Settings
    if _wp litespeed-option set cache 1; then
        _wp litespeed-purge all 2>/dev/null
        _log "✅ Done: $SITE"
        touch "${RESULT_DIR}/success_${UNIQUE}" 2>/dev/null
    else
        _log "❌ FAILED: $SITE"
        touch "${RESULT_DIR}/failed_${UNIQUE}" 2>/dev/null
    fi
}

export -f save_site

declare -a PIDS=()
for dir in "${DIRS[@]}"; do
    save_site "$dir" "$LOG_FILE" "$LOCK_FILE" "$RESULT_DIR" "$WP_TIMEOUT" &
    PIDS+=($!)
    if [ "${#PIDS[@]}" -ge "$MAX_JOBS" ]; then
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
