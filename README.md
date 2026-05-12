# hestiacp-ipset-blacklist

Automatic IP blacklist blocker for Linux servers using **ipset** and **iptables**.  
Blocks malicious traffic — spam, phishing, port scanners, botnets — at the kernel level, before it reaches any service.

Tested on **Ubuntu 20.04 / 22.04 / 24.04** and **Debian 11 / 12**.  
Works alongside **HestiaCP**, **fail2ban**, and **UFW** (when inactive) without conflicts.

---

## How it works

- Downloads a curated IP blacklist every 12 hours via cron
- Loads all IPs into an **ipset** hash table using a single `awk` pass with deduplication — extremely fast even with 150k+ entries
- **iptables** drops all traffic from blacklisted IPs at kernel level
- On reboot, ipset data and iptables rules are restored via a **systemd service** that runs before network interfaces come up
- A separate **custom list** (`spam-custom`) lets you add your own IPs manually — never overwritten by automatic updates

### Blacklist source

Maintained by **[@ufukart](https://github.com/ufukart/Blacklist)** and updated regularly.  
All credits for the IP list go to the original author.

---

## Installation

```bash
wget -O install.sh https://raw.githubusercontent.com/Komorebihost/hestiacp-ipset-blacklist/main/install.sh
bash install.sh
```

The installer will:
1. Install `ipset`, `wget`, and `iptables` if not present
2. Deploy `/usr/local/bin/update-blacklist.sh`
3. Deploy `/usr/local/bin/ipset-iptables-insert.sh`
4. Create the `spam-custom` ipset for manual entries
5. Install and enable the systemd boot-restore service
6. Install HestiaCP firewall hook and wrapper (if HestiaCP is detected)
7. Add a cron job (runs at 00:00 and 12:00)
8. Run the first update immediately

---

## Upgrade from a previous version

The installer is idempotent — safe to run multiple times:

```bash
wget -O install.sh https://raw.githubusercontent.com/Komorebihost/hestiacp-ipset-blacklist/main/install.sh
bash install.sh
```

It will update all scripts, fix the systemd service, clean up legacy services, and preserve your `spam-custom` entries.

---

## Usage

### Force an immediate update

```bash
/usr/local/bin/update-blacklist.sh
```

### Manage the custom IP list

```bash
# Add a single IP
ipset add spam-custom 1.2.3.4

# Add a CIDR block
ipset add spam-custom 1.2.3.0/24

# Remove an IP
ipset del spam-custom 1.2.3.4

# List all custom entries
ipset list spam-custom

# Save state after any manual change
ipset save spam-blacklist > /etc/ipset.conf
ipset save spam-custom >> /etc/ipset.conf
```

---

## Tests & verification

### Check loaded IPs

```bash
ipset list spam-blacklist | grep "Number of entries"
ipset list spam-custom | grep "Number of entries"
```

### Verify iptables rules

```bash
iptables -L INPUT -n --line-numbers | grep spam
```

Expected output:
```
1  DROP  all  --  0.0.0.0/0  0.0.0.0/0  match-set spam-blacklist src
2  DROP  all  --  0.0.0.0/0  0.0.0.0/0  match-set spam-custom src
```

### Check if a specific IP is blocked

```bash
ipset test spam-blacklist 1.2.3.4 && echo "BLOCKED" || echo "not in list"
ipset test spam-custom 1.2.3.4    && echo "BLOCKED" || echo "not in list"
```

### Verify the cron job

```bash
crontab -l | grep update-blacklist
```

### Verify the boot service

```bash
systemctl status ipset-restore.service
systemctl is-enabled ipset-restore.service
```

### Check the update log

```bash
tail -20 /var/log/blacklist-update.log
```

### Simulate reboot restore

```bash
ipset destroy spam-blacklist 2>/dev/null || true
systemctl start ipset-restore.service
ipset list spam-blacklist | grep "Number of entries"
iptables -L INPUT -n | grep spam
```

---

## HestiaCP compatibility

HestiaCP rebuilds its own iptables rules when `v-update-firewall` runs (e.g. after panel firewall changes). The installer creates a hook and a wrapper to automatically re-insert the ipset rules after any firewall rebuild.

Use the wrapper instead of `v-update-firewall` directly:

```bash
/usr/local/bin/v-update-firewall-wrapper.sh
```

Or re-insert manually after a panel firewall change:

```bash
/usr/local/bin/ipset-iptables-insert.sh
```

---

## Uninstall

```bash
# Remove cron
crontab -l | grep -v "update-blacklist" | crontab -

# Remove iptables rules
iptables -D INPUT -m set --match-set spam-blacklist src -j DROP 2>/dev/null || true
iptables -D INPUT -m set --match-set spam-custom src -j DROP 2>/dev/null || true

# Destroy ipsets
ipset destroy spam-blacklist 2>/dev/null || true
ipset destroy spam-custom    2>/dev/null || true

# Remove systemd service
systemctl disable ipset-restore.service
rm -f /etc/systemd/system/ipset-restore.service
rm -f /etc/systemd/system/spam-custom-iptables.service
systemctl daemon-reload

# Remove files
rm -f /usr/local/bin/update-blacklist.sh
rm -f /usr/local/bin/ipset-iptables-insert.sh
rm -f /usr/local/bin/v-update-firewall-wrapper.sh
rm -f /usr/local/hestia/data/firewall/ipset-hook.sh
rm -f /etc/ipset.conf
```

---

## Changelog

### v3 (2026-05-12)
- **Optimized:** `update-blacklist.sh` rewritten with a single `awk` pass — built-in deduplication, no subshell loop
- **Improved:** atomic swap with explicit rollback — original set stays intact if swap fails
- **Fixed:** `ipset restore` now uses `-exist` flag — no crash on interrupted previous runs
- **Fixed:** `ipset save` now persists only `spam-blacklist` and `spam-custom` — does not overwrite unrelated sets
- **Fixed:** systemd service uses `DefaultDependencies=no` + `After=local-fs.target` + `Before=network-pre.target` — firewall is active before any network interface comes up
- **Fixed:** `iptables-restore` now uses `--noflush` — existing rules are preserved on restore
- **Fixed:** service `WantedBy=basic.target` for correct early-boot ordering
- **Added:** update log at `/var/log/blacklist-update.log`
- **Added:** wget user-agent to avoid CDN blocks
- **Added:** empty file check after download

### v2 (2026-04-18)
- **Fixed:** iptables rules are now restored after reboot (v1 only restored ipset data)
- **Fixed:** systemd service runs after HestiaCP to prevent rule conflicts
- **Added:** dedicated `ipset-iptables-insert.sh` for reliable rule insertion
- **Added:** HestiaCP firewall wrapper for `v-update-firewall` compatibility
- **Removed:** unnecessary FORWARD chain rules
- **Improved:** installer cleans up legacy services from v1

### v1 (2024)
- Initial release

---

## Disclaimer

This is an independent, community-developed tool. It is **not affiliated with, endorsed by, or supported by** HestiaCP.

Use at your own risk. Always keep backups of your firewall configuration before installation. The authors accept no responsibility for data loss, service disruptions, or misconfiguration resulting from the use of this software.

IP blacklist data is maintained by [@ufukart](https://github.com/ufukart/Blacklist) and is subject to their own terms.

---

## License

MIT License — © 2024 [Komorebihost](https://komorebihost.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, subject to the following conditions: the above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

**THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.**

---

## Contributing

Issues and pull requests are welcome.  
Repository: [github.com/Komorebihost/hestiacp-ipset-blacklist](https://github.com/Komorebihost/hestiacp-ipset-blacklist)
