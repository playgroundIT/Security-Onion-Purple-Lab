# Security Onion 3.3 Purple Team Lab — Four VMs, One NIC

Build an isolated Security Onion purple-team lab on an existing Proxmox VE host using **one physical NIC**.

The deployment kit creates exactly four VMs:

- Security Onion 3.3 Standalone
- Kali Linux
- Windows 11
- Ubuntu

> **Authorized lab testing only.**
>
> Keep attack/victim traffic inside the isolated lab network. Do not expose the victim VMs, Proxmox, or Security Onion SOC through public router forwards.

---

## Architecture

```text
Home / Management Network
192.168.0.0/24

              Physical NIC
                   │
                 vmbr0
                   │
       ┌───────────┴───────────┐
       │                       │
 Proxmox VE              Security Onion
192.168.0.253           management NIC
                        192.168.0.252
                              │
                         monitor NIC
                          bond0 / no IP
                              ▲
                              │
                         tc packet copies
                              │
                         vmbr-lab
                   no physical uplink
                   no host IP
                   no gateway
                   no ordinary NAT
                              │
          ┌───────────────────┼───────────────────┐
          │                   │                   │
        Kali               Windows             Ubuntu
    10.50.0.10          10.50.0.20         10.50.0.30
```

`vmbr-lab` carries only the isolated attack/victim network.

Linux `tc` ingress mirroring copies traffic from the Kali, Windows, and Ubuntu TAP interfaces to Security Onion's detached monitoring TAP. Security Onion observes the traffic but does not act as the lab router.

The owned guard rules prevent the lab from using the Proxmox host as a path into other networks.

---

## Default VM Resources

| Role | VMID | RAM | vCPU | System disk |
|---|---:|---:|---:|---:|
| Security Onion 3.3.0-20260911 Standalone | 200 | 32 GiB | 6 | Up to 800 GiB |
| Kali Linux | 201 | 6 GiB | 4 | 80 GiB |
| Windows 11 | 202 | 8 GiB | 4 | 100 GiB |
| Ubuntu | 203 | 4 GiB | 2 | 60 GiB |

The default guest allocation is **50 GiB RAM**, with another **8 GiB reserved for Proxmox**.

Existing saved plans keep their existing allocations.

The tutorial host was:

```text
AMD Ryzen 5 5600G
64 GiB RAM
2 TB NVMe
```

This is an example, not a requirement.

Security Onion 3.3 requires the required x86-64-v3 CPU features, so its VM uses:

```text
cpu: host
```

Adjust VM resources in `lab.env` **before the first preflight**.

---

# 1. Copy the Deployment Kit

The supported deployment implementation is:

```text
single-nic-3.3/
```

Copy the complete directory to your Proxmox host.

Example from your workstation:

```bash
rsync -av single-nic-3.3/ \
  root@192.168.0.253:/root/so-single-nic-3.3/
```

Then connect:

```bash
ssh root@192.168.0.253
```

All `lab.sh` commands below must be run as **root on Proxmox VE**.

```bash
cd /root/so-single-nic-3.3
export LC_ALL=C
```

---

# 2. Configure `lab.env`

Review:

```bash
nano lab.env
```

Important host-specific values include:

```bash
HOST_IP=192.168.0.253
HOME_GATEWAY=192.168.0.1

HOME_BRIDGE=vmbr0
PHYSICAL_NIC=nic0

LAB_BRIDGE=vmbr-lab
LAB_CIDR=10.50.0.0/24

SO_IP=192.168.0.252

KALI_IP=10.50.0.10
WINDOWS_IP=10.50.0.20
UBUNTU_IP=10.50.0.30
```

The physical interface name is an example.

Verify yours with:

```bash
ip -br link
```

Resource settings are configurable per VM.

For example:

```bash
KALI_MEMORY_MB=4096
KALI_CORES=2
KALI_DISK_GB=120
KALI_STORAGE=local-lvm
```

Resource units:

```text
*_MEMORY_MB = MiB
*_DISK_GB   = GiB
*_STORAGE   = existing Proxmox storage ID
```

The scripts do not format physical disks or resize/move existing VMs.

---

# 3. Run the Host-Side Build Stages

Run each stage separately and check its result before continuing.

```bash
bash lab.sh preflight
```

Then:

```bash
bash lab.sh dependencies
```

Then:

```bash
bash lab.sh media
```

Then:

```bash
bash lab.sh network
```

Then:

```bash
bash lab.sh create
```

Finally:

```bash
bash lab.sh tools
```

The approximate flow is:

```text
preflight
    ↓
dependencies
    ↓
media
    ↓
network
    ↓
create
    ↓
tools
    ↓
install the four guests
```

`create` creates the four VMs in a stopped state.

SO, Windows, and Kali credentials should also be entered off camera.

Generated deployment state, cloud-init seeds, helper media, VM disks, credentials, and backups are private runtime artifacts and should not be published.

---

# 4. Install the VMs

Use this order:

```text
1. Security Onion
2. Windows
3. Ubuntu
4. Kali
```

Security Onion is prepared first so that the monitoring stack exists before victim and attacker traffic is generated.

---

# 4.1 Security Onion — VM 200

Security Onion uses the official installation ISO.

Start the VM from Proxmox:

```bash
cd /root/so-single-nic-3.3

bash lab.sh start SO
```

Open:

```text
Proxmox
→ VM 200
→ Console
```

Confirm that the installer is targeting the Security Onion VM disk, not another disk.

Complete the base OS installation.

Recommended hostname:

```text
so-lab
```

At the installer's reboot boundary, **before allowing it to boot the ISO again**, run on Proxmox:

```bash
bash lab.sh boot-disk SO
```

Verify:

```bash
qm config 200 | grep '^boot:'
```

Expected:

```text
boot: order=scsi0
```

Let Security Onion reboot from its installed disk.

If Security Onion Setup does not automatically start after login, the documented setup command is:

```bash
sudo SecurityOnion/setup/so-setup iso
```

## Security Onion setup values

For this tutorial topology:

| Setting | Value |
|---|---|
| Deployment | Standalone |
| Installation type | Standard |
| Hostname | `so-lab` |
| Management address | `192.168.0.252/24` |
| Gateway | `192.168.0.1` |
| DNS | `192.168.0.1` |
| Search domain | `home.arpa` |
| Management NIC | NIC ending in MAC `c8:00` |
| Monitoring NIC | NIC ending in MAC `c8:01` |
| Monitoring IP | None |
| Web access | IP |
| Telemetry | No for tutorial |

The observed interfaces were:

```text
ens18 = management
ens19 = monitoring
```

Do not rely only on interface names. Confirm using MAC addresses:

```bash
ip -br link

for path in /sys/class/net/*/address; do
    printf '%s ' "${path%/address}"
    cat "$path"
done
```

After setup:

```bash
sudo so-status
```

Check:

```bash
ip -br addr
ip -4 route
ip -6 addr show dev bond0
```

The monitoring interface/bond should have **no IP address**.

From your analyst workstation, open:

```text
https://192.168.0.252
```

Confirm SOC/Grid access before continuing.

---

# 4.2 Windows 11 — VM 202

Start Windows from Proxmox:

```bash
cd /root/so-single-nic-3.3

bash lab.sh start WINDOWS
```

Open:

```text
Proxmox
→ VM 202
→ Console
```

The initial boot should use the Windows installer ISO.

For a fresh VM:

1. Boot the Windows installation DVD.
2. Choose the appropriate language/keyboard.
3. Select the clean/custom installation path.
4. Install Windows onto the approximately 100 GiB system disk.
5. Do not install Windows onto EFI/TPM/helper devices.

Before Windows performs its first installer reboot, switch the VM to its installed disk:

```bash
bash lab.sh boot-disk WINDOWS
```

Verify:

```bash
qm config 202 | grep '^boot:'
```

Expected:

```text
boot: order=sata0
```

Let Windows continue its setup from disk.

Do not press a key to boot the installation DVD again.

## Windows OOBE

The lab is intentionally offline.

If available, choose:

```text
I don't have internet
```

and create a local account such as:

```text
labadmin
```

Use a private password.

Do **not** temporarily attach Windows to `vmbr0` merely to complete installation.

## Configure Windows networking

Open:

```text
Win + R
→ ncpa.cpl
→ Ethernet
→ Properties
→ Internet Protocol Version 4
```

Configure:

```text
IP address:       10.50.0.20
Subnet mask:      255.255.255.0
Default gateway:  <blank>
DNS:              <blank>
```

Verify:

```cmd
ipconfig
route print -4
```

There should be no ordinary default route.

For lab ICMP testing, a subnet-scoped firewall rule can be added from elevated CMD:

```cmd
netsh advfirewall firewall add rule name="SO LAB Allow Ping" dir=in action=allow protocol=icmpv4:8,any localip=10.50.0.20 remoteip=10.50.0.0/24 profile=any enable=yes
```

Do not disable Windows Firewall globally.

---

# 4.3 Ubuntu — VM 203

Ubuntu is different from the other guests.

It does **not** use a normal ISO installer.

The `create` stage imports the Ubuntu Noble cloud image and creates the VM disk automatically.

Therefore there is no:

```text
bash lab.sh boot-disk UBUNTU
```

command.

The VM should already boot from `scsi0`.

Before starting, inspect it:

```bash
qm status 203

qm config 203 | grep -E \
'^(boot|scsi0|scsihw|serial0|vga|ide2|ipconfig0|cicustom):'
```

The real build encountered a serial-console display issue.

For the graphical noVNC console, while VM 203 is stopped:

```bash
qm set 203 --vga std
```

Then start Ubuntu:

```bash
cd /root/so-single-nic-3.3

bash lab.sh start UBUNTU
```

Open:

```text
Proxmox
→ VM 203
→ Console
```

Log in as:

```text
labadmin
```

using the private password printed during `bash lab.sh create`.

Check cloud-init:

```bash
cloud-init status --wait
cloud-init status --long
```

Verify networking:

```bash
ip -br addr
ip -4 route
```

Expected:

```text
10.50.0.30/24
```

with **no default route**.

The lab cloud-init configuration also prepares the Ubuntu demo service.

Check:

```bash
systemctl is-active so-lab-demo
```

Then:

```bash
curl --noproxy '*' \
  --fail \
  --max-time 10 \
  http://10.50.0.30:8080/
```

Expected response:

```text
SO LAB Ubuntu victim: HTTP ready
```

If cloud-init or the demo service fails:

```bash
sudo journalctl -u so-lab-demo -n 60 --no-pager
sudo tail -n 60 /var/log/cloud-init-output.log
sudo tail -n 60 /var/log/cloud-init.log
sudo ss -lntp
```

Do not blindly rerun `cloud-init clean` before diagnosing the original failure.

---

# 4.4 Kali Linux — VM 201

Kali is installed last because it is the attacker/test workstation.

Start it from Proxmox:

```bash
cd /root/so-single-nic-3.3

bash lab.sh start KALI
```

Open:

```text
Proxmox
→ VM 201
→ Console
```

Choose:

```text
Graphical install
```

The lab has no DHCP server, so configure networking manually when DHCP fails.

Use:

```text
Hostname:         kali
Domain:           <blank>

IP address:       10.50.0.10
Subnet mask:      255.255.255.0
Gateway:          <blank>
DNS:              <blank>
```

Recommended login:

```text
labadmin
```

Use a private password.

For disk setup:

```text
Guided
→ use entire disk
→ approximately 80 GiB VM disk
→ all files in one partition
```

For software selection, install:

```text
Xfce
top10
default/recommended Kali tools
```

Do not configure a network package mirror. The VM intentionally has no Internet route.

Install GRUB onto the identified whole system disk.

At the final Kali installer reboot prompt, run on Proxmox:

```bash
bash lab.sh boot-disk KALI
```

Verify:

```bash
qm config 201 | grep '^boot:'
```

Expected:

```text
boot: order=scsi0
```

Let Kali reboot into the installed OS.

## Verify Kali networking

Inside Kali:

```bash
ip -br addr
nmcli device status
nmcli connection show
ip -4 route
```

Expected:

```text
10.50.0.10/24
```

with only the connected lab-subnet route and **no default route**.

If necessary, configure the persistent NetworkManager profile after identifying the actual interface.

For an interface named `eth0`:

```bash
if ! nmcli connection show SO-LAB >/dev/null 2>&1; then
    sudo nmcli connection add \
      type ethernet \
      ifname eth0 \
      con-name SO-LAB
fi

sudo nmcli connection modify SO-LAB \
    connection.interface-name eth0 \
    connection.autoconnect yes \
    connection.autoconnect-priority 100 \
    ipv4.method manual \
    ipv4.addresses 10.50.0.10/24 \
    ipv4.gateway "" \
    ipv4.dns "" \
    ipv4.never-default yes \
    ipv6.method disabled

sudo nmcli connection up SO-LAB
```

Verify:

```bash
ip -br addr
ip -4 route
```

## Kali tools helper

Mount the supplied tools disc:

```bash
lsblk -f

sudo mkdir -p /mnt/so-lab

sudo mount -o ro \
  /dev/disk/by-label/SOLABTOOLS \
  /mnt/so-lab
```

Run:

```bash
sudo bash /mnt/so-lab/kali-setup.sh
```

Then verify:

```bash
command -v nmcli nmap curl ethtool
ip -4 route
```

---

# 5. VM Start/Boot Command Summary

All of these commands run on **Proxmox VE**, not inside the guest.

| VM | Start | Switch installer to disk |
|---|---|---|
| Security Onion | `bash lab.sh start SO` | `bash lab.sh boot-disk SO` |
| Windows | `bash lab.sh start WINDOWS` | `bash lab.sh boot-disk WINDOWS` |
| Ubuntu | `bash lab.sh start UBUNTU` | Not required |
| Kali | `bash lab.sh start KALI` | `bash lab.sh boot-disk KALI` |

The complete installation order is therefore:

```bash
# Security Onion
bash lab.sh start SO

# At SO installer reboot boundary:
bash lab.sh boot-disk SO


# Windows
bash lab.sh start WINDOWS

# Before Windows installer reboots from ISO again:
bash lab.sh boot-disk WINDOWS


# Ubuntu cloud image
bash lab.sh start UBUNTU


# Kali
bash lab.sh start KALI

# At Kali installer final reboot:
bash lab.sh boot-disk KALI
```

---

# 6. Host Configuration Verification

After the guests are installed:

```bash
cd /root/so-single-nic-3.3

bash lab.sh verify
```

This verifies the **host-side configuration**.

It does not prove that traffic successfully reaches Security Onion.

---

# 7. Verify Traffic Mirroring

On Proxmox:

```bash
/usr/local/lib/so-single-nic/mirror.sh
```

Check the timer:

```bash
systemctl is-active so-lab-mirror.timer
```

Inspect Kali's mirror filter:

```bash
tc -s filter show dev tap201i0 ingress
```

Equivalent mirror filters should exist for the Windows and Ubuntu endpoint TAPs.

Traffic should be copied toward Security Onion's monitoring TAP.

---

# 8. Verify Security Onion Capture

On Security Onion:

```bash
sudo so-status
```

Then watch the monitoring bond:

```bash
sudo tcpdump -nn -i bond0 \
  'host 10.50.0.10 and host 10.50.0.20'
```

From Kali:

```bash
ping -c 5 10.50.0.20
```

Then perform a controlled scan:

```bash
sudo nmap \
  -sS \
  -Pn \
  -p 22,80,135,139,445,3389 \
  --max-rate 20 \
  --max-retries 1 \
  10.50.0.20
```

If packets appear on `bond0`, the packet-copy path is functioning.

---

# 9. Verify Hunt

In Security Onion SOC → **Hunt**, search:

```text
source.ip:10.50.0.10 AND destination.ip:10.50.0.20
```

Seeing matching indexed events proves more than `tcpdump` alone:

```text
Kali
 ↓
vmbr-lab
 ↓
tc mirror
 ↓
SO bond0
 ↓
Zeek / Suricata
 ↓
Elastic
 ↓
Hunt
```

---

# 10. Verify a Deterministic Suricata Alert

A simple lab-only test signature can be used to prove the detection path:

```suricata
alert icmp 10.50.0.10 any -> 10.50.0.20 any \
(msg:"SO LAB ingestion verification ping"; \
itype:8; sid:1000010; rev:1;)
```

Enable/deploy the rule through Security Onion Detections.

Then from Kali:

```bash
ping -c 3 10.50.0.20
```

Confirm the corresponding alert appears in SOC.

If SID `1000010` already exists, inspect it rather than creating a duplicate.

---

# 11. Verify PCAP

The final validation chain should prove:

```text
Endpoint traffic
      ↓
tc counter changes
      ↓
bond0 packet capture
      ↓
Zeek / Suricata telemetry
      ↓
Hunt result
      ↓
Suricata test alert
      ↓
matching PCAP
```

A successful:

```bash
bash lab.sh verify
```

alone does **not** prove this end-to-end path.

See:

[SECURITY-ONION-PURPLE-LAB-GUIDE.md](SECURITY-ONION-PURPLE-LAB-GUIDE.md)

for the complete validation procedure.

---

# 12. Lab Network Summary

| System | Address | Gateway | Purpose |
|---|---|---|---|
| Proxmox | `192.168.0.253/24` | `192.168.0.1` | Hypervisor management |
| Security Onion management | `192.168.0.252/24` | `192.168.0.1` | SOC/management |
| Security Onion monitor | No IP | None | Passive capture |
| Kali | `10.50.0.10/24` | None | Attacker/test system |
| Windows | `10.50.0.20/24` | None | Victim |
| Ubuntu | `10.50.0.30/24` | None | Victim |

The three lab guests should **not** have:

```text
default gateway
external DNS
ordinary Internet access
NIC on vmbr0
```

Security Onion's management interface is the only lab VM interface connected to the home management network.

---

# 13. Important Files

```text
single-nic-3.3/
├── lab.sh
├── lab.env
├── RUNBOOK.md
├── RESOURCES.md
└── ...
```

Main documentation:

```text
README.md
SECURITY-ONION-PURPLE-LAB-GUIDE.md
CONTRIBUTING.md
```

Do not publish generated runtime state, credentials, VM images, installation media, packet captures, or private backups.

---

# 14. Quick Build Overview

```bash
# On Proxmox
cd /root/so-single-nic-3.3
export LC_ALL=C

# Host preparation
bash lab.sh preflight
bash lab.sh dependencies
bash lab.sh media
bash lab.sh network
bash lab.sh create
bash lab.sh tools

# Security Onion
bash lab.sh start SO
# install SO...
bash lab.sh boot-disk SO

# Windows
bash lab.sh start WINDOWS
# install Windows...
bash lab.sh boot-disk WINDOWS

# Ubuntu
bash lab.sh start UBUNTU
# wait for cloud-init and validate...

# Kali
bash lab.sh start KALI
# install Kali...
bash lab.sh boot-disk KALI

# Host-side verification
bash lab.sh verify
```
