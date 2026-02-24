#!/usr/bin/env bash
#How to use:
#nano full_clean.sh
#chmod +x full_clean.sh
#sudo ./full_clean.sh

#Как запускать именно “чистку этих папок”
#Сначала безопасно посмотреть эффект:
#sudo ./full_clean.sh
#Применить:
#sudo ./full_clean.sh --apply
#Если прямо хочешь попытаться убрать firmware:
#sudo ./full_clean.sh --apply --purge-firmware

set -Eeuo pipefail

APPLY=0
PURGE_FIRMWARE=0
LOG="/var/log/cleanup_usr_lib_safe.log"

TARGETS=(
  "/usr/lib/x86_64-linux-gnu"
  "/usr/lib/firmware"
  "/lib/modules"
)

if [[ -t 1 ]]; then
  RED=$'\e[31m'; GRN=$'\e[32m'; YLW=$'\e[33m'; BLU=$'\e[34m'; DIM=$'\e[2m'; BLD=$'\e[1m'; RST=$'\e[0m'
else
  RED=""; GRN=""; YLW=""; BLU=""; DIM=""; BLD=""; RST=""
fi

usage() {
  cat <<EOF
Usage: sudo $0 [--apply] [--purge-firmware]

  --apply           реально выполнять (иначе dry-run)
  --purge-firmware  попытаться удалить linux-firmware (ОСТОРОЖНО)

Examples:
  sudo $0
  sudo $0 --apply
  sudo $0 --apply --purge-firmware
EOF
}

need_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    echo "${RED}Нужно запускать от root:${RST} sudo $0 ..."
    exit 1
  fi
}

ensure_log() {
  mkdir -p "$(dirname "$LOG")" || true
  touch "$LOG" 2>/dev/null || true
}
ensure_log
trap 'echo "ERROR line $LINENO: $BASH_COMMAND" | tee -a "$LOG" >&2' ERR

log(){ echo "$*" | tee -a "$LOG"; }

run() {
  local cmd="$1"
  log "${DIM}>> ${cmd}${RST}"
  if [[ $APPLY -eq 1 ]]; then
    bash -c "$cmd" >>"$LOG" 2>&1 || true
  else
    log "${YLW}(dry-run) не выполняю${RST}"
  fi
}

bytes_to_human() {
  local b="${1:-0}"
  awk -v b="$b" 'function human(x){
    s="B KB MB GB TB PB"; split(s,a," ");
    for(i=1; x>=1024 && i<6; i++) x/=1024;
    return sprintf("%.2f %s", x, a[i]);
  } BEGIN{ if(b<0) b=0; print human(b) }'
}

dir_size_bytes() {
  local p="$1"
  [[ -d "$p" ]] || { echo 0; return; }
  du -sb "$p" 2>/dev/null | awk '{print $1}' || echo 0
}

snapshot_sizes() {
  for p in "${TARGETS[@]}"; do
    local sz
    sz="$(dir_size_bytes "$p")"
    echo -e "$p\t$sz"
  done
}

print_snapshot() {
  local title="$1"
  local snap="$2"
  echo "${BLD}${BLU}${title}${RST}"
  echo -e "${BLD}Path\t\t\t\tSize${RST}"
  while IFS=$'\t' read -r p sz; do
    printf "%-32s %s\n" "$p" "$(bytes_to_human "$sz")"
  done <<<"$snap"
  echo
}

# ---- args ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) APPLY=1; shift;;
    --purge-firmware) PURGE_FIRMWARE=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1"; usage; exit 1;;
  esac
done

need_root

echo "${BLD}${BLU}=== Safe cleanup for /usr/lib* and /lib/modules ===${RST}"
echo "Log: $LOG"
echo -n "Mode: "; [[ $APPLY -eq 1 ]] && echo "${GRN}APPLY${RST}" || echo "${YLW}DRY-RUN${RST}"
echo

BEFORE="$(snapshot_sizes)"
print_snapshot "BEFORE" "$BEFORE"

echo "${BLD}${BLU}--- Actions ---${RST}"

# 1) Remove unused packages + old kernels (это чистит /lib/modules в основном)
if command -v apt-get >/dev/null 2>&1; then
  run "apt-get autoremove --purge -y"
  run "apt-get autoclean -y"
  run "apt-get clean -y"
fi

# 2) DKMS cleanup leftovers (аккуратно)
# Удаляем “orphaned” dkms деревья, если модуль не зарегистрирован (супер-консервативно)
if [[ -d /var/lib/dkms ]]; then
  cmd='for d in /var/lib/dkms/*/*; do
          [[ -d "$d" ]] || continue
          mod=$(basename "$(dirname "$d")"); ver=$(basename "$d");
          dkms status -m "$mod" -v "$ver" >/dev/null 2>&1 || { echo "orphan dkms: $mod/$ver"; rm -rf "$d"; }
       done'
  run "$cmd"
fi

# 3) Optional: purge linux-firmware (ОСТОРОЖНО)
if [[ $PURGE_FIRMWARE -eq 1 ]]; then
  if command -v apt-get >/dev/null 2>&1; then
    run "apt-get purge -y linux-firmware"
    run "apt-get autoremove --purge -y"
  fi
else
  echo "${DIM}Пропускаю purge linux-firmware (включи --purge-firmware если точно нужно).${RST}" | tee -a "$LOG"
fi

echo "${BLD}${BLU}--- Done ---${RST}"
echo

AFTER="$(snapshot_sizes)"
print_snapshot "AFTER" "$AFTER"

# Report freed
echo "${BLD}${GRN}=== Report ===${RST}"
total_freed=0
while IFS=$'\t' read -r p bsz; do
  asz="$(echo "$AFTER" | awk -F'\t' -v p="$p" '$1==p{print $2}')"
  freed=$(( bsz - asz ))
  if (( freed > 0 )); then
    echo "  ${BLD}${p}${RST}: freed $(bytes_to_human "$freed")"
    total_freed=$(( total_freed + freed ))
  fi
done <<<"$BEFORE"

echo
echo "${BLD}Total freed:${RST} $(bytes_to_human "$total_freed")"
echo
echo "${DIM}Log: $LOG${RST}"

if [[ $APPLY -eq 0 ]]; then
  echo
  echo "${YLW}${BLD}DRY-RUN:${RST} ничего не удалено. Для применения:"
  echo "  sudo $0 --apply"
fi
