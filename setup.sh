#!/bin/bash
# ═══════════════════════════════════════════════════════════════
#  Pi Edge Node — Setup completo
#  Sistema: Debian 13 | Usuário: deniederror
#  wlan1 = cliente Wi-Fi (internet entrada) — adaptador USB RTL8188FTV
#  wlan0 = Access Point (rede PiEdge-Net)
#
#  Uso: chmod +x setup.sh && sudo ./setup.sh
# ═══════════════════════════════════════════════════════════════

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC}  $1"; }
info() { echo -e "${CYAN}[..]${NC}  $1"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $1"; }
fail() { echo -e "${RED}[ERR]${NC} $1"; exit 1; }

[ "$EUID" -ne 0 ] && fail "Execute com sudo: sudo ./setup.sh"

USER_NAME="deniederror"
USER_HOME="/home/$USER_NAME"
INSTALL_DIR="$USER_HOME/piserver"
STATIC_DIR="$INSTALL_DIR/static"

echo ""
echo "═══════════════════════════════════════════════════"
echo "   Pi Edge Node — Instalação"
echo "   Debian 13 · wlan1→internet · wlan0→AP"
echo "═══════════════════════════════════════════════════"
echo ""

# ───────────────────────────────────────────────────
# ETAPA 1 — Dependências
# ───────────────────────────────────────────────────
info "Atualizando pacotes..."
apt-get update -qq
apt-get install -y -qq \
    python3 python3-pip python3-venv \
    hostapd dnsmasq iptables-persistent \
    network-manager dkms git curl net-tools
log "Dependências instaladas"

# ───────────────────────────────────────────────────
# ETAPA 2 — Driver RTL8188FTV
# ───────────────────────────────────────────────────
info "Verificando driver RTL8188FTV..."
if ! lsmod | grep -q 8188fu; then
    info "Instalando driver rtl8188fu via DKMS..."
    rm -rf /tmp/rtl8188fu
    git clone https://github.com/kelebek333/rtl8188fu /tmp/rtl8188fu
    dkms add /tmp/rtl8188fu
    dkms build rtl8188fu/1.0
    dkms install rtl8188fu/1.0
    modprobe 8188fu
    grep -q 8188fu /etc/modules || echo "8188fu" >> /etc/modules
    log "Driver RTL8188FTV instalado"
else
    log "Driver RTL8188FTV já carregado"
fi

# ───────────────────────────────────────────────────
# ETAPA 3 — Estrutura do projeto
# ───────────────────────────────────────────────────
info "Criando estrutura de diretórios..."
mkdir -p "$INSTALL_DIR" "$STATIC_DIR"
chown -R $USER_NAME:$USER_NAME "$INSTALL_DIR"
log "Diretórios criados"

info "Criando ambiente virtual Python..."
sudo -u $USER_NAME python3 -m venv "$INSTALL_DIR/venv"
sudo -u $USER_NAME "$INSTALL_DIR/venv/bin/pip" install --quiet flask
log "Flask instalado"

# ───────────────────────────────────────────────────
# ETAPA 4 — Copiar arquivos
# ───────────────────────────────────────────────────
info "Copiando arquivos do servidor..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

[ -f "$SCRIPT_DIR/server.py" ] \
    && cp "$SCRIPT_DIR/server.py" "$INSTALL_DIR/server.py" \
    && chown $USER_NAME:$USER_NAME "$INSTALL_DIR/server.py" \
    && log "server.py copiado" \
    || fail "server.py não encontrado"

for f in online.html offline.html; do
    if [ -f "$SCRIPT_DIR/static/$f" ]; then
        cp "$SCRIPT_DIR/static/$f" "$STATIC_DIR/$f"
        chown $USER_NAME:$USER_NAME "$STATIC_DIR/$f"
        log "$f copiado"
    else
        warn "$f não encontrado em static/"
    fi
done

# ───────────────────────────────────────────────────
# ETAPA 5 — Desconecta wlan0 do NetworkManager
# ───────────────────────────────────────────────────
info "Removendo wlan0 do NetworkManager..."
nmcli device disconnect wlan0 2>/dev/null || true
if ! grep -q "unmanaged-devices=interface-name:wlan0" /etc/NetworkManager/NetworkManager.conf; then
    cat >> /etc/NetworkManager/NetworkManager.conf <<'NM'

[keyfile]
unmanaged-devices=interface-name:wlan0
NM
fi
systemctl restart NetworkManager
log "wlan0 livre para AP"

# ───────────────────────────────────────────────────
# ETAPA 6 — IP estático wlan0
# ───────────────────────────────────────────────────
info "Configurando IP 10.0.0.1 no wlan0..."
cat > /etc/network/interfaces.d/wlan0-ap <<'EOF'
auto wlan0
iface wlan0 inet static
    address 10.0.0.1
    netmask 255.255.255.0
EOF
ip addr flush dev wlan0 2>/dev/null || true
ip addr add 10.0.0.1/24 dev wlan0 2>/dev/null || true
ip link set wlan0 up 2>/dev/null || true
log "IP 10.0.0.1/24 aplicado no wlan0"

# ───────────────────────────────────────────────────
# ETAPA 7 — hostapd
# ───────────────────────────────────────────────────
info "Configurando hostapd (AP)..."
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
sed -i 's|^#\?DAEMON_CONF=.*|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
grep -q 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' /etc/default/hostapd \
    || echo 'DAEMON_CONF="/etc/hostapd/hostapd.conf"' >> /etc/default/hostapd
systemctl unmask hostapd
log "hostapd configurado — SSID: PiEdge-Net | Senha: piedge2024"

# ───────────────────────────────────────────────────
# ETAPA 8 — dnsmasq
# ───────────────────────────────────────────────────
info "Configurando dnsmasq (DHCP)..."
[ -f /etc/dnsmasq.conf ] && mv /etc/dnsmasq.conf /etc/dnsmasq.conf.bak
cat > /etc/dnsmasq.conf <<'EOF'
interface=wlan0
dhcp-range=10.0.0.10,10.0.0.100,255.255.255.0,24h
domain=local
address=/pi.local/10.0.0.1
EOF
log "dnsmasq configurado (10.0.0.10–100)"

# ───────────────────────────────────────────────────
# ETAPA 9 — NAT wlan1 → wlan0
# ───────────────────────────────────────────────────
info "Ativando NAT (wlan1 → wlan0)..."
grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf \
    || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true
iptables -t nat -A POSTROUTING -o wlan1 -j MASQUERADE
iptables -A FORWARD -i wlan1 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0 -o wlan1 -j ACCEPT
netfilter-persistent save >/dev/null 2>&1
log "NAT configurado e salvo"

# ───────────────────────────────────────────────────
# ETAPA 10 — Tailscale
# ───────────────────────────────────────────────────
info "Verificando Tailscale..."
if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
    log "Tailscale instalado"
else
    log "Tailscale já instalado"
fi
systemctl enable tailscaled >/dev/null 2>&1
systemctl start tailscaled 2>/dev/null || true

# ───────────────────────────────────────────────────
# ETAPA 11 — Serviço systemd
# ───────────────────────────────────────────────────
info "Registrando serviço piserver..."
cat > /etc/systemd/system/piserver.service <<EOF
[Unit]
Description=Pi Edge Node — Servidor Flask
After=network-online.target tailscaled.service
Wants=network-online.target

[Service]
Type=simple
User=$USER_NAME
WorkingDirectory=$INSTALL_DIR
Environment="PORT=5000"
Environment="FLASK_ENV=production"
ExecStart=$INSTALL_DIR/venv/bin/python server.py
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

# ───────────────────────────────────────────────────
# FINALIZAÇÃO
# ───────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════"
echo -e "  ${GREEN}Instalação concluída!${NC}"
echo "═══════════════════════════════════════════════════"
echo ""
echo -e "  Wi-Fi  : ${CYAN}PiEdge-Net${NC}"
echo -e "  Senha  : ${CYAN}piedge2024${NC}  ← troque depois!"
echo -e "  Gateway: ${CYAN}10.0.0.1${NC}"
echo -e "  Flask  : ${CYAN}http://10.0.0.1:5000${NC}"
echo ""
echo -e "  ${YELLOW}Próximos passos:${NC}"
echo -e "  1. Conectar wlan1 na internet:"
echo -e "     ${CYAN}sudo nmcli device wifi connect \"SuaRede\" password \"SuaSenha\" ifname wlan1${NC}"
echo -e "  2. Autenticar Tailscale (acesso remoto):"
echo -e "     ${CYAN}sudo tailscale up${NC}"
echo -e "  3. Reiniciar:"
echo -e "     ${CYAN}sudo reboot${NC}"
echo ""