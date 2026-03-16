#!/bin/bash
# FusionPBX/FreeSwitch Health Check
# Checks gateway registrations, FreeSwitch responsiveness, and system resources
# Logs issues to syslog and optionally sends email alerts

ALERT_EMAIL=""  # Set to an email address to receive alerts (e.g. Pushover, PagerDuty, etc.)
LOG_TAG="fusionpbx-health"

alert() {
    local level="$1"
    local msg="$2"
    logger -t "$LOG_TAG" -p "user.${level}" "$msg"
    if [ -n "$ALERT_EMAIL" ] && command -v mail &>/dev/null; then
        echo "$msg" | mail -s "[$(hostname -s)] FusionPBX Alert: $level" "$ALERT_EMAIL"
    fi
}

ISSUES=0

# 1. Check if FreeSwitch is responsive
FS_STATUS=$(timeout 10 /usr/bin/fs_cli -x 'status' 2>/dev/null)
if [ $? -ne 0 ] || [ -z "$FS_STATUS" ]; then
    alert "crit" "CRITICAL: FreeSwitch is NOT responding to fs_cli - process may be hung!"
    exit 1
fi

# 2. Check gateway registrations
# Gateways using IP-based auth (e.g. BulkVS, AWS Chime) show NOREG which is normal.
# Only alert on states like FAIL_WAIT, TRYING, UNREGED — not REGED or NOREG.
GATEWAYS=$(timeout 10 /usr/bin/fs_cli -x 'sofia status' 2>/dev/null)
TOTAL_GW=$(echo "$GATEWAYS" | awk '$2=="gateway" {total++} END {print total+0}')
FAILED_GW=$(echo "$GATEWAYS" | awk '$2=="gateway" && $NF!="REGED" && $NF!="NOREG" {print $3}' | tr '\n' ', ')
if [ -n "$FAILED_GW" ]; then
    alert "err" "Gateway issues ($TOTAL_GW total): $FAILED_GW"
    ISSUES=1
fi

# 3. Check registered phone count (both internal and external profiles)
# FusionPBX may register phones on either profile depending on configuration.
REG_INT=$(timeout 10 /usr/bin/fs_cli -x 'sofia status profile internal reg' 2>/dev/null | grep -c 'Call-ID:')
REG_EXT=$(timeout 10 /usr/bin/fs_cli -x 'sofia status profile external reg' 2>/dev/null | grep -c 'Call-ID:')
REG_COUNT=$(( REG_INT + REG_EXT ))
if [ "$REG_COUNT" -eq 0 ]; then
    alert "err" "No phones registered on any profile"
    ISSUES=1
elif [ "$REG_COUNT" -lt 3 ]; then
    alert "warning" "Low phone registration count: $REG_COUNT phones"
    ISSUES=1
fi

# 4. Check for SQLite contention (sane value shows retries remaining out of 300)
# sane=299 means resolved on 2nd try (normal). Alert when sane drops to 280 or lower.
SQLITE_LOW_SANE=$(tail -5000 /var/log/freeswitch/freeswitch.log 2>/dev/null | grep -oP 'sane=\K\d+' | sort -n | head -1)
if [ -n "$SQLITE_LOW_SANE" ] && [ "$SQLITE_LOW_SANE" -le 280 ]; then
    alert "warning" "SQLite contention: sane=$SQLITE_LOW_SANE (retries exhausting, 0=failed request)"
    ISSUES=1
fi

# 5. Check disk space
DISK_USE=$(df / --output=pcent | tail -1 | tr -d ' %')
if [ "$DISK_USE" -gt 90 ]; then
    alert "warning" "Disk usage at ${DISK_USE}%"
    ISSUES=1
fi

# 6. Check memory
MEM_AVAIL=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
if [ "$MEM_AVAIL" -lt 512 ]; then
    alert "warning" "Low available memory: ${MEM_AVAIL}MB"
    ISSUES=1
fi

# Log OK status every 30 min (every 6th run at 5-min interval)
if [ "$ISSUES" -eq 0 ]; then
    COUNTER_FILE="/tmp/fusionpbx-health-counter"
    COUNT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    COUNT=$(( (COUNT + 1) % 6 ))
    echo "$COUNT" > "$COUNTER_FILE"
    if [ "$COUNT" -eq 0 ]; then
        logger -t "$LOG_TAG" "OK: $REG_COUNT phones, $TOTAL_GW gateways, mem ${MEM_AVAIL}MB, disk ${DISK_USE}%"
    fi
fi
