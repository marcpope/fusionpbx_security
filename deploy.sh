#!/bin/bash
# Deploy FusionPBX security and monitoring configs to a new server
# Usage: ./deploy.sh user@hostname
#
# Prerequisites on target server:
#   - FusionPBX + FreeSwitch installed
#   - fail2ban installed
#   - iptables-persistent installed
#   - exim4 or mailutils installed (for email alerts)

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 user@hostname"
    exit 1
fi

TARGET="$1"
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Deploying to $TARGET ==="

echo "1. Copying fail2ban filters..."
for f in "$DIR"/fail2ban/filter.d/*.conf; do
    scp "$f" "$TARGET:/tmp/$(basename $f)"
    ssh "$TARGET" "sudo cp /tmp/$(basename $f) /etc/fail2ban/filter.d/ && rm /tmp/$(basename $f)"
done

echo "2. Copying fail2ban jail.local..."
scp "$DIR/fail2ban/jail.local" "$TARGET:/tmp/jail.local"
ssh "$TARGET" "sudo cp /tmp/jail.local /etc/fail2ban/jail.local && rm /tmp/jail.local"

echo "3. Copying scripts..."
for f in "$DIR"/scripts/*.sh; do
    scp "$f" "$TARGET:/tmp/$(basename $f)"
    ssh "$TARGET" "sudo cp /tmp/$(basename $f) /usr/local/bin/ && sudo chmod +x /usr/local/bin/$(basename $f) && rm /tmp/$(basename $f)"
done

echo "4. Restarting fail2ban..."
ssh "$TARGET" "sudo systemctl restart fail2ban && sudo fail2ban-client status"

echo "5. Installing health check cron (every 5 min)..."
ssh "$TARGET" "sudo crontab -l 2>/dev/null | grep -v fusionpbx-health-check | { cat; echo '*/5 * * * * /usr/local/bin/fusionpbx-health-check.sh'; } | sudo crontab -"

echo ""
echo "=== Deployment complete ==="
echo ""
echo "Post-deploy steps:"
echo "  1. Update ALERT_EMAIL in /usr/local/bin/fusionpbx-health-check.sh"
echo "  2. Update ignoreip in /etc/fail2ban/jail.local with this server's gateway IPs"
echo "  3. Configure exim4 for internet delivery: sudo dpkg-reconfigure exim4-config"
echo "  4. Save iptables: sudo netfilter-persistent save"
