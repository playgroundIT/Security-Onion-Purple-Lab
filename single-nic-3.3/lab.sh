#!/usr/bin/env bash
# Additive Proxmox provisioning. Never reload all networking or destroy a VM.
set -Eeuo pipefail
umask 077
KIT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
STATE=/var/lib/so-single-nic
INSTALL=/usr/local/lib/so-single-nic
NETFILE=/etc/network/interfaces.d/so-single-nic
source "$KIT/lab.env"
die() { echo "ERROR: $*" >&2; exit 1; }
note() { echo "[$(date -u +%FT%TZ)] $*"; }
export_resources() {
    export STATE VM_STORAGE FILE_STORAGE HOST_RESERVE_MB SO_DISK_AUTO_SHRINK
    local role
    for role in SO KALI WINDOWS UBUNTU; do
        export "${role}_MEMORY_MB" "${role}_CORES" "${role}_DISK_GB" "${role}_STORAGE"
    done
}
check_cpu() {
    python3 "$KIT/cpu-check.py" /proc/cpuinfo
}
need_host() {
    [[ ${BASH_VERSINFO[0]} -ge 5 ]] || die 'Use Proxmox Bash 5 or newer.'
    [[ $EUID == 0 && -d /etc/pve ]] || die 'Run as root on Proxmox, not on the Mac.'
    for c in qm pvesh pvesm pveversion python3 ip flock; do command -v "$c" >/dev/null || die "Missing $c"; done
    exec 9>/run/lock/so-single-nic.lock
    flock -n 9 || die 'Another deployment stage is running.'
    # Explicit unlock also releases copies inherited by background processes.
    trap 'flock -u 9; exec 9>&-' EXIT
}
load_plan() {
    [[ -s $STATE/plan.env ]] || die 'Run preflight first.'
    export_resources
    # Check requested settings before sourcing the immutable plan. The helper
    # also supplies original allocations for a compatible legacy plan.
    local rendered
    rendered=$(python3 "$KIT/resource-plan.py" load) || die 'Saved resource plan validation failed.'
    # emit() shell-quotes validated values. No state file is written by verify.
    source /dev/stdin <<< "$rendered"
    [[ ${PLANNED_SO_BUILD:-} == "$SO_BUILD" ]] || die 'Existing plan belongs to another SO build. Inspect it; do not reuse or delete existing VM disks.'
}
confirm() {
    local answer
    read -r -p "$* Type YES to continue: " answer </dev/tty
    [[ $answer == YES ]] || die 'Cancelled.'
}
owned() { qm config "$1" | grep -Fq "description: so-single-nic owner=$OWNER role=$2"; }
management_ok() {
    ip -4 -o addr show dev "$HOME_BRIDGE" | grep -Fq " $HOST_IP/24 " || die 'Host management address differs.'
    [[ $(basename "$(readlink -f "/sys/class/net/$PHYSICAL_NIC/master")") == "$HOME_BRIDGE" ]] || die 'nic0 is not a member of vmbr0.'
    ip -4 route show default | grep -Fq "via $HOME_GATEWAY dev $HOME_BRIDGE" || die 'Unexpected default route.'
}
preflight() {
    export_resources
    python3 "$KIT/resource-plan.py" validate
    management_ok
    [[ $LAB_BRIDGE == vmbr-lab && $LAB_CIDR == 10.50.0.0/24 && $KALI_IP == 10.50.0.10 && $WINDOWS_IP == 10.50.0.20 && $UBUNTU_IP == 10.50.0.30 ]] || die 'This kit pins the lab subnet; change the guest scripts/rules too before using another subnet.'
    [[ -c /dev/kvm ]] || die '/dev/kvm missing; enable SVM in BIOS.'
    grep -Eq '\b(svm|vmx)\b' /proc/cpuinfo || die 'CPU virtualization is unavailable.'
    check_cpu
    pveversion
    pveversion --verbose
    pvesm status
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
    free -h
    qm list
    [[ ! -f /etc/network/interfaces.new ]] || die 'Pending Proxmox network changes exist; apply/review them first.'
    # Refuse overlap, an unowned bridge, or definitions elsewhere before creating it.
    if [[ ! -f $STATE/network.owned ]]; then
        [[ ! -e /sys/class/net/$LAB_BRIDGE ]] || die "$LAB_BRIDGE exists and is not owned by this kit."
        if grep -RqsE "^[[:space:]]*(auto|iface)[[:space:]].*\b$LAB_BRIDGE\b" /etc/network/interfaces /etc/network/interfaces.d 2>/dev/null; then
            die 'Lab bridge is already configured outside this kit.'
        fi
    fi
    mkdir -p "$STATE"
    if [[ -f $STATE/plan.env ]]; then
        load_plan
        for role in SO KALI WINDOWS UBUNTU; do
            local idvar=${role}_ID id
            id=${!idvar}
            if qm config "$id" >/dev/null 2>&1; then owned "$id" "$role" || die "VM $id ownership mismatch"; fi
        done
        note 'Existing immutable plan retained. create/start recheck capacity and ownership.'
        cat "$STATE/plan.env"
        return
    fi
    local node
    node=$(hostname -s)
    pvesh get /cluster/resources --type vm --output-format json > "$STATE/inventory-vms.json"
    pvesh get "/nodes/$node/storage" --output-format json > "$STATE/inventory-storage.json"
    pvesh get /storage --output-format json > "$STATE/storage-config.json"
    ip -j -4 route show table all > "$STATE/routes.json"
    # Account for every existing logical image before choosing a thin pool.
    export STATE
    python3 - <<'PYSPACE'
import json,os,subprocess
from pathlib import Path
p=Path(os.environ['STATE']); node=os.uname().nodename.split('.')[0]
committed={}
for s in json.loads((p/'inventory-storage.json').read_text()):
    if not s.get('active') or s.get('type') not in ('lvmthin','zfspool','dir') or 'images' not in s.get('content','').split(','): continue
    content=json.loads(subprocess.check_output(['pvesh','get','/nodes/'+node+'/storage/'+s['storage']+'/content','--output-format','json'],text=True))
    committed[s['storage']]=sum(int(v.get('size',0)) for v in content if v.get('content')=='images')
(p/'committed.json').write_text(json.dumps(committed))
PYSPACE
    # Compute a plan from actual host capacity. Bash remains the orchestration layer.
    export FIRST_VMID LAB_CIDR SO_BUILD
    python3 "$KIT/resource-plan.py" plan > "$STATE/plan.env.tmp"
    mv "$STATE/plan.env.tmp" "$STATE/plan.env"
    cat "$STATE/plan.env"
    note 'PRECHECK OK. Plan contains detected Proxmox version and adjusted storage/VM IDs.'
}
dependencies() {
    load_plan
    apt-get update
    apt-get install -y --no-install-recommends curl ca-certificates gnupg nftables ethtool tcpdump xorriso
    # Never change repository subscriptions or enable/restart nftables.service.
    note 'DEPENDENCIES OK; existing host firewall services were left in place.'
}
fetch() {
    local url=$1 out=$2
    [[ -f $out ]] && return
    curl --fail --location --proto '=https' --proto-redir '=https' --retry 4 --connect-timeout 20 --continue-at - "$url" -o "$out.part"
    mv "$out.part" "$out"
}
hash_ok() {
    if ! printf '%s  %s\n' "$1" "$2" | sha256sum -c -; then
        die "Checksum verification failed: $2. Provisioning stopped; review the publisher's verification guide before replacing the download."
    fi
}
import_key() {
    local keyfile=$1 fpr=$2
    gpg --homedir "$STATE/gnupg" --batch --import "$keyfile"
    gpg --homedir "$STATE/gnupg" --batch --with-colons --fingerprint "$fpr" | grep -Fq ":$fpr:" || die 'Signing key fingerprint mismatch.'
}
verify_signature() {
    local fpr=$1 sig=$2 data=$3
    if ! gpg --homedir "$STATE/gnupg" --batch --status-fd 1 --verify "$sig" "$data" > "$STATE/signature-status.tmp"; then
        die "Signature verification failed: $data. Provisioning stopped; do not bypass verification."
    fi
    # Accept either a primary signature or a subkey signed by the pinned primary key.
    awk -v f="$fpr" '$2=="VALIDSIG" && ($3==f || $NF==f) {ok=1} END {exit !ok}' "$STATE/signature-status.tmp" || die 'Unexpected signer.'
}
from_manifest() {
    local manifest=$1 file=$2
    awk -v f="$file" '{n=$2; sub(/^\*/,"",n); if(n==f) print tolower($1)}' "$manifest"
}
media() {
    load_plan
    mkdir -p "$FILE_PATH/template/iso" "$STATE/media" "$STATE/gnupg"
    chmod 700 "$STATE/gnupg"
    local dir=$FILE_PATH/template/iso meta=$STATE/media kname khash uhash
    fetch 'https://raw.githubusercontent.com/Security-Onion-Solutions/securityonion/3/main/KEYS' "$meta/so-keys"
    import_key "$meta/so-keys" "$SO_FPR"
    fetch "https://raw.githubusercontent.com/Security-Onion-Solutions/securityonion/3/main/sigs/$SO_ISO.sig" "$meta/$SO_ISO.sig"
    fetch "$SO_URL" "$dir/$SO_ISO"
    hash_ok "$SO_SHA256" "$dir/$SO_ISO"
    verify_signature "$SO_FPR" "$meta/$SO_ISO.sig" "$dir/$SO_ISO"
    fetch 'https://archive.kali.org/archive-key.asc' "$meta/kali-key.asc"
    import_key "$meta/kali-key.asc" "$KALI_FPR"
    fetch 'https://cdimage.kali.org/current/SHA256SUMS' "$meta/kali-SHA256SUMS"
    fetch 'https://cdimage.kali.org/current/SHA256SUMS.gpg' "$meta/kali-SHA256SUMS.gpg"
    verify_signature "$KALI_FPR" "$meta/kali-SHA256SUMS.gpg" "$meta/kali-SHA256SUMS"
    kname=$(awk '{n=$2; sub(/^\*/,"",n); if(n ~ /^kali-linux-[0-9.]+-installer-amd64\.iso$/) print n}' "$meta/kali-SHA256SUMS")
    [[ $kname =~ ^kali-linux-[0-9.]+-installer-amd64\.iso$ ]] || die 'Manifest does not contain exactly one Kali amd64 offline installer.'
    khash=$(from_manifest "$meta/kali-SHA256SUMS" "$kname")
    # Use a release URL so a change to current cannot silently change our artifact.
    local krelease=${kname#kali-linux-}; krelease=${krelease%-installer-amd64.iso}
    fetch "https://cdimage.kali.org/kali-$krelease/$kname" "$dir/$kname"
    hash_ok "$khash" "$dir/$kname"
    fetch "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$UBUNTU_FPR" "$meta/ubuntu-key.asc"
    import_key "$meta/ubuntu-key.asc" "$UBUNTU_FPR"
    fetch 'https://cloud-images.ubuntu.com/noble/current/SHA256SUMS' "$meta/ubuntu-SHA256SUMS"
    fetch 'https://cloud-images.ubuntu.com/noble/current/SHA256SUMS.gpg' "$meta/ubuntu-SHA256SUMS.gpg"
    verify_signature "$UBUNTU_FPR" "$meta/ubuntu-SHA256SUMS.gpg" "$meta/ubuntu-SHA256SUMS"
    uhash=$(from_manifest "$meta/ubuntu-SHA256SUMS" noble-server-cloudimg-amd64.img)
    [[ $uhash =~ ^[a-f0-9]{64}$ ]] || die 'Ubuntu hash missing.'
    fetch 'https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img' "$meta/noble-server-cloudimg-amd64.img"
    hash_ok "$uhash" "$meta/noble-server-cloudimg-amd64.img"
    fetch "$WINDOWS_URL" "$dir/$WINDOWS_ISO"
    hash_ok "$WINDOWS_SHA256" "$dir/$WINDOWS_ISO"
    printf 'KALI_ISO=%q\nKALI_SHA256=%q\nUBUNTU_SHA256=%q\n' "$kname" "$khash" "$uhash" > "$STATE/media.env.tmp"
    mv "$STATE/media.env.tmp" "$STATE/media.env"
    note 'MEDIA OK. Signed Linux manifests/ISO and Microsoft-published Windows SHA256 verified.'
}
install_same() {
    local src=$1 dst=$2 mode=${3:-600}
    if [[ -e $dst ]]; then cmp -s "$src" "$dst" || die "Refusing to overwrite changed file $dst"; else install -D -m "$mode" "$src" "$dst"; fi
}
ensure_network_include() {
    # ifupdown2 does not support trailing comments. Repair the old kit line.
    python3 - "$1" "$2" <<'PYINCLUDE'
import re, sys
from pathlib import Path
path, marker = map(Path, sys.argv[1:])
original = path.read_text()
line = 'source /etc/network/interfaces.d/so-single-nic'
updated = re.sub(r'^' + re.escape(line + ' # so-single-nic-owned') + r'$', line, original, flags=re.M)
include = r'^\s*source\s+/etc/network/interfaces.d/(\*|so-single-nic)(\s|$)|^\s*source-directory\s+/etc/network/interfaces.d(\s|$)'
if not re.search(include, updated, re.M):
    updated += '\n' + line + '\n'
if updated != original:
    path.write_text(updated)
    marker.touch()
PYINCLUDE
}
network() {
    load_plan; management_ok
    [[ ! -f /etc/network/interfaces.new ]] || die 'Pending network changes exist.'
    command -v nft >/dev/null || die 'Run dependencies first.'
    if [[ ! -f $STATE/interfaces.before ]]; then
        cp -a /etc/network/interfaces "$STATE/interfaces.before"
        [[ ! -d /etc/network/interfaces.d ]] || cp -a /etc/network/interfaces.d "$STATE/interfaces.d.before"
    fi
    [[ ! -e /sys/class/net/$LAB_BRIDGE || -f $STATE/network.owned ]] || die 'Unowned existing bridge.'
    mkdir -p "$INSTALL" /etc/network/interfaces.d
    cat > "$STATE/interfaces.lab" <<EOF
# Owned by so-single-nic. vmbr0 and nic0 are intentionally absent.
auto $LAB_BRIDGE
iface $LAB_BRIDGE inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    mtu 9000
    post-up /usr/local/lib/so-single-nic/guard.sh
EOF
    install_same "$STATE/interfaces.lab" "$NETFILE"
    # Add only an include if the default installation lacks one; never ifreload -a.
    ensure_network_include /etc/network/interfaces "$STATE/include.added"
    cp "$STATE/plan.env" "$INSTALL/plan.env"
    install_same "$KIT/lab.env" "$INSTALL/lab.env"
    install_same "$KIT/guard.sh" "$INSTALL/guard.sh" 700
    install_same "$KIT/mirror.sh" "$INSTALL/mirror.sh" 700
    install_same "$KIT/hook.sh" "$INSTALL/hook.sh" 700
    "$INSTALL/guard.sh"
    if [[ ! -e /sys/class/net/$LAB_BRIDGE ]]; then ifup "$LAB_BRIDGE"; fi
    ip link set dev "$LAB_BRIDGE" up
    touch "$STATE/network.owned"
    install_same "$KIT/so-lab-mirror.service" /etc/systemd/system/so-lab-mirror.service 644
    install_same "$KIT/so-lab-mirror.timer" /etc/systemd/system/so-lab-mirror.timer 644
    systemctl daemon-reload
    systemctl enable --now so-lab-mirror.timer
    management_ok
    [[ -z $(ip -4 -o addr show dev "$LAB_BRIDGE") ]] || die 'Lab bridge has an unexpected IPv4 address.'
    [[ -z $(ip -4 route show dev "$LAB_BRIDGE") ]] || die 'Lab bridge has an unexpected route.'
    note 'NETWORK OK. Management retained; lab bridge is unnumbered; forwarding and sensor TX blocked.'
    note 'Rollback: bash /root/so-single-nic-3.3/lab.sh rollback'
}
capacity_now() {
    # Recheck free space and memory before allocation; full-disk commitments, not thin optimism.
    export_resources
    python3 "$KIT/resource-plan.py" capacity
}
seed() {
    load_plan
    local old contents hash passwd
    old=$(pvesh get "/storage/$FILE_STORE" --output-format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["content"])')
    if [[ ,$old, != *,snippets,* ]]; then pvesm set "$FILE_STORE" --content "$old,snippets"; fi
    mkdir -p "$FILE_PATH/snippets"
    install_same "$KIT/hook.sh" "$FILE_PATH/snippets/so-single-nic-hook.sh" 700
    if [[ -f $STATE/ubuntu-user.yaml ]]; then
        install_same "$STATE/ubuntu-user.yaml" "$FILE_PATH/snippets/so-lab-ubuntu-user.yaml"
        return
    fi
    command -v openssl >/dev/null || die 'openssl missing.'
    passwd=$(openssl rand -base64 24)
    hash=$(printf '%s' "$passwd" | openssl passwd -6 -stdin)
    printf 'Ubuntu console user: labadmin\nPassword (shown once; save it now): %s\n' "$passwd" >/dev/tty
    unset passwd
    export KIT STATE UBUNTU_IP UBUNTU_ID hash
    python3 - <<'PY'
import json,os
from pathlib import Path
k=Path(os.environ['KIT']); p=Path(os.environ['STATE'])
doc={'hostname':'ubuntu-victim','manage_etc_hosts':True,'ssh_pwauth':False,'disable_root':True,
     'users':[{'name':'labadmin','groups':['sudo'],'shell':'/bin/bash','lock_passwd':False,'passwd':os.environ['hash'],'sudo':['ALL=(ALL) ALL']}],
     'package_update':False,'package_upgrade':False,
     'write_files':[{'path':'/opt/so-lab/demo.py','permissions':'0644','content':(k/'demo.py').read_text()},
                    {'path':'/etc/systemd/system/so-lab-demo.service','content':(k/'so-lab-demo.service').read_text()},
                    {'path':'/etc/sysctl.d/90-so-lab.conf','content':'net.ipv4.ip_forward=0\nnet.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1\n'},
                    {'path':'/var/lib/cloud/scripts/per-boot/so-lab-offload.sh','permissions':'0755','content':'#!/bin/bash\nfor path in /sys/class/net/*; do\n dev=${path##*/}; [[ $dev == lo ]] && continue\n for feature in rx tx sg tso gso gro lro; do ethtool -K "$dev" "$feature" off >/dev/null 2>&1 || true; done\ndone\n'}],
     'runcmd':[['sysctl','--system'],['bash','/var/lib/cloud/scripts/per-boot/so-lab-offload.sh'],['systemctl','daemon-reload'],['systemctl','enable','--now','so-lab-demo.service']]}
(p/'ubuntu-user.yaml').write_text('#cloud-config\n'+json.dumps(doc,indent=2)+'\n')
PY
    unset hash
    install_same "$STATE/ubuntu-user.yaml" "$FILE_PATH/snippets/so-lab-ubuntu-user.yaml"
}
create() {
    load_plan; source "$STATE/media.env"; management_ok; check_cpu
    [[ -f $STATE/network.owned ]] || die 'Run network first.'
    hash_ok "$SO_SHA256" "$FILE_PATH/template/iso/$SO_ISO"
    hash_ok "$KALI_SHA256" "$FILE_PATH/template/iso/$KALI_ISO"
    hash_ok "$WINDOWS_SHA256" "$FILE_PATH/template/iso/$WINDOWS_ISO"
    hash_ok "$UBUNTU_SHA256" "$STATE/media/noble-server-cloudimg-amd64.img"
    capacity_now
    # An imported cloud disk cannot be shrunk by qm disk resize. Check before
    # creating any VM so a small requested size does not leave a partial guest.
    local ubuntu_bytes
    ubuntu_bytes=$(qemu-img info --output=json "$STATE/media/noble-server-cloudimg-amd64.img" | python3 -c 'import json,sys; print(int(json.load(sys.stdin)["virtual-size"]))')
    (( UBUNTU_GB * 1024 * 1024 * 1024 >= ubuntu_bytes )) || die 'UBUNTU_DISK_GB is smaller than the verified cloud image virtual size. Choose a larger disk before a fresh preflight.'
    seed
    local role id mem cores disk name diskkey store key
    for role in SO KALI WINDOWS UBUNTU; do
        key=${role}_ID; id=${!key}
        key=${role}_MEMORY_MB; mem=${!key}
        key=${role}_CORES; cores=${!key}
        key=${role}_GB; disk=${!key}
        key=${role}_STORE; store=${!key}
        case $role in
            SO) name=securityonion; diskkey=scsi0;;
            KALI) name=kali; diskkey=scsi0;;
            WINDOWS) name=windows-victim; diskkey=sata0;;
            UBUNTU) name=ubuntu-victim; diskkey=scsi0;;
        esac
        if qm config "$id" >/dev/null 2>&1; then
            owned "$id" "$role" || die "VMID $id now belongs to another VM"
            [[ -f $STATE/$role.complete ]] || die "Partial $role provisioning: inspect qm config $id; no disks will be overwritten."
            note "VM $id already created; unchanged."
            continue
        fi
        [[ $(pvesh get /cluster/nextid --vmid "$id") == "$id" ]] || die "VMID $id is no longer free."
        local mac0 mac1
        printf -v mac0 '02:50:%02x:%02x:%02x:00' $((id>>16 & 255)) $((id>>8 & 255)) $((id & 255))
        printf -v mac1 '02:50:%02x:%02x:%02x:01' $((id>>16 & 255)) $((id>>8 & 255)) $((id & 255))
        local -a args=(--name "$name" --memory "$mem" --balloon 0 --cores "$cores" --cpu host --sockets 1 --onboot 0 --tags so-single-nic --description "so-single-nic owner=$OWNER role=$role" --ostype l26 --scsihw virtio-scsi-single --hookscript "$FILE_STORE:snippets/so-single-nic-hook.sh")
        if [[ $role == SO ]]; then
            args+=(--net0 "virtio=$mac0,bridge=$HOME_BRIDGE,firewall=0" --net1 "virtio=$mac1,bridge=$LAB_BRIDGE,firewall=0,mtu=9000")
        elif [[ $role == WINDOWS ]]; then
            args+=(--net0 "e1000=$mac0,bridge=$LAB_BRIDGE,firewall=0" --ostype win11 --machine q35 --bios ovmf --efidisk0 "$store:1,efitype=4m,pre-enrolled-keys=1" --tpmstate0 "$store:1,version=v2.0")
        else
            args+=(--net0 "virtio=$mac0,bridge=$LAB_BRIDGE,firewall=0,mtu=1500")
        fi
        if [[ $role == UBUNTU ]]; then
            args+=(--scsi0 "$store:0,import-from=$STATE/media/noble-server-cloudimg-amd64.img,discard=on,iothread=1" --ide2 "$store:cloudinit" --ciuser labadmin --ipconfig0 "ip=$UBUNTU_IP/24" --cicustom "user=$FILE_STORE:snippets/so-lab-ubuntu-user.yaml" --serial0 socket --vga serial0 --boot order=scsi0)
        else
            local mediafile=$SO_ISO
            [[ $role != KALI ]] || mediafile=$KALI_ISO
            [[ $role != WINDOWS ]] || mediafile=$WINDOWS_ISO
            args+=(--"$diskkey" "$store:$disk,discard=on" --ide2 "$FILE_STORE:iso/$mediafile,media=cdrom" --boot "order=ide2;$diskkey")
        fi
        qm create "$id" "${args[@]}"
        [[ $role != UBUNTU ]] || qm disk resize "$id" scsi0 "${disk}G"
        touch "$STATE/$role.complete"
        note "Created STOPPED $role VM $id"
    done
    local listed='|'
    for role in SO KALI WINDOWS UBUNTU; do
        key=${role}_STORE; store=${!key}
        if [[ $listed != *"|$store|"* ]]; then pvesm list "$store"; listed+="$store|"; fi
    done
    note 'CREATE OK. Installers never run until you explicitly start a VM.'
}
start_vm() {
    load_plan
    local role=${1^^} idvar id
    [[ $role =~ ^(SO|KALI|WINDOWS|UBUNTU)$ ]] || die 'Choose SO, KALI, WINDOWS or UBUNTU.'
    idvar=${role}_ID; id=${!idvar}
    owned "$id" "$role" || die 'Ownership mismatch.'
    [[ -f $STATE/$role.complete ]] || die 'VM provisioning incomplete.'
    management_ok
    [[ -e /sys/class/net/$LAB_BRIDGE ]] || die "$LAB_BRIDGE is missing. Run: bash lab.sh network; then retry start $role."
    check_cpu; capacity_now
    "$INSTALL/guard.sh"
    if [[ $(qm status "$id") != 'status: running' ]]; then qm start "$id" 9>&-; fi
    "$INSTALL/mirror.sh"
    note "START OK: $role VM $id. Open its Proxmox console."
}
boot_disk() {
    load_plan
    local role=${1^^} idvar id disk=scsi0
    [[ $role =~ ^(SO|KALI|WINDOWS)$ ]] || die 'Choose SO, KALI or WINDOWS.'
    idvar=${role}_ID; id=${!idvar}
    owned "$id" "$role" || die 'Ownership mismatch.'
    [[ $role != WINDOWS ]] || disk=sata0
    qm set "$id" --boot "order=$disk"
    # Do not erase installer media or remove drives; changing boot order is reversible.
    note "BOOT OK: $id now boots $disk. Reboot the GUEST when its installer requests it."
}
tools_iso() {
    load_plan
    local dir=$FILE_PATH/template/iso common=so-lab-tools-$OWNER.iso win=so-lab-windows-$OWNER.iso
    mkdir -p "$STATE/tools"
    for file in lab.env plan.env so-wizard.sh lab.rules windows.ps1 kali-setup.sh kali-test.sh; do
        local src=$KIT/$file
        [[ $file != plan.env ]] || src=$STATE/plan.env
        install_same "$src" "$STATE/tools/$file"
    done
    if [[ ! -f $dir/$common ]]; then
        # Do not recursively copy private/stale files somebody added to tools.
        # This generated disc still includes private deployment metadata.
        local common_stage
        common_stage=$(mktemp -d "$STATE/linux-tools.XXXXXX")
        for file in lab.env plan.env so-wizard.sh lab.rules windows.ps1 kali-setup.sh kali-test.sh; do
            install -m 600 "$STATE/tools/$file" "$common_stage/$file"
        done
        xorriso -as mkisofs -quiet -r -J -V SOLABTOOLS -o "$dir/$common.part" "$common_stage"
        mv "$dir/$common.part" "$dir/$common"
        rm -r -- "$common_stage"
    fi
    # Fresh Windows setup uses privately entered accounts; no new answer files.
    # A new filename cannot silently reuse the legacy password-bearing ISO.
    win=so-lab-windows-public-$OWNER.iso
    if [[ ! -f $dir/$win ]]; then
        local public_stage
        public_stage=$(mktemp -d "$STATE/windows-public.XXXXXX")
        for file in windows.ps1; do
            install -m 600 "$KIT/$file" "$public_stage/$file"
        done
        xorriso -as mkisofs -quiet -r -J -V SOLABWIN -o "$dir/$win.part" "$public_stage"
        mv "$dir/$win.part" "$dir/$win"
        rm -r -- "$public_stage"
    fi
    chmod 600 "$dir/$common" "$dir/$win"
    local role idvar id iso existing
    for role in SO KALI WINDOWS; do
        idvar=${role}_ID; id=${!idvar}; iso=$common
        [[ $role != WINDOWS ]] || iso=$win
        owned "$id" "$role" || die 'Ownership mismatch.'
        existing=$(qm config "$id" | sed -n 's/^sata1: //p')
        if [[ -n $existing ]]; then
            [[ $existing == "$FILE_STORE:iso/$iso,media=cdrom" ]] || die "VM $id sata1 is already occupied."
        else
            [[ $(qm status "$id") == 'status: stopped' ]] || die "Stop VM $id normally before attaching tools."
            qm set "$id" --sata1 "$FILE_STORE:iso/$iso,media=cdrom"
        fi
    done
    note 'TOOLS OK. Windows media contains only public scripts; enter the Windows account/password privately during setup. Legacy password-bearing media is retained for review, never regenerated.'
}
verify() {
    load_plan; management_ok
    pveversion; qm list; pvesm status
    ip -br addr show "$HOME_BRIDGE"
    ip -br addr show "$LAB_BRIDGE"
    ip -4 route
    nft list table bridge so_lab_guard
    nft list table inet so_lab_guard
    systemctl is-active so-lab-mirror.timer
    local role idvar id
    for role in SO KALI WINDOWS UBUNTU; do
        idvar=${role}_ID; id=${!idvar}
        owned "$id" "$role" || die "Ownership failure: $id"
        qm config "$id" | grep -E '^(name|memory|cores|cpu|net[0-9]|boot|hookscript|scsi0|sata0):'
    done
    if [[ -e /sys/class/net/tap${SO_ID}i1 ]]; then
        [[ ! -L /sys/class/net/tap${SO_ID}i1/master ]] || die 'Sensor port is still in bridge.'
        ip -br link show "tap${SO_ID}i1"
        for port in /sys/class/net/"$LAB_BRIDGE"/brif/*; do
            [[ -e $port ]] || continue
            tc -s filter show dev "${port##*/}" ingress
        done
    else note 'Start SO to verify the sensor tap and mirrors.'; fi
    note 'HOST VERIFY OK. Guest traffic and SOC ingestion still need the end-to-end test.'
}
rollback() {
    load_plan
    # Validate the four-VM boundary before removing a bridge somebody else uses.
    "$INSTALL/guard.sh"
    confirm 'Rollback gracefully shuts down owned lab VMs and removes only lab networking. VM disks and media are retained.'
    local role idvar id
    for role in SO KALI WINDOWS UBUNTU; do
        idvar=${role}_ID; id=${!idvar}
        if qm config "$id" >/dev/null 2>&1; then
            owned "$id" "$role" || die 'Ownership mismatch; abort rollback.'
            if [[ $(qm status "$id") == 'status: running' ]]; then qm shutdown "$id" --timeout 60; fi
            [[ $(qm status "$id") == 'status: stopped' ]] || die 'Guest did not shut down; no force-stop performed.'
        fi
    done
    systemctl disable --now so-lab-mirror.timer
    rm -f /etc/systemd/system/so-lab-mirror.timer /etc/systemd/system/so-lab-mirror.service
    systemctl daemon-reload
    [[ ! -e /sys/class/net/$LAB_BRIDGE ]] || ip link delete "$LAB_BRIDGE" type bridge
    cmp -s "$NETFILE" "$STATE/interfaces.lab" || die 'Network snippet was edited; refusing to remove it.'
    rm "$NETFILE"
    if [[ -f $STATE/include.added ]]; then
        sed -i '\|^source /etc/network/interfaces.d/so-single-nic\( # so-single-nic-owned\)\?$|d' /etc/network/interfaces
        rm "$STATE/include.added"
    fi
    # Host main configuration is preserved; backup available for console recovery.
    nft list table bridge so_lab_guard >/dev/null 2>&1 && nft delete table bridge so_lab_guard
    nft list table inet so_lab_guard >/dev/null 2>&1 && nft delete table inet so_lab_guard
    rm -f "$STATE/network.owned"
    management_ok
    note 'ROLLBACK OK. Host management retained; VM disks retained.'
}
need_host
case ${1:-help} in
    preflight) preflight;; dependencies) dependencies;; media) media;; network) network;; create) create;;
    tools) tools_iso;; start) start_vm "${2:-}";; boot-disk) boot_disk "${2:-}";; verify) verify;; rollback) rollback;;
    *) echo 'Usage: lab.sh preflight|dependencies|media|network|create|tools|start ROLE|boot-disk ROLE|verify|rollback';;
esac
