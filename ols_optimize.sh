#!/usr/bin/env bash
# OpenLiteSpeed Optimizer - CORRECTED AND STABILIZED VERSION
# Combines optimizations from new script with security protections from old one
# 
# APPLIED CORRECTIONS:
# ✓ Fixed configure_ssl_listeners() function (was incomplete)
# ✓ Restored integrity validation (validate_config_integrity)
# ✓ Atomic operations on temporary files (.working/.tmp)
# ✓ Pre-SSL backup with automatic rollback
# ✓ Additional validations at each critical stage
# ✓ Protection against file corruption
#
# Date: 2025-11-04
# Author: WebDigHost - Stabilized Version

set -euo pipefail
IFS=$'\n\t'

# =======================
# EDITABLE CONFIGURATION
# =======================

SERVER_NAME="your.host.name"
ADMIN_EMAILS="mail@host.name"
HTTPD_WORKERS="16"
CPU_AFFINITY="1"
ENABLE_LVE="0"
IN_MEM_BUF_SIZE="384M"  # Reduced from 512M for greater stability

# Tuning - Conservative values for stability
MAX_CONNECTIONS="100000"
MAX_SSL_CONNECTIONS="100000"
SND_BUF_SIZE="512k"
RCV_BUF_SIZE="512k"
TOTAL_IN_MEM_CACHE_SIZE="512M"
MAX_MMAP_FILE_SIZE="64M"
TOTAL_MMAP_CACHE_SIZE="512M"
USE_AIO="3"         # 0=off, 1=libaio, 2=posix, 3=io_uring
AIO_BLOCK_SIZE="3"  # 0=64K, 1=128K, 2=256K, 3=512K, 4=1M

# Logs
LOG_LEVEL="NOTICE"
LOG_ROLLING_SIZE="500"       # MB (access log)
LOG_KEEP_DAYS="14"
ERROR_LOG_ROLLING_SIZE="100" # MB (error log)

# SSL (applied to LISTENERS)
TLS_PROTOCOLS="13,12"        # TLS 1.3 and 1.2

# Base paths
CONFIG_PATH="/usr/local/lsws/conf/httpd_config.conf"
BACKUP_DIR="/usr/local/lsws/conf/backups"
LOG_FILE="/var/log/ols_optimizer.log"
MD5_FILE="/usr/local/lsws/conf/.ols_config_md5sum"
LOCK_FILE="/tmp/ols_optimize.lock"

# =======================
# HELPER FUNCTIONS
# =======================

log_msg() {
  local msg="$1"
  echo "$msg"
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$msg" >> "$LOG_FILE"
}

acquire_lock() {
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    log_msg "[!] Script already running - aborted"
    exit 0
  fi
}

check_requirements() {
  if [ "$(id -u)" -ne 0 ]; then
    log_msg "[!] This script must be run as root"
    exit 1
  fi
  if ! command -v flock >/dev/null 2>&1; then
    log_msg "[!] 'flock' not found. Install: apt-get install -y util-linux"
    exit 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    log_msg "[!] Configuration file not found: $CONFIG_PATH"
    exit 1
  fi
  if ! command -v /usr/local/lsws/bin/lswsctrl &>/dev/null; then
    log_msg "[!] OpenLiteSpeed not found"
    exit 1
  fi
  mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"
  : > "$LOG_FILE" || true
}

detect_cpu_cores() {
  if [ "$HTTPD_WORKERS" = "auto" ]; then
    HTTPD_WORKERS=$(nproc)
    log_msg "[i] Auto-detected $HTTPD_WORKERS CPU cores"
  fi
}

adjust_by_ram() {
  local total_ram_gb
  total_ram_gb=$(free -g | awk '/^Mem:/{print $2}')
  total_ram_gb=${total_ram_gb:-0}
  
  if [ "$HTTPD_WORKERS" = "auto" ]; then
    HTTPD_WORKERS=$(nproc)
  fi
  
  if [ "$total_ram_gb" -lt 4 ]; then
    log_msg "[!] RAM < 4GB — adjusting conservative values..."
    if [ "$HTTPD_WORKERS" -gt 8 ]; then HTTPD_WORKERS=8; fi
    IN_MEM_BUF_SIZE="256M"
    TOTAL_IN_MEM_CACHE_SIZE="256M"
    TOTAL_MMAP_CACHE_SIZE="256M"
  elif [ "$total_ram_gb" -lt 8 ]; then
    log_msg "[i] RAM ${total_ram_gb}GB — moderate values"
    if [ "$HTTPD_WORKERS" -gt 12 ]; then HTTPD_WORKERS=12; fi
    IN_MEM_BUF_SIZE="384M"
  else
    log_msg "[i] RAM ${total_ram_gb}GB — maximum values OK"
    if [ "$HTTPD_WORKERS" -gt 16 ]; then HTTPD_WORKERS=16; fi
  fi
}

check_io_uring() {
  if [ "$USE_AIO" = "3" ]; then
    if ! grep -q io_uring /proc/filesystems 2>/dev/null; then
      log_msg "[!] io_uring not available — using libaio (1)"
      USE_AIO="1"
    else
      log_msg "[+] io_uring available and active"
    fi
  fi
}

configure_kernel_limits() {
  log_msg "[*] Configuring kernel limits..."
  local dropin="/etc/sysctl.d/99-ols.conf"
  mkdir -p /etc/sysctl.d
  cat > "$dropin" <<'EOF'
net.core.somaxconn = 65535
fs.file-max = 2097152
EOF
  sysctl -w net.core.somaxconn=65535 >/dev/null || true
  sysctl -w fs.file-max=2097152      >/dev/null || true
  sysctl --system >/dev/null 2>&1 || true
  ulimit -n 200000 2>/dev/null || true
  log_msg "[+] Kernel tunables applied (persisted in $dropin)"
}

# ✅ RESTORED: Critical integrity validation
validate_config_integrity() {
  log_msg "[*] Validating configuration integrity..."
  
  # Check balanced braces
  local open_count close_count
  open_count=$(grep -o '{' "$CONFIG_PATH" | wc -l)
  close_count=$(grep -o '}' "$CONFIG_PATH" | wc -l)
  
  if [ "$open_count" -ne "$close_count" ]; then
    log_msg "[!] CRITICAL: Unbalanced braces (open: $open_count, close: $close_count)"
    return 1
  fi
  
  # Check minimum file size (should be at least 1KB)
  local file_size
  file_size=$(stat -c%s "$CONFIG_PATH")
  if [ "$file_size" -lt 1024 ]; then
    log_msg "[!] CRITICAL: Configuration file too small ($file_size bytes)"
    return 1
  fi
  
  # Check for at least one listener
  if ! grep -q "listener" "$CONFIG_PATH"; then
    log_msg "[!] WARNING: No listener blocks found in configuration"
  fi
  
  log_msg "[+] Integrity validation passed"
  return 0
}

create_backup() {
  local backup_file="$BACKUP_DIR/httpd_config_$(date +'%Y%m%d-%H%M%S').conf"
  cp -a "$CONFIG_PATH" "$backup_file"
  log_msg "[+] Backup created: $backup_file"
  
  # Keep only the last 10 backups
  find "$BACKUP_DIR" -name "httpd_config_*.conf" -type f -printf '%T@ %p\0' 2>/dev/null \
    | sort -zrn \
    | tail -zn +11 \
    | cut -zd' ' -f2- \
    | xargs -0 -r rm -f || true
  
  echo "$backup_file"
}

# =======================
# EDITING (ATOMIC OPERATIONS)
# =======================

set_top() {
  local key="$1" val="$2"
  [ -z "$val" ] && return 0
  
  if grep -qE "^[[:space:]]*${key}[[:space:]]+" "$CONFIG_PATH"; then
    sed -E -i "s|^[[:space:]]*${key}[[:space:]]+.*|${key}                ${val}|" "$CONFIG_PATH"
  else
    sed -i "1i ${key}                ${val}" "$CONFIG_PATH"
  fi
  log_msg "[=] ${key} => ${val}"
}

# ✅ RESTORED: Safe version with atomic operations
update_block_kv() {
  local block="$1"
  local key="$2"
  local val="$3"
  local label="${4:-}"
  [ -z "$val" ] && return 0

  # Use temporary file for atomic operation
  awk -v blk="$block" -v k="$key" -v v="$val" '
    BEGIN{inblk=0; depth=0; updated=0}
    {
      line=$0
      if (!inblk) {
        if (line ~ "^[ \t]*" blk "[ \t]*\\{") {
          inblk=1; depth=1; updated=0
          print line; next
        } else { print line; next }
      } else {
        oc=gsub(/\{/,"{",line); cc=gsub(/\}/,"}",line); depth += (oc-cc)
        if (line ~ "^[ \t]*" k "[ \t]+") {
          sub("^[ \t]*" k "[ \t]+.*$", "  " k "              " v, line)
          updated=1
          print line
          if (depth<=0){ inblk=0 }
          next
        }
        if (depth<=0) {
          if (!updated) { print "  " k "              " v }
          print line
          inblk=0; updated=0
          next
        }
        print line
      }
    }' "$CONFIG_PATH" > "${CONFIG_PATH}.tmp"

  # Check if temporary file was created successfully
  if [ ! -f "${CONFIG_PATH}.tmp" ]; then
    log_msg "[!] ERROR: Failed to create temporary file"
    return 1
  fi

  mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

  if [ -n "$label" ]; then
    log_msg "[=] ${label} => ${val}"
  else
    log_msg "[=] ${block}.${key} => ${val}"
  fi
}

# =======================
# SSL LISTENERS (TLS only)
# =======================

get_secure_listener_ranges() {
  awk '
    BEGIN { inblk=0; pending=0; start=0; depth=0; hassecure=0 }
    {
      line=$0
      if (!inblk) {
        if (line ~ /^[ \t]*listener[ \t]/) {
          pending=1
          if (line ~ /{/) {
            inblk=1; start=NR; depth=0; hassecure=0
            oc=gsub(/{/,"{",line); cc=gsub(/}/,"}",line); depth += (oc-cc)
            next
          }
        }
        if (pending && line ~ /{/) {
          inblk=1; start=NR; depth=0; hassecure=0
          oc=gsub(/{/,"{",line); cc=gsub(/}/,"}",line); depth += (oc-cc)
          pending=0
          next
        }
      } else {
        if (line ~ /(^|[ \t])secure[ \t]+1([ \t]|$)/) { hassecure=1 }
        oc=gsub(/{/,"{",line); cc=gsub(/}/,"}",line); depth += (oc-cc)
        if (depth <= 0) {
          if (hassecure) { printf "%d,%d\n", start, NR }
          inblk=0; hassecure=0; start=0; depth=0
        }
      }
    }
  ' "$CONFIG_PATH"
}

# ✅ FIXED: Safe version with atomic operations
set_listener_ssl_param() {
  local key="$1"
  local val="$2"
  [ -z "$val" ] && return 0
  
  local ranges
  ranges="$(get_secure_listener_ranges || true)"
  if [ -z "${ranges:-}" ]; then
    log_msg "[i] No SSL listener (secure 1) found — ignoring '${key}'."
    return 0
  fi
  
  # Create working copy
  cp "$CONFIG_PATH" "${CONFIG_PATH}.working"
  
  printf '%s\n' "$ranges" | while IFS=, read -r _start _end; do
    [ -z "$_start" ] || [ -z "$_end" ] && continue
    
    # Use awk for safe range-based editing
    awk -v s="$_start" -v e="$_end" -v k="$key" -v v="$val" '
      BEGIN { found=0 }
      {
        if (NR >= s && NR <= e) {
          if ($0 ~ "^[[:space:]]*" k "[[:space:]]+") {
            sub("^[[:space:]]*" k "[[:space:]]+.*", "  " k "              " v)
            found=1
          } else if (NR == e && $0 ~ /^[[:space:]]*}[[:space:]]*$/ && !found) {
            print "  " k "              " v
            found=1
          }
        }
        print
      }
    ' "${CONFIG_PATH}.working" > "${CONFIG_PATH}.working.tmp"
    
    if [ -f "${CONFIG_PATH}.working.tmp" ]; then
      mv "${CONFIG_PATH}.working.tmp" "${CONFIG_PATH}.working"
      log_msg "[=] listener.ssl ${key} => ${val} (lines ${_start}-${_end})"
    fi
  done
  
  # Apply changes atomically
  if [ -f "${CONFIG_PATH}.working" ]; then
    mv "${CONFIG_PATH}.working" "$CONFIG_PATH"
  fi
}

# ✅ FIXED: Safe version
strip_listener_ssl_keys() {
  local ranges
  ranges="$(get_secure_listener_ranges || true)"
  [ -z "${ranges:-}" ] && return 0
  
  # Create working copy
  cp "$CONFIG_PATH" "${CONFIG_PATH}.working"
  
  printf '%s\n' "$ranges" | while IFS=, read -r _start _end; do
    [ -z "$_start" ] || [ -z "$_end" ] && continue
    
    # Use awk to safely remove lines
    awk -v s="$_start" -v e="$_end" '
      {
        if (NR >= s && NR <= e) {
          if ($0 !~ /^[[:space:]]*(sslCert|sslKey|sslCertChain)[[:space:]]+/) {
            print
          }
        } else {
          print
        }
      }
    ' "${CONFIG_PATH}.working" > "${CONFIG_PATH}.working.tmp"
    
    if [ -f "${CONFIG_PATH}.working.tmp" ]; then
      mv "${CONFIG_PATH}.working.tmp" "${CONFIG_PATH}.working"
      log_msg "[=] listener.ssl cleared sslCert/sslKey/sslCertChain (lines ${_start}-${_end})"
    fi
  done
  
  # Apply changes atomically
  if [ -f "${CONFIG_PATH}.working" ]; then
    mv "${CONFIG_PATH}.working" "$CONFIG_PATH"
  fi
}

# ✅ FIXED: Function was incomplete in the new script!
configure_ssl_listeners() {
  log_msg "[*] Configuring TLS on SSL listeners..."
  
  # ✅ RESTORED: Backup before SSL changes
  cp "$CONFIG_PATH" "${CONFIG_PATH}.pre-ssl-backup"
  
  strip_listener_ssl_keys
  set_listener_ssl_param "sslProtocol" "${TLS_PROTOCOLS}"
  
  # ✅ RESTORED: Validate after SSL changes
  if ! validate_config_integrity; then
    log_msg "[!] Validation failed after SSL changes - rolling back"
    cp "${CONFIG_PATH}.pre-ssl-backup" "$CONFIG_PATH"
    log_msg "[!] SSL listener configuration skipped due to validation failure"
  else
    log_msg "[+] SSL listener configuration validated successfully"
    rm -f "${CONFIG_PATH}.pre-ssl-backup"
  fi
}

rollback() {
  local backup_file="$1"
  log_msg "[!] Rolling back to backup: $backup_file"
  cp -a "$backup_file" "$CONFIG_PATH"
  /usr/local/lsws/bin/lswsctrl restart >/dev/null 2>&1 || true
  log_msg "[!] Previous configuration restored"
}

# =======================
# MAIN
# =======================

main() {
  log_msg "========================================="
  log_msg "[*] OLS Optimizer - CORRECTED VERSION"
  log_msg "========================================="

  acquire_lock
  check_requirements

  local cur_md5=""
  if [ -f "$CONFIG_PATH" ]; then
    cur_md5=$(md5sum "$CONFIG_PATH" | awk '{print $1}')
  fi

  detect_cpu_cores
  adjust_by_ram
  check_io_uring
  configure_kernel_limits

  local backup_file
  backup_file=$(create_backup)

  # ✅ Initial validation
  if ! validate_config_integrity; then
    log_msg "[!] Configuration file corrupted BEFORE changes!"
    log_msg "[!] Aborting to prevent further damage"
    exit 1
  fi

  # Top-level
  log_msg "[*] Applying top-level settings..."
  set_top "serverName"   "$SERVER_NAME"
  set_top "adminEmails"  "$ADMIN_EMAILS"
  set_top "httpdWorkers" "$HTTPD_WORKERS"
  set_top "cpuAffinity"  "$CPU_AFFINITY"
  set_top "enableLVE"    "$ENABLE_LVE"
  set_top "inMemBufSize" "$IN_MEM_BUF_SIZE"

  # ✅ Validation after top-level
  if ! validate_config_integrity; then
    log_msg "[!] Configuration corrupted after top-level changes"
    rollback "$backup_file"
    exit 1
  fi

  # Logs
  log_msg "[*] Configuring logging..."
  update_block_kv "errorlog[ \t]+logs/error[.]log"   "logLevel"        "$LOG_LEVEL"                  "errorlog.logLevel"
  update_block_kv "errorlog[ \t]+logs/error[.]log"   "rollingSize"     "${ERROR_LOG_ROLLING_SIZE}M"  "errorlog.rollingSize"
  update_block_kv "accesslog[ \t]+logs/access[.]log" "rollingSize"     "${LOG_ROLLING_SIZE}M"        "accesslog.rollingSize"
  update_block_kv "accesslog[ \t]+logs/access[.]log" "keepDays"        "$LOG_KEEP_DAYS"              "accesslog.keepDays"
  update_block_kv "accesslog[ \t]+logs/access[.]log" "compressArchive" "1"                           "accesslog.compressArchive"

  # ✅ Validation after logs
  if ! validate_config_integrity; then
    log_msg "[!] Configuration corrupted after logging changes"
    rollback "$backup_file"
    exit 1
  fi

  # Tuning
  log_msg "[*] Applying tuning..."
  update_block_kv "tuning" "maxConnections"      "$MAX_CONNECTIONS"         "tuning.maxConnections"
  update_block_kv "tuning" "maxSSLConnections"   "$MAX_SSL_CONNECTIONS"     "tuning.maxSSLConnections"
  update_block_kv "tuning" "sndBufSize"          "$SND_BUF_SIZE"            "tuning.sndBufSize"
  update_block_kv "tuning" "rcvBufSize"          "$RCV_BUF_SIZE"            "tuning.rcvBufSize"
  update_block_kv "tuning" "totalInMemCacheSize" "$TOTAL_IN_MEM_CACHE_SIZE" "tuning.totalInMemCacheSize"
  update_block_kv "tuning" "maxMMapFileSize"     "$MAX_MMAP_FILE_SIZE"      "tuning.maxMMapFileSize"
  update_block_kv "tuning" "totalMMapCacheSize"  "$TOTAL_MMAP_CACHE_SIZE"   "tuning.totalMMapCacheSize"
  update_block_kv "tuning" "useAIO"              "$USE_AIO"                 "tuning.useAIO"
  update_block_kv "tuning" "AIOBlockSize"        "$AIO_BLOCK_SIZE"          "tuning.AIOBlockSize"

  # ✅ Validation after tuning
  if ! validate_config_integrity; then
    log_msg "[!] Configuration corrupted after tuning changes"
    rollback "$backup_file"
    exit 1
  fi

  # SSL — TLS policy on listeners only
  configure_ssl_listeners

  # ✅ Final validation
  if ! validate_config_integrity; then
    log_msg "[!] Final validation failed after all changes"
    rollback "$backup_file"
    exit 1
  fi

  # Validate and restart if changed
  local new_md5
  new_md5=$(md5sum "$CONFIG_PATH" | awk '{print $1}')
  
  if [ "${cur_md5:-}" = "${new_md5:-}" ]; then
    log_msg "[i] No effective changes (MD5 equal). Restart not required."
  else
    log_msg "[*] Changes detected. Diff (first lines):"
    diff -u "$backup_file" "$CONFIG_PATH" 2>/dev/null | grep "^[+-]" | grep -v "^[+-][+-]" | head -n 30 || true
    
    log_msg "[*] Restarting OpenLiteSpeed..."
    if ! /usr/local/lsws/bin/lswsctrl restart; then
      log_msg "[!] Restart failed!"
      rollback "$backup_file"
      exit 1
    fi
    
    echo "$new_md5" > "$MD5_FILE"
    log_msg "[+] OpenLiteSpeed restarted successfully"
  fi

  # Final info
  log_msg "[i] ========================================="
  log_msg "[i] PHP configuration (lsphp):"
  local php_children
  php_children=$(sed -n '/^extprocessor[[:space:]]\+lsphp[[:space:]]*{/,/^}/p' "$CONFIG_PATH" \
    | awk '/env[[:space:]]+PHP_LSAPI_CHILDREN=/{sub(/^.*=/,""); pc=$0} /maxConns[[:space:]]+/{mc=$2} END{ if(pc!="")print pc; else if(mc!="")print "via maxConns="mc; else print "default" }')
  log_msg "[i] - Children/Conns: $php_children"
  log_msg "[i] - Adjust in: Enhance > Packages > PHP (if needed)"
  log_msg "[i] ========================================="
  log_msg "[✓] OLS Optimizer - Completed safely"
  log_msg "========================================="
}

main "$@"
