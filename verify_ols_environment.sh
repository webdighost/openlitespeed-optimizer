#!/usr/bin/env bash
# verify_ols_environment.sh – Minimal post-optimization verifier (IMPROVED)
# Runs automatically from ols_optimize.sh (errors only). Can run standalone.
set -euo pipefail

LOG_FILE="/var/log/verify_ols_environment.log"
ADMIN_EMAILS="mail@host.name"
CONFIG_PATH="/usr/local/lsws/conf/httpd_config.conf"

# Ensure log directory exists
mkdir -p "$(dirname "$LOG_FILE")"

log() {
  local msg="$1"
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$msg" | tee -a "$LOG_FILE"
}

errs=0
warnings=0

# Check if running as root (warning only, not error)
if [ "$(id -u)" -ne 0 ]; then
  log "[WARN] Not running as root - some checks may be limited"
  warnings=$((warnings+1))
fi

# 1. Service status
if ! systemctl is-active --quiet lshttpd; then
  log "[ERROR] lshttpd service is not active"
  errs=$((errs+1))
  
  # Additional diagnostics
  if systemctl is-failed --quiet lshttpd; then
    log "[INFO] Service is in failed state. Status:"
    systemctl status lshttpd --no-pager -l >> "$LOG_FILE" 2>&1 || true
  fi
else
  log "[OK] lshttpd service is active"
fi

# 2. Config file exists and is readable
if [ ! -f "$CONFIG_PATH" ]; then
  log "[ERROR] Config file not found: $CONFIG_PATH"
  errs=$((errs+1))
elif [ ! -r "$CONFIG_PATH" ]; then
  log "[ERROR] Config file not readable: $CONFIG_PATH"
  errs=$((errs+1))
else
  log "[OK] Config file exists and is readable"
fi

# 3. Config syntax validation (manual - OLS doesn't have configtest)
if [ -f "$CONFIG_PATH" ]; then
  # Check brace balance
  open_braces=$(grep -o '{' "$CONFIG_PATH" | wc -l)
  close_braces=$(grep -o '}' "$CONFIG_PATH" | wc -l)
  file_size=$(stat -c%s "$CONFIG_PATH")
  
  if [ "$open_braces" -ne "$close_braces" ]; then
    log "[ERROR] Config has unbalanced braces (open: $open_braces, close: $close_braces)"
    errs=$((errs+1))
  elif [ "$file_size" -lt 1000 ]; then
    log "[ERROR] Config file suspiciously small ($file_size bytes)"
    errs=$((errs+1))
  else
    log "[OK] Config syntax appears valid (balanced braces, reasonable size)"
  fi
else
  log "[ERROR] Config file not found for validation"
  errs=$((errs+1))
fi

# 4. Port listening check (80 and/or 443)
port80_listening=0
port443_listening=0

if ss -lnt 'sport = :80' 2>/dev/null | grep -q LISTEN; then
  port80_listening=1
  log "[OK] Port 80 is listening"
fi

if ss -lnt 'sport = :443' 2>/dev/null | grep -q LISTEN; then
  port443_listening=1
  log "[OK] Port 443 is listening"
fi

if [ "$port80_listening" -eq 0 ] && [ "$port443_listening" -eq 0 ]; then
  log "[ERROR] Neither port 80 nor 443 is listening"
  errs=$((errs+1))
  
  # Show what ports ARE listening
  log "[INFO] Currently listening ports:"
  ss -lnt >> "$LOG_FILE" 2>&1 || true
fi

# 5. Check for zombie/defunct processes
zombie_count=$(ps aux | grep -c '[d]efunct' || true)
if [ "$zombie_count" -gt 0 ]; then
  log "[WARN] Found $zombie_count defunct/zombie process(es)"
  ps aux | grep '[d]efunct' >> "$LOG_FILE" 2>&1 || true
  warnings=$((warnings+1))
fi

# 6. Check disk space on critical paths
check_disk_space() {
  local path="$1"
  local threshold=90
  
  if [ ! -d "$path" ]; then
    return
  fi
  
  local usage
  usage=$(df -h "$path" | awk 'NR==2 {print $5}' | sed 's/%//')
  
  if [ "$usage" -ge "$threshold" ]; then
    log "[WARN] Disk usage on $path is ${usage}% (threshold: ${threshold}%)"
    warnings=$((warnings+1))
  fi
}

check_disk_space "/usr/local/lsws"
check_disk_space "/tmp"
check_disk_space "/var/log"

# 7. Check for recent core dumps
if [ -d "/tmp" ]; then
  core_count=$(find /tmp -name 'core.*' -mtime -1 2>/dev/null | wc -l)
  if [ "$core_count" -gt 0 ]; then
    log "[WARN] Found $core_count recent core dump(s) in /tmp"
    warnings=$((warnings+1))
  fi
fi

# Summary
log "========================================="
log "Verification Summary:"
log "  Errors: $errs"
log "  Warnings: $warnings"
log "========================================="

# Send alert email if there are errors
if [ "$errs" -gt 0 ]; then
  log "[ALERT] Sending notification email..."
  
  if command -v mail >/dev/null 2>&1; then
    {
      echo "OpenLiteSpeed verification detected $errs error(s) and $warnings warning(s) on $(hostname)"
      echo ""
      echo "Timestamp: $(date +'%Y-%m-%d %H:%M:%S')"
      echo ""
      echo "Check the log file for details:"
      echo "  $LOG_FILE"
      echo ""
      echo "Recent errors:"
      grep -E '\[ERROR\]' "$LOG_FILE" | tail -10 || echo "  (none in recent entries)"
    } | mail -s "[CRITICAL] OLS verification failed on $(hostname)" "$ADMIN_EMAILS" 2>> "$LOG_FILE" || {
      log "[ERROR] Failed to send email notification"
    }
  else
    log "[WARN] 'mail' command not available - cannot send email alerts"
    log "[WARN] Install with: apt-get install mailutils"
  fi
  
  exit 1
fi

if [ "$warnings" -gt 0 ]; then
  log "[INFO] Verification completed with warnings (non-critical)"
  exit 0
fi

log "[OK] All checks passed successfully"
exit 0
