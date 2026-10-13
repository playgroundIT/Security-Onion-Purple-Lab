# Configure RAM, CPU, disk size, and SSD/HDD storage

Edit **`lab.env` before the first `bash lab.sh preflight`**. You do not need to edit VM creation code or capacity arithmetic. The four-VM fresh-build defaults are:

| VM | RAM setting (MiB) | CPU setting | Disk setting (GiB) | Storage override |
|---|---|---|---|---|
| Security Onion | `SO_MEMORY_MB=32768` | `SO_CORES=6` | `SO_DISK_GB=800` | `SO_STORAGE=` |
| Kali | `KALI_MEMORY_MB=6144` | `KALI_CORES=4` | `KALI_DISK_GB=80` | `KALI_STORAGE=` |
| Windows | `WINDOWS_MEMORY_MB=8192` | `WINDOWS_CORES=4` | `WINDOWS_DISK_GB=100` | `WINDOWS_STORAGE=` |
| Ubuntu | `UBUNTU_MEMORY_MB=4096` | `UBUNTU_CORES=2` | `UBUNTU_DISK_GB=60` | `UBUNTU_STORAGE=` |

RAM is in **MiB**: 4096 = 4 GiB, 6144 = 6 GiB, 8192 = 8 GiB, 32768 = 32 GiB. Disk capacities are whole **GiB**; do not append `G` or `GB` in `lab.env`. Every VM retains one socket, `cpu: host`, fixed RAM (`balloon: 0`), its original disk interface, and its isolated network topology.

## 1. Change the desired allocations

For example, change Kali to 4 GiB RAM, 2 vCPUs, and a 120 GiB disk, and Ubuntu to 90 GiB:

```bash
KALI_MEMORY_MB=4096
KALI_CORES=2
KALI_DISK_GB=120
UBUNTU_DISK_GB=90
```

Replace the existing assignments in `lab.env`; these are not commands for changing an already-created VM. The planner calculates the new memory total and storage commitments automatically. Ubuntu's cloud-image import is expanded to its planned disk size; a requested disk smaller than the downloaded image's virtual size is rejected before any VM is created.

The four defaults need **50 GiB guest RAM plus `HOST_RESERVE_MB=8192` (8 GiB)** and any existing host workload allocations. Preflight and runtime checks budget the four planned guests automatically. Physical capacity is checked from the host's usable RAM, not its advertised label. Keep headroom for Proxmox and, if used, ZFS. Each VM's core count must fit the host's logical CPU count; the combined count may exceed it for light concurrent workloads and produces a CPU-sharing notice.

Kit floors:

| VM | Minimum RAM | Minimum vCPU | Minimum disk |
|---|---:|---:|---:|
| SO Standalone | 24576 MiB | 4 | 300 GiB |
| Kali desktop/tools | 2048 MiB | 1 | 20 GiB |
| Windows 11 | 4096 MiB | 2 | 64 GiB |
| Ubuntu cloud guest | 1024 MiB | 1 | 8 GiB, and at least the image's virtual size |

These are rejection floors, not a performance promise. The SO disk floor is this kit's conservative policy; the [official Standalone minimum](https://docs.securityonion.net/en/3/main/hardware/) is 200 GB, 24 GB RAM, and 4 cores. SO recommends considering 32 GB RAM or more even for small amounts of monitored traffic. Keep the tutorial's 32 GiB default unless your workload and measurements justify changing it. [Windows 11 requirements](https://www.microsoft.com/en-us/windows/windows-11-specifications) and [Kali installation requirements](https://www.kali.org/docs/installation/hard-disk-install/) describe their supported baselines.

## 2. Choose the SSD or HDD backing each VM

First identify existing storage IDs in **Proxmox → Datacenter → Storage** and check their backing disks in the node's storage/disks pages. On the Proxmox host:

```bash
pvesm status
```

Use a **Proxmox storage ID**, such as `local-lvm`, in `lab.env`. A label does not prove a pool is an SSD: confirm its physical backing. The provisioner does not format disks, create new pools, or accept `/dev/sda` as a storage setting. Prepare a new physical storage pool separately in Proxmox if necessary.

Selection order for each VM:

1. Its own `*_STORAGE` override, if nonempty.
2. The common `VM_STORAGE`, if nonempty.
3. The planner's eligible local storage selection, otherwise.

Example **only if these storage IDs already exist on your host**:

```bash
VM_STORAGE=hdd-pool
SO_STORAGE=ssd-pool
KALI_STORAGE=
WINDOWS_STORAGE=ssd-pool
UBUNTU_STORAGE=
FILE_STORAGE=local
```

SO and Windows go on `ssd-pool`; Kali and Ubuntu inherit `hdd-pool`. Windows's EFI and TPM volumes follow its system disk. Ubuntu's cloud-init volume follows its system disk. `FILE_STORAGE` selects a local directory storage for installer/tools ISOs and snippets and is independent of the VM disk overrides.

Allowed VM backends are active local **LVM-thin, ZFS, and directory storage** with `images` content. Shared and remote backends are rejected by this kit. Each selected VM storage retains at least **100 GiB or 10% of its total capacity**, whichever is larger, plus auxiliary-volume/allocation headroom. If it also holds the media, 40 GiB of media/staging headroom is retained. Full existing logical disk commitments are counted, so an almost-empty thin disk still reserves its promised capacity.

Use distinct backing pools when splitting VM storage. Do not declare multiple storage IDs for the same pool/filesystem to claim capacity twice. Identical configured backend aliases are rejected. Storage IDs are grouped for capacity checks; this is not an automatic discovery of SSD/HDD type or every possible overlapping mount layout.

## 3. Decide whether SO's requested disk may be reduced

```bash
SO_DISK_AUTO_SHRINK=1
```

This preserves the previous behavior: `SO_DISK_GB` is the requested maximum; preflight may reduce it to fit the selected pool, keeping at least 300 GiB. The selected size is printed and saved as `SO_GB`. This happens before creating the disk; it never shrinks an existing disk.

For an exact requested allocation:

```bash
SO_DISK_AUTO_SHRINK=0
```

Insufficient space now fails preflight rather than reducing SO's disk. Kali, Windows, and Ubuntu always retain their exact configured sizes.

## 4. Review the saved plan, then provision

On the Proxmox host, from the copied kit directory:

```bash
nano lab.env
bash lab.sh preflight
cat /var/lib/so-single-nic/plan.env
```

Review each VM's `*_MEMORY_MB`, `*_CORES`, `*_GB`, `*_STORE`, and `*_ID`. For example, `KALI_STORAGE` is the requested override in the input file; `KALI_STORE` is the resolved storage ID in the plan. Continue through dependencies, media, network, create, and tools only after the plan fits the intended host.

## Existing deployments and upgrades

**These settings are for a fresh plan and new VMs.** Rerunning `create` skips existing completed VMs, including their disks and accounts. It does not resize RAM/disks, move storage, or reinstall an OS.

New plans freeze the requested resource configuration. If `lab.env` changes afterward, the script stops with a configuration-drift message. Restore the planned settings, or use the backed-up clean-rebuild procedure before making a new plan. Do not delete or hand-edit a saved plan to bypass ownership checks. For one-off changes to existing VMs, use Proxmox's RAM, disk-resize, and Move Storage controls; increasing a disk also requires extending the guest partition/filesystem.

Previous resource-schema plans using Kali 4 GiB and Windows 6 GiB remain valid with `KALI_MEMORY_MB=4096` and `WINDOWS_MEMORY_MB=6144` in their host-side configuration. Keep those settings when updating their scripts; copying the new defaults over them will correctly trigger a drift refusal.

Original plans without resource metadata remain usable with their original allocations and storage. They retain the original planned SO disk even if it was reduced below 800 GiB. Custom resource changes require a fresh deployment. Runtime checks also count larger actual guest RAM allocations and current disk commitments, so manual PVE changes cannot silently bypass the capacity budget.

Copy the **whole updated kit directory**, including `resource-plan.py`, when upgrading the host-side script. Keep the host's original `lab.env` values for its management network and allocation plan. This feature is locally tested with mocked Proxmox commands; a mixed SSD/HDD deployment has **not been tested on the live host**.
