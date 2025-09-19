#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   /app/gpu-spoof.sh install
#   /app/gpu-spoof.sh test     # optional quick test

BIN="/usr/local/bin/nvidia-smi"

install_spoof() {
  cat > "${BIN}" <<'EOS'
#!/usr/bin/env bash
set -e

# Minimal NVIDIA-SMI spoof to satisfy:
# nvidia-smi --query-gpu=uuid,driver_version,name,memory.total,pci.bus_id --format=csv,noheader,nounits

query=""
format=""

# Collect args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --query-gpu=*) query="${1#*=}"; shift ;;
    --format=*)    format="${1#*=}"; shift ;;
    *) shift ;;
  esac
done

# Default fake data
UUID="GPU-aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
DRIVER="535.00"
NAME="GeForce RTX 4090"
MEMORY_TOTAL="24576"              # in MiB (no units because of 'nounits')
PCI_BUS_ID="00000000:01:00.0"

if [[ -n "$query" ]]; then
  # Produce fields in given order, comma-separated, no header
  IFS=',' read -ra KEYS <<< "$query"
  out=()
  for key in "${KEYS[@]}"; do
    k="$(echo "$key" | xargs)"  # trim spaces
    case "$k" in
      uuid)           out+=("$UUID") ;;
      driver_version) out+=("$DRIVER") ;;
      name)           out+=("$NAME") ;;
      memory.total)   out+=("$MEMORY_TOTAL") ;;
      pci.bus_id)     out+=("$PCI_BUS_ID") ;;
      *)              out+=("") ;;
    esac
  done
  (IFS=','; echo "${out[*]}")
  exit 0
fi

# Fallback pretty output when no query passed (not really used by CLI)
cat <<TXT
Thu Sep 18 12:00:00 2025
+-----------------------------------------------------------------------------+
| NVIDIA-SMI ${DRIVER}       Driver Version: ${DRIVER}       CUDA Version: 12.2     |
|-------------------------------+----------------------+----------------------+
| GPU  Name        Persistence-M| Bus-Id        Disp.A | Volatile Uncorr. ECC|
|  0  ${NAME}     Off  | ${PCI_BUS_ID} Off |                  N/A |
+-------------------------------+----------------------+----------------------+
| Processes:  GPU   GI   CI        PID   Type   Process name         GPU Memory |
|    0     0    0      9999      C   fake-process                       1024MiB |
+-----------------------------------------------------------------------------+
TXT
EOS

  chmod +x "${BIN}"
  echo "[gpu-spoof] Installed ${BIN}"
}

test_spoof() {
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    echo "[gpu-spoof] nvidia-smi not found"
    exit 1
  fi
  echo "[gpu-spoof] which nvidia-smi -> $(which nvidia-smi)"
  echo "[gpu-spoof] query test:"
  nvidia-smi --query-gpu=uuid,driver_version,name,memory.total,pci.bus_id --format=csv,noheader,nounits || true
}

case "${1:-}" in
  install) install_spoof ;;
  test)    test_spoof ;;
  *) echo "Usage: $0 {install|test}"; exit 0 ;;
esac
