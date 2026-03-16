#!/bin/bash
# Deploy FusionPBX security and monitoring configs to a new server
# Usage: ./deploy.sh [-p PORT] user@hostname
#
# Prerequisites on target server:
#   - FusionPBX + FreeSwitch installed
#   - fail2ban installed
#   - iptables-persistent installed
#   - exim4 or mailutils installed (for email alerts)

set -e

SSH_PORT=22
while getopts "p:" opt; do
    case $opt in
        p) SSH_PORT="$OPTARG" ;;
        *) echo "Usage: $0 [-p PORT] user@hostname"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

if [ -z "$1" ]; then
    echo "Usage: $0 [-p PORT] user@hostname"
    exit 1
fi

TARGET="$1"
DIR="$(cd "$(dirname "$0")" && pwd)"
SSH_OPTS="-p $SSH_PORT"
SCP_OPTS="-P $SSH_PORT"

echo "=== Deploying to $TARGET (port $SSH_PORT) ==="

# Back up existing config
echo "0. Backing up existing fail2ban config..."
ssh $SSH_OPTS "$TARGET" "[ -f /etc/fail2ban/jail.local ] && sudo cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak.$(date +%Y%m%d%H%M%S) && echo 'Backed up jail.local' || echo 'No existing jail.local'"

echo "1. Copying fail2ban filters..."
for f in "$DIR"/fail2ban/filter.d/*.conf; do
    scp $SCP_OPTS "$f" "$TARGET:/tmp/$(basename $f)"
    ssh $SSH_OPTS "$TARGET" "sudo cp /tmp/$(basename $f) /etc/fail2ban/filter.d/ && rm /tmp/$(basename $f)"
done

echo "2. Copying fail2ban jail.local..."
scp $SCP_OPTS "$DIR/fail2ban/jail.local" "$TARGET:/tmp/jail.local"
# Update SSH port in jail.local if non-standard
if [ "$SSH_PORT" != "22" ]; then
    ssh $SSH_OPTS "$TARGET" "sed -i 's/^port     = 22$/port     = $SSH_PORT/' /tmp/jail.local"
fi
ssh $SSH_OPTS "$TARGET" "sudo cp /tmp/jail.local /etc/fail2ban/jail.local && rm /tmp/jail.local"

echo "3. Copying scripts..."
for f in "$DIR"/scripts/*.sh; do
    scp $SCP_OPTS "$f" "$TARGET:/tmp/$(basename $f)"
    ssh $SSH_OPTS "$TARGET" "sudo cp /tmp/$(basename $f) /usr/local/bin/ && sudo chmod +x /usr/local/bin/$(basename $f) && rm /tmp/$(basename $f)"
done

echo "4. Restarting fail2ban..."
ssh $SSH_OPTS "$TARGET" "sudo systemctl restart fail2ban && sudo fail2ban-client status"

echo "5. Installing health check cron (every 5 min)..."
ssh $SSH_OPTS "$TARGET" "sudo crontab -l 2>/dev/null | grep -v fusionpbx-health-check | { cat; echo '*/5 * * * * /usr/local/bin/fusionpbx-health-check.sh'; } | sudo crontab -"

echo ""
echo "=== Deployment complete ==="
echo ""
echo "Post-deploy steps:"
echo "  1. Update ALERT_EMAIL in /usr/local/bin/fusionpbx-health-check.sh"
echo "  2. Add your admin IP(s) to ignoreip in the [ssh] jail in /etc/fail2ban/jail.local"
echo "  3. Add your SIP provider gateway IPs to ignoreip in the SIP jails"
echo "  4. Configure exim4 for internet delivery: sudo dpkg-reconfigure exim4-config"
echo "  5. Save iptables: sudo netfilter-persistent save"
echo "  6. Restart fail2ban after ignoreip changes: sudo systemctl restart fail2ban"
