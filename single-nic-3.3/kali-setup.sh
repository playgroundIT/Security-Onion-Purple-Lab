#!/usr/bin/env bash
# Run with sudo INSIDE the Kali VM after offline installation.
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/lab.env"
source "$HERE/plan.env"
[[ $EUID == 0 ]] || exit 1
printf -v mac '02:50:%02x:%02x:%02x:00' $((KALI_ID>>16 & 255)) $((KALI_ID>>8 & 255)) $((KALI_ID & 255))
nic=
for path in /sys/class/net/*/address; do
    if [[ $(cat "$path") == "$mac" ]]; then nic=$(basename "$(dirname "$path")"); break; fi
done
[[ -n $nic ]] || { echo 'Kali NIC MAC does not match the VM plan.' >&2; exit 1; }
if ! nmcli con show SO-LAB >/dev/null 2>&1; then
    nmcli con add type ethernet con-name SO-LAB ifname "$nic" ipv4.method manual ipv4.addresses "$KALI_IP/24"
fi
nmcli con mod SO-LAB ipv4.method manual ipv4.addresses "$KALI_IP/24" ipv4.gateway '' ipv4.dns '' ipv4.never-default yes ipv6.method disabled connection.autoconnect yes connection.autoconnect-priority 100
nmcli con up SO-LAB
mkdir -p /etc/NetworkManager/dispatcher.d
cat > /etc/NetworkManager/dispatcher.d/90-so-lab-offload <<'EOF'
#!/bin/bash
[[ $2 == up && ${CONNECTION_ID:-} == SO-LAB ]] || exit 0
for feature in rx tx sg tso gso gro lro; do ethtool -K "$1" "$feature" off >/dev/null 2>&1 || true; done
EOF
chmod 700 /etc/NetworkManager/dispatcher.d/90-so-lab-offload
for feature in rx tx sg tso gso gro lro; do ethtool -K "$nic" "$feature" off >/dev/null 2>&1 || true; done
ip -br addr show "$nic"
ip -4 route
command -v nmap
command -v curl
echo 'KALI OK: 10.50.0.10/24; no default gateway; offline scan tools available.'
