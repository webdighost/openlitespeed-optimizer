# OpenLiteSpeed Freeze + Optimizer (Ubuntu + systemd)

Reliable and minimalist scripts for: (1) optimizing OpenLiteSpeed, (2) freezing the top section of the configuration so cPFence/OLS rebuilds don't overwrite your settings, and (3) verifying environment health.

Designed to be **reliable**, **minimal**, and run **hourly**.

---

## 📦 Files

| File | Description |
|------|-------------|
| `ols_optimize.sh` | Applies tuning, logging, TLS policy, validates config, restarts if needed |
| `cPFence_ols_freeze.sh` | Freezes/unfreezes/enforces top-of-config. Keeps backups for last 24h |
| `verify_ols_environment.sh` | Minimal checks (service active, `lswsctrl configtest`, ports 80/443). Only alerts on errors |
| `logrotate_ols_optimize` | Logrotate configuration for optimizer logs |
| `logrotate_cpfence_ols_freeze` | Logrotate configuration for freeze logs |

---

## 🚀 Installation

```bash
# Copy scripts to correct locations
install -m 0755 ols_optimize.sh /root/ols_optimize.sh
install -m 0755 cPFence_ols_freeze.sh /usr/local/src/cPFence_ols_freeze.sh
install -m 0755 verify_ols_environment.sh /root/verify_ols_environment.sh

# Install logrotate configurations
install -m 0644 logrotate_ols_optimize /etc/logrotate.d/ols_optimize
install -m 0644 logrotate_cpfence_ols_freeze /etc/logrotate.d/cpfence_ols_freeze

# Create necessary directories
mkdir -p /usr/local/lsws/conf/backups
mkdir -p /var/log

# Verify permissions
chmod +x /root/ols_optimize.sh
chmod +x /usr/local/src/cPFence_ols_freeze.sh
chmod +x /root/verify_ols_environment.sh
```

---

## ⚙️ Configuration (Optional)

Edit the **FIXED CONFIG** block at the top of `ols_optimize.sh`:

```bash
# Server settings
SERVER_NAME="your.host.name"
ADMIN_EMAILS="mail@host.name"

# Workers (16 = maximum, auto-adjusts based on RAM)
HTTPD_WORKERS="16"

# Tuning
MAX_CONNECTIONS="100000"
MAX_SSL_CONNECTIONS="100000"
IN_MEM_BUF_SIZE="384M"
TOTAL_IN_MEM_CACHE_SIZE="512M"

# I/O (3 = io_uring with automatic fallback to libaio)
USE_AIO="3"
```

### 🧮 Automatic Worker Adjustment

The script automatically adjusts `HTTPD_WORKERS` based on available RAM:

| Available RAM | Workers | Buffers |
|---------------|---------|---------|
| < 4 GB | 8 | Conservative (256M) |
| 4-8 GB | 12 | Moderate (384M) |
| > 8 GB | 16 | Maximum (512M) |

---

## ⏰ Cron Configuration

### Option 1: Basic Execution (Recommended)

```cron
# Optimize OLS once per hour (minute 00)
0 * * * * /root/ols_optimize.sh >> /var/log/ols_optimize.log 2>&1

# Enforce freeze every 5 minutes (no-op if not frozen)
*/5 * * * * /usr/local/src/cPFence_ols_freeze.sh >> /var/log/cpfence_ols_freeze.log 2>&1

# Daily verification (at 6:00 AM)
0 6 * * * /root/verify_ols_environment.sh >> /var/log/verify_ols_environment.log 2>&1
```

### Option 2: Execution with Integrated Validation

```cron
# Optimize + verify immediately after
0 * * * * /root/ols_optimize.sh >> /var/log/ols_optimize.log 2>&1 && /root/verify_ols_environment.sh >> /var/log/verify_ols_environment.log 2>&1

# Enforce freeze
*/5 * * * * /usr/local/src/cPFence_ols_freeze.sh >> /var/log/cpfence_ols_freeze.log 2>&1
```

**To install:**
```bash
crontab -e
# Paste the block above and save
```

---

## 🧊 Freeze Usage

### Freeze Configuration

```bash
# Freezes the current top-of-config (before first 'virtualhost {')
/usr/local/src/cPFence_ols_freeze.sh freeze
```

**What happens:**
1. Creates backup of current configuration
2. Extracts everything before the first `virtualhost {` block
3. Creates a freeze marker
4. All future runs will preserve this section

### Check Status

```bash
# Shows if configuration is frozen
/usr/local/src/cPFence_ols_freeze.sh status
```

### Unfreeze

```bash
# Removes the freeze
/usr/local/src/cPFence_ols_freeze.sh unfreeze
```

### Enforce (via cron)

```bash
# Normal execution - applies freeze if configured
/usr/local/src/cPFence_ols_freeze.sh
```

---

## ✅ Manual Verification

```bash
# Run full verification
/root/verify_ols_environment.sh

# Check exit code
if [ $? -eq 0 ]; then
    echo "✓ Everything OK"
else
    echo "✗ Issues found (see /var/log/verify_ols_environment.log)"
fi
```

**What is checked:**
- ✓ `lshttpd` service active
- ✓ Configuration file integrity (balanced braces, reasonable size)
- ✓ Ports 80/443 listening
- ✓ Disk space
- ✓ Zombie/defunct processes
- ✓ Recent core dumps

**Note:** OpenLiteSpeed doesn't have a native `configtest` command like Apache. The scripts validate configuration by checking brace balance and file integrity.

---

## 🔧 What Gets Optimized

### Top-level (Main Configuration)
- `serverName` – Server name
- `adminEmails` – Administrator emails
- `httpdWorkers` – Workers (auto up to 16, based on RAM)
- `cpuAffinity` – CPU affinity (1 = enabled)
- `enableLVE` – LVE (0 = disabled for non-cPanel use)
- `inMemBufSize` – In-memory buffer

### Logs
- Error/access rotation size
- Retention days
- Archive compression

### Tuning
- `maxConnections` / `maxSSLConnections` – Maximum connections
- `sndBufSize` / `rcvBufSize` – Socket buffers
- `totalInMemCacheSize` – In-memory cache
- `totalMMapCacheSize` – Mmap cache
- `useAIO` – AIO mode (auto downgrade from io_uring to libaio)
- `AIOBlockSize` – AIO block size

### SSL/TLS
- Enforces `sslProtocol 13,12` (TLS 1.3 and 1.2) **only on SSL listeners**
- Removes `sslCert`, `sslKey`, `sslCertChain` from listeners (uses SNI per vhost)

### Kernel
- `net.core.somaxconn = 65535`
- `fs.file-max = 2097152`
- Persisted in `/etc/sysctl.d/99-ols.conf`

---

## 🛡️ Safety and Recovery

### Automatic Backups
- ✅ Backup before any changes
- ✅ Keeps last **10 backups** (optimize)
- ✅ Keeps backups from last **24 hours** (freeze)
- ✅ Location: `/usr/local/lsws/conf/backups/`

### Validation and Rollback
1. **Syntax validation** before restart
2. **Automatic rollback** if restart fails
3. **MD5 verification** to avoid unnecessary restarts

### Lock Protection
- 🔒 Uses `flock` to prevent simultaneous executions
- 🔒 Lock file: `/tmp/ols_optimize.lock`

---

## 📊 Logs

| Log | Location | Purpose |
|-----|----------|---------|
| Optimizer | `/var/log/ols_optimize.log` | Optimization history |
| Freeze | `/var/log/cpfence_ols_freeze.log` | Freeze actions |
| Verify | `/var/log/verify_ols_environment.log` | Verification results |

**View logs in real-time:**
```bash
tail -f /var/log/ols_optimize.log
tail -f /var/log/cpfence_ols_freeze.log
tail -f /var/log/verify_ols_environment.log
```

**Log rotation:**
Logs are automatically rotated daily, keeping 1 day of history. Older logs are compressed.

---

## 🐛 Troubleshooting

### Problem: Script doesn't execute
```bash
# Check permissions
ls -lh /root/ols_optimize.sh
chmod +x /root/ols_optimize.sh

# Test manually
bash -x /root/ols_optimize.sh
```

### Problem: Restart fails
```bash
# View service logs
journalctl -u lshttpd -n 50 --no-pager

# Check config manually (OLS doesn't have configtest)
CONFIG="/usr/local/lsws/conf/httpd_config.conf"
echo "Open braces: $(grep -o '{' $CONFIG | wc -l)"
echo "Close braces: $(grep -o '}' $CONFIG | wc -l)"

# Restore last backup
LAST_BACKUP=$(ls -1t /usr/local/lsws/conf/backups/httpd_config_*.conf | head -1)
cp "$LAST_BACKUP" /usr/local/lsws/conf/httpd_config.conf
systemctl restart lshttpd
```

### Problem: Email not sent
```bash
# Install mailutils
apt-get update && apt-get install -y mailutils

# Test email
echo "Test" | mail -s "Test from $(hostname)" your@email.com
```

### Problem: Config gets overwritten by cPFence
```bash
# This is exactly what the freeze script prevents!
# Make sure freeze is active:
/usr/local/src/cPFence_ols_freeze.sh status

# If not frozen, freeze it:
/usr/local/src/cPFence_ols_freeze.sh freeze

# Verify cron is running the freeze enforcement:
crontab -l | grep cPFence_ols_freeze
```

---

## 🗑️ Uninstallation

```bash
# Remove cron jobs
crontab -e
# (remove the script lines)

# Remove scripts
rm -f /root/ols_optimize.sh
rm -f /root/verify_ols_environment.sh
rm -f /usr/local/src/cPFence_ols_freeze.sh

# Remove logrotate configs
rm -f /etc/logrotate.d/ols_optimize
rm -f /etc/logrotate.d/cpfence_ols_freeze

# Remove configurations and markers
rm -f /usr/local/src/ols_top_config_frozen.conf
rm -f /usr/local/src/ols_config_frozen.md5
rm -f /usr/local/src/.ols_frozen
rm -f /usr/local/lsws/conf/.ols_config_md5sum

# (Optional) Remove backups
rm -rf /usr/local/lsws/conf/backups/

# (Optional) Remove logs
rm -f /var/log/ols_optimize.log*
rm -f /var/log/cpfence_ols_freeze.log*
rm -f /var/log/verify_ols_environment.log*
```

---

## 📝 Compatibility Notes

### Requirements
- ✅ Ubuntu 20.04+ (or Debian derivatives)
- ✅ OpenLiteSpeed installed
- ✅ systemd
- ✅ Bash 4.0+
- ✅ Packages: `util-linux` (flock), `coreutils`

### Tested with
- ✅ Enhance Control Panel
- ✅ cPFence
- ✅ OpenLiteSpeed 1.7.x / 1.8.x

### Not compatible with
- ❌ cPanel (uses different configuration)
- ❌ Systems without systemd (must use init.d manually)
- ❌ Alpine Linux (uses different package manager and init system)

---

## 🔍 How It Works

### Optimizer Flow
1. **Lock acquisition** – Prevents concurrent runs
2. **Requirements check** – Validates root, tools, config file
3. **RAM detection** – Adjusts workers based on available memory
4. **io_uring check** – Falls back to libaio if unavailable
5. **Kernel tuning** – Applies sysctl settings
6. **Backup creation** – Saves current config
7. **Configuration updates** – Applies all settings
8. **SSL listener optimization** – TLS protocol enforcement
9. **MD5 comparison** – Only restarts if config changed
10. **Restart & validation** – Restarts OLS, rolls back on failure

### Freeze Flow
1. **Status check** – Is freeze active?
2. **MD5 comparison** – Has config changed?
3. **Backup** – Saves current config
4. **Extraction** – Splits config into top + vhosts
5. **Merge** – Combines frozen top with current vhosts
6. **Validation** – Checks syntax and size
7. **Apply** – Installs merged config
8. **Restart** – Restarts service, rolls back on failure

---

## 🆘 Support

**In case of issues:**
1. Check logs in `/var/log/`
2. Run `verify_ols_environment.sh` for diagnostics
3. Check backups in `/usr/local/lsws/conf/backups/`
4. Open an issue on GitHub

---

## 📜 Changelog

### v2.0 (2025-11) - CORRECTED
- ✅ Fixed syntax error in `configure_ssl_listeners()`
- ✅ Complete rewrite of SSL functions with AWK
- ✅ Atomic operations with `.working` files
- ✅ Better backup management with null-termination
- ✅ User/group validation in freeze
- ✅ Config size verification in merge
- ✅ Added `status` mode to freeze
- ✅ Expanded checks in verify (disk, zombie, cores)
- ✅ Added logrotate configurations

### v1.0 (2025-09) - INITIAL
- 🎉 Initial release

---

## 📄 License

MIT License - Feel free to use, modify, and distribute.

---

## 🤝 Contributing

Contributions are welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Test your changes thoroughly
4. Submit a pull request

---

## ⭐ Credits

Developed for use with:
- **Enhance Control Panel** – Modern hosting control panel
- **cPFence** – Security and hardening solution
- **OpenLiteSpeed** – High-performance web server

---

**✨ Happy hosting with OpenLiteSpeed!**
