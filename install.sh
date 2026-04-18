#!/bin/bash
# ============================================================
#  hestiacp-ipset-blacklist — installer
#  Tested on Ubuntu 20.04/22.04/24.04 and Debian 11/12
#  https://github.com/Komorebihost/hestiacp-ipset-blacklist
# ============================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; exit 1; }

[ "$EUID" -ne 0 ] && error "Run as root: sudo bash install.sh"

. /etc/os-release
[[ "$ID" != "ubuntu" && "$ID" != "debian" ]] && error "Unsupported OS: $ID"

info "Detected OS: $PRETTY_NAME"

# ============================================================
# 1. Dependencies
# ============================================================
info "Installing dependencies..."
apt-get update -qq
apt-get install -y -qq ipset wget iptables

# ============================================================
# 2. Main update script (uses ipset restore for speed)
# ============================================================
info "Installing update-blacklist.sh..."
cat > /usr/local/bin/update-blacklist.sh << 'EOF'
#!/bin/bash
BLACKLIST_URL="https://raw.githubusercontent.com/ufukart/Blacklist/main/blacklist.txt"
IPSET_NAME="spam-blacklist"
TMP_FILE="/tmp/blacklist_raw.txt"
TMP_RESTORE="/tmp/blacklist_restore.txt"
TMP_SET="${IPSET_NAME}_tmp"

wget -q --timeout=30 -O "$TMP_FILE" "$BLACKLIST_URL" || exit 1

# Build ipset restore file — much faster than one add per IP
{
    echo "create ${TMP_SET} hash:net maxelem 200000"
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]' "$TMP_FILE" | while read -r ip; do
        echo "add ${TMP_SET} ${ip}"
    done
} > "$TMP_RESTORE"

ipset create "$IPSET_NAME" hash:net maxelem 200000 2>/dev/null || true
ipset destroy "$TMP_SET" 2>/dev/null || true
ipset restore < "$TMP_RESTORE"
ipset swap "$TMP_SET" "$IPSET_NAME"
ipset destroy "$TMP_SET"

# Ensure iptables rules are in place
/usr/local/bin/ipset-iptables-insert.sh

ipset save > /etc/ipset.conf
rm -f "$TMP_FILE" "$TMP_RESTORE"
EOF
chmod +x /usr/local/bin/update-blacklist.sh

# ============================================================
# 3. iptables insertion script (used by systemd and update)
# ============================================================
info "Installing iptables insertion script..."
cat > /usr/local/bin/ipset-iptables-insert.sh << 'INSERTEOF'
#!/bin/bash
# ============================================================
#  Inserts ipset DROP rules into iptables INPUT chain.
#  Safe to run multiple times — checks before inserting.
#  Called by: systemd (ipset-restore.service), update-blacklist.sh
# ============================================================

for SET in spam-blacklist spam-custom; do
    # Skip if the ipset doesn't exist
    ipset list "$SET" &>/dev/null || continue

    # INPUT chain — insert only if not already present
    if ! iptables -C INPUT -m set --match-set "$SET" src -j DROP 2>/dev/null; then
        iptables -I INPUT 1 -m set --match-set "$SET" src -j DROP
    fi
done
INSERTEOF
chmod +x /usr/local/bin/ipset-iptables-insert.sh

# ============================================================
# 4. Custom IP list
# ============================================================
info "Creating spam-custom ipset..."
ipset create spam-custom hash:net maxelem 10000 2>/dev/null || true

# Insert iptables rules
/usr/local/bin/ipset-iptables-insert.sh

# ============================================================
# 5. Systemd service — restores ipset AND iptables rules
# ============================================================
info "Installing systemd service..."

# Remove old service if present (v1 bug: only restored ipset, not iptables rules)
if [ -f /etc/systemd/system/ipset-restore.service ]; then
    systemctl disable ipset-restore.service 2>/dev/null || true
fi
# Remove old iptables-only service if present
if [ -f /etc/systemd/system/spam-custom-iptables.service ]; then
    systemctl disable spam-custom-iptables.service 2>/dev/null || true
    rm -f /etc/systemd/system/spam-custom-iptables.service
fi

cat > /etc/systemd/system/ipset-restore.service << 'EOF'
[Unit]
Description=Restore ipset blacklists and iptables rules
After=network.target hestia.service

[Service]
Type=oneshot
ExecStart=/bin/bash -c '/sbin/ipset restore -! < /etc/ipset.conf 2>/dev/null; /usr/local/bin/ipset-iptables-insert.sh'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ipset-restore.service

# ============================================================
# 6. HestiaCP post-hook (auto-restore after v-update-firewall)
# ============================================================
HESTIA_HOOK="/usr/local/hestia/data/firewall/ipset-hook.sh"
if [ -d /usr/local/hestia/data/firewall ]; then
    info "Installing HestiaCP firewall hook..."
    cat > "$HESTIA_HOOK" << 'EOF'
#!/bin/bash
# Called after v-update-firewall to re-insert ipset rules
/usr/local/bin/ipset-iptables-insert.sh
EOF
    chmod +x "$HESTIA_HOOK"

    # Wrap v-update-firewall to auto-restore ipset rules
    V_UPDATE="/usr/local/hestia/bin/v-update-firewall"
    WRAPPER="/usr/local/bin/v-update-firewall-wrapper.sh"
    if [ -f "$V_UPDATE" ] && ! grep -q "ipset-iptables-insert" "$V_UPDATE" 2>/dev/null; then
        cat > "$WRAPPER" << 'EOF'
#!/bin/bash
# Wrapper: runs v-update-firewall then restores ipset rules
/usr/local/hestia/bin/v-update-firewall "$@"
sleep 1
/usr/local/bin/ipset-iptables-insert.sh
EOF
        chmod +x "$WRAPPER"
        info "Created wrapper: use 'v-update-firewall-wrapper.sh' or re-run update-blacklist.sh after v-update-firewall"
    fi
fi

# ============================================================
# 7. Cron job (every 12 hours)
# ============================================================
info "Installing cron job..."
CRON_LINE="0 0,12 * * * /usr/local/bin/update-blacklist.sh"
( crontab -l 2>/dev/null | grep -v "update-blacklist"; echo "$CRON_LINE" ) | crontab -

# ============================================================
# 8. First run
# ============================================================
info "Running first blacklist update (this may take a moment)..."
/usr/local/bin/update-blacklist.sh

# ============================================================
# 9. Summary
# ============================================================
ENTRIES=$(ipset list spam-blacklist 2>/dev/null | grep "Number of entries" | awk '{print $NF}')
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} Installation complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  Blacklist IPs loaded : ${GREEN}${ENTRIES}${NC}"
echo -e "  Auto-update cron     : ${GREEN}every 12 hours (00:00 and 12:00)${NC}"
echo -e "  Boot restore service : ${GREEN}ipset + iptables rules${NC}"
echo -e "  Custom list          : ${GREEN}spam-custom${NC}"
echo ""
echo -e "  Quick commands:"
echo -e "    Add custom IP  : ${YELLOW}ipset add spam-custom 1.2.3.4 && ipset save > /etc/ipset.conf${NC}"
echo -e "    Remove custom  : ${YELLOW}ipset del spam-custom 1.2.3.4 && ipset save > /etc/ipset.conf${NC}"
echo -e "    Force update   : ${YELLOW}/usr/local/bin/update-blacklist.sh${NC}"
echo -e "    Check status   : ${YELLOW}ipset list spam-blacklist | grep 'Number of entries'${NC}"
echo ""
