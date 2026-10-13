#!/usr/bin/env bash
# Run with sudo inside Kali. Targets are deliberately fixed to these two lab VMs.
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo 'Use sudo for the SYN scan.' >&2; exit 1; }
ip -4 -o addr show | grep -Fq ' 10.50.0.10/24 ' || { echo 'Configure Kali first.' >&2; exit 1; }
[[ -z $(ip -4 route show default) ]] || { echo 'Remove the default route; lab testing requires the isolated bridge.' >&2; exit 1; }
date -u
curl --noproxy '*' --fail --max-time 10 http://10.50.0.30:8080/
nmap -sS -sV --version-light -Pn -p 1-1024,8080 --max-rate 100 --max-retries 1 10.50.0.20 10.50.0.30
echo 'Command-injection exercise: expected output contains uid=65534(nobody).'
curl --noproxy '*' --fail --max-time 10 'http://10.50.0.30:8080/run?cmd=id'
echo 'Record this UTC time and search SOC Alerts/Hunt for source.ip:10.50.0.10.'
