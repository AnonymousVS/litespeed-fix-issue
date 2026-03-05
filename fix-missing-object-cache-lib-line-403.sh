#!/bin/bash

LOG_FILE="/var/log/lscwp-fix-objcache-lib.log"
LOCK_FILE="${LOG_FILE}.lock"
RESULT_DIR="/tmp/lscwp-fix-lib-$$"
RAM_PER_JOB_MB=200
WP_TIMEOUT=120

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

# ====================================
# เช็ค WP-CLI
# ====================================
if ! command -v wp &>/dev/null; then
    log "❌ ERROR: ไม่พบ WP-CLI กรุณาติดตั้งก่อน"
    exit 1
fi

# ====================================
# คำนวณ MAX_JOBS อัตโนมัติ
# ====================================
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
log " FIX MISSING object-cache.php /lib/"
log " (LiteSpeed object-cache.cls.php:403)"
log " เริ่มเวลา      : $(date '+%Y-%m-%d %H:%M:%S')"
log " CPU Cores     : $CPU_CORES Core"
log " Total RAM     : $TOTAL_RAM_MB MB"
log " Auto MAX_JOBS : $MAX_JOBS"
log " WP Timeout    : $WP_TIMEOUT วินาที"
log "======================================"

# ====================================
# หา WordPress ทั้งหมด
# ====================================
DIRS=()
for dir in /home/*/public_html/*/; do
    if [ -f "${dir}wp-config.php" ]; then
        DIRS+=("$dir")
    fi
done

TOTAL=${#DIRS[@]}
log "พบ WordPress ทั้งหมด: $TOTAL เว็บ"
log "======================================"

# ====================================
# เช็ค + แก้ไขในฟังก์ชันเดียว
# ====================================
process_site() {
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

    if [ ! -d "$RESULT_DIR" ]; then return; fi

    local PLUGIN_DIR="${dir}wp-content/plugins/litespeed-cache"
    local LIB_FILE="${PLUGIN_DIR}/lib/object-cache.php"

    # ====================================
    # เช็ค Plugin มีอยู่ไหม
    # ====================================
    if [ ! -d "$PLUGIN_DIR" ]; then
        _log "⏭  NO LITESPEED: $SITE"
        touch "${RESULT_DIR}/skipped_${UNIQUE}" 2>/dev/null
        return
    fi

    # ====================================
    # เช็คไฟล์ ถ้าครบ → ข้ามไป
    # ====================================
    if [ -f "$LIB_FILE" ]; then
        _log "✅ OK (ไม่ต้องแก้): $SITE"
        touch "${RESULT_DIR}/ok_${UNIQUE}" 2>/dev/null
        return
    fi

    # ====================================
    # ไฟล์หาย → แก้ไขทันที
    # ====================================
    _log "❌ MISSING → กำลังแก้ไข: $SITE"

    # ดึง Owner
    local OWNER
    OWNER=$(stat -c '%U:%G' "${dir}wp-config.php" 2>/dev/null)
    if [ -z "$OWNER" ]; then
        _log "❌ FAILED (ไม่พบ Owner): $SITE"
        touch "${RESULT_DIR}/failed_${UNIQUE}" 2>/dev/null
        return
    fi

    # Deactivate
    timeout "$WP_TIMEOUT" wp --path="$dir" plugin deactivate litespeed-cache \
        --allow-root 2>/dev/null
    _log "   [$SITE] Deactivated"

    # Delete
    if ! timeout "$WP_TIMEOUT" wp --path="$dir" plugin delete litespeed-cache \
        --allow-root 2>/dev/null; then
        _log "❌ FAILED (Delete ไม่สำเร็จ): $SITE"
        touch "${RESULT_DIR}/failed_${UNIQUE}" 2>/dev/null
        return
    fi
    _log "   [$SITE] Deleted"

    # Install + Activate
    if ! timeout "$WP_TIMEOUT" wp --path="$dir" plugin install litespeed-cache \
        --activate --allow-root 2>/dev/null; then
        _log "❌ FAILED (Install ไม่สำเร็จ): $SITE"
        touch "${RESULT_DIR}/failed_${UNIQUE}" 2>/dev/null
        return
    fi
    _log "   [$SITE] Installed"

    # แก้ Owner
    chown -R "$OWNER" "${PLUGIN_DIR}/" 2>/dev/null

    # Verify
    if [ -f "$LIB_FILE" ]; then
        _log "✅ FIXED: $SITE"
        touch "${RESULT_DIR}/success_${UNIQUE}" 2>/dev/null
    else
        _log "❌ VERIFY FAILED (ไฟล์ยังหายอยู่): $SITE"
        touch "${RESULT_DIR}/failed_${UNIQUE}" 2>/dev/null
    fi
}

export -f process_site

# ====================================
# Parallel Sliding Window
# ====================================
declare -a PIDS=()
for dir in "${DIRS[@]}"; do
    process_site "$dir" "$LOG_FILE" "$LOCK_FILE" "$RESULT_DIR" "$WP_TIMEOUT" &
    PIDS+=($!)
    if [ "${#PIDS[@]}" -ge "$MAX_JOBS" ]; then
        wait "${PIDS[0]}"
        PIDS=("${PIDS[@]:1}")
    fi
done
for pid in "${PIDS[@]}"; do wait "$pid"; done

# ====================================
# คำนวณเวลารวม
# ====================================
END_TIME=$(date +%s)
ELAPSED=$(( END_TIME - START_TIME ))

OK=$(find "$RESULT_DIR" -name "ok_*" 2>/dev/null | wc -l)
SUCCESS=$(find "$RESULT_DIR" -name "success_*" 2>/dev/null | wc -l)
FAILED=$(find "$RESULT_DIR" -name "failed_*" 2>/dev/null | wc -l)
SKIPPED=$(find "$RESULT_DIR" -name "skipped_*" 2>/dev/null | wc -l)

log "======================================"
log " สรุปผลรวม"
log " รวมทั้งหมด         : $TOTAL เว็บ"
log " ✅ ไฟล์ครบอยู่แล้ว  : $OK เว็บ"
log " ✅ แก้ไขสำเร็จ      : $SUCCESS เว็บ"
log " ❌ แก้ไขไม่สำเร็จ   : $FAILED เว็บ"
log " ⏭  ไม่มี LiteSpeed  : $SKIPPED เว็บ"
log " เวลาที่ใช้          : $(( ELAPSED / 60 )) นาที $(( ELAPSED % 60 )) วินาที"
log " Log อยู่ที่         : $LOG_FILE"
log "======================================"

if [ "$SUCCESS" -gt 0 ]; then
    log "======================================"
    log " ⚠️  สำคัญ: Plugin ถูก Reinstall แล้ว"
    log " ⚠️  Settings ถูก Reset กลับเป็นค่า Default"
    log " ⚠️  ต้องรัน Setup Object Cache ใหม่ทันที:"
    log " curl -s https://raw.githubusercontent.com/ufavision/server-scripts/main/litespeed/setup-object-cache.sh | bash"
    log "======================================"
fi
```

