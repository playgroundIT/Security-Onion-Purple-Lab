# Four-VM single-NIC runbook

Use the [complete guide](../SECURITY-ONION-PURPLE-LAB-GUIDE.md) for installer choices and troubleshooting. This directory is the only deployment kit: SO Standalone, Kali, Windows, and Ubuntu. Live actions in this runbook are **untested** unless the complete guide marks historical evidence as observed. Testing must be authorized and restricted to the isolated lab.

## Before starting

1. Have an existing Proxmox host, local console/second management session, and private backups.
2. Review `lab.env`: match your management bridge, IP/router, and physical NIC. Default tutorial values are `vmbr0`, `.253`, `.1`, and `nic0`.
3. Select RAM/CPU/disk/storage using [RESOURCES.md](RESOURCES.md) before first preflight. Default IDs are 200–203; the planner avoids occupied IDs, so read the saved plan before using an ID in a command.
4. Keep `vmbr-lab` unnumbered, without uplink or gateway. The three endpoints have static `.10/.20/.30` addresses and no default route. SO alone has a separate management NIC.

## Stages — Proxmox root shell

```bash
cd /root/so-single-nic-3.3
export LC_ALL=C
```

| Stage | Exact command | Acceptance before moving on |
|---|---|---|
| Preflight | `bash lab.sh preflight` | CPU/capacity/network checks pass; read planned four IDs, allocations and storage |
| Dependencies | `bash lab.sh dependencies` | Required tools installed; PVE repository settings retained |
| Media | `bash lab.sh media` | SO/Kali/Ubuntu signatures and image hashes pass; Windows hash passes |
| Network | `bash lab.sh network` | Only isolated lab bridge added; management retained; mirror timer active |
| Create | `bash lab.sh create` | Four stopped owned VMs; save Ubuntu password privately |
| Tools | `bash lab.sh tools` | Intended tools discs attached; Windows disc contains public scripts only |
| Start | `bash lab.sh start SO` | Owned guest starts; complete its installation/readiness checks |
| Disk boot | `bash lab.sh boot-disk SO` | SO boots `scsi0`; run before its installer's reboot |
| Verify | `bash lab.sh verify` | Host layout, ownership and intended mirror rules pass |
| Rollback | `bash lab.sh rollback` | After backup and typed `YES`: owned guests stop, networking removed, disks retained |

`start` accepts `SO`, `WINDOWS`, `UBUNTU`, or `KALI`. `boot-disk` accepts SO/Kali (`scsi0`) or Windows (`sata0`); Ubuntu already boots its imported cloud disk. Use **SO → Windows → Ubuntu → Kali** as the install/recording order. Do not run all start commands before completing a guest's checks.

## Guest checkpoints

- **SO:** official `securityonion-3.3.0-20260911.iso`; Standalone; OS hostname `so-lab`; management NIC on `vmbr0`; monitoring NIC selected by verified MAC, no IP; scoped analyst access. Privately enter OS/SOC credentials. Verify `so-status`, then prove ingestion separately.
- **Windows:** SATA/E1000, OVMF/EFI/TPM; offline setup; local credentials; `10.50.0.20/24`, no gateway/DNS; keep firewall enabled and use the scoped ping rule from the guide. Never move it to management to satisfy setup.
- **Ubuntu:** verified cloud-image import; private `labadmin` password from `create`; use VGA if serial display shows no guest output; verify cloud-init, `.30/24`, no default route, and demo service.
- **Kali:** full offline installer; non-reserved username; guided disk only after checking its identity; keep Xfce/top10/default tools. At `default=1 2 5 6 7`, press Enter. Verify `.10/24` and no default route using the supplied NetworkManager setup.

## Proof and safety

`verify` cannot certify the ingestion pipeline. Follow [nine-layer validation](../SECURITY-ONION-PURPLE-LAB-GUIDE.md#11-nine-layer-end-to-end-validation) for counters, both-direction capture, engine metadata, indexed alert, Hunt and PCAP. Capture only the authorized lab pair and redact identities/credentials.

Both guard and mirror helpers accept only the three planned endpoint TAPs and SO capture TAP. Unexpected bridge members or a host IPv4 lab address stop guard setup before firewall changes. This kit has no lab egress/NAT stage. Existing-host upgrades do not uninstall old files: preserve private backups and restore the intended offline layout before copying a reviewed revision. `install_same` refuses silently overwriting different installed configuration.
