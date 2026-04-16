#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Pi Edge Node — Setup v4
# Debian 13 | deniederror
#
# ADAPTADOR : LV-UW06 (Ralink RT5370) → wlan1
# TOPOLOGIA : wlan1 (internet) → Pi → eth0 (cabo PC)
#                                    → wlan0 (AP PiEdge-Net)
#
# ORDEM CORRETA:
#   1. Instala pacotes
#   2. Confirma driver RT5370
#   3. Cria estrutura/venv/Flask
#   4. Libera APENAS wlan0 e eth0 do NM (wlan1 fica livre para NM)
#   5. Configura IPs estáticos (wlan0, eth0)
#   6. hostapd / dnsmasq / NAT
#   7. Serviço systemd
#
# Uso: sudo ./setup.sh
# ═══════════════════════════════════════════════════════════════
set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
fail() { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && fail "Rode com: sudo ./setup.sh"

USER_NAME="deniederror"
INSTALL_DIR="/home/$USER_NAME/pi-edge-node"
STATIC_DIR="$INSTALL_DIR/static"
WAN="wlan1"
ETH="eth0"
AP="wlan0"
ETH_IP="192.168.50.1"
AP_IP="10.0.0.1"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  Pi Edge Node v4 — LV-UW06 · eth0 · wlan0"
echo "═══════════════════════════════════════════════════════"
echo ""

# ── 1. Pacotes ───────────────────────────────────────────────
info "Instalando pacotes..."
apt-get update -qq
apt-get install -y -qq \
    python3 python3-pip python3-venv \
    hostapd dnsmasq iptables-persistent \
    network-manager firmware-misc-nonfree \
    net-tools wireless-tools curl git
log "Pacotes OK"

# ── 2. Driver RT5370 ─────────────────────────────────────────
info "Verificando driver RT5370..."
modprobe rt2800usb 2>/dev/null || true
if lsmod | grep -q rt2800usb; then
    log "rt2800usb carregado"
else
    warn "rt2800usb não detectado — verifique se o USB está plugado"
fi

# ── 3. Projeto ───────────────────────────────────────────────
info "Criando estrutura em $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR" "$STATIC_DIR"
chown -R $USER_NAME:$USER_NAME "$INSTALL_DIR"

info "Instalando Flask no venv..."
sudo -u $USER_NAME python3 -m venv "$INSTALL_DIR/venv"
sudo -u $USER_NAME "$INSTALL_DIR/venv/bin/pip" install --quiet flask
log "Flask OK"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "$SCRIPT_DIR/server.py" ]; then
    cp "$SCRIPT_DIR/server.py" "$INSTALL_DIR/server.py"
    chown $USER_NAME:$USER_NAME "$INSTALL_DIR/server.py"
    log "server.py copiado"
else
    fail "server.py não encontrado em $SCRIPT_DIR"
fi

for f in online.html offline.html; do
    if [ -f "$SCRIPT_DIR/static/$f" ]; then
        cp "$SCRIPT_DIR/static/$f" "$STATIC_DIR/$f"
        chown $USER_NAME:$USER_NAME "$STATIC_DIR/$f"
        log "$f copiado"
    else
        warn "static/$f não encontrado — crie depois"
    fi
done

# ── 4. NetworkManager — libera wlan0 e eth0 APENAS ──────────
# wlan1 PERMANECE gerenciado pelo NM para conectar no Wi-Fi
info "Configurando NetworkManager..."

nmcli device disconnect "$AP" 2>/dev/null || true
nmcli device disconnect "$ETH" 2>/dev/null || true

NM_CONF="/etc/NetworkManager/NetworkManager.conf"

# Remove bloco [keyfile] anterior para evitar duplicatas
python3 - <<PYEOF
import re, pathlib
p = pathlib.Path("$NM_CONF")
txt = p.read_text()
txt = re.sub(r'\n\[keyfile\][^\[]*', '', txt)
p.write_text(txt.strip() + '\n')
PYEOF

# Adiciona bloco limpo
cat >> "$NM_CONF" <<'NM'

[keyfile]
unmanaged-devices=interface-name:wlan0,interface-name:eth0
NM

systemctl restart NetworkManager
sleep 2
log "NM: wlan0 e eth0 não gerenciados | wlan1 livre para conectar"

# ── 5. IPs estáticos via /etc/network/interfaces.d ──────────
info "Configurando IPs estáticos..."

cat > /etc/network/interfaces.d/eth0-static <<IFACE
auto eth0
iface eth0 inet static
    address ${ETH_IP}
    netmask 255.255.255.0
IFACE

cat > /etc/network/interfaces.d/wlan0-ap <<IFACE
auto wlan0
iface wlan0 inet static
    address ${AP_IP}
    netmask 255.255.255.0
IFACE

# Aplica imediatamente
ip addr flush dev eth0  2>/dev/null || true
ip addr flush dev wlan0 2>/dev/null || true
ip addr add ${ETH_IP}/24 dev eth0  2>/dev/null || true
ip addr add ${AP_IP}/24  dev wlan0 2>/dev/null || true
ip link set eth0  up 2>/dev/null || true
ip link set wlan0 up 2>/dev/null || true

log "eth0  → ${ETH_IP}/24"
log "wlan0 → ${AP_IP}/24"

# ── 6a. hostapd ──────────────────────────────────────────────
info "Configurando hostapd..."
systemctl stop hostapd 2>/dev/null || true
systemctl unmask hostapd

cat > /etc/hostapd/hostapd.conf <<'HCONF'
interface=wlan0
driver=nl80211
ssid=PiEdge-Net
hw_mode=g
channel=6
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=piedge2024
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
HCONF

# Garante DAEMON_CONF apontando certo
sed -i 's|^#*DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' \
    /etc/default/hostapd
grep -q 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' /etc/default/hostapd \
    || echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd

log "hostapd: PiEdge-Net / piedge2024"

# ── 6b. dnsmasq ──────────────────────────────────────────────
info "Configurando dnsmasq..."
[ -f /etc/dnsmasq.conf ] && cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak

cat > /etc/dnsmasq.conf <<DCONF
# Não toca no wlan1 (gerenciado pelo NM)
except-interface=${WAN}
bind-interfaces

# eth0 — cabo para PC
interface=${ETH}
dhcp-range=192.168.50.10,192.168.50.50,255.255.255.0,24h

# wlan0 — AP Wi-Fi
interface=${AP}
dhcp-range=10.0.0.10,10.0.0.100,255.255.255.0,24h
address=/pi.local/${AP_IP}

server=8.8.8.8
server=1.1.1.1
DCONF

log "dnsmasq: eth0 (50.x) | wlan0 (10.0.0.x)"

# ── 6c. NAT / IP forwarding ──────────────────────────────────
info "Ativando NAT..."
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf \
    || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null

iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true

# wlan1 → eth0
iptables -t nat -A POSTROUTING -o ${WAN} -j MASQUERADE
iptables -A FORWARD -i ${WAN} -o ${ETH} \
    -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i ${ETH} -o ${WAN} -j ACCEPT

# wlan1 → wlan0
iptables -A FORWARD -i ${WAN} -o ${AP} \
    -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i ${AP}  -o ${WAN} -j ACCEPT

netfilter-persistent save >/dev/null 2>&1
log "NAT: ${WAN} → ${ETH} e ${AP}"

# ── 7. Serviço systemd ───────────────────────────────────────
info "Criando serviço piserver..."
cat > /etc/systemd/system/piserver.service <<SVCEOF
[Unit]
Description=Pi Edge Node — Flask
After=network-online.target hostapd.service dnsmasq.service
Wants=network-online.target

[Service]
Type=simple
User=${USER_NAME}
WorkingDirectory=${INSTALL_DIR}
Environment="PORT=5000"
Environment="WAN_IFACE=${WAN}"
Environment="ETH_IFACE=${ETH}"
Environment="AP_IFACE=${AP}"
ExecStart=${INSTALL_DIR}/venv/bin/python server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=piserver

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable piserver hostapd dnsmasq
log "Serviços habilitados no boot"

# ── Fim ──────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo -e "  ${GREEN}✓ Setup concluído!${NC}"
echo "═══════════════════════════════════════════════════════"
echo ""
echo -e "  ${YELLOW}AGORA (antes de reiniciar):${NC}"
echo -e "  Conecte o wlan1 à sua rede Wi-Fi:"
echo -e "  ${CYAN}sudo nmcli device wifi connect \"SuaRede\" password \"Senha\" ifname wlan1${NC}"
echo ""
echo -e "  Depois reinicie:"
echo -e "  ${CYAN}sudo reboot${NC}"
echo ""
echo -e "  Após reboot:"
echo -e "  AP Wi-Fi  → ${CYAN}PiEdge-Net${NC} / ${CYAN}piedge2024${NC}"
echo -e "  Flask AP  → ${CYAN}http://${AP_IP}:5000${NC}"
echo -e "  Flask cab → ${CYAN}http://${ETH_IP}:5000${NC}"
echo ""