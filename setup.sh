#!/bin/bash

# ═══════════════════════════════════════════════════════════════
# Pi Edge Node — Setup completo v3
# Sistema: Debian 13 (Trixie) | Usuário: deniederror
#
# ADAPTADOR: LV-UW06 — Chipset Ralink RT5370
#            Driver: rt2800usb (nativo no kernel, sem DKMS)
#
# TOPOLOGIA:
#   wlan1 (USB LV-UW06) ──→ Pi ──┬──→ eth0  (cabo Ethernet → PC)
#                                  └──→ wlan0 (AP Wi-Fi PiEdge-Net)
#
# Uso: chmod +x setup.sh && sudo ./setup.sh
# ═══════════════════════════════════════════════════════════════

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $1"; }
info() { echo -e "${CYAN}[..]${NC} $1"; }
warn() { echo -e "${YELLOW}[!!]${NC} $1"; }
fail() { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && fail "Execute com sudo: sudo ./setup.sh"

# ── Variáveis globais ────────────────────────────────────────
USER_NAME="deniederror"
USER_HOME="/home/$USER_NAME"
INSTALL_DIR="$USER_HOME/pi-edge-node"
STATIC_DIR="$INSTALL_DIR/static"

WAN_IFACE="wlan1"       # USB LV-UW06 — cliente Wi-Fi (internet)
ETH_IFACE="eth0"        # Ethernet — saída cabeada para PC
AP_IFACE="wlan0"        # Wi-Fi interno — Access Point

ETH_IP="192.168.50.1"   # IP do Pi na rede cabeada
AP_IP="10.0.0.1"        # IP do Pi na rede Wi-Fi AP

echo ""
echo "═══════════════════════════════════════════════════════"
echo " Pi Edge Node v3 — Instalação"
echo " LV-UW06 (RT5370) · wlan1→WAN · eth0→PC · wlan0→AP"
echo "═══════════════════════════════════════════════════════"
echo ""

# ───────────────────────────────────────────────────────────
# ETAPA 1 — Dependências
# ───────────────────────────────────────────────────────────
info "Atualizando pacotes…"
apt-get update -qq
apt-get install -y -qq \
    python3 python3-pip python3-venv \
    hostapd dnsmasq iptables-persistent \
    network-manager firmware-misc-nonfree \
    git curl net-tools wireless-tools wpasupplicant
log "Dependências instaladas"

# ───────────────────────────────────────────────────────────
# ETAPA 2 — Verificar driver RT5370 (nativo no kernel)
# Não precisa de DKMS — apenas garante o firmware
# ───────────────────────────────────────────────────────────
info "Verificando driver RT5370 (rt2800usb)…"

# Carrega o módulo caso não esteja ativo
modprobe rt2800usb 2>/dev/null || true

if lsmod | grep -q rt2800usb; then
    log "Driver rt2800usb carregado"
else
    warn "rt2800usb não detectado — verifique se o adaptador está plugado"
fi

# Verifica firmware (necessário para RT5370)
if [ ! -f /lib/firmware/rt2870.bin ]; then
    info "Instalando firmware Ralink…"
    apt-get install -y -qq firmware-ralink 2>/dev/null \
        || apt-get install -y -qq firmware-misc-nonfree 2>/dev/null \
        || warn "Firmware não encontrado via apt — tente: apt install firmware-ralink"
else
    log "Firmware Ralink já presente"
fi

# ───────────────────────────────────────────────────────────
# ETAPA 3 — Aguarda interfaces aparecerem
# ───────────────────────────────────────────────────────────
info "Aguardando interfaces de rede…"
sleep 2

# Detecta o nome real do adaptador USB (pode ser wlan1, wlan2, etc.)
USB_IFACE=$(ip link show | grep -v 'wlan0\|eth0\|lo\|: e' \
    | grep -oP 'wlan\d+' | head -1 || echo "wlan1")

if [ "$USB_IFACE" != "$WAN_IFACE" ] && [ -n "$USB_IFACE" ]; then
    warn "Adaptador USB detectado como '$USB_IFACE' (esperado: '$WAN_IFACE')"
    warn "Ajustando WAN_IFACE para '$USB_IFACE'…"
    WAN_IFACE="$USB_IFACE"
fi

log "Interfaces: WAN=$WAN_IFACE | ETH=$ETH_IFACE | AP=$AP_IFACE"

# ───────────────────────────────────────────────────────────
# ETAPA 4 — Estrutura do projeto
# ───────────────────────────────────────────────────────────
info "Criando estrutura de diretórios…"
mkdir -p "$INSTALL_DIR" "$STATIC_DIR"
chown -R $USER_NAME:$USER_NAME "$INSTALL_DIR"
log "Diretórios: $INSTALL_DIR"

info "Criando ambiente virtual Python…"
sudo -u $USER_NAME python3 -m venv "$INSTALL_DIR/venv"
sudo -u $USER_NAME "$INSTALL_DIR/venv/bin/pip" install --quiet flask
log "Flask instalado no venv"

# ───────────────────────────────────────────────────────────
# ETAPA 5 — Copiar arquivos do projeto
# ───────────────────────────────────────────────────────────
info "Copiando arquivos do servidor…"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -f "$SCRIPT_DIR/server.py" ] \
    && cp "$SCRIPT_DIR/server.py" "$INSTALL_DIR/server.py" \
    && chown $USER_NAME:$USER_NAME "$INSTALL_DIR/server.py" \
    && log "server.py copiado" \
    || fail "server.py não encontrado em $SCRIPT_DIR"

for f in online.html offline.html; do
    if [ -f "$SCRIPT_DIR/static/$f" ]; then
        cp "$SCRIPT_DIR/static/$f" "$STATIC_DIR/$f"
        chown $USER_NAME:$USER_NAME "$STATIC_DIR/$f"
        log "$f copiado"
    else
        warn "$f não encontrado em static/ — dashboard pode não carregar"
    fi
done

# ───────────────────────────────────────────────────────────
# ETAPA 6 — NetworkManager: libera wlan0 e eth0, mantém wlan1
# wlan1 fica gerenciado pelo NM para conectar no Wi-Fi facilmente
# ───────────────────────────────────────────────────────────
info "Configurando NetworkManager…"
nmcli device disconnect wlan0 2>/dev/null || true
nmcli device disconnect eth0  2>/dev/null || true

NM_CONF="/etc/NetworkManager/NetworkManager.conf"
# Remove qualquer linha unmanaged existente e reescreve
sed -i '/^\[keyfile\]/,/^unmanaged-devices/d' "$NM_CONF" 2>/dev/null || true
cat >> "$NM_CONF" <<NM

[keyfile]
unmanaged-devices=interface-name:wlan0,interface-name:eth0
NM

systemctl restart NetworkManager
sleep 1
log "NM: wlan0 e eth0 não gerenciados | wlan1 gerenciado"

# ───────────────────────────────────────────────────────────
# ETAPA 7 — IP estático: eth0 (saída cabeada)
# ───────────────────────────────────────────────────────────
info "Configurando eth0 → ${ETH_IP}/24…"
cat > /etc/network/interfaces.d/eth0-lan <<EOF
auto eth0
iface eth0 inet static
    address ${ETH_IP}
    netmask 255.255.255.0
EOF

ip addr flush dev eth0 2>/dev/null || true
ip addr add ${ETH_IP}/24 dev eth0 2>/dev/null || true
ip link set eth0 up 2>/dev/null || true
log "eth0 → ${ETH_IP}/24"

# ───────────────────────────────────────────────────────────
# ETAPA 8 — IP estático: wlan0 (AP)
# ───────────────────────────────────────────────────────────
info "Configurando wlan0 → ${AP_IP}/24…"
cat > /etc/network/interfaces.d/wlan0-ap <<EOF
auto wlan0
iface wlan0 inet static
    address ${AP_IP}
    netmask 255.255.255.0
EOF

ip addr flush dev wlan0 2>/dev/null || true
ip addr add ${AP_IP}/24 dev wlan0 2>/dev/null || true
ip link set wlan0 up 2>/dev/null || true
log "wlan0 → ${AP_IP}/24"

# ───────────────────────────────────────────────────────────
# ETAPA 9 — hostapd (AP no wlan0 interno do Pi)
# ───────────────────────────────────────────────────────────
info "Configurando hostapd (AP)…"
cat > /etc/hostapd/hostapd.conf <<'EOF'
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
EOF

sed -i 's|^#*DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
grep -q 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' /etc/default/hostapd \
    || echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd

systemctl unmask hostapd
log "hostapd: SSID=PiEdge-Net | Senha=piedge"

# ───────────────────────────────────────────────────────────
# ETAPA 10 — dnsmasq (DHCP para eth0 e wlan0)
# ───────────────────────────────────────────────────────────
info "Configurando dnsmasq (DHCP duplo)…"
[ -f /etc/dnsmasq.conf ] && cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak

cat > /etc/dnsmasq.conf <<EOF
# ── eth0: rede cabeada ────────────────────────────────────
interface=eth0
dhcp-range=192.168.50.10,192.168.50.50,255.255.255.0,24h

# ── wlan0: Access Point Wi-Fi ─────────────────────────────
interface=wlan0
dhcp-range=10.0.0.10,10.0.0.100,255.255.255.0,24h
address=/pi.local/${AP_IP}

# DNS público de fallback
server=8.8.8.8
server=1.1.1.1
EOF
log "dnsmasq: eth0 (192.168.50.10–50) | wlan0 (10.0.0.10–100)"

# ───────────────────────────────────────────────────────────
# ETAPA 11 — IP Forwarding + NAT
# wlan1 (USB) → eth0 (cabo) e wlan1 → wlan0 (AP)
# ───────────────────────────────────────────────────────────
info "Ativando IP forwarding e NAT…"

# Forwarding persistente
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf \
    || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Limpa regras anteriores
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true

# NAT: saída pelo WAN (wlan1)
iptables -t nat -A POSTROUTING -o ${WAN_IFACE} -j MASQUERADE

# FORWARD: wlan1 ↔ eth0
iptables -A FORWARD -i ${WAN_IFACE} -o ${ETH_IFACE} \
    -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i ${ETH_IFACE} -o ${WAN_IFACE} -j ACCEPT

# FORWARD: wlan1 ↔ wlan0
iptables -A FORWARD -i ${WAN_IFACE} -o ${AP_IFACE} \
    -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i ${AP_IFACE} -o ${WAN_IFACE} -j ACCEPT

netfilter-persistent save >/dev/null 2>&1
log "NAT salvo: ${WAN_IFACE} → ${ETH_IFACE} e ${AP_IFACE}"

# ───────────────────────────────────────────────────────────
# ETAPA 12 — Tailscale (acesso remoto)
# ───────────────────────────────────────────────────────────
info "Verificando Tailscale…"
if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
    log "Tailscale instalado"
else
    log "Tailscale já instalado"
fi
systemctl enable tailscaled >/dev/null 2>&1
systemctl start tailscaled 2>/dev/null || true

# ───────────────────────────────────────────────────────────
# ETAPA 13 — Serviço systemd piserver
# ───────────────────────────────────────────────────────────
info "Registrando serviço piserver…"
cat > /etc/systemd/system/piserver.service <<EOF
[Unit]
Description=Pi Edge Node — Flask Server v3
After=network-online.target hostapd.service dnsmasq.service
Wants=network-online.target

[Service]
Type=simple
User=${USER_NAME}
WorkingDirectory=${INSTALL_DIR}
Environment="PORT=5000"
Environment="FLASK_ENV=production"
Environment="WAN_IFACE=${WAN_IFACE}"
Environment="ETH_IFACE=${ETH_IFACE}"
Environment="AP_IFACE=${AP_IFACE}"
ExecStart=${INSTALL_DIR}/venv/bin/python server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=piserver

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable piserver hostapd dnsmasq
log "Serviços habilitados no boot"

# ───────────────────────────────────────────────────────────
# FINALIZAÇÃO
# ───────────────────────────────────────────────────────────
echo ""
echo "══════════════════════════════════════════════════════"
echo -e " ${GREEN}✓ Instalação concluída!${NC}"
echo "══════════════════════════════════════════════════════"
echo ""
echo -e "  Topologia:"
echo -e "  ${CYAN}wlan1${NC} (USB LV-UW06) ──→ Pi ──┬──→ ${CYAN}eth0${NC}  (cabo → PC)"
echo -e "                               └──→ ${CYAN}wlan0${NC} (AP PiEdge-Net)"
echo ""
echo -e "  AP Wi-Fi : ${CYAN}PiEdge-Net${NC} / ${CYAN}piedge2024${NC}"
echo -e "  Flask AP : ${CYAN}http://${AP_IP}:5000${NC}"
echo -e "  Flask cab: ${CYAN}http://${ETH_IP}:5000${NC}"
echo ""
echo -e " ${YELLOW}Próximos passos:${NC}"
echo -e " 1. Conectar wlan1 (USB) na internet:"
echo -e "    ${CYAN}sudo nmcli device wifi connect \"Bruno Dratcu\" password \"deniederror\" ifname ${WAN_IFACE}${NC}"
echo -e " 2. Autenticar Tailscale:"
echo -e "    ${CYAN}sudo tailscale up${NC}"
echo -e " 3. Reiniciar:"
echo -e "    ${CYAN}sudo reboot${NC}"
echo ""