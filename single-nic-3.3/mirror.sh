#!/usr/bin/env bash
# Reconcile TAP recreation on start/stop/reboot/hotplug. One ingress copy per packet.
set -Eeuo pipefail
source /usr/local/lib/so-single-nic/lab.env
source /usr/local/lib/so-single-nic/plan.env
PREF=49150
CAP=tap${SO_ID}i1
RUN=/run/so-lab-mirror
mkdir -p "$RUN"
exec 8>/run/lock/so-lab-mirror.lock
flock 8
offload() {
    local dev=$1 feature
    # Fixed/unsupported features may return errors; do not change the home NIC.
    for feature in rx tx sg tso gso gro lro; do ethtool -K "$dev" "$feature" off >/dev/null 2>&1 || true; done
}
clsact() {
    if ! tc qdisc show dev "$1" | grep -q '\bclsact\b'; then
        tc qdisc add dev "$1" clsact
    fi
}
[[ -e /sys/class/net/$LAB_BRIDGE/bridge ]] || exit 0
# Only the three planned endpoints and SO's capture NIC may join this bridge.
for path in /sys/class/net/"$LAB_BRIDGE"/brif/*; do
    [[ -e $path ]] || continue
    dev=${path##*/}
    case $dev in
        "tap${KALI_ID}i0"|"tap${WINDOWS_ID}i0"|"tap${UBUNTU_ID}i0"|"$CAP") ;;
        *) echo "Unexpected lab port $dev; only the four planned VMs are supported" >&2; exit 1;;
    esac
done
if ! nft list table bridge so_lab_guard >/dev/null 2>&1 || ! nft list table inet so_lab_guard >/dev/null 2>&1; then
    /usr/local/lib/so-single-nic/guard.sh
fi
if [[ ! -e /sys/class/net/$CAP ]]; then
    for path in /sys/class/net/"$LAB_BRIDGE"/brif/*; do
        [[ -e $path ]] || continue
        dev=${path##*/}
        tc filter del dev "$dev" ingress pref "$PREF" 2>/dev/null || true
    done
    rm -f "$RUN"/*.ready
    exit 0
fi
# Kernel DROP on capture ingress means guest TX never reaches Proxmox or the bridge.
capidx=$(cat "/sys/class/net/$CAP/ifindex")
[[ ! -L /sys/class/net/$CAP/master ]] || ip link set dev "$CAP" nomaster
if [[ ! -f $RUN/capture-$capidx.ready ]]; then
    clsact "$CAP"
    tc filter replace dev "$CAP" ingress pref "$PREF" protocol all matchall action drop
    ip link set dev "$CAP" mtu 9000 up promisc on
    echo 1 > "/proc/sys/net/ipv6/conf/$CAP/disable_ipv6"
    offload "$CAP"
    touch "$RUN/capture-$capidx.ready"
fi
# Disable bridge offloads too, but keep all changes on the isolated lab path.
if [[ ! -f $RUN/bridge-$(cat "/sys/class/net/$LAB_BRIDGE/ifindex").ready ]]; then
    offload "$LAB_BRIDGE"
    touch "$RUN/bridge-$(cat "/sys/class/net/$LAB_BRIDGE/ifindex").ready"
fi
for path in /sys/class/net/"$LAB_BRIDGE"/brif/*; do
    [[ -e $path ]] || continue
    dev=${path##*/}
    [[ $dev != "$CAP" ]] || continue
    idx=$(cat "/sys/class/net/$dev/ifindex")
    mark=$RUN/source-$idx-to-$capidx.ready
    [[ ! -f $mark ]] || continue
    clsact "$dev"
    offload "$dev"
    tc filter replace dev "$dev" ingress pref "$PREF" protocol all matchall \
        action mirred egress mirror dev "$CAP"
    touch "$mark"
done
