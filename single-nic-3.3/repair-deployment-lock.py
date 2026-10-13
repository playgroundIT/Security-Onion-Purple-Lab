#!/usr/bin/env python3
"""Repair the kit's inherited deployment lock without stopping any guest."""
import fcntl
import os
from pathlib import Path
import re
import shutil
import subprocess
import time


def patch_script(path):
    original = path.read_text()
    anchor = "    flock -n 9 || die 'Another deployment stage is running.'\n"
    unlock = "    trap 'flock -u 9; exec 9>&-' EXIT\n"
    if anchor not in original:
        raise SystemExit('STOP: unrecognized lab.sh lock code; no files changed.')
    updated = original
    if unlock not in updated:
        updated = updated.replace(anchor, anchor + unlock, 1)
    updated = updated.replace('then qm start "$id"; fi', 'then qm start "$id" 9>&-; fi')
    subprocess.run(['bash', '-n'], input=updated, text=True, check=True)
    if updated != original:
        backup = path.with_name(path.name + '.before-lock-fix.' + str(time.time_ns()))
        shutil.copy2(path, backup)
        path.write_text(updated)
        print('PATCH OK; script backup:', backup)
    else:
        print('PATCH OK; already applied.')


def is_lab_qemu(executable, args, ids):
    if Path(executable).name not in ('kvm', 'qemu-system-x86_64'):
        return False
    return any(args[i] == '-id' and args[i + 1] in ids for i in range(len(args) - 1))


def find_holders(inode):
    holders = []
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit() or int(proc.name) == os.getpid():
            continue
        try:
            for descriptor in (proc / 'fd').iterdir():
                try:
                    info = descriptor.stat()
                except FileNotFoundError:
                    continue
                if (info.st_dev, info.st_ino) == inode:
                    args = (proc / 'cmdline').read_bytes().decode(errors='replace').rstrip('\0').split('\0')
                    holders.append((proc.name, os.readlink(proc / 'exe'), args))
                    break
        except FileNotFoundError:
            continue
    return holders


def main():
    if os.geteuid() != 0 or not Path('/etc/pve').is_dir():
        raise SystemExit('Run as root on Proxmox.')
    patch_script(Path(__file__).resolve().with_name('lab.sh'))
    plan = Path('/var/lib/so-single-nic/plan.env').read_text()
    ids = set(re.findall(r'^(?:SO|KALI|WINDOWS|UBUNTU)_ID=(\d+)$', plan, re.M))
    if len(ids) != 4:
        raise SystemExit('STOP: cannot identify all four lab VM IDs.')
    lock = Path('/run/lock/so-single-nic.lock')
    with lock.open('a') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            info = os.fstat(handle.fileno())
            holders = find_holders((info.st_dev, info.st_ino))
            for pid, executable, args in holders:
                print('Holder PID', pid, executable, ' '.join(args)[:240])
            if not holders or not all(is_lab_qemu(exe, args, ids) for _, exe, args in holders):
                raise SystemExit('STOP: holder is not exclusively lab QEMU; leave the lock in place and inspect the output.')
            # All remaining holders are guest processes; preserve their old inode.
            backup = lock.with_name(lock.name + '.inherited.' + str(time.time_ns()))
            lock.rename(backup)
            new = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(new)
            print('Archived inherited lock:', backup)
        else:
            fcntl.flock(handle, fcntl.LOCK_UN)
            print('Existing deployment lock is already free.')
    with lock.open('a') as check:
        fcntl.flock(check, fcntl.LOCK_EX | fcntl.LOCK_NB)
        fcntl.flock(check, fcntl.LOCK_UN)
    print('LOCK OK; no VM was stopped. Retry your lab.sh command.')


if __name__ == '__main__':
    main()
