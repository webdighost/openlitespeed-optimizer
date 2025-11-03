#!/usr/bin/env bash
# OpenLiteSpeed Optimizer (Ubuntu + systemd) - CORRECTED VERSION
# - Idempotent config edits via AWK
# - Backup + MD5 guard
# - Graceful restart only on real changes
# - Auto rollback on failure
# - Kernel tuning drop-in (/etc/sysctl.d/99-ols.conf)
# - io_uring auto-detect (fallback to libaio)
# - TLS policy only on SSL listeners
# - Clear logs
# NOTE: ASCII-only, UNIX line endings, bash required.

set -euo pipefail
IFS=$'\n\t'

# =======================
# FIXED CONFIG
# =======================
SERVER_NAME="your.host.name"
ADMIN_EMAILS="mail@host.name"
HTTPD_WORKERS="16"
CPU_AFFINITY="1"
ENABLE_LVE="0"
IN_MEM_BUF_SIZE="384M"

MAX_CONNECTIONS="100000"
MAX_SSL_CONNECTIONS="100000"
SND_BUF_SIZE="512k"
RCV_BUF_SIZE="512k"
TOTAL_IN_MEM_CACHE_SIZE="512M"
MAX_MMAP_FILE_SIZE="64M"
TOTAL_MMAP_CACHE_SIZE="512M"
USE_AIO="3"         # 0=off, 1=libaio, 2=posix, 3=io_uring (auto fallback)
AIO_BLOCK_SIZE="3"  # 0=64K, 1=128K, 2=256K, 3=512K, 4=1M

LOG_LEVEL="NOTICE"
LOG_ROLLING_SIZE="500"       # MB
LOG_KEEP_DAYS="14"
ERROR_LOG_ROLLING_SIZE="100" # MB

TLS_PROTOCOLS="13,12"        # TLS 1.3 and 1.2

CONFIG_PATH="/usr/local/lsws/conf/httpd_config.conf"
BACKUP_DIR="/usr/local/lsws/conf/backups"
LOG_FILE="/var/log/ols_optimize.log"
MD5_FILE="/usr/local/lsws/conf/.ols_config_md5sum"
LOCK_FILE="/tmp/ols_optimize.lock"

# =======================
# Helpers
# =======================
log_msg() {
  _msg="${1:-}"
  echo "$_msg"
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$_msg" >> "$LOG_FILE"
}

acquire_lock() {
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    log_msg "[!] Another run is in progress — exiting"
    exit 0
  fi
}

check_requirements() {
  if [ "$(id -u)" -ne 0 ]; then
    log_msg "[!] Must run as root"; exit 1
  fi
  if ! command -v flock >/dev/null 2>&1; then
    log_msg "[!] Missing 'flock' (install util-linux)"; exit 1
  fi
  if [ ! -f "$CONFIG_PATH" ]; then
    log_msg "[!] Config not found: $CONFIG_PATH"; exit 1
  fi
  if [ ! -x "/usr/local/lsws/bin/lswsctrl" ]; then
    log_msg "[!] OpenLiteSpeed controller not found"; exit 1
  fi
  mkdir -p "$(dirname "$LOG_FILE")" "$BACKUP_DIR"
  : > "$LOG_FILE" || true
}

detect_ram_and_workers() {
  _total_ram_gb=$(free -g | awk '/^Mem:/{print $2}')
  _total_ram_gb=${_total_ram_gb:-0}
  if [ "$_total_ram_gb" -lt 4 ]; then
    _cap=8
    IN_MEM_BUF_SIZE="256M"
    TOTAL_IN_MEM_CACHE_SIZE="256M"
    TOTAL_MMAP_CACHE_SIZE="256M"
    log_msg "[i] RAM ${_total_ram_gb}GB -> workers=${_cap}, conservative buffers"
  elif [ "$_total_ram_gb" -lt 8 ]; then
    _cap=12
    log_msg "[i] RAM ${_total_ram_gb}GB -> workers=${_cap}, moderate buffers"
  else
    _cap=16
    log_msg "[i] RAM ${_total_ram_gb}GB -> workers=${_cap}, max buffers OK"
  fi
  if [ "$HTTPD_WORKERS" -gt "$_cap" ]; then
    HTTPD_WORKERS="$_cap"
  elif [ "$HTTPD_WORKERS" -lt 1 ]; then
    HTTPD_WORKERS="1"
  fi
}

check_io_uring() {
  if [ "$USE_AIO" = "3" ]; then
    if ! grep -q io_uring /proc/filesystems 2>/dev/null; then
      log_msg "[!] io_uring not available — switching to libaio (1)"
      USE_AIO="1"
    fi
  fi
}

configure_kernel_limits() {
  log_msg "[*] Applying kernel limits..."
  _dropin="/etc/sysctl.d/99-ols.conf"
  mkdir -p /etc/sysctl.d
  cat > "$_dropin" <<'EOF'
net.core.somaxconn = 65535
fs.file-max = 2097152
EOF
  sysctl -w net.core.somaxconn=65535 >/dev/null || true
  sysctl -w fs.file-max=2097152      >/dev/null || true
  sysctl --system >/dev/null 2>&1 || true
  ulimit -n 200000 2>/dev/null || true
  log_msg "[+] Kernel tunables applied (persisted in /etc/sysctl.d/99-ols.conf)"
}

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
    log_msg "[!] CRITICAL: Config file too small ($file_size bytes)"
    return 1
  fi
  
  # Check for at least one listener
  if ! grep -q "listener" "$CONFIG_PATH"; then
    log_msg "[!] WARNING: No listener blocks found in config"
  fi
  
  log_msg "[+] Configuration integrity check passed"
  return 0
}

create_backup() {
  _backup_file="$BACKUP_DIR/httpd_config_$(date +'%Y%m%d-%H%M%S').conf"
  cp -a "$CONFIG_PATH" "$_backup_file"
  log_msg "[+] Backup created: $_backup_file"
  
  # Keep latest 10 backups (using find for safety with special filenames)
  find "$BACKUP_DIR" -name "httpd_config_*.conf" -type f -printf '%T@ %p\0' 2>/dev/null \
    | sort -zrn \
    | tail -zn +11 \
    | cut -zd' ' -f2- \
    | xargs -0 -r rm -f || true
  
  echo "$_backup_file"
}

# =======================
# Editing primitives
# =======================
set_top() {
  _key="$1"
  _val="$2"
  [ -z "$_val" ] && return 0
  if grep -qE "^[[:space:]]*${_key}[[:space:]]+" "$CONFIG_PATH"; then
    sed -E -i "s|^[[:space:]]*${_key}[[:space:]]+.*|${_key}                ${_val}|" "$CONFIG_PATH"
  else
    sed -i "1i ${_key}                ${_val}" "$CONFIG_PATH"
  fi
  log_msg "[=] ${_key} => ${_val}"
}

# update_block_kv <block_regex> <key> <value> [label]
update_block_kv() {
  _block="$1"
  _key="$2"
  _val="$3"
  _label="${4:-}"
  [ -z "$_val" ] && return 0

  awk -v blk="$_block" -v k="$_key" -v v="$_val" '
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

  mv "${CONFIG_PATH}.tmp" "$CONFIG_PATH"

  if [ -n "$_label" ]; then
    log_msg "[=] ${_label} => ${_val}"
  else
    log_msg "[=] ${_block}.${_key} => ${_val}"
  fi
}

# ===== SSL listeners (TLS only) =====
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

set_listener_ssl_param() {
  _key="$1"
  _val="$2"
  [ -z "$_val" ] && return 0
  
  _ranges="$(get_secure_listener_ranges || true)"
  if [ -z "${_ranges:-}" ]; then
    log_msg "[i] No SSL listener (secure 1) found — skipping '${_key}'."
    return 0
  fi
  
  # Create temp file for atomic operations
  cp "$CONFIG_PATH" "${CONFIG_PATH}.working"
  
  printf '%s\n' "$_ranges" | while IFS=, read -r _start _end; do
    [ -z "$_start" ] || [ -z "$_end" ] && continue
    
    # Use awk for safe range-based editing
    awk -v s="$_start" -v e="$_end" -v k="$_key" -v v="$_val" '
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
    
    mv "${CONFIG_PATH}.working.tmp" "${CONFIG_PATH}.working"
    log_msg "[=] listener.ssl ${_key} => ${_val} (lines ${_start}-${_end})"
  done
  
  # Apply changes atomically
  if [ -f "${CONFIG_PATH}.working" ]; then
    mv "${CONFIG_PATH}.working" "$CONFIG_PATH"
  fi
}

strip_listener_ssl_keys() {
  _ranges="$(get_secure_listener_ranges || true)"
  [ -z "${_ranges:-}" ] && return 0
  
  # Create working copy
  cp "$CONFIG_PATH" "${CONFIG_PATH}.working"
  
  printf '%s\n' "$_ranges" | while IFS=, read -r _start _end; do
    [ -z "$_start" ] || [ -z "$_end" ] && continue
    
    # Use awk to safely remove lines within range
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
    
    mv "${CONFIG_PATH}.working.tmp" "${CONFIG_PATH}.working"
    log_msg "[=] listener.ssl cleared sslCert/sslKey/sslCertChain (lines ${_start}-${_end})"
  done
  
  # Apply changes atomically
  if [ -f "${CONFIG_PATH}.working" ]; then
    mv "${CONFIG_PATH}.working" "$CONFIG_PATH"
  fi
}

configure_ssl_listeners() {
  log_msg "[*] Configuring TLS on SSL listeners..."
  
  # Backup before SSL changes
  cp "$CONFIG_PATH" "${CONFIG_PATH}.pre-ssl-backup"
  
  strip_listener_ssl_keys
  set_listener_ssl_param "sslProtocol" "${TLS_PROTOCOLS}"
  
  # Validate after SSL changes (manual check since OLS has no configtest)
  if ! validate_config_integrity; then
    log_msg "[!] Config validation failed after SSL changes - rolling back"
    cp "${CONFIG_PATH}.pre-ssl-backup" "$CONFIG_PATH"
    log_msg "[!] SSL listener configuration skipped due to validation failure"
  else
    log_msg "[+] SSL listener configuration validated successfully"
    rm -f "${CONFIG_PATH}.pre-ssl-backup"
  fi
}

# =======================
# MAIN
# =======================
main() {
  log_msg "========================================="
  log_msg "[*] OLS Optimizer - Start"
  log_msg "========================================="

  acquire_lock
  check_requirements

  _cur_md5=""
  if [ -f "$CONFIG_PATH" ]; then
    _cur_md5="$(md5sum "$CONFIG_PATH" | awk '{print $1}')"
  fi

  detect_ram_and_workers
  check_io_uring
  configure_kernel_limits

  _backup_file="$(create_backup)"

  # Top-level
  log_msg "[*] Applying top-level settings..."
  set_top "serverName"   "$SERVER_NAME"
  set_top "adminEmails"  "$ADMIN_EMAILS"
  set_top "httpdWorkers" "$HTTPD_WORKERS"
  set_top "cpuAffinity"  "$CPU_AFFINITY"
  set_top "enableLVE"    "$ENABLE_LVE"
  set_top "inMemBufSize" "$IN_MEM_BUF_SIZE"

  # Logs
  log_msg "[*] Configuring logging..."
  update_block_kv "errorlog[ \t]+logs/error[.]log"   "logLevel"        "$LOG_LEVEL"                  "errorlog.logLevel"
  update_block_kv "errorlog[ \t]+logs/error[.]log"   "rollingSize"     "${ERROR_LOG_ROLLING_SIZE}M"  "errorlog.rollingSize"
  update_block_kv "accesslog[ \t]+logs/access[.]log" "rollingSize"     "${LOG_ROLLING_SIZE}M"        "accesslog.rollingSize"
  update_block_kv "accesslog[ \t]+logs/access[.]log" "keepDays"        "$LOG_KEEP_DAYS"              "accesslog.keepDays"
  update_block_kv "accesslog[ \t]+logs/access[.]log" "compressArchive" "1"                           "accesslog.compressArchive"

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

  # TLS policy on SSL listeners
  if ! validate_config_integrity; then
    log_msg "[!] Config integrity check failed before SSL configuration"
    log_msg "[!] Restoring backup and aborting"
    cp -a "$_backup_file" "$CONFIG_PATH"
    exit 1
  fi
  
  configure_ssl_listeners
  
  # Final integrity check
  if ! validate_config_integrity; then
    log_msg "[!] Config integrity check failed after all changes"
    log_msg "[!] Restoring backup and aborting"
    cp -a "$_backup_file" "$CONFIG_PATH"
    exit 1
  fi

  # Validate & maybe restart (only if content changed)
  _new_md5="$(md5sum "$CONFIG_PATH" | awk '{print $1}')"

  if [ "${_cur_md5:-}" = "${_new_md5:-}" ]; then
    log_msg "[i] No effective changes (MD5 equal). Restart not required."
  else
    log_msg "[*] Changes detected. Diff (first lines):"
    diff -u "$_backup_file" "$CONFIG_PATH" 2>/dev/null | grep "^[+-]" | grep -v "^[+-][+-]" | head -n 30 || true
    log_msg "[*] Restarting OpenLiteSpeed..."
    if ! /usr/local/lsws/bin/lswsctrl restart; then
      log_msg "[!] Restart failed!"
      cp -a "$_backup_file" "$CONFIG_PATH"
      /usr/local/lsws/bin/lswsctrl restart >/dev/null 2>&1 || true
      log_msg "[!] Previous configuration restored"
      exit 1
    fi
    echo "$_new_md5" > "$MD5_FILE"
    log_msg "[+] OpenLiteSpeed restarted successfully"
  fi

  # Summary
  log_msg "[i] ========================================="
  log_msg "[i] lsphp configuration:"
  _php_children="$(sed -n '/^extprocessor[[:space:]]\+lsphp[[:space:]]*{/,/^}/p' "$CONFIG_PATH" \
    | awk '/env[[:space:]]+PHP_LSAPI_CHILDREN=/{sub(/^.*=/,""); pc=$0} /maxConns[[:space:]]+/{mc=$2} END{ if(pc!="")print pc; else if(mc!="")print "via maxConns="mc; else print "default" }')"
  log_msg "[i] - Children/Conns: ${_php_children}"
  log_msg "[i] - Adjust in: Enhance > Packages > PHP (if needed)"
  log_msg "[i] ========================================="
  log_msg "[OK] OLS Optimizer - Done"
  log_msg "========================================="
}

main "$@"
