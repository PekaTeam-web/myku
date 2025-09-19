#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   /app/gpu-spoof.sh install
#   /app/gpu-spoof.sh test     # optional quick test
#
# ENV (opsional, hanya untuk debug/override):
#   GPU_SPOOF_UUID           - paksa UUID (format GPU-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)
#   GPU_SPOOF_PCI_BUS_ID     - paksa PCI bus id (format 00000000:BB:DD.F)
#   GPU_SPOOF_NAME           - default "GeForce RTX 4090"
#   GPU_SPOOF_DRIVER         - default "535.00"
#   GPU_SPOOF_MEMORY_TOTAL   - default "24576" (MiB, tanpa satuan)
#   GPU_SPOOF_STATE_DIR      - default "/var/run/gpu-spoof" (ephemeral per container run)

BIN="/usr/local/bin/nvidia-smi"

install_spoof() {
  cat > "${BIN}" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

# Minimal NVIDIA-SMI spoof to satisfy:
# nvidia-smi --query-gpu=uuid,driver_version,name,memory.total,pci.bus_id --format=csv,noheader,nounits

# Config with env overrides
STATE_DIR="${GPU_SPOOF_STATE_DIR:-/var/run/gpu-spoof}"
UUID_OVERRIDE="${GPU_SPOOF_UUID:-}"
PCI_OVERRIDE="${GPU_SPOOF_PCI_BUS_ID:-}"
NAME="${GPU_SPOOF_NAME:-GeForce RTX 4090}"
DRIVER="${GPU_SPOOF_DRIVER:-535.00}"
MEMORY_TOTAL="${GPU_SPOOF_MEMORY_TOTAL:-24576}"   # MiB, no units

mkdir -p "${STATE_DIR}"

UUID_FILE="${STATE_DIR}/uuid"
PCI_FILE="${STATE_DIR}/pcibus"

# Generate random GPU-like UUID (prefix GPU- + UUID v4 uppercase)
gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    printf "GPU-%s\n" "$(uuidgen | tr 'a-f' 'A-F')"
  elif [ -r /proc/sys/kernel/random/uuid ]; then
    printf "GPU-%s\n" "$(cat /proc/sys/kernel/random/uuid | tr 'a-f' 'A-F')"
  else
    # Fallback: 32 hex from urandom
    HEX="$(tr -dc 'A-F0-9' </dev/urandom | head -c32)"
    printf "GPU-%s-%s-%s-%s-%s\n" "${HEX:0:8}" "${HEX:8:4}" "${HEX:12:4}" "${HEX:16:4}" "${HEX:20:12}"
  fi
}

# Generate pseudo PCI bus id like 00000000:BB:DD.F (lowercase hex, zero-padded)
gen_pcibus() {
  ENTROPY="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || date +%s%N || echo $$)"
  SUM="$(printf "%s" "${ENTROPY}" | cksum | awk '{print $1}')"
  BUS=$(printf "%02x" $(( (SUM      ) % 256 )))
  DEV=$(printf "%02x" $(( (SUM / 7  ) % 32  )))
  FUN=$(( (SUM / 11) % 8 ))
  printf "00000000:%s:%s.%d\n" "${BUS}" "${DEV}" "${FUN}"
}

# Load or create state (unique-per-run)
if [ -n "${UUID_OVERRIDE}" ]; then
  UUID="${UUID_OVERRIDE}"
else
  if [ -s "${UUID_FILE}" ]; then
    UUID="$(cat "${UUID_FILE}")"
  else
    UUID="$(gen_uuid)"
    printf "%s" "${UUID}" > "${UUID_FILE}"
    chmod 0644 "${UUID_FILE}"
  fi
fi

if [ -n "${PCI_OVERRIDE}" ]; then
  PCI_BUS_ID="${PCI_OVERRIDE}"
else
  if [ -s "${PCI_FILE}" ]; then
    PCI_BUS_ID="$(cat "${PCI_FILE}")"
  else
    PCI_BUS_ID="$(gen_pcibus)"
    printf "%s" "${PCI_BUS_ID}" > "${PCI_FILE}"
    chmod 0644 "${PCI_FILE}"
  fi
fi

query=""
format=""

# Collect args (very minimal parser for the common flags the CLI uses)
while [ ${#} -gt 0 ]; do
  case "$1" in
    --query-gpu=*) query="${1#*=}" ;;
    --format=*)    format="${1#*=}" ;;
    *) ;; # ignore other args
  esac
  shift || true
done

if [ -n "${query}" ]; then
  IFS=',' read -ra KEYS <<< "${query}"
  out=()
  for key in "${KEYS[@]}"; do
    k="$(echo "${key}" | xargs)"
    case "${k}" in
      uuid)           out+=("${UUID}") ;;
      driver_version) out+=("${DRIVER}") ;;
      name)           out+=("${NAME}") ;;
      memory.total)   out+=("${MEMORY_TOTAL}") ;;
      pci.bus_id)     out+=("${PCI_BUS_ID}") ;;
      *)              out+=("") ;;
    esac
  done
  (IFS=','; echo "${out[*]}")
  exit 0
fi

# Fallback pretty output when no query passed
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
