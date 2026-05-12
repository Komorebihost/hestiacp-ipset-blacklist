#!/bin/bash
# hestiacp-ipset-blacklist — installer v3
# Tested on Ubuntu 20.04/22.04/24.04 and Debian 11/12
# https://github.com/Komorebihost/hestiacp-ipset-blacklist

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[+]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
error() { echo -e "${RED}[x]${NC} $*"; exit 1; }

[ "$EUID" -ne 0 ] && error "Run as root: sudo bash install.sh"

. /etc/os-release
[[ "$ID" != "ubuntu" && "$ID" != "debian" ]] && error "Unsupported OS: $ID"

info "Detected OS: $PRETTY_NAME"

# ── 1. Dependencies ────────────────────────────────────────
info "Installing dependencies..."
apt-get update -qq
apt-get install -y -qq ipset wget iptables

# ── 2. Main update script ──────────────────────────────────
info "Installing update-blacklist.sh..."
cat > /usr/local/bin/update-blacklist.sh << 'BLEOF'
#!/bin/bash
set -euo pipefail

IPSET_NAME="spam-blacklist"
TMP_SET="${IPSET_NAME}_tmp"
TMP_FILE="/tmp/bl_raw.txt"
TMP_RESTORE="/tmp/bl_restore.txt"
LOG="/var/log/blacklist-update.log"
URL="https://raw.githubusercontent.com/ufukart/Blacklist/main/blacklist.txt"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

wget -q --timeout=30 --user-agent="Mozilla/5.0" -O "$TMP_FILE" "$URL" \
    || { log "ERROR: download failed"; exit 1; }

[[ -s "$TMP_FILE" ]] || { log "ERROR: empty file"; rm -f "$TMP_FILE"; exit 1; }

awk -v s="$TMP_SET" '
    BEGIN { print "create " s " hash:net maxelem 200000" }
    /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(\/[0-9]+)?$/ && !seen[$1]++ { print "add " s " " $1 }
' "$TMP_FILE" > "$TMP_RESTORE"

ipset create "$IPSET_NAME" hash:net maxelem 200000 2>/dev/null || true
ipset destroy "$TMP_SET" 2>/dev/null || true

ipset restore -exist < "$TMP_RESTORE" || { log "ERROR: restore failed"; rm -f "$TMP_FILE" "$TMP_RESTORE"; exit 1; }

ipset swap "$TMP_SET" "$IPSET_NAME" || {
    log "ERROR: swap failed — original set intact"
    ipset destroy "$TMP_SET" 2>/dev/null || true
    rm -f "$TMP_FILE" "$TMP_RESTORE"
    exit 1
}

ipset destroy "$TMP_SET"
/usr/local/bin/ipset-iptables-insert.sh

ipset save "$IPSET_NAME" > /etc/ipset.conf
ipset list spam-custom &>/dev/null && ipset save spam-custom >> /etc/ipset.conf || true

iptables-save > /etc/iptables/rules.v4
rm -f "$TMP_FILE" "$TMP_RESTORE"

log "OK — $(ipset list "$IPSET_NAME" | awk '/Number of entries/{print $NF}') IPs loaded"
BLEOF
chmod +x /usr/local/bin/update-blacklist.sh

# ── 3. iptables insertion script ───────────────────────────
info "Installing ipset-iptables-insert.sh..."
cat > /usr/local/bin/ipset-iptables-insert.sh << 'INSERTEOF'
#!/bin/bash
for SET in spam-blacklist spam-custom; do
    ipset list "$SET" &>/dev/null || continue
    if ! iptables -C INPUT -m set --match-set "$SET" src -j DROP 2>/dev/null; then
        iptables -I INPUT 1 -m set --match-set "$SET" src -j DROP
    fi
done
INSERTEOF
chmod +x /usr/local/bin/ipset-iptables-insert.sh

# ── 4. Custom IP list ──────────────────────────────────────
info "Creating spam-custom ipset..."
ipset create spam-custom hash:net maxelem 10000 2>/dev/null || true
/usr/local/bin/ipset-iptables-insert.sh

# ── 5. Systemd service ─────────────────────────────────────
info "Installing systemd service..."

if [ -f /etc/systemd/system/ipset-restore.service ]; then
    systemctl disable ipset-restore.service 2>/dev/null || true
fi
if [ -f /etc/systemd/system/spam-custom-iptables.service ]; then
    systemctl disable spam-custom-iptables.service 2>/dev/null || true
    rm -f /etc/systemd/system/spam-custom-iptables.service
fi

cat > /etc/systemd/system/ipset-restore.service << 'SVCEOF'
[Unit]
Description=Restore ipset and iptables
DefaultDependencies=no
After=local-fs.target
Before=network-pre.target network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ipset restore -exist -f /etc/ipset.conf
ExecStartPost=/sbin/iptables-restore --noflush /etc/iptables/rules.v4

[Install]
WantedBy=basic.target
SVCEOF
systemctl daemon-reload
systemctl enable ipset-restore.service

# ── 6. HestiaCP post-hook ──────────────────────────────────
HESTIA_HOOK="/usr/local/hestia/data/firewall/ipset-hook.sh"
if [ -d /usr/local/hestia/data/firewall ]; then
    info "Installing HestiaCP firewall hook..."
    cat > "$HESTIA_HOOK" << 'HOOKEOF'
#!/bin/bash
/usr/local/bin/ipset-iptables-insert.sh
HOOKEOF
    chmod +x "$HESTIA_HOOK"

    V_UPDATE="/usr/local/hestia/bin/v-update-firewall"
    WRAPPER="/usr/local/bin/v-update-firewall-wrapper.sh"
    if [ -f "$V_UPDATE" ] && ! grep -q "ipset-iptables-insert" "$V_UPDATE" 2>/dev/null; then
        cat > "$WRAPPER" << 'WRAPEOF'
#!/bin/bash
/usr/local/hestia/bin/v-update-firewall "$@"
sleep 1
/usr/local/bin/ipset-iptables-insert.sh
WRAPEOF
        chmod +x "$WRAPPER"
        info "Created wrapper: use v-update-firewall-wrapper.sh after panel firewall changes"
    fi
fi

# ── 7. Cron job ────────────────────────────────────────────
info "Installing cron job..."
( crontab -l 2>/dev/null | grep -v "update-blacklist"; echo "0 0,12 * * * /usr/local/bin/update-blacklist.sh" ) | crontab -

# ── 8. First run ───────────────────────────────────────────
info "Running first blacklist update..."
/usr/local/bin/update-blacklist.sh

# ── 9. Summary ─────────────────────────────────────────────
ENTRIES=$(ipset list spam-blacklist 2>/dev/null | awk '/Number of entries/{print $NF}')
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
echo -e "    Add IP to custom   : ${YELLOW}ipset add spam-custom 1.2.3.4${NC}"
echo -e "    Remove from custom : ${YELLOW}ipset del spam-custom 1.2.3.4${NC}"
echo -e "    Save state         : ${YELLOW}ipset save spam-blacklist > /etc/ipset.conf && ipset save spam-custom >> /etc/ipset.conf${NC}"
echo -e "    Force update       : ${YELLOW}/usr/local/bin/update-blacklist.sh${NC}"
echo -e "    Check status       : ${YELLOW}ipset list spam-blacklist | grep 'Number of entries'${NC}"
echo ""
