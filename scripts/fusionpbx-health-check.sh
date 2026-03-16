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
GATEWAYS=$(timeout 10 /usr/bin/fs_cli -x 'sofia status' 2>/dev/null)
TOTAL_GW=$(echo "$GATEWAYS" | awk '$2=="gateway" {total++} END {print total+0}')
REGED_GW=$(echo "$GATEWAYS" | awk '$2=="gateway" && $NF=="REGED" {count++} END {print count+0}')
if [ "$TOTAL_GW" -gt 0 ] && [ "$REGED_GW" -lt "$TOTAL_GW" ]; then
    UNREG_NAMES=$(echo "$GATEWAYS" | awk '$2=="gateway" && $NF!="REGED" {print $3}' | tr '\n' ', ')
    alert "err" "Unregistered gateways ($REGED_GW/$TOTAL_GW up): $UNREG_NAMES"
    ISSUES=1
fi

# 3. Check registered phone count
REG_COUNT=$(timeout 10 /usr/bin/fs_cli -x 'sofia status profile external reg' 2>/dev/null | grep -c 'Call-ID:')
if [ "$REG_COUNT" -eq 0 ]; then
    alert "err" "No phones registered on external profile"
    ISSUES=1
elif [ "$REG_COUNT" -lt 5 ]; then
    alert "warning" "Low phone registration count: $REG_COUNT phones"
    ISSUES=1
fi

# 4. Check for SQLite contention (last 5000 lines of log)
SQLITE_BUSY=$(tail -5000 /var/log/freeswitch/freeswitch.log 2>/dev/null | grep -c 'SQLite is BUSY')
if [ "$SQLITE_BUSY" -gt 10 ]; then
    alert "warning" "High SQLite contention: $SQLITE_BUSY BUSY warnings in recent log"
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
        logger -t "$LOG_TAG" "OK: $REG_COUNT phones, $REGED_GW/$TOTAL_GW gateways, mem ${MEM_AVAIL}MB, disk ${DISK_USE}%"
    fi
fi
