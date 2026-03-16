#!/bin/bash
# Check if an IP has a current SIP registration in FreeSwitch
# Used by fail2ban ignorecommand - exit 0 = ignore (don't ban), exit 1 = allow ban
#
# Checks both internal and external profiles since FusionPBX deployments
# may register phones on either profile depending on configuration.
IP="$1"
/usr/bin/fs_cli -x 'sofia status profile internal reg' 2>/dev/null | grep -q "IP:.*${IP}" && exit 0
/usr/bin/fs_cli -x 'sofia status profile external reg' 2>/dev/null | grep -q "IP:.*${IP}" && exit 0
exit 1
