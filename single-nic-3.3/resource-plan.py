#!/usr/bin/env python3
"""Validate resource settings and budget full logical disks on local PVE storage.

All Proxmox operations in this helper are read-only. lab.sh creates the VMs.
"""
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import uuid

MIB = 1024**2
GIB = 1024**3
ROLES = ('SO', 'KALI', 'WINDOWS', 'UBUNTU')
# Proxmox parse_storage_id: letter first, alphanumeric last, at least two chars.
STORAGE_ID = re.compile(r'[A-Za-z][A-Za-z0-9_.-]*[A-Za-z0-9]')
# Four-VM defaults; budget the host reserve and any existing host workloads too.
DEFAULTS = {
    'HOST_RESERVE_MB': 8192,
    'SO_MEMORY_MB': 32768, 'SO_CORES': 6, 'SO_DISK_GB': 800,
    'KALI_MEMORY_MB': 6144, 'KALI_CORES': 4, 'KALI_DISK_GB': 80,
    'WINDOWS_MEMORY_MB': 8192, 'WINDOWS_CORES': 4, 'WINDOWS_DISK_GB': 100,
    'UBUNTU_MEMORY_MB': 4096, 'UBUNTU_CORES': 2, 'UBUNTU_DISK_GB': 60,
    'SO_DISK_AUTO_SHRINK': 1, 'VM_STORAGE': '', 'FILE_STORAGE': '',
    **{role+'_STORAGE': '' for role in ROLES},
}
# Plans created before resource metadata do not record individual allocations.
# Keep this historical compatibility definition separate; never infer a resize.
LEGACY_ALLOCATIONS = {
    'SO_MEMORY_MB': 32768, 'SO_CORES': 6, 'SO_DISK_GB': 800,
    'KALI_MEMORY_MB': 6144, 'KALI_CORES': 4, 'KALI_DISK_GB': 80,
    'WINDOWS_MEMORY_MB': 8192, 'WINDOWS_CORES': 4, 'WINDOWS_DISK_GB': 100,
    'UBUNTU_MEMORY_MB': 4096, 'UBUNTU_CORES': 2, 'UBUNTU_DISK_GB': 60,
}
# Conservative kit floors, not sizing recommendations for every workload.
MINIMUMS = {
    'SO': (24576, 4, 300), 'KALI': (2048, 1, 20),
    'WINDOWS': (4096, 2, 64), 'UBUNTU': (1024, 1, 8),
}
# Reserve room for Windows EFI/TPM volumes and Ubuntu's cloud-init volume.
AUXILIARY_GB = {'SO': 0, 'KALI': 0, 'WINDOWS': 2, 'UBUNTU': 1}


class ResourceError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ResourceError(message)


def configuration(env):
    values = {}
    for key, default in DEFAULTS.items():
        raw = str(env.get(key, default))
        if isinstance(default, int):
            require(re.fullmatch(r'0|[1-9][0-9]*', raw) is not None,
                    f'{key} must be a whole number, not {raw!r}')
            value = int(raw)
            require(value <= 2147483647, f'{key} is too large')
        else:
            require(not raw or STORAGE_ID.fullmatch(raw) is not None,
                    f'{key} must be a Proxmox storage ID, not a path or volume ID')
            value = raw
        values[key] = value
    require(values['HOST_RESERVE_MB'] >= 1024, 'HOST_RESERVE_MB must be at least 1024 MiB')
    require(values['SO_DISK_AUTO_SHRINK'] in (0, 1), 'SO_DISK_AUTO_SHRINK must be 0 or 1')
    for role, floors in MINIMUMS.items():
        for suffix, minimum in zip(('MEMORY_MB', 'CORES', 'DISK_GB'), floors):
            require(values[role+'_'+suffix] >= minimum,
                    f'{role}_{suffix} must be at least {minimum} for this kit')
    return values


def fingerprint(config):
    return hashlib.sha256(json.dumps(config, sort_keys=True).encode()).hexdigest()


def read_plan(path):
    """Read assignments without executing shell code."""
    result = {}
    for line in Path(path).read_text().splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        key, separator, encoded = line.partition('=')
        require(separator and re.fullmatch(r'[A-Z][A-Z0-9_]*', key) is not None,
                'Malformed saved plan; inspect it before proceeding')
        tokens = shlex.split(encoded)
        require(len(tokens) == 1 and key not in result, 'Malformed or duplicate saved plan assignment')
        result[key] = tokens[0]
    return result


def resolve_plan(config, plan):
    """Freeze allocations; accept an original plan only with its original sizing."""
    result = dict(plan)
    if 'RESOURCE_SCHEMA' in plan:
        require(str(plan['RESOURCE_SCHEMA']) == '1', 'Unsupported resource plan version')
        require(plan.get('RESOURCE_CONFIG_SHA256') == fingerprint(config),
                'Resource settings differ from the saved plan. Restore lab.env to its planned '
                'settings; use Proxmox for existing VM changes or the backed-up fresh-rebuild procedure. '
                'Do not delete the plan to bypass this check.')
    else:
        for role in ROLES:
            for suffix in ('MEMORY_MB', 'CORES', 'DISK_GB'):
                key = role+'_'+suffix
                if key != 'SO_DISK_GB':
                    require(config[key] == LEGACY_ALLOCATIONS[key],
                            'Legacy plan uses the original VM allocations; restore those settings '
                            'or use the backed-up fresh-rebuild procedure for custom resources')
            store = config[role+'_STORAGE'] or config['VM_STORAGE'] or plan['VM_STORE']
            require(store == plan['VM_STORE'], 'Legacy plan cannot change VM storage')
            result[role+'_MEMORY_MB'] = config[role+'_MEMORY_MB']
            result[role+'_CORES'] = config[role+'_CORES']
            result[role+'_GB'] = plan['SO_GB'] if role == 'SO' else config[role+'_DISK_GB']
            result[role+'_STORE'] = plan['VM_STORE']
            result[role+'_RESERVE_GB'] = plan['STORAGE_RESERVE_GB']
        require(config['SO_DISK_GB'] >= int(plan['SO_GB']), 'Legacy plan retains its original SO disk size')
        require(config['SO_DISK_AUTO_SHRINK'] or config['SO_DISK_GB'] == int(plan['SO_GB']),
                'Legacy plan retains a reduced SO disk; restore SO_DISK_AUTO_SHRINK=1')
        require(not config['FILE_STORAGE'] or config['FILE_STORAGE'] == plan['FILE_STORE'],
                'Legacy plan cannot change media storage')
        result['HOST_RESERVE_MB'] = config['HOST_RESERVE_MB']
    for role in ROLES:
        for suffix in ('MEMORY_MB', 'CORES', 'GB', 'RESERVE_GB', 'ID'):
            key = role+'_'+suffix
            require(key in result and str(result[key]).isdigit(), f'Saved plan is missing a valid {key}')
            result[key] = int(result[key])
        for suffix, minimum in zip(('MEMORY_MB', 'CORES', 'GB'), MINIMUMS[role]):
            require(result[role+'_'+suffix] >= minimum, f'Saved {role}_{suffix} is too small')
        require(100 <= result[role+'_ID'] <= 999999999, f'Saved {role} VM ID is invalid')
        if 'RESOURCE_SCHEMA' in plan:
            require(result[role+'_MEMORY_MB'] == config[role+'_MEMORY_MB']
                    and result[role+'_CORES'] == config[role+'_CORES'],
                    f'Saved {role} allocations differ from resource settings')
            if role == 'SO' and config['SO_DISK_AUTO_SHRINK']:
                require(result['SO_GB'] <= config['SO_DISK_GB'], 'Saved SO disk exceeds its requested size')
            else:
                require(result[role+'_GB'] == config[role+'_DISK_GB'],
                        f'Saved {role} disk differs from resource settings')
        store = result.get(role+'_STORE', '')
        require(STORAGE_ID.fullmatch(store) is not None,
                f'Saved {role} storage ID is invalid')
    require(len({result[role+'_ID'] for role in ROLES}) == len(ROLES), 'Saved VM IDs are not distinct')
    return result


def eligible_storages(storages, storage_config):
    cfg = {s['storage']: s for s in storage_config}
    active = [s for s in storages if s.get('active') and s.get('enabled', 1)
              and s['storage'] in cfg and not cfg[s['storage']].get('shared', 0)]
    images = {s['storage']: s for s in active
              if 'images' in s.get('content', '').split(',')
              and s.get('type') in ('lvmthin', 'zfspool', 'dir')}
    files = {s['storage']: s for s in active
             if s.get('type') == 'dir' and 'iso' in s.get('content', '').split(',')}
    return cfg, images, files


def safe_available(storage, committed):
    return min(int(storage.get('avail', 0)), int(storage['total']) - int(committed))


def storage_reserve(storage):
    return max(100, int(storage['total']) // GIB // 10)


def reject_aliases(selected, cfg):
    """Do not count two IDs for an identical configured backing store twice."""
    backends = {}
    for name in selected:
        store = cfg[name]
        fields = {'dir': ('path',), 'lvmthin': ('vgname', 'thinpool'), 'zfspool': ('pool',)}[store['type']]
        if not all(store.get(key) for key in fields):
            continue
        backend = (store['type'], *(store[key] for key in fields))
        require(backend not in backends,
                f'{name} and {backends.get(backend)} refer to the same backing storage; use one ID')
        backends[backend] = name


def build_plan(config, *, vms, storages, storage_config, committed, routes,
               memory_mb, first_vmid, lab_cidr, so_build, node, pve_version, threads):
    lab = ipaddress.ip_network(lab_cidr)
    for route in routes:
        destination = route.get('dst', 'default')
        if destination != 'default':
            require(not lab.overlaps(ipaddress.ip_network(destination, strict=False)),
                    f'route overlap: {destination}')
    other_mb = sum(int(vm.get('maxmem', 0)) for vm in vms if not vm.get('template')) / MIB
    total_mb = sum(config[role+'_MEMORY_MB'] for role in ROLES)
    require(memory_mb >= total_mb + config['HOST_RESERVE_MB'] + other_mb,
            f'insufficient RAM: guests need {total_mb} MiB + host reserve '
            f'{config["HOST_RESERVE_MB"]} MiB + existing guests {other_mb:g} MiB')
    for role in ROLES:
        require(config[role+'_CORES'] <= threads,
                f'{role}_CORES exceeds the host\'s {threads} logical CPUs')
    cfg, images, files = eligible_storages(storages, storage_config)
    require(images and files, 'need local images storage and a directory ISO storage')
    if config['VM_STORAGE']:
        require(config['VM_STORAGE'] in images, 'VM_STORAGE is not active local images storage')
        default_store = config['VM_STORAGE']
    else:
        default_store = max(images, key=lambda name: safe_available(images[name], committed.get(name, 0)))
    if config['FILE_STORAGE']:
        require(config['FILE_STORAGE'] in files, 'FILE_STORAGE is not active local directory ISO storage')
        file_store = config['FILE_STORAGE']
    else:
        file_store = max(files, key=lambda name: int(files[name].get('avail', 0)))
    require(int(files[file_store]['avail']) >= 40*GIB, 'ISO storage needs 40 GiB free for media/staging')
    stores = {role: config[role+'_STORAGE'] or default_store for role in ROLES}
    for role, store in stores.items():
        require(store in images, f'{role}_STORAGE={store} is not active local images storage')
    reject_aliases(set(stores.values()) | {file_store}, cfg)
    sizes = {role: config[role+'_DISK_GB'] for role in ROLES}
    reserves = {store: storage_reserve(images[store]) for store in set(stores.values())}
    for store, reserve in reserves.items():
        assigned = [role for role in ROLES if stores[role] == store]
        # 1 GiB allocation margin per selected VM store, plus actual auxiliary volumes.
        room = safe_available(images[store], committed.get(store, 0)) // GIB - reserve - 1
        room -= sum(AUXILIARY_GB[role] for role in assigned)
        if store == file_store:
            room -= 40
        fixed = sum(sizes[role] for role in assigned if role != 'SO')
        if 'SO' in assigned and config['SO_DISK_AUTO_SHRINK']:
            sizes['SO'] = min(sizes['SO'], room-fixed)
        require(sizes['SO'] >= MINIMUMS['SO'][2],
                f'cannot fit minimum 300 GiB SO disk on {stores["SO"]} with configured guests and reserves')
        required = sum(sizes[role] for role in assigned)
        require(required <= room,
                f'cannot fit {required} GiB of configured VM disks on {store}; '
                f'{max(room, 0)} GiB available after reserves')
    start = int(first_vmid)
    require(100 <= start <= 999999996, 'FIRST_VMID must be between 100 and 999999996')
    used = {int(vm['vmid']) for vm in vms}
    while start <= 999999996 and any(start+i in used for i in range(4)):
        start += 1
    require(start <= 999999996, 'no VM IDs available')
    plan = {'PLANNED_SO_BUILD': so_build, 'OWNER': str(uuid.uuid4()), 'NODE': node,
            'VM_STORE': default_store, 'FILE_STORE': file_store, 'FILE_PATH': cfg[file_store]['path'],
            'SO_GB': sizes['SO'], 'STORAGE_RESERVE_GB': reserves.get(default_store, storage_reserve(images[default_store])),
            'PVE_VERSION': pve_version, 'RESOURCE_SCHEMA': 1,
            'RESOURCE_CONFIG_SHA256': fingerprint(config), 'HOST_RESERVE_MB': config['HOST_RESERVE_MB'],
            'LAB_MEMORY_MB': total_mb}
    for index, role in enumerate(ROLES):
        plan.update({role+'_ID': start+index, role+'_MEMORY_MB': config[role+'_MEMORY_MB'],
                     role+'_CORES': config[role+'_CORES'], role+'_GB': sizes[role],
                     role+'_STORE': stores[role], role+'_RESERVE_GB': reserves[stores[role]]})
    return plan


def check_capacity(plan, *, vms, storages, storage_config, committed, memory_mb, threads):
    by_id = {int(vm['vmid']): vm for vm in vms}
    ids = {int(plan[role+'_ID']) for role in ROLES}
    other = sum(int(vm.get('maxmem', 0)) for vm in vms
                if int(vm['vmid']) not in ids and not vm.get('template'))
    # Honor larger manual PVE allocations too; smaller ones retain planned headroom.
    guests = sum(max(int(plan[role+'_MEMORY_MB'])*MIB,
                     int(by_id.get(int(plan[role+'_ID']), {}).get('maxmem', 0))) for role in ROLES)
    require(memory_mb*MIB >= other + guests + int(plan['HOST_RESERVE_MB'])*MIB,
            'Insufficient RAM headroom for planned/actual guest allocations and host reserve')
    for role in ROLES:
        require(int(plan[role+'_CORES']) <= threads, f'{role} has more planned cores than host logical CPUs')
    cfg, images, _ = eligible_storages(storages, storage_config)
    selected = {plan[role+'_STORE'] for role in ROLES}
    for store in selected:
        require(store in images, f'Planned storage {store} is no longer active local images storage')
    reject_aliases(selected, cfg)
    for store in selected:
        assigned = [role for role in ROLES if plan[role+'_STORE'] == store]
        missing = [role for role in assigned if int(plan[role+'_ID']) not in by_id]
        remaining = sum(int(plan[role+'_GB']) + AUXILIARY_GB[role] for role in missing) + 1
        reserve = max(storage_reserve(images[store]), *(int(plan[role+'_RESERVE_GB']) for role in assigned))
        if store == plan['FILE_STORE']:
            remaining += 40
        require(safe_available(images[store], committed.get(store, 0)) >= (remaining+reserve)*GIB,
                f'Insufficient physical or logical disk headroom on {store}')


def pve_get(*args):
    return json.loads(subprocess.check_output(['pvesh', 'get', *args, '--output-format', 'json'], text=True))


def host_memory_mb():
    return int(next(line.split()[1] for line in Path('/proc/meminfo').read_text().splitlines()
                    if line.startswith('MemTotal:'))) // 1024


def emit(values):
    for key, value in values.items():
        print(key+'='+shlex.quote(str(value)))


def main():
    config = configuration(os.environ)
    command = sys.argv[1]
    if command == 'validate':
        return
    state = Path(os.environ['STATE'])
    if command == 'plan':
        def read(name): return json.loads((state/name).read_text())
        plan = build_plan(config, vms=read('inventory-vms.json'), storages=read('inventory-storage.json'),
                          storage_config=read('storage-config.json'), committed=read('committed.json'),
                          routes=read('routes.json'), memory_mb=host_memory_mb(),
                          first_vmid=os.environ['FIRST_VMID'], lab_cidr=os.environ['LAB_CIDR'],
                          so_build=os.environ['SO_BUILD'], node=os.uname().nodename.split('.')[0],
                          pve_version=subprocess.check_output(['pveversion'], text=True).strip(),
                          threads=os.cpu_count() or 1)
        emit(plan)
        if plan['SO_GB'] != config['SO_DISK_GB']:
            print(f'SO disk reduced from {config["SO_DISK_GB"]} to {plan["SO_GB"]} GiB to retain reserves.', file=sys.stderr)
        total_cores = sum(config[role+'_CORES'] for role in ROLES)
        if total_cores > (os.cpu_count() or 1):
            print(f'CPU sharing: {total_cores} vCPUs across {os.cpu_count()} host logical CPUs; '
                  'size concurrent workloads accordingly.', file=sys.stderr)
        return
    plan = resolve_plan(config, read_plan(state/'plan.env'))
    if command == 'load':
        base = {'PLANNED_SO_BUILD', 'OWNER', 'NODE', 'VM_STORE', 'FILE_STORE', 'FILE_PATH',
                'SO_GB', 'STORAGE_RESERVE_GB', 'PVE_VERSION', 'RESOURCE_SCHEMA',
                'RESOURCE_CONFIG_SHA256', 'HOST_RESERVE_MB', 'LAB_MEMORY_MB'}
        emit({key: value for key, value in plan.items()
              if key in base or any(key == role+'_'+suffix for role in ROLES
                                    for suffix in ('ID', 'MEMORY_MB', 'CORES', 'GB', 'STORE', 'RESERVE_GB'))})
    elif command == 'capacity':
        node = os.uname().nodename.split('.')[0]
        selected = {plan[role+'_STORE'] for role in ROLES}
        committed = {store: sum(int(volume.get('size', 0)) for volume in
                               pve_get('/nodes/'+node+'/storage/'+store+'/content')
                               if volume.get('content') == 'images') for store in selected}
        check_capacity(plan, vms=pve_get('/cluster/resources', '--type', 'vm'),
                       storages=pve_get('/nodes/'+node+'/storage'), storage_config=pve_get('/storage'),
                       committed=committed, memory_mb=host_memory_mb(), threads=os.cpu_count() or 1)
    else:
        raise ResourceError('Unknown resource helper command')


if __name__ == '__main__':
    try:
        main()
    except (ResourceError, KeyError, OSError, subprocess.CalledProcessError, ValueError) as error:
        raise SystemExit('Resources: '+str(error))
