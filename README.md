# myku — Kuzco/Inference Worker + Novita OpenAI-Compatible Proxy

Container ini menyiapkan:
- Proxy HTTP ringan (Express/Node.js) yang kompatibel dengan OpenAI Chat Completions API dan meneruskan permintaan ke Novita AI (OpenAI-compatible endpoints).
- Worker Inference (Kuzco) yang dijalankan via Inference CLI.
- Opsi NAT redirect agar koneksi lokal port 14444 diarahkan ke port proxy (default 14000).
- “GPU spoof” nvidia-smi untuk lingkungan tanpa GPU fisik (mode unik per run).

Cocok untuk menjalankan worker Inference yang berbicara ke endpoint OpenAI-compatible milik Novita, sambil tetap kompatibel dengan klien OpenAI Chat Completions (non-stream/stream).

---

## Fitur Utama

- OpenAI-compatible Chat Completions di `/v1/chat/completions`.
- Simulasi streaming SSE ke klien, meskipun upstream dipanggil secara non-stream (dipecah jadi chunk).
- Normalisasi nama model dari klien → PUBLIC_MODEL, sementara upstream menggunakan UPSTREAM_BASE_MODEL.
- Daftar alias model (MODEL_ALIASES) agar klien dapat menggunakan berbagai nama model “setara”.
- NAT redirect otomatis (14444 → 14000) jika container diberi izin jaringan.
- Spoof `nvidia-smi` untuk sistem tanpa GPU fisik, sehingga Inference CLI bisa berjalan.
- “Unik per run” untuk identitas GPU spoof (UUID dan PCI bus id) agar menghindari duplikasi.

---

## Arsitektur Singkat

- Docker image berbasis Debian slim.
- Node.js 20.x untuk proxy.
- Inference CLI di-install dari skrip resmi.
- Entrypoint `execute.sh`:
  - Validasi env wajib (CODE, NOVITA_API_KEY).
  - Pastikan machine-id ada.
  - Pasang spoof `nvidia-smi` bila perlu.
  - Jalankan Novita proxy di background dan cek liveness.
  - Tambahkan aturan NAT redirect (jika diizinkan).
  - Jalankan Inference CLI (opsi keepalive).

---

## Prasyarat

- Docker / Docker Compose.
- Kode akses Inference CLI: `CODE` (dari layanan Kuzco/Inference Anda).
- API key Novita: `NOVITA_API_KEY`.

---

## Variabel Lingkungan

Wajib:
- `CODE` — kode untuk Inference CLI (Kuzco worker).
- `NOVITA_API_KEY` — API key Novita untuk panggilan upstream.

Opsional (default di container):
- `PROXY_PORT` — port proxy HTTP (default: `14000`).
- `UPSTREAM_BASE_MODEL` — model upstream untuk Novita (default: `meta-llama/llama-3.2-3b-instruct`).
- `PUBLIC_MODEL` — nama model publik yang diekspos proxy (default: `meta-llama/llama-3.2-3b-instruct/fp-16-fast-vllm-1`).
- `MODEL_ALIASES` — daftar alias model, dipisah koma.
- `NOVITA_OPENAI_ENDPOINTS` — daftar endpoint Novita dipisah `;` (default prioritas:  
  `https://api.novita.ai/v3/openai/chat/completions;https://api.novita.ai/openai/v1/chat/completions;https://api.novita.ai/v1/chat/completions`)
- `STREAM_CHUNK_SIZE` — ukuran chunk SSE hasil streaming ke klien (default: `64`).
- `STREAM_DELAY_MS` — jeda antar chunk SSE (ms) (default: `30`).
- `KEEPALIVE` — `1` untuk auto-restart Inference CLI saat crash (default: `0`).

Opsional (GPU spoof):
- `GPU_SPOOF_UUID` — paksa UUID, contoh: `GPU-12345678-1234-1234-1234-1234567890AB`.
- `GPU_SPOOF_PCI_BUS_ID` — paksa PCI bus id, contoh: `00000000:02:05.1`.
- `GPU_SPOOF_NAME` — nama GPU ditampilkan (default: `GeForce RTX 4090`).
- `GPU_SPOOF_DRIVER` — versi driver (default: `535.00`).
- `GPU_SPOOF_MEMORY_TOTAL` — total memori MiB tanpa satuan (default: `24576`).
- `GPU_SPOOF_STATE_DIR` — lokasi state spoof (default: `/var/run/gpu-spoof`).

Catatan keamanan:
- Proxy tidak menggunakan Authorization header dari klien untuk ke Novita. API key Novita hanya dibaca dari environment server. Simpan `NOVITA_API_KEY` sebagai secret.

---

## Build dan Jalankan

Build image:
```bash
docker build -t myku:latest kuzco-main
```

Jalankan minimal (tanpa NAT redirect):
```bash
docker run --rm -p 14000:14000 \
  -e CODE=YOUR_INFERENCE_CODE \
  -e NOVITA_API_KEY=YOUR_NOVITA_KEY \
  --name kuzco-main \
  myku:latest
```

Jalankan dengan NAT redirect 14444 → 14000 (butuh CAP_NET_ADMIN):
```bash
docker run --rm -p 14000:14000 \
  --cap-add NET_ADMIN \
  -e CODE=YOUR_INFERENCE_CODE \
  -e NOVITA_API_KEY=YOUR_NOVITA_KEY \
  --name kuzco-main \
  myku:latest
```

Contoh docker-compose.yml:
```yaml
services:
  kuzco-main:
    image: myku:latest
    build:
      context: ./kuzco-main
    container_name: kuzco-main
    ports:
      - "14000:14000"
    environment:
      CODE: "YOUR_INFERENCE_CODE"
      NOVITA_API_KEY: "YOUR_NOVITA_KEY"
      PROXY_PORT: "14000"
      KEEPALIVE: "1"
      # Opsi spoof (debug):
      # GPU_SPOOF_NAME: "GeForce RTX 4090"
      # GPU_SPOOF_MEMORY_TOTAL: "24576"
    # Untuk NAT redirect 14444 -> 14000:
    cap_add:
      - NET_ADMIN
    restart: unless-stopped
```

---

## Verifikasi Cepat

Healthz:
```bash
curl http://localhost:14000/healthz
```

OpenAI Chat Completions (non-stream):
```bash
curl -sS -X POST http://localhost:14000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model":"bebas-aja",
    "messages":[{"role":"user","content":"Halo!"}]
  }' | jq
```

OpenAI Chat Completions (stream SSE simulasi):
```bash
curl -N -X POST http://localhost:14000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model":"apa-aja",
    "messages":[{"role":"user","content":"Jelaskan fungsi kamu."}],
    "stream": true
  }'
```

Jika NAT aktif (container dengan NET_ADMIN), healthz via 14444:
```bash
curl http://127.0.0.1:14444/healthz
```

---

## Endpoint yang Tersedia

- `GET /healthz` — status, model publik, model upstream, alias, dan daftar endpoint Novita.
- `GET /api/tags` — daftar “models” (memetakan PUBLIC_MODEL → UPSTREAM_BASE_MODEL).
- `POST /api/pull` — emulasi NDJSON ala “ollama pull” (dummy sukses).
- `POST /v1/chat/completions` — OpenAI-compatible Chat Completions:
  - Body OpenAI standar.
  - Upstream ke Novita dipanggil non-stream.
  - Jika client minta `stream: true`, proxy akan memecah hasil final menjadi SSE chunk (ukuran/jeda via STREAM_CHUNK_SIZE/STREAM_DELAY_MS).
- `POST /api/generate` — endpoint generik (prompt/messages, dapat stream false/true) → balasan JSON sederhana.

---

## Model dan Aliasing

- Semua `model` dari klien akan dinormalisasi ke `PUBLIC_MODEL` pada respons ke klien.
- Panggilan upstream selalu menggunakan `UPSTREAM_BASE_MODEL`.
- `MODEL_ALIASES` dapat berisi beberapa nama/variasi; server juga membangkitkan bentuk “compact” (menghapus separator) untuk toleransi input.

---

## GPU Spoof (nvidia-smi): Identitas Unik per Run

Fitur spoof `nvidia-smi` membangkitkan identitas GPU palsu saat container dijalankan:
- Unik per run: UUID dan PCI_BUS_ID dibangkitkan sekali pada panggilan pertama dan disimpan di direktori state (default: `/var/run/gpu-spoof`). Setiap container baru memiliki identitas baru.
- Stabil selama container hidup: nilai yang sama dikembalikan untuk semua panggilan berikutnya sampai container dihentikan/di-recreate.

Detail:
- UUID: `GPU-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (UUID v4, huruf besar).
- PCI Bus ID: `00000000:BB:DD.F`.

Verifikasi:
```bash
# di dalam container
nvidia-smi --query-gpu=uuid,pci.bus_id --format=csv,noheader,nounits

# restart container lalu cek lagi (identitas akan berubah)
```

Paksa ganti identitas pada container berjalan:
```bash
rm -rf /var/run/gpu-spoof
nvidia-smi --query-gpu=uuid,pci.bus_id --format=csv,noheader,nounits
```

ENV override (opsional):
- `GPU_SPOOF_UUID`, `GPU_SPOOF_PCI_BUS_ID`, `GPU_SPOOF_NAME`, `GPU_SPOOF_DRIVER`, `GPU_SPOOF_MEMORY_TOTAL`, `GPU_SPOOF_STATE_DIR`.

Catatan:
- Tujuan spoof adalah agar tooling yang memeriksa `nvidia-smi` tetap berjalan pada host tanpa GPU.
- Layanan pihak ketiga dapat menerapkan kebijakan 1-GPU-1-instance; identitas unik per run menghindari benturan, tetapi kebijakan layanan tetap berlaku.

---

## Logging

- Proxy: dicetak ke stdout dan disalin ke `/app/novita-proxy.log`.
- Inference CLI: mengikuti lifecycle launcher/CLI dan tampil di log container.

---

## Troubleshooting

- Duplicate GPU detected:
  - Recreate container (down lalu up) agar mendapatkan identitas baru.
  - Pastikan tidak ada container lain yang berjalan dengan identitas spoof yang sama (dalam 1 run, identitas konsisten).
  - Opsi terakhir: paksa override UUID/PCI via ENV.

- NAT redirect gagal:
  - Pastikan container dijalankan dengan `--cap-add NET_ADMIN`.
  - Atau akses langsung ke `PROXY_PORT` tanpa mengandalkan port 14444.

- Authorization Novita:
  - Proxy tidak membaca Authorization header dari klien. Gunakan `NOVITA_API_KEY` via environment di server.

---

## Kustomisasi

- Ubah `PUBLIC_MODEL`, `UPSTREAM_BASE_MODEL`, dan `MODEL_ALIASES` sesuai kebutuhan branding atau kompatibilitas klien.
- Tambahkan/ubah daftar endpoint Novita via `NOVITA_OPENAI_ENDPOINTS` (pisah dengan `;`).
- Sesuaikan pengalaman “streaming” ke klien via `STREAM_CHUNK_SIZE` dan `STREAM_DELAY_MS`.

---

## Struktur Direktori (ringkas)

```
kuzco-main/
  Dockerfile
  execute.sh
  gpu-spoof.sh
  novita-proxy/
    package.json
    server.js
```

---

## Lisensi

Silakan tambahkan lisensi yang sesuai (mis. MIT) jika diperlukan.
