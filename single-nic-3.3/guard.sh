#!/usr/bin/env bash
# Own tables only: never flush the ruleset or touch vmbr0/nic0.
set -Eeuo pipefail
source /usr/local/lib/so-single-nic/lab.env
source /usr/local/lib/so-single-nic/plan.env
STATE=/var/lib/so-single-nic
exec 8>/run/lock/so-lab-guard.lock
flock 8
# Refuse topology changes before touching the owned firewall tables.
for path in /sys/class/net/"$LAB_BRIDGE"/brif/*; do
    [[ -e $path ]] || continue
    dev=${path##*/}
    case $dev in
        "tap${KALI_ID}i0"|"tap${WINDOWS_ID}i0"|"tap${UBUNTU_ID}i0"|"tap${SO_ID}i1") ;;
        *) echo "Unexpected lab port $dev; only the four planned VMs are supported" >&2; exit 1;;
    esac
done
if [[ -e /sys/class/net/$LAB_BRIDGE ]]; then
    [[ -z $(ip -4 -o addr show dev "$LAB_BRIDGE") ]] || { echo 'Lab bridge must have no IPv4 address or gateway; restore the isolated layout before continuing.' >&2; exit 1; }
fi
prefix=''
for family in bridge inet; do
    if nft list table "$family" so_lab_guard >/dev/null 2>&1; then
        [[ -f $STATE/guard.owned ]] || { echo 'Refusing to adopt an existing firewall table' >&2; exit 1; }
        prefix+="delete table $family so_lab_guard"$'\n'
    fi
done
rules=$(cat <<EOF
${prefix}table bridge so_lab_guard {
    chain prerouting {
        type filter hook prerouting priority -300; policy accept;
        iifname "tap${SO_ID}i1" counter drop
    }
    chain input {
        type filter hook input priority -300; policy accept;
        meta ibrname "$LAB_BRIDGE" counter drop
    }
    chain forward {
        type filter hook forward priority -300; policy accept;
        meta ibrname "$LAB_BRIDGE" meta obrname != "$LAB_BRIDGE" counter drop
        meta obrname "$LAB_BRIDGE" meta ibrname != "$LAB_BRIDGE" counter drop
    }
}
table inet so_lab_guard {
    chain input {
        type filter hook input priority -300; policy accept;
        iifname { "$LAB_BRIDGE", "tap${SO_ID}i1" } counter drop
    }
    chain forward {
        type filter hook forward priority -300; policy accept;
        iifname "$LAB_BRIDGE" oifname "$LAB_BRIDGE" accept
        iifname { "$LAB_BRIDGE", "tap${SO_ID}i1" } counter drop
        oifname { "$LAB_BRIDGE", "tap${SO_ID}i1" } counter drop
    }
}
EOF
)
printf '%s\n' "$rules" | nft -c -f -
printf '%s\n' "$rules" | nft -f -
touch "$STATE/guard.owned"
if [[ -e /proc/sys/net/ipv6/conf/$LAB_BRIDGE/disable_ipv6 ]]; then
    echo 1 > "/proc/sys/net/ipv6/conf/$LAB_BRIDGE/disable_ipv6"
fi
