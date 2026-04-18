#!/bin/bash
WAN="wlan1"; AP="wlan0"; AP_IP="10.0.0.1"
AP_SSID="PiEdge-Net"; AP_PASS="piedge2024"
WIFI_CON="PiWifi"; LOG="logger -t piedge-router"

mode_ap() {
    $LOG "Modo AP ativado"
    nmcli device disconnect "$AP" 2>/dev/null || true
    nmcli device set "$AP" managed no 2>/dev/null || true
    systemctl stop hostapd 2>/dev/null || true
    ip addr flush dev "$AP" 2>/dev/null || true
    ip addr add ${AP_IP}/24 dev "$AP"
    ip link set "$AP" up
    cat > /etc/hostapd/hostapd.conf << HCONF
interface=${AP}
driver=nl80211
ssid=${AP_SSID}
hw_mode=g
channel=6
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${AP_PASS}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
HCONF
    systemctl unmask hostapd 2>/dev/null || true
    systemctl start hostapd
    cat > /etc/dnsmasq.d/piedge-ap.conf << DCONF
except-interface=${WAN}
bind-interfaces
interface=${AP}
dhcp-range=10.0.0.10,10.0.0.100,255.255.255.0,24h
address=/pi.local/${AP_IP}
server=8.8.8.8
server=1.1.1.1
DCONF
    systemctl restart dnsmasq
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    iptables -F FORWARD 2>/dev/null || true
    iptables -t nat -A POSTROUTING -o ${WAN} -j MASQUERADE
    iptables -A FORWARD -i ${WAN} -o ${AP} -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i ${AP}  -o ${WAN} -j ACCEPT
    $LOG "AP ativo: ${AP_SSID} @ ${AP_IP}"
}

mode_wifi() {
    $LOG "Modo Wi-Fi normal"
    systemctl stop hostapd 2>/dev/null || true
    rm -f /etc/dnsmasq.d/piedge-ap.conf
    systemctl restart dnsmasq 2>/dev/null || true
    iptables -t nat -F POSTROUTING 2>/dev/null || true
    iptables -F FORWARD 2>/dev/null || true
    sysctl -w net.ipv4.ip_forward=0 >/dev/null
    ip addr flush dev "$AP" 2>/dev/null || true
    nmcli device set "$AP" managed yes 2>/dev/null || true
    sleep 1
    nmcli connection up "$WIFI_CON" ifname "$AP" 2>/dev/null || true
    $LOG "wlan0 devolvido ao NM"
}

check_wan() {
    local ip=$(ip -4 addr show "$WAN" 2>/dev/null | grep -oP '(?<=inet )\d+\.\d+\.\d+\.\d+')
    [ -z "$ip" ] && return 1
    ping -c 1 -W 2 -I "$WAN" 8.8.8.8 >/dev/null 2>&1
}

check_wan && mode_ap || mode_wifi