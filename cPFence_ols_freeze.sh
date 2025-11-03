#!/usr/bin/env bash
# cPFence OpenLiteSpeed Freeze - Ubuntu systemd mode (CORRECTED)
# Purpose: Freeze/unfreeze top-of-config so OLS/cPFence rebuilds don't override your top settings.
# Notes: keeps backups for last 24h; combines frozen top with current vhost section.
set -euo pipefail

CONFIG_PATH="/usr/local/lsws/conf/httpd_config.conf"
BACKUP_DIR="/usr/local/lsws/conf/"
FREEZE_DIR="/usr/local/src"
FROZEN_TOP_FILE="$FREEZE_DIR/ols_top_config_frozen.conf"
FROZEN_MD5_FILE="$FREEZE_DIR/ols_config_frozen.md5"
FREEZE_MARKER="$FREEZE_DIR/.ols_frozen"
SERVICE_NAME="lshttpd"
RESTORE_OWNER="lsadm"
RESTORE_GROUP="www-data"
LOG_FILE="/var/log/cpfence_ols_freeze.log"

display() { 
  printf '%s\n' "$*"
  printf '[%s] %s\n' "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

require() {
  [ -f "$CONFIG_PATH" ] || { display "ERROR: Config not found at $CONFIG_PATH"; exit 1; }
}

validate_ownership() {
  # Check if user and group exist
  if ! id "$RESTORE_OWNER" >/dev/null 2>&1; then
    display "WARNING: User '$RESTORE_OWNER' not found, using root"
    RESTORE_OWNER="root"
  fi
  if ! getent group "$RESTORE_GROUP" >/dev/null 2>&1; then
    display "WARNING: Group '$RESTORE_GROUP' not found, using root"
    RESTORE_GROUP="root"
  fi
}

cleanup_old_backups() {
  # Remove backups older than 24h (corrected: -delete before -print)
  local count_before count_after
  count_before=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "httpd_config_backup-*.conf" 2>/dev/null | wc -l)
  
  find "$BACKUP_DIR" -maxdepth 1 -type f -name "httpd_config_backup-*.conf" -mtime +1 -delete 2>/dev/null || true
  
  count_after=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "httpd_config_backup-*.conf" 2>/dev/null | wc -l)
  
  if [ "$count_before" -ne "$count_after" ]; then
    display "[cleanup] Removed $((count_before - count_after)) old backup(s)"
  fi
}

freeze_config() {
  require
  validate_ownership
  cleanup_old_backups
  
  local TS BACKUP_FILE
  TS="$(date +'%Y%m%d-%H%M%S')"
  BACKUP_FILE="${BACKUP_DIR}httpd_config_backup-${TS}.conf"
  
  display "[backup] Saving current config: $BACKUP_FILE"
  cp -a "$CONFIG_PATH" "$BACKUP_FILE"

  display "[top] Extracting top-of-config (before first 'virtualhost {')"
  awk 'BEGIN{found=0} /^[[:space:]]*virtualhost[[:space:]]*\{/ {found=1; exit} {print}' "$CONFIG_PATH" > "$FROZEN_TOP_FILE"

  # Validate that we extracted something meaningful
  if [ ! -s "$FROZEN_TOP_FILE" ]; then
    display "ERROR: Failed to extract top-of-config (file is empty)"
    rm -f "$FROZEN_TOP_FILE"
    exit 1
  fi

  display "[md5] Storing current md5"
  md5sum "$CONFIG_PATH" | awk '{print $1}' > "$FROZEN_MD5_FILE"

  touch "$FREEZE_MARKER"
  display "✓ FROZEN. Future runs will enforce frozen top-of-config."
  display "  Frozen file: $FROZEN_TOP_FILE"
  display "  Lines preserved: $(wc -l < "$FROZEN_TOP_FILE")"
}

unfreeze_config() {
  rm -f "$FREEZE_MARKER" "$FROZEN_TOP_FILE" "$FROZEN_MD5_FILE" 2>/dev/null || true
  display "✓ Unfrozen. Top-of-config will no longer be enforced."
}

enforce_freeze_if_needed() {
  [ -f "$FREEZE_MARKER" ] || { display "[i] Not frozen. Nothing to do."; exit 0; }
  
  require
  validate_ownership
  
  [ -f "$FROZEN_TOP_FILE" ] && [ -f "$FROZEN_MD5_FILE" ] || { 
    display "ERROR: Frozen files missing (marker exists but files are gone)"
    display "  Run: $0 freeze"
    exit 1
  }

  local CUR SMD5
  CUR="$(md5sum "$CONFIG_PATH" | awk '{print $1}')"
  SMD5="$(cat "$FROZEN_MD5_FILE" 2>/dev/null || echo "")"
  
  if [ "$CUR" = "$SMD5" ]; then
    display "[i] No changes (md5 match). Config unchanged."
    exit 0
  fi

  display "[*] Config change detected - enforcing frozen top..."
  cleanup_old_backups
  
  local TS BACKUP_FILE TMP_VHOSTS TMP_NEW
  TS="$(date +'%Y%m%d-%H%M%S')"
  BACKUP_FILE="${BACKUP_DIR}httpd_config_backup-${TS}.conf"
  
  cp -a "$CONFIG_PATH" "$BACKUP_FILE"
  display "[backup] Saved changed config to: $BACKUP_FILE"

  TMP_VHOSTS="$(mktemp /tmp/ols_vhosts.XXXXXX)"
  TMP_NEW="$(mktemp /tmp/ols_new_conf.XXXXXX)"
  
  # Ensure cleanup on exit
  trap "rm -f '$TMP_VHOSTS' '$TMP_NEW'" EXIT

  display "[slice] Extracting from first 'virtualhost {' to EOF"
  awk 'BEGIN{found=0} { 
    if(!found && $0 ~ /^[[:space:]]*virtualhost[[:space:]]*\{/){ found=1 } 
    if(found){ print } 
  }' "$CONFIG_PATH" > "$TMP_VHOSTS"

  # Validate extraction
  if [ ! -s "$TMP_VHOSTS" ]; then
    display "WARNING: No virtualhost blocks found in current config"
    display "  This might indicate a problem with the config file"
  fi

  display "[merge] Combining frozen top with current vhosts"
  cat "$FROZEN_TOP_FILE" "$TMP_VHOSTS" > "$TMP_NEW"

  # Validate merged config size
  local orig_lines new_lines
  orig_lines=$(wc -l < "$CONFIG_PATH")
  new_lines=$(wc -l < "$TMP_NEW")
  
  if [ "$new_lines" -lt $((orig_lines / 2)) ]; then
    display "ERROR: Merged config is suspiciously small ($new_lines vs $orig_lines lines)"
    display "  Not applying changes to prevent data loss"
    exit 1
  fi

  display "[install] Writing merged config and setting owner/group"
  install -m 0640 -o "$RESTORE_OWNER" -g "$RESTORE_GROUP" "$TMP_NEW" "$CONFIG_PATH"

  # Verify config syntax before restart (manual check - OLS has no configtest)
  open_braces=$(grep -o '{' "$CONFIG_PATH" | wc -l)
  close_braces=$(grep -o '}' "$CONFIG_PATH" | wc -l)
  
  if [ "$open_braces" -ne "$close_braces" ]; then
    display "ERROR: Config validation failed (unbalanced braces: open=$open_braces close=$close_braces)"
    display "  Rolling back to backup..."
    cp -a "$BACKUP_FILE" "$CONFIG_PATH"
    exit 1
  fi

  display "[restart] Restarting $SERVICE_NAME"
  if ! systemctl restart "$SERVICE_NAME"; then
    display "ERROR: Service restart failed!"
    display "  Rolling back to backup..."
    cp -a "$BACKUP_FILE" "$CONFIG_PATH"
    systemctl restart "$SERVICE_NAME" || true
    exit 1
  fi

  # Update stored MD5 only after successful restart
  md5sum "$CONFIG_PATH" | awk '{print $1}' > "$FROZEN_MD5_FILE"
  display "✓ Enforcement complete. Top-of-config preserved."
}

# Main
mkdir -p "$(dirname "$LOG_FILE")"

MODE="${1:-run}"
case "$MODE" in
  freeze)   freeze_config ;;
  unfreeze) unfreeze_config ;;
  status)
    if [ -f "$FREEZE_MARKER" ]; then
      display "Status: FROZEN"
      display "  Marker: $FREEZE_MARKER"
      display "  Frozen config: $FROZEN_TOP_FILE"
      [ -f "$FROZEN_TOP_FILE" ] && display "  Lines: $(wc -l < "$FROZEN_TOP_FILE")"
    else
      display "Status: NOT FROZEN"
    fi
    ;;
  *)        enforce_freeze_if_needed ;;
esac
