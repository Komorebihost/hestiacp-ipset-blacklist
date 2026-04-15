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
    echo "create ${TMP_SET} hash:net maxelem 100000"
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]' "$TMP_FILE" | while read -r ip; do
        echo "add ${TMP_SET} ${ip}"
    done
} > "$TMP_RESTORE"

ipset create "$IPSET_NAME" hash:net maxelem 100000 2>/dev/null || true
ipset destroy "$TMP_SET" 2>/dev/null || true
ipset restore < "$TMP_RESTORE"
ipset swap "$TMP_SET" "$IPSET_NAME"
ipset destroy "$TMP_SET"

iptables -C INPUT   -m set --match-set "$IPSET_NAME" src -j DROP 2>/dev/null || \
    iptables -I INPUT   1 -m set --match-set "$IPSET_NAME" src -j DROP
iptables -C FORWARD -m set --match-set "$IPSET_NAME" src -j DROP 2>/dev/null || \
    iptables -I FORWARD 1 -m set --match-set "$IPSET_NAME" src -j DROP

ipset save > /etc/ipset.conf
rm -f "$TMP_FILE" "$TMP_RESTORE"
EOF
chmod +x /usr/local/bin/update-blacklist.sh

# ============================================================
# 3. Custom IP list
# ============================================================
info "Creating spam-custom ipset..."
ipset create spam-custom hash:net maxelem 10000 2>/dev/null || true

iptables -C INPUT   -m set --match-set spam-custom src -j DROP 2>/dev/null || \
    iptables -I INPUT   1 -m set --match-set spam-custom src -j DROP
iptables -C FORWARD -m set --match-set spam-custom src -j DROP 2>/dev/null || \
    iptables -I FORWARD 1 -m set --match-set spam-custom src -j DROP

# ============================================================
# 4. Systemd service for restore at boot
# ============================================================
info "Installing ipset-restore systemd service..."
cat > /etc/systemd/system/ipset-restore.service << 'EOF'
[Unit]
Description=Restore ipset spam blacklist
Before=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ipset restore -f /etc/ipset.conf
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ipset-restore.service

# ============================================================
# 5. Cron job (every 12 hours)
# ============================================================
info "Installing cron job..."
CRON_LINE="0 0,12 * * * /usr/local/bin/update-blacklist.sh"
( crontab -l 2>/dev/null | grep -v "update-blacklist"; echo "$CRON_LINE" ) | crontab -

# ============================================================
# 6. First run
# ============================================================
info "Running first blacklist update (this may take a moment)..."
/usr/local/bin/update-blacklist.sh

# ============================================================
# 7. Summary
# ============================================================
ENTRIES=$(ipset list spam-blacklist | grep "Number of entries" | awk '{print $NF}')
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} Installation complete!${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  Blacklist IPs loaded : ${GREEN}${ENTRIES}${NC}"
echo -e "  Auto-update cron     : ${GREEN}every 12 hours (00:00 and 12:00)${NC}"
echo -e "  Boot restore service : ${GREEN}enabled${NC}"
echo -e "  Custom list          : ${GREEN}spam-custom (empty, add IPs manually)${NC}"
echo ""
echo -e "  Quick commands:"
echo -e "    Add custom IP  : ${YELLOW}ipset add spam-custom 1.2.3.4 && ipset save > /etc/ipset.conf${NC}"
echo -e "    Remove custom  : ${YELLOW}ipset del spam-custom 1.2.3.4 && ipset save > /etc/ipset.conf${NC}"
echo -e "    Force update   : ${YELLOW}/usr/local/bin/update-blacklist.sh${NC}"
echo -e "    Check status   : ${YELLOW}ipset list spam-blacklist | grep 'Number of entries'${NC}"
echo ""
