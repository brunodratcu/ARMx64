# Pi Edge Node — Documentação

## Hardware
- Raspberry Pi 4B
- Adaptador USB Wi-Fi: LV-UW06 (chip Realtek, driver rtl8xxxu — nativo no kernel)

## Topologia
```
wlan1 (USB LV-UW06) ──→ Pi 4B ──→ wlan0 (AP PiEdge-Net)
     ↑                                      ↓
    SuaRede                     clientes Wi-Fi
  (internet)                       (10.0.0.x)
```

## Interfaces
| Interface | Função | IP |
|-----------|--------|----|
| wlan1 | USB adapter — cliente Wi-Fi (internet) | DHCP da sua rede |
| wlan0 | AP interno do Pi — PiEdge-Net | 10.0.0.1 |
| eth0 | Ethernet (não usado atualmente) | — |
| tailscale0 | Acesso remoto | IP Tailscale |

## Redes Wi-Fi
| SSID | Senha | Função |
|------|-------|--------|
| SuaRede | SuaSenha | Internet (via wlan1) |
| PiEdge-Net | piedge2024 | AP do Pi (via wlan0) |

## Arquivos do sistema
| Arquivo | Destino | Função |
|---------|---------|--------|
| piedge-ap.sh | /usr/local/bin/ | Script de boot do AP |
| piedge-ap.service | /etc/systemd/system/ | Serviço systemd do AP |
| hostapd.conf | /etc/hostapd/ | Configuração do AP |
| dnsmasq-piedge.conf | /etc/dnsmasq.d/ | DHCP para clientes AP |
| server.py | ~/pi-edge-node/ | Servidor Flask |
| piserver.service | /etc/systemd/system/ | Serviço Flask |

## Estrutura de pastas
```
/home/PI/pi-edge-node/
├── server.py
├── venv/
└── static/
    ├── online.html
    └── offline.html
```

## Serviços systemd
```bash
# Status
sudo systemctl status piedge-ap
sudo systemctl status hostapd
sudo systemctl status dnsmasq
sudo systemctl status piserver

# Reiniciar
sudo systemctl restart piedge-ap
sudo systemctl restart hostapd
```

## Instalação do zero (Pi formatado)

### 1. Instalar dependências
```bash
sudo apt-get update
sudo apt-get install -y python3 python3-pip python3-venv \
    hostapd dnsmasq iptables-persistent \
    network-manager firmware-misc-nonfree \
    net-tools wireless-tools
```

### 2. Conectar wlan1 (USB) na internet
```bash
# Plugar o adaptador USB primeiro
sudo nmcli connection add \
    type wifi ifname wlan1 con-name "BrunoDratcu" \
    ssid "SuaRede" \
    wifi-sec.key-mgmt wpa-psk \
    wifi-sec.psk "SuaSenha" \
    connection.autoconnect yes
sudo nmcli connection up "SuaRede" ifname wlan1
```

### 3. Instalar script do AP
```bash
sudo cp piedge-ap.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/piedge-ap.sh
sudo cp piedge-ap.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable piedge-ap
```

### 4. Configurar hostapd
```bash
sudo systemctl unmask hostapd
sudo cp hostapd.conf /etc/hostapd/hostapd.conf
sudo systemctl enable hostapd
```

### 5. Configurar dnsmasq
```bash
sudo cp dnsmasq-piedge.conf /etc/dnsmasq.d/piedge-ap.conf
sudo systemctl enable dnsmasq
```

### 6. Instalar Flask
```bash
mkdir -p ~/pi-edge-node/static
cd ~/pi-edge-node
python3 -m venv venv
venv/bin/pip install flask
cp server.py ~/pi-edge-node/
```

### 7. Instalar serviço Flask
```bash
sudo cp piserver.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable piserver
```

### 8. Tailscale
```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

### 9. Reboot
```bash
sudo reboot
```

## Verificação pós-boot
```bash
# Interfaces
nmcli device status
ip addr show wlan0   # deve ter 10.0.0.1
ip addr show wlan1   # deve ter IP do Bruno Dratcu

# Serviços
sudo systemctl status piedge-ap hostapd dnsmasq piserver

# Internet no Pi
ping -c 3 -I wlan1 8.8.8.8

# Flask
curl http://10.0.0.1:5000/health
curl http://10.0.0.1:5000/metrics
```

## Acesso remoto
```bash
# SSH pelo Tailscale
ssh pi@ID_PI.local

# Funnel (expõe Flask na internet)
sudo tailscale funnel 5000
# URL: https://tail4e04f3.ts.net/
```

## Solução de problemas

### PiEdge-Net não aparece
```bash
sudo systemctl restart piedge-ap
sudo journalctl -u hostapd --no-pager -n 20
```

### Sem internet no celular
```bash
# Verifica forwarding
cat /proc/sys/net/ipv4/ip_forward   # deve ser 1

# Verifica NAT
sudo iptables -t nat -L POSTROUTING -n -v

# Verifica wlan1
ip addr show wlan1
ping -c 3 -I wlan1 8.8.8.8
```

### wlan0 perdeu IP
```bash
sudo ip addr add 10.0.0.1/24 dev wlan0
sudo systemctl restart dnsmasq
```