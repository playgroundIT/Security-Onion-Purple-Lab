#!/usr/bin/env bash
set -Eeuo pipefail
source /usr/local/lib/so-single-nic/plan.env
case ${1:-} in "$SO_ID"|"$KALI_ID"|"$WINDOWS_ID"|"$UBUNTU_ID") ;; *) exit 1;; esac
case ${2:-} in
    pre-start) /usr/local/lib/so-single-nic/guard.sh;;
    post-start|post-stop) /usr/local/lib/so-single-nic/mirror.sh;;
    pre-stop) :;;
    *) exit 1;;
esac
