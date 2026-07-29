#!/usr/bin/env bash
#
# Add a swapfile. RUN ON hetzner.
#
#   ./setup-swap.sh [size]        default 2G
#
# WHY, given the box shows no memory pressure today (2026-07-29: zero OOM
# events in a year of persistent journal, PSI flat at 0.00):
#
#   This is insurance, not a remedy. Two specific facts justify it here:
#
#   1. systemd-oomd is NOT installed on this host. Ubuntu 22.04+ normally
#      ships it as a userspace OOM handler that acts early and kills the
#      process actually responsible. Without it and without swap there is no
#      graceful degradation at all -- memory pressure goes straight to the
#      kernel OOM killer.
#   2. The kernel OOM killer targets large RSS, which here is mysqld. Losing
#      mysqld takes down every site at once, not just whichever one spiked.
#
#   With 3.7 GiB total and the site count about to roughly triple, the cost
#   (2 GB of a 45 GB free disk) is trivial against that failure mode.
#
# swappiness is set to 10, not the default 60: this exists so the kernel has
# somewhere to put cold anonymous pages under pressure, NOT so it swaps during
# normal operation. Low swappiness keeps it as a valve.
#
# To undo:
#   sudo swapoff /swapfile && sudo rm /swapfile
#   then remove the /etc/fstab line and /etc/sysctl.d/99-swappiness.conf

set -euo pipefail

SIZE="${1:-2G}"
SWAPFILE=/swapfile

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

if swapon --show --noheadings 2>/dev/null | grep -q .; then
  log "swap already active:"
  swapon --show
  log "nothing to do"
  exit 0
fi

log "creating ${SIZE} swapfile at ${SWAPFILE}"

# fallocate can produce a sparse/extent file that mkswap rejects on some
# filesystems; dd is slower but always yields something swapon accepts.
if ! sudo fallocate -l "${SIZE}" "${SWAPFILE}" 2>/dev/null; then
  log "fallocate unavailable, falling back to dd"
  sudo dd if=/dev/zero of="${SWAPFILE}" bs=1M \
    count="$(numfmt --from=iec "${SIZE}" | awk '{print int($1/1048576)}')" status=none
fi

sudo chmod 600 "${SWAPFILE}"
sudo mkswap "${SWAPFILE}" >/dev/null
sudo swapon "${SWAPFILE}"

log "making persistent across reboots"
if ! grep -q "^${SWAPFILE} " /etc/fstab; then
  sudo cp /etc/fstab "/etc/fstab.bak-$(date +%F-%H%M%S)"
  echo "${SWAPFILE} none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
fi

log "setting vm.swappiness=10"
printf 'vm.swappiness=10\n' | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
sudo sysctl -q -w vm.swappiness=10

log "done"
echo
swapon --show
echo
free -h
