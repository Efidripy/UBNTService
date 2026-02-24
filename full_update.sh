#!/bin/bash
#How to use:
#nano full_update.sh
#chmod +x full_update.sh
#sudo ./full_update.sh


set -euo pipefail

log() { echo -e "\n=== $* ==="; }

# root check
if [[ "${EUID}" -ne 0 ]]; then
  echo "Запусти от root: sudo $0"
  exit 1
fi

START_FREE_KB=$(df --output=avail / | tail -1 | tr -d ' ')
START_FREE_H=$(df -h / | tail -1 | awk '{print $4}')

echo "======================================"
echo "  FULL UBUNTU VPS UPDATE + CLEANUP"
echo "======================================"
echo "Free space before: ${START_FREE_H}"

log "APT: update"
apt-get update -y

log "APT: upgrade"
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

log "APT: full-upgrade"
DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y

log "APT: autoremove + autoclean + clean"
apt-get autoremove -y --purge
apt-get autoclean -y
apt-get clean

log "APT: purge old config leftovers (rc)"
# remove packages in 'rc' state (configs left behind)
dpkg -l | awk '/^rc/ {print $2}' | xargs -r dpkg -P

log "APT: remove cached lists (will be re-downloaded on next apt update)"
rm -rf /var/lib/apt/lists/*
mkdir -p /var/lib/apt/lists/partial

log "SNAP: refresh + remove old revisions (if snap exists)"
if command -v snap >/dev/null 2>&1; then
  snap refresh || true

  # remove disabled old revisions
  # (officially common cleanup snippet)
  snap list --all 2>/dev/null | awk '/disabled/{print $1, $3}' | while read -r snapname revision; do
    snap remove "$snapname" --revision="$revision" || true
  done
fi

log "Firmware: skip on virtualized VPS, otherwise try (optional)"
if command -v systemd-detect-virt >/dev/null 2>&1; then
  if systemd-detect-virt -q; then
    echo "Virtual environment detected -> fwupd skipped."
  else
    if command -v fwupdmgr >/dev/null 2>&1; then
      fwupdmgr refresh || true
      fwupdmgr update -y || true
    fi
  fi
fi

log "Logs: systemd journal vacuum"
# keep last 7 days OR cap size to 200MB (both are fine; we do size-based)
if command -v journalctl >/dev/null 2>&1; then
  journalctl --vacuum-size=200M || true
fi

log "Temp: cleanup /tmp and /var/tmp"
# delete files older than 2 days to avoid killing active temp files
find /tmp -mindepth 1 -mtime +2 -exec rm -rf {} + 2>/dev/null || true
find /var/tmp -mindepth 1 -mtime +2 -exec rm -rf {} + 2>/dev/null || true

log "Caches: user caches (safe-ish) — only thumbnails + generic cache"
# This is conservative: only ~/.cache contents, doesn't touch browser profiles explicitly.
for d in /home/*; do
  if [[ -d "$d/.cache" ]]; then
    rm -rf "$d/.cache/"* 2>/dev/null || true
  fi
done

log "Optional: truncate rotated logs (if any huge .gz remain) — light cleanup"
# Do NOT delete all logs; just remove very old compressed rotated logs (>14 days)
find /var/log -type f \( -name "*.gz" -o -name "*.1" -o -name "*.old" \) -mtime +14 -delete 2>/dev/null || true

END_FREE_KB=$(df --output=avail / | tail -1 | tr -d ' ')
END_FREE_H=$(df -h / | tail -1 | awk '{print $4}')

FREED_KB=$((END_FREE_KB - START_FREE_KB))
FREED_MB=$((FREED_KB / 1024))

echo "======================================"
echo "DONE."
echo "Free space after : ${END_FREE_H}"
echo "Freed approx     : ${FREED_MB} MB"
echo "======================================"

if [[ -f /var/run/reboot-required ]]; then
  echo "⚠️ Требуется перезагрузка: $(cat /var/run/reboot-required)"
else
  echo "✅ Перезагрузка не требуется."
fi

log "Failed systemd units (if any)"
systemctl --failed --no-pager || true
