# hestiacp-ipset-blacklist

Automatic IP blacklist blocker for Linux servers using **ipset** and **iptables**.  
Blocks malicious traffic — spam, phishing, port scanners, botnets — at the kernel level, before it reaches any service.

Tested on **Ubuntu 20.04 / 22.04 / 24.04** and **Debian 11 / 12**.  
Works alongside **HestiaCP**, **fail2ban**, and **UFW** (when inactive) without conflicts.

---

## How it works

- Downloads a curated IP blacklist every 12 hours via cron
- Loads all IPs into an **ipset** hash table (extremely fast even with 100k+ entries)
- **iptables** drops all traffic from blacklisted IPs at kernel level
- On reboot, both ipset data **and iptables rules** are automatically restored via a **systemd service** (runs after HestiaCP to prevent rule conflicts)
- A separate **custom list** (`spam-custom`) lets you add your own IPs manually — it is never overwritten by automatic updates

### Blacklist source

The blacklist is maintained by **[@ufukart](https://github.com/ufukart/Blacklist)** and updated regularly.  
All credits for the IP list go to the original author.

---

## Installation

```bash
wget -O install.sh https://raw.githubusercontent.com/Komorebihost/hestiacp-ipset-blacklist/main/install.sh
bash install.sh
```

The installer will:
1. Install `ipset` and `wget` if not present
2. Deploy the update script to `/usr/local/bin/update-blacklist.sh`
3. Deploy the iptables insertion script to `/usr/local/bin/ipset-iptables-insert.sh`
4. Create the `spam-custom` ipset for manual entries
5. Install and enable the systemd boot-restore service (restores both ipset and iptables rules)
6. Add a cron job (runs at 00:00 and 12:00)
7. Run the first update immediately

---

## Upgrade from v1

If you installed a previous version, simply re-run the installer:

```bash
wget -O install.sh https://raw.githubusercontent.com/Komorebihost/hestiacp-ipset-blacklist/main/install.sh
bash install.sh
```

The installer is idempotent — safe to run multiple times. It will:
- Update all scripts to the latest version
- Fix the systemd service to restore **both** ipset and iptables rules after reboot
- Clean up any legacy services (`spam-custom-iptables.service`)
- Preserve your existing `spam-custom` entries

### What changed in v2

**Bug fix:** In v1, the systemd service only restored ipset data at boot but did **not** re-insert the iptables rules. Since HestiaCP rebuilds iptables on startup, the ipset lists were loaded but never referenced — meaning **no traffic was actually blocked after a reboot** until the next cron run (up to 12 hours later).

v2 fixes this by:
- Restoring iptables rules together with ipset data in the systemd service
- Running the service **after** HestiaCP (`After=hestia.service`) so rules aren't overwritten
- Extracting iptables insertion into a dedicated script (`ipset-iptables-insert.sh`) reused by all components

---

## Usage

### Force an immediate blacklist update

```bash
/usr/local/bin/update-blacklist.sh
```

### Add IPs to the custom list

```bash
# Single IP
ipset add spam-custom 1.2.3.4
ipset save > /etc/ipset.conf

# CIDR block
ipset add spam-custom 1.2.3.0/24
ipset save > /etc/ipset.conf

# Multiple IPs
ipset add spam-custom 1.2.3.4
ipset add spam-custom 5.6.7.8
ipset add spam-custom 9.10.11.12
ipset save > /etc/ipset.conf
```

### Remove an IP from the custom list

```bash
ipset del spam-custom 1.2.3.4
ipset save > /etc/ipset.conf
```

### List all IPs in the custom list

```bash
ipset list spam-custom
```

---

## Tests & verification

### Check how many IPs are loaded

```bash
ipset list spam-blacklist | grep "Number of entries"
ipset list spam-custom | grep "Number of entries"
```

### Verify iptables rules are active

```bash
iptables -L INPUT -n | grep spam
```

Expected output:
```
DROP  all  --  0.0.0.0/0  0.0.0.0/0  match-set spam-blacklist src
DROP  all  --  0.0.0.0/0  0.0.0.0/0  match-set spam-custom src
```

### Check if a specific IP is blocked

```bash
ipset test spam-blacklist 1.2.3.4 && echo "BLOCKED" || echo "not in list"
ipset test spam-custom 1.2.3.4    && echo "BLOCKED" || echo "not in list"
```

### Simulate blocking your own IP (connection test)

> **Warning:** Keep your current SSH session open. Only new connections will be blocked.

```bash
# Find your public IP
curl -s ifconfig.me

# Add it to custom list
ipset add spam-custom YOUR_IP

# Try opening a NEW ssh connection from your PC — it should time out

# Remove it
ipset del spam-custom YOUR_IP
ipset save > /etc/ipset.conf
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

### Check the saved ipset state (persisted across reboots)

```bash
wc -l /etc/ipset.conf
```

---

## HestiaCP compatibility note

HestiaCP manages its own iptables rules. If you run `v-update-firewall` manually (e.g. after changing firewall rules in the panel), the ipset rules will be removed. Re-run the insertion script immediately after:

```bash
/usr/local/hestia/bin/v-update-firewall
/usr/local/bin/ipset-iptables-insert.sh
```

Or use the wrapper script installed automatically:

```bash
/usr/local/bin/v-update-firewall-wrapper.sh
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

### v2 (2026-04-18)
- **Fixed:** iptables rules are now restored after reboot (v1 only restored ipset data)
- **Fixed:** systemd service runs after HestiaCP to prevent rule conflicts
- **Added:** dedicated `ipset-iptables-insert.sh` script for reliable rule insertion
- **Added:** HestiaCP firewall wrapper for `v-update-firewall` compatibility
- **Removed:** unnecessary FORWARD chain rules (not needed on most hosting servers)
- **Improved:** installer cleans up legacy services from v1

### v1 (2024)
- Initial release

---

## Disclaimer

> This plugin is an independent, community-developed tool. It is **not affiliated with, endorsed by, or supported by** HestiaCP.
>
> Use at your own risk. Always keep backups of your firewall configuration before installation. The authors accept no responsibility for data loss, service disruptions, or misconfiguration resulting from the use of this software.
>
> IP blacklist data is maintained by [@ufukart](https://github.com/ufukart/Blacklist) and is subject to their own terms.

---

## License

MIT License — © 2024 [Komorebihost](https://komorebihost.com)

Permission is hereby granted, free of charge, to any person obtaining a copy of this software to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the software, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all copies or substantial portions of the software.

**THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.**

---

## Contributing

Issues and pull requests are welcome.  
Repository: [github.com/Komorebihost/hestiacp-ipset-blacklist](https://github.com/Komorebihost/hestiacp-ipset-blacklist)
