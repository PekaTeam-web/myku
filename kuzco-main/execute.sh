#!/usr/bin/env bash
set -euo pipefail

PROXY_PORT="${PROXY_PORT:-14000}"
KEEPALIVE="${KEEPALIVE:-0}"

echo "[execute] Validasi environment..."
[ -z "${CODE:-}" ] && echo "[FATAL] CODE belum diisi (set di .env atau compose env)." && exit 1
[ -z "${NOVITA_API_KEY:-}" ] && echo "[FATAL] NOVITA_API_KEY belum diisi." && exit 1

ensure_machine_id() {
  local etc_path="/etc/machine-id"
  local dbus_dir="/var/lib/dbus"
  local dbus_path="${dbus_dir}/machine-id"
  mkdir -p "${dbus_dir}"

  local current=""
  if [ -s "${etc_path}" ] && grep -Eq '^[0-9a-f]{32}$' "${etc_path}"; then
    current="$(cat "${etc_path}")"
  elif [ -s "${dbus_path}" ] && grep -Eq '^[0-9a-f]{32}$' "${dbus_path}"; then
    current="$(cat "${dbus_path}")"
  fi
  if [ -z "${current}" ]; then
    current="$(cat /proc/sys/kernel/random/uuid | tr -d '-' | tr 'A-F' 'a-f' | cut -c1-32)"
    echo "[execute] Membuat machine-id baru: ${current}"
  else
    echo "[execute] Menemukan machine-id eksisting."
  fi
  printf "%s" "${current}" > "${dbus_path}"
  chmod 0644 "${dbus_path}"
  if [ -L "${etc_path}" ]; then
    local target
    target="$(readlink -f "${etc_path}" || true)"
    if [ -n "${target}" ]; then
      printf "%s" "${current}" > "${target}"
      chmod 0644 "${target}"
    else
      rm -f "${etc_path}"
      printf "%s" "${current}" > "${etc_path}"
      chmod 0644 "${etc_path}"
    fi
  else
    printf "%s" "${current}" > "${etc_path}"
    chmod 0644 "${etc_path}"
  fi
  echo "[execute] machine-id siap."
}

install_redirect() {
  local dst=14444
  if command -v iptables >/dev/null 2>&1; then
    if ! iptables -t nat -C OUTPUT -p tcp --dport ${dst} -j REDIRECT --to-ports ${PROXY_PORT} 2>/dev/null; then
      iptables -t nat -A OUTPUT -p tcp --dport ${dst} -j REDIRECT --to-ports ${PROXY_PORT} || echo "[warn] iptables REDIRECT gagal (butuh CAP_NET_ADMIN)"
    fi
    echo "[execute] NAT rules (OUTPUT nat) yang match 14444:"
    iptables -t nat -S OUTPUT | grep 14444 || echo "[execute] (tidak terdeteksi rule 14444 di OUTPUT nat)"
  else
    echo "[warn] iptables tidak ada, lewati redirect 14444 -> ${PROXY_PORT}"
  fi
  # IPv6 best-effort
  if command -v ip6tables >/dev/null 2>&1; then
    if ! ip6tables -t nat -C OUTPUT -p tcp --dport ${dst} -j REDIRECT --to-ports ${PROXY_PORT} 2>/dev/null; then
      ip6tables -t nat -A OUTPUT -p tcp --dport ${dst} -j REDIRECT --to-ports ${PROXY_PORT} || true
    fi
  fi
  echo "[execute] NAT redirect 14444 -> ${PROXY_PORT} diset (jika diizinkan)."
}

# 1) machine-id
ensure_machine_id

# 2) spoof nvidia-smi jika perlu
if ! command -v nvidia-smi >/dev/null 2>&1; then
  echo "[execute] nvidia-smi tidak ditemukan, memasang spoof..."
  /app/gpu-spoof.sh install
else
  echo "[execute] nvidia-smi sudah ada, lewati spoof."
fi

# 3) start proxy (log ke file + stdout)
echo "[execute] Menjalankan Novita proxy di port ${PROXY_PORT}..."
node /app/novita-proxy/server.js 2>&1 | tee -a /app/novita-proxy.log &
sleep 0.5

# 4) tunggu proxy listen
for i in {1..40}; do
  if ss -ltn | grep -q ":${PROXY_PORT}"; then
    echo "[execute] Proxy listening on ${PROXY_PORT}"
    break
  fi
  sleep 0.25
done
if ! ss -ltn | grep -q ":${PROXY_PORT}"; then
  echo "[FATAL] Proxy belum listen setelah timeout."
  exit 1
fi

# 5) NAT redirect
install_redirect

# 6) tes cepat NAT: kalau NAT OK, panggilan ke 127.0.0.1:14444/healthz harus dibalas proxy (bukan Ollama)
echo "[execute] Cek NAT test http://127.0.0.1:14444/healthz ..."
set +e
NAT_TEST="$(curl -s -m 1 http://127.0.0.1:14444/healthz)"
set -e
if echo "$NAT_TEST" | grep -q '"ok":true'; then
  echo "[execute] NAT OK (healthz via 14444 dibalas proxy)"
else
  echo "[warn] NAT mungkin belum aktif (healthz via 14444 tidak dibalas proxy)"
fi

run_inference() {
  echo "[execute] Menjalankan Inference CLI (Kuzco worker)..."
  inference node start --code "${CODE}"
  return $?
}

if [ "$KEEPALIVE" = "1" ]; then
  # Loop agar container tetap hidup meski CLI exit saat kita debug
  while true; do
    run_inference
    rc=$?
    echo "[execute] Inference CLI exit code: $rc"
    echo "[execute] Tidur 5s lalu coba start ulang (KEEPALIVE=1) ..."
    sleep 5
  done
else
  exec inference node start --code "${CODE}"
fi