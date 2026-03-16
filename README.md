# FusionPBX Security & Monitoring

Fail2ban jails, iptables rules, and health monitoring scripts for [FusionPBX](https://www.fusionpbx.com/) / FreeSwitch servers.

## Why this exists

SIP brute-force scanners constantly probe FusionPBX servers with fake registration attempts for non-existent users. The default FusionPBX fail2ban configuration often has these jails disabled, leaving FreeSwitch to handle thousands of bogus auth requests. Over time, this can cause SQLite database contention within FreeSwitch, eventually deadlocking the process and taking all gateways and phone registrations offline.

These configs were built after diagnosing exactly that failure mode in production.

## What's included

### Fail2ban

**`fail2ban/jail.local`** — Jail configuration with three SIP-focused jails enabled:

| Jail | What it catches | maxretry | bantime |
|------|----------------|----------|---------|
| `freeswitch` | SIP auth failures (wrong password for valid users) | 5 in 2min | 24hr |
| `freeswitch-ip` | Registration attempts using raw IP as domain (obvious scanners) | 1 in 1min | 24hr |
| `freeswitch-scan` | Any registration attempt for a non-existent user | 5 in 2min | 24hr |

Also includes jails for web login brute-force (`fusionpbx`), MAC address scanning (`fusionpbx-mac`), and nginx abuse (`nginx-404`, `nginx-dos`).

**Important:** After deploying, add your admin IP(s) and SIP provider gateway IPs to the `ignoreip` lines in `jail.local`. Do **not** use inline comments on `ignoreip` lines — fail2ban will parse them as IP addresses.

**`fail2ban/filter.d/`** — Filter definitions:

- `freeswitch-scan.conf` — Matches all "Can't find user" log entries (the primary scan vector)
- `freeswitch.conf` — Matches SIP auth failures (REGISTER and INVITE)
- `freeswitch-ip.conf` — Matches "Can't find user" where the domain is a raw IP address
- `freeswitch-acl.conf` — Matches ACL rejections
- `sip-auth-failure.conf` — Matches SIP auth failures (REGISTER only)
- `sip-auth-challenge.conf` — Matches SIP auth challenges
- `auth-challenge-ip.conf` — Matches auth challenges targeting IP-based domains
- `fusionpbx.conf` — Matches FusionPBX web login failures
- `fusionpbx-404.conf` — Matches inbound call 404s
- `fusionpbx-mac.conf` — Matches invalid MAC provisioning attempts

### Scripts

**`scripts/fail2ban-check-registered.sh`** — Dynamic whitelist for fail2ban. Queries FreeSwitch to check if an IP has currently registered phones on either the `internal` or `external` profile. Used via `ignorecommand` in the jail config so that a location with working phones won't get banned if a misconfigured device at the same IP generates some failed registration attempts.

**`scripts/fusionpbx-health-check.sh`** — Health monitoring script (runs via cron every 5 minutes). Checks:

1. **FreeSwitch responsiveness** — Detects hung/deadlocked processes via `fs_cli`
2. **Gateway registrations** — Alerts on gateway failures (REGED and NOREG are both treated as healthy, since IP-auth gateways like BulkVS or AWS Chime use NOREG normally)
3. **Phone registration count** — Checks both `internal` and `external` profiles; alerts if count drops below threshold
4. **SQLite contention** — Watches for "SQLite is BUSY" warnings that precede deadlocks
5. **Disk space** — Alerts above 90% usage
6. **Memory** — Alerts below 512MB available

Alerts go to syslog and optionally email (set `ALERT_EMAIL` for Pushover, PagerDuty, etc.). The "OK" status is only logged to syslog every 30 minutes — email is only sent when there's a problem.

### Firewall

**`iptables-rules.v4`** — Reference iptables rules with:

- Default DROP policy on INPUT
- String-match rules to drop known SIP scanning user agents (`friendly-scanner`, `sipcli`, `VaxSIPUserAgent`, `pplsip`, etc.)
- Custom chains (`sip-auth-fail`, `sip-auth-ip`) for manually blocked IPs
- DSCP/QoS marking for SIP signaling (CS3) and RTP media (EF)

### Deployment

**`deploy.sh`** — One-command deployment to a new server:

```bash
# Standard SSH port
./deploy.sh user@newserver

# Custom SSH port
./deploy.sh -p 2222 user@newserver
```

The script backs up any existing `jail.local`, copies all filters, jails, and scripts, automatically adjusts the SSH port in the jail config, restarts fail2ban, and installs the health check cron.

After running, you'll need to:

1. Set `ALERT_EMAIL` in `/usr/local/bin/fusionpbx-health-check.sh`
2. Add your admin IP(s) to `ignoreip` in the `[ssh]` jail to avoid lockout
3. Add your SIP provider gateway IPs to `ignoreip` in the SIP jails
4. Configure outbound email if needed: `sudo dpkg-reconfigure exim4-config`
5. Save iptables rules: `sudo netfilter-persistent save`
6. Restart fail2ban after any `ignoreip` changes: `sudo systemctl restart fail2ban`

## Requirements

- Debian/Ubuntu with FusionPBX and FreeSwitch
- `fail2ban`
- `iptables-persistent`
- `mail` command (via `mailutils` or `exim4`) for email alerts

## License

MIT
