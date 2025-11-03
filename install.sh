#!/usr/bin/env bash
# Quick installation script for OpenLiteSpeed Optimizer
set -euo pipefail

echo "========================================="
echo "OpenLiteSpeed Optimizer - Installation"
echo "========================================="
echo ""

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root"
  echo "Please run: sudo bash install.sh"
  exit 1
fi

# Check if OpenLiteSpeed is installed
if [ ! -d "/usr/local/lsws" ]; then
  echo "ERROR: OpenLiteSpeed doesn't appear to be installed"
  echo "Expected directory /usr/local/lsws not found"
  exit 1
fi

echo "[*] Installing scripts..."

# Install main scripts
install -m 0755 ols_optimize.sh /root/ols_optimize.sh
install -m 0755 cPFence_ols_freeze.sh /usr/local/src/cPFence_ols_freeze.sh
install -m 0755 verify_ols_environment.sh /root/verify_ols_environment.sh

echo "    ✓ Scripts installed"

# Install logrotate configs
if [ -d "/etc/logrotate.d" ]; then
  install -m 0644 logrotate_ols_optimize /etc/logrotate.d/ols_optimize
  install -m 0644 logrotate_cpfence_ols_freeze /etc/logrotate.d/cpfence_ols_freeze
  echo "    ✓ Logrotate configs installed"
else
  echo "    ! Logrotate directory not found - skipping logrotate configs"
fi

# Create necessary directories
mkdir -p /usr/local/lsws/conf/backups
mkdir -p /var/log
echo "    ✓ Directories created"

# Verify installations
echo ""
echo "[*] Verifying installation..."

if [ -x "/root/ols_optimize.sh" ]; then
  echo "    ✓ ols_optimize.sh is executable"
else
  echo "    ✗ Problem with ols_optimize.sh"
  exit 1
fi

if [ -x "/usr/local/src/cPFence_ols_freeze.sh" ]; then
  echo "    ✓ cPFence_ols_freeze.sh is executable"
else
  echo "    ✗ Problem with cPFence_ols_freeze.sh"
  exit 1
fi

if [ -x "/root/verify_ols_environment.sh" ]; then
  echo "    ✓ verify_ols_environment.sh is executable"
else
  echo "    ✗ Problem with verify_ols_environment.sh"
  exit 1
fi

echo ""
echo "========================================="
echo "Installation completed successfully!"
echo "========================================="
echo ""
echo "Next steps:"
echo ""
echo "1. CONFIGURE the scripts (edit /root/ols_optimize.sh):"
echo "   - Set SERVER_NAME"
echo "   - Set ADMIN_EMAILS"
echo "   - Adjust HTTPD_WORKERS if needed"
echo ""
echo "2. TEST manually before adding to cron:"
echo "   sudo /root/ols_optimize.sh"
echo ""
echo "3. SETUP cron jobs (run: crontab -e):"
echo "   # Optimize hourly"
echo "   0 * * * * /root/ols_optimize.sh >> /var/log/ols_optimize.log 2>&1"
echo ""
echo "   # Enforce freeze every 5 minutes"
echo "   */5 * * * * /usr/local/src/cPFence_ols_freeze.sh >> /var/log/cpfence_ols_freeze.log 2>&1"
echo ""
echo "   # Daily verification at 6 AM"
echo "   0 6 * * * /root/verify_ols_environment.sh >> /var/log/verify_ols_environment.log 2>&1"
echo ""
echo "4. FREEZE top-of-config (optional but recommended):"
echo "   sudo /usr/local/src/cPFence_ols_freeze.sh freeze"
echo ""
echo "For more information, see: README.md"
echo ""
