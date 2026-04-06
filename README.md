# Edge Node Monitor — Guia de Instalação e Inicialização

Aplicação para Raspberry Pi que utiliza:

* **Assembly ARM64** → coleta de dados do sistema (`/proc/meminfo`)
* **Python + Flask** → interface web e endpoint HTTP
* **systemd** → execução automática no boot

---

# 🧭 Visão geral do processo

O fluxo completo de instalação é:

```text
1. Gravar Raspberry Pi OS Lite
2. Configurar SSH e rede
3. Acessar o Pi remotamente
4. Instalar dependências
5. Copiar o projeto
6. Compilar Assembly
7. Testar binário
8. Rodar Flask manualmente
9. Criar serviço systemd
10. Ativar execução automática
```

---

# 🧱 1. Preparação do Raspberry Pi

## 1.1 Instalar o sistema operacional

Use o **Raspberry Pi Imager**:

* OS: **Raspberry Pi OS Lite (64-bit)**

Antes de gravar (⚙️ configurações avançadas):

Configure:

* Hostname: `edge-node`
* Username: `pi`
* Password: (defina uma senha)
* Enable SSH: ✅
* Wi-Fi: (se necessário)

Grave no cartão SD.

---

## 1.2 Primeiro boot

* Insira o SD no Raspberry Pi
* Conecte à energia
* Conecte na rede (cabo ou Wi-Fi)

---

# 🌐 2. Descobrir IP do Raspberry Pi

No seu computador:

```bash
arp -a
```

ou

```bash
nmap -sn 192.168.0.0/24
```

Procure algo como:

```text
192.168.0.50
```

---

# 🔐 3. Acesso via SSH

Conecte ao Raspberry Pi:

```bash
ssh pi@IP_DO_PI
```

Exemplo:

```bash
ssh pi@192.168.0.50
```

Confirme a chave:

```text
yes
```

Digite a senha definida.

---

# 🔑 4. Configurar autenticação por chave (RECOMENDADO)

No seu PC:

```bash
ssh-keygen -t ed25519
```

Enviar para o Pi:

```bash
ssh-copy-id pi@IP_DO_PI
```

Agora você pode acessar sem senha.

---

## 4.1 (Opcional) Desativar login por senha

No Pi:

```bash
sudo nano /etc/ssh/sshd_config
```

Altere:

```text
PasswordAuthentication no
```

Reinicie:

```bash
sudo systemctl restart ssh
```

---

# 📦 5. Atualizar sistema e instalar dependências

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y python3 python3-pip binutils gcc make
pip3 install flask
```

---

# 📁 6. Criar estrutura do projeto

```bash
mkdir -p ~/edge-node/bin
mkdir -p ~/edge-node/templates
cd ~/edge-node
```

Copie os arquivos do projeto:

* `main.s`
* `app.py`
* `templates/index.html`
* `edge.service`

---

# ⚙️ 7. Compilar o Assembly

```bash
cd ~/edge-node

as -o main.o main.s
ld -o bin/monitor main.o
chmod +x bin/monitor
```

---

# 🧪 8. Testar o binário Assembly

```bash
./bin/monitor
```

Saída esperada:

```text
MemTotal:        948732 kB
MemAvailable:    512000 kB
...
```

Se isso aparecer, o Assembly está funcionando.

---

# 🧪 9. Testar aplicação Flask manualmente

```bash
python3 app.py
```

Abra no navegador:

```text
http://IP_DO_PI:5000
```

Ou via terminal:

```bash
curl http://IP_DO_PI:5000/metrics
```

---

# ⚙️ 10. Configurar execução automática (systemd)

## 10.1 Copiar o serviço

```bash
sudo cp edge.service /etc/systemd/system/edge.service
```

## 10.2 Recarregar systemd

```bash
sudo systemctl daemon-reload
```

## 10.3 Ativar no boot

```bash
sudo systemctl enable edge
```

## 10.4 Iniciar agora

```bash
sudo systemctl start edge
```

## 10.5 Ver status

```bash
sudo systemctl status edge
```

---

# 📊 11. Acessar o sistema

No navegador:

```text
http://IP_DO_PI:5000
```

Endpoints disponíveis:

| Endpoint   | Função              |
| ---------- | ------------------- |
| `/`        | Página inicial      |
| `/metrics` | Retorna JSON        |
| `/view`    | Página com métricas |
| `/health`  | Status do sistema   |

---

# 🧾 12. Logs do sistema

Ver logs em tempo real:

```bash
journalctl -u edge -f
```

---

# 🔄 13. Fluxo de inicialização automático

Quando o Raspberry Pi liga:

```text
1. Sistema Linux inicia
2. Rede sobe
3. systemd ativa edge.service
4. Flask inicia automaticamente
5. API fica disponível
6. Cliente pode acessar via navegador
```

---

# 🧑‍💻 14. Jornada de uso

### Usuário final:

1. Liga o Raspberry Pi
2. Descobre o IP
3. Abre no navegador
4. Clica em “Consultar métricas”
5. Recebe dados do sistema

---

# ⚠️ Problemas comuns

## Porta não abre

Verifique:

```bash
sudo systemctl status edge
```

## Flask não inicia

Teste manual:

```bash
python3 app.py
```

## Binário não executa

```bash
chmod +x bin/monitor
```

---

# 🚀 Conclusão

Após seguir todos os passos:

✔ Raspberry Pi acessível via SSH
✔ Assembly compilado e funcional
✔ Flask respondendo via rede
✔ Serviço iniciando automaticamente

Você terá um:

👉 **nó edge de monitoramento com processamento em Assembly e acesso remoto via HTTP**

---

# 🔜 Próximos passos recomendados

* Adicionar CPU (`/proc/stat`)
* Salvar histórico
* Criar coleta contínua
* Implementar autenticação por token
* Integrar com sistema de predição

---
