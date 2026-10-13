#!/usr/bin/env bash
# Official ISO wizard only. No undocumented unattended flags or test profiles.
set -Eeuo pipefail
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
source "$HERE/lab.env"
source "$HERE/plan.env"
[[ $EUID == 0 && -f /etc/oracle-release ]] || { echo 'Use sudo inside the Security Onion ISO VM.' >&2; exit 1; }
grep -Eq 'release 9([.[:space:]]|$)' /etc/oracle-release || { echo 'Oracle Linux 9 is required.' >&2; exit 1; }
[[ ! -f /root/install_opt && ! -f /root/accept_changes ]] || { echo 'Previous setup state exists. Inspect before rerunning the installer.' >&2; exit 1; }
printf -v mmac '02:50:%02x:%02x:%02x:00' $((SO_ID>>16 & 255)) $((SO_ID>>8 & 255)) $((SO_ID & 255))
printf -v bmac '02:50:%02x:%02x:%02x:01' $((SO_ID>>16 & 255)) $((SO_ID>>8 & 255)) $((SO_ID & 255))
find_nic() {
    local path
    for path in /sys/class/net/*/address; do
        [[ $(cat "$path") != "$1" ]] || { basename "$(dirname "$path")"; return; }
    done
    return 1
}
MNIC=$(find_nic "$mmac"); SNIFF_NIC=$(find_nic "$bmac")
cat <<EOF
Security Onion $SO_BUILD official ISO setup answers:
  Install -> STANDALONE -> review/accept Elastic license -> Standard
  Confirm OS hostname is so-lab BEFORE setup; description: isolated Proxmox lab
  Do not rename the SO host after certificates/setup have been created.
  Management NIC: $MNIC ($mmac); Static
  IPv4/CIDR: $SO_IP/24; gateway/DNS: $HOME_GATEWAY; search: home.arpa
  Internet: Direct; Docker range: Yes, keep default
  Monitor NIC: ONLY $SNIFF_NIC ($bmac), selected with Space; no address
  SOC admin: your email and a new password, entered twice
  Web access: IP; allow web access: Yes; analyst CIDR: 192.168.0.0/24
  Telemetry: No; review final settings; Yes to install this guest
  Zeek metadata and Suricata PCAP are the 3.3 Standalone defaults.
  No Pro license, Onion AI adapters, or AI credentials are needed.
EOF
read -r -p 'Press Enter to open the official interactive wizard: ' _answer </dev/tty
SETUP=
for candidate in "/home/${SUDO_USER:-labadmin}/SecurityOnion/setup" /root/SecurityOnion/setup /root/manager_setup/securityonion/setup; do
    if [[ -f $candidate/so-setup ]]; then SETUP=$candidate; break; fi
done
[[ -n $SETUP ]] || { echo 'Locate SecurityOnion/setup/so-setup under your OS account home. The documented command is: sudo SecurityOnion/setup/so-setup iso' >&2; exit 1; }
# Installation docs: sudo SecurityOnion/setup/so-setup iso
bash "$SETUP/so-setup" iso
