# Pi Edge Node

Servidor de monitoramento rodando em **Raspberry Pi 4B**, com Access Point Wi-Fi próprio, dashboard web e acesso remoto via Tailscale Funnel. Uma página hospedada no GitHub Pages detecta automaticamente se o Pi está online ou offline.

---

## Arquitetura

```
[Internet]
    │
  wlan1 (adaptador USB RTL8188FTV — recebe internet)
    │
[Raspberry Pi 4B — Debian 13]
    │
  wlan0 (AP nativo — transmite PiEdge-Net)
    │
[Dispositivos conectados — 10.0.0.x]

Acesso remoto:
[Browser] → [GitHub Pages] → fetch() → [Tailscale Funnel] → [Pi :5000]
```

---

## Estrutura do repositório

```
pi-edge-node/
├── .github/
│   └── workflows/
│       └── deploy.yml     # CI/CD — injeta URL e faz deploy no GitHub Pages
├── static/
│   ├── online.html        # Dashboard (servido pelo Flask quando Pi está up)
│   └── offline.html       # Fallback (referência)
├── index.html             # Página pública — detecta online/offline via fetch()
├── config.js              # URL do Tailscale (local apenas, no .gitignore)
├── server.py              # Servidor Flask — rotas /, /health, /metrics
├── setup.sh               # Instalador completo para o Pi
├── .gitignore
└── README.md
```

---

## Pré-requisitos

| Item | Detalhe |
|---|---|
| Hardware | Raspberry Pi 4B |
| Sistema | Debian 13 (Bookworm) |
| Adaptador Wi-Fi | USB RTL8188FTV (wlan1) |
| Conta | Tailscale (gratuita — tailscale.com) |
| Conta | GitHub (para GitHub Pages) |

---

## Instalação no Pi

### 1. Acessa o Pi via SSH

```bash
ssh pi@<ip-do-pi>
```

### 2. Cria os arquivos no Pi

**server.py:**
```bash
cat > ~/server.py << 'EOF'
# cole o conteúdo de server.py aqui
EOF
```

**setup.sh:**
```bash
cat > ~/setup.sh << 'EOF'
# cole o conteúdo de setup.sh aqui
EOF
```

**Páginas HTML** (pasta static):
```bash
mkdir -p ~/static
cat > ~/static/online.html  << 'EOF'
# cole o conteúdo de static/online.html aqui
EOF

cat > ~/static/offline.html << 'EOF'
# cole o conteúdo de static/offline.html aqui
EOF
```

> **Dica:** se preferir clonar do GitHub diretamente:
> ```bash
> git clone https://github.com/SEU-USUARIO/pi-edge-node ~/pi-edge-node
> cd ~/pi-edge-node
> ```

### 3. Roda o instalador

```bash
chmod +x ~/setup.sh
sudo ~/setup.sh
```

O script instala automaticamente:
- Driver RTL8188FTV (DKMS)
- Python 3 + Flask (venv isolado)
- hostapd (Access Point)
- dnsmasq (DHCP + DNS local)
- NAT wlan1 → wlan0
- Tailscale
- Serviço systemd `piserver`

### 4. Conecta wlan1 na internet

```bash
sudo nmcli device wifi connect "NomeDaRede" password "SenhaDaRede" ifname wlan1
```

### 5. Autentica no Tailscale

```bash
sudo tailscale up
```

Abre o link gerado no navegador e faz login com Google ou GitHub.

### 6. Ativa o Tailscale Funnel (URL pública)

```bash
sudo tailscale funnel 5000
```

Anota a URL gerada — formato `https://NOME.tail1234.ts.net`. Você vai precisar dela para o GitHub Pages.

### 7. Reinicia o Pi

```bash
sudo reboot
```

Após o boot (~30s), todos os serviços sobem automaticamente.

---

## Verificação pós-boot

```bash
# Serviços rodando?
sudo systemctl status piserver hostapd dnsmasq tailscaled

# Flask respondendo?
curl http://localhost:5000/health

# Métricas completas?
curl http://localhost:5000/metrics

# Clientes conectados no AP?
cat /var/lib/misc/dnsmasq.leases

# IP Tailscale?
sudo tailscale ip -4
```

---

## Acesso

| Contexto | URL |
|---|---|
| Conectado no PiEdge-Net | `http://10.0.0.1:5000` |
| DNS local | `http://pi.local:5000` |
| Tailscale (remoto) | `http://<tailscale-ip>:5000` |
| Funnel público | `https://NOME.tail1234.ts.net` |

---

## Rede Wi-Fi (AP)

| Parâmetro | Valor |
|---|---|
| SSID | `PiEdge-Net` |
| Senha padrão | `piedge2024` |
| Segurança | WPA2-PSK |
| Gateway | `10.0.0.1` |
| Range DHCP | `10.0.0.10` – `10.0.0.100` |
| DNS local | `pi.local` → `10.0.0.1` |

**Trocar a senha do AP:**
```bash
sudo nano /etc/hostapd/hostapd.conf
# alterar: wpa_passphrase=NovaSenha
sudo systemctl restart hostapd
```

---

## API do servidor

| Rota | Retorno |
|---|---|
| `GET /` | Dashboard HTML |
| `GET /health` | `{"status":"ok","uptime":"...","timestamp":...}` |
| `GET /metrics` | RAM, CPU, temperatura, clientes AP, IP Tailscale |

---

## Serviços systemd

| Serviço | Função |
|---|---|
| `piserver` | Servidor Flask na porta 5000 |
| `hostapd` | Access Point Wi-Fi (wlan0) |
| `dnsmasq` | DHCP + DNS local |
| `tailscaled` | VPN WireGuard (Tailscale) |

```bash
# Logs em tempo real
sudo journalctl -u piserver -f
```

---

## Expansão planejada

- [ ] Assembly binary `ram_integrity.s` para verificação de integridade de RAM
- [ ] Hub server com proxy `/proxy/<token>/metrics`
- [ ] Autenticação por token nas rotas da API
- [ ] Dashboard com atualização automática de métricas em tempo real

---
