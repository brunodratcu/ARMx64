#!/bin/bash
sleep 8
nmcli device set wlan0 managed no 2>/dev/null || true
ip link set wlan0 up
ip addr flush dev wlan0
ip addr add 10.0.0.1/24 dev wlan0
systemctl restart hostapd
sleep 2
systemctl restart dnsmasq
sysctl -w net.ipv4.ip_forward=1
iptables -t nat -F POSTROUTING
iptables -F FORWARD
iptables -t nat -A POSTROUTING -o wlan1 -j MASQUERADE
iptables -A FORWARD -i wlan1 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A FORWARD -i wlan0 -o wlan1 -j ACCEPT