#!/usr/bin/env bash
set -euo pipefail

say() { printf "%s\n" "$*" ; }
hr()  { printf "\n==== %s ====\n" "$*" ; }
have() { command -v "$1" >/dev/null 2>&1; }

# Installer ringan (best-effort)
install_if_missing() {
  local pkg="$1" ; local try=""
  if have "$pkg"; then return 0; fi
  if have apk; then try="apk add --no-cache $pkg" ; fi
  if have apt-get; then try="apt-get update >/dev/null 2>&1 && apt-get install -y $pkg" ; fi
  if have dnf; then try="dnf install -y $pkg" ; fi
  if have yum; then try="yum install -y $pkg" ; fi
  if [ -n "${try}" ]; then
    say "[setup] installing $pkg ..."
    sh -c "$try" >/dev/null 2>&1 || true
  fi
}

# Tools yang kita butuhkan
for t in curl jq openssl nc; do install_if_missing "$t"; done
# Alternatif nc
if ! have nc && have ncat; then alias nc=ncat; fi
if ! have nc && have netcat; then alias nc=netcat; fi

hr "Environment & System"
say "DATE:  $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
say "HOST:  $(hostname)"
say "KERNEL: $(uname -a)"
say "IP:    $(hostname -I 2>/dev/null || true)"
say "ROUTE:"
ip route 2>/dev/null || true
say "DNS resolv.conf:"
cat /etc/resolv.conf 2>/dev/null || true
say "iptables nat (OUTPUT rules):"
(iptables -t nat -S OUTPUT 2>/dev/null || true) | sed 's/^/- /'

PROXY_PORT="${PROXY_PORT:-14000}"
hr "Proxy healthz (local checks)"
curl -sS -m 5 "http://127.0.0.1:${PROXY_PORT}/healthz" | jq . 2>/dev/null || curl -sS -m 5 "http://127.0.0.1:${PROXY_PORT}/healthz" || true
say
say "NAT test to 127.0.0.1:14444/healthz (should be proxy):"
curl -sS -m 5 -D- -o /dev/null "http://127.0.0.1:14444/healthz" || true

hr "Targets"
NATS_HOSTS=("nc.devnet.inference.net:4222" "nc-logs.devnet.inference.net:4222")
HTTP_URLS=("https://relay.devnet.inference.net/public/latest-client-version" "https://cfs.devnet.inference.net/auto-update/inference-cli-linux-amd64/versions.json")
NOVITA_URLS=("https://api.novita.ai/v3/openai/chat/completions" "https://api.novita.ai/openai/v1/chat/completions")

resolve_host() {
  local host="$1"
  if have getent; then getent hosts "$host" | awk '{print $1}' | paste -sd, -; return; fi
  ping -c1 -W1 "$host" 2>/dev/null | awk -F'[ ()]+' '/PING/{print $3}' | head -n1
}

tcp_check() {
  local host="$1" port="$2"
  local start end dur
  start=$(date +%s%3N)
  if nc -z -w 3 "$host" "$port" >/dev/null 2>&1; then
    end=$(date +%s%3N); dur=$((end-start))
    say "  TCP connect OK (${dur}ms)"
    return 0
  else
    end=$(date +%s%3N); dur=$((end-start))
    say "  TCP connect FAIL (${dur}ms)"
    return 1
  fi
}

tls_check() {
  local host="$1" port="$2"
  if ! have openssl; then say "  TLS: openssl not found"; return; fi
  local out
  out=$(echo | timeout 5 openssl s_client -connect "${host}:${port}" -servername "${host}" -brief 2>/dev/null || true)
  if [ -n "$out" ]; then
    say "  TLS: OK ($(echo "$out" | head -n1))"
  else
    say "  TLS: FAIL (timeout/err)"
  fi
}

http_timing() {
  local url="$1"
  curl -sS -m 8 -o /dev/null -w "  HTTP: %{http_code} time_namelookup=%{time_namelookup}s time_connect=%{time_connect}s time_starttransfer=%{time_starttransfer}s time_total=%{time_total}s\n" "$url" || say "  HTTP: curl error"
}

hr "Check DevNet NATS endpoints (DNS/TCP/TLS)"
for entry in "${NATS_HOSTS[@]}"; do
  host="${entry%%:*}"; port="${entry##*:}"
  say "* ${host}:${port}"
  say "  DNS: $(resolve_host "$host")"
  tcp_check "$host" "$port"
  tls_check "$host" "$port"
done

hr "Check DevNet HTTP endpoints (timings)"
for u in "${HTTP_URLS[@]}"; do
  say "* $u"
  http_timing "$u"
done

hr "Check Novita endpoints (timings only)"
for u in "${NOVITA_URLS[@]}"; do
  say "* $u"
  http_timing "$u"
done

if [ -n "${NOVITA_API_KEY:-}" ]; then
  hr "Novita minimal POST (if NOVITA_API_KEY present)"
  body='{"model":"meta-llama/llama-3.2-3b-instruct","messages":[{"role":"user","content":"hi"}],"max_tokens":8,"temperature":0}'
  for u in "${NOVITA_URLS[@]}"; do
    say "* POST $u"
    curl -sS -m 12 -D- -o /dev/null -H "Authorization: Bearer ${NOVITA_API_KEY}" -H "Content-Type: application/json" --data "$body" "$u" \
      -w "  HTTP: %{http_code} time_total=%{time_total}s\n" || say "  POST error"
  done
else
  hr "Novita minimal POST skipped (NOVITA_API_KEY not set)"
fi

hr "Summary hints"
say "- Jika DNS lambat atau TCP connect FAIL ke nc*.devnet.inference.net:4222, timeout NATS akan muncul."
say "- Jika TLS ke 4222 gagal, mungkin ada masalah TLS interception/firewall."
say "- Jika HTTP DevNet punya time_total tinggi/timeout, jaringan sedang jitter."
say "- Jika Novita POST time_total tinggi, inference end-to-end juga bisa lambat."
