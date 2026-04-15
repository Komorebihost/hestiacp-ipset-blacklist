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
- On reboot, the ipset is automatically restored via a **systemd service**
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
3. Create the `spam-custom` ipset for manual entries
4. Install and enable the systemd boot-restore service
5. Add a cron job (runs at 00:00 and 12:00)
6. Run the first update immediately

---

## Update

To update the installer itself (re-run install):

```bash
wget -O install.sh https://raw.githubusercontent.com/Komorebihost/hestiacp-ipset-blacklist/main/install.sh
bash install.sh
```

The script is idempotent — safe to run multiple times.

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

HestiaCP manages its own iptables rules. If you run `v-update-firewall` manually (e.g. after changing firewall rules in the panel), re-run the update script immediately after to restore the ipset rules:

```bash
/usr/local/hestia/bin/v-update-firewall
/usr/local/bin/update-blacklist.sh
```

---

## Uninstall

```bash
# Remove cron
crontab -l | grep -v "update-blacklist" | crontab -

# Remove iptables rules
iptables -D INPUT   -m set --match-set spam-blacklist src -j DROP 2>/dev/null || true
iptables -D FORWARD -m set --match-set spam-blacklist src -j DROP 2>/dev/null || true
iptables -D INPUT   -m set --match-set spam-custom src -j DROP 2>/dev/null || true
iptables -D FORWARD -m set --match-set spam-custom src -j DROP 2>/dev/null || true

# Destroy ipsets
ipset destroy spam-blacklist 2>/dev/null || true
ipset destroy spam-custom    2>/dev/null || true

# Remove systemd service
systemctl disable ipset-restore.service
rm -f /etc/systemd/system/ipset-restore.service
systemctl daemon-reload

# Remove files
rm -f /usr/local/bin/update-blacklist.sh
rm -f /etc/ipset.conf
```

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
