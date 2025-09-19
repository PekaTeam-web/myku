## GPU spoof (nvidia-smi): identitas unik per run

Fitur spoof nvidia-smi membangkitkan identitas GPU palsu saat container dijalankan:
- Unik per run: UUID dan PCI_BUS_ID dibangkitkan sekali pada panggilan pertama dan disimpan di direktori state (default: `/var/run/gpu-spoof`). Setiap container baru memiliki identitas baru.
- Stabil selama container hidup: nilai yang sama akan dikembalikan untuk semua panggilan berikutnya hingga container dihentikan/di-recreate.

Detail teknis:
- UUID berformat `GPU-xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx` (UUID v4, huruf besar).
- PCI Bus ID pseudo berformat `00000000:BB:DD.F`.
- State dapat diubah via ENV `GPU_SPOOF_STATE_DIR` (opsional).

### Cara verifikasi

1) Lihat identitas saat ini (di dalam container):
```bash
nvidia-smi --query-gpu=uuid,pci.bus_id --format=csv,noheader,nounits
```

2) Restart container dan cek lagi (identitas harus berubah):
```bash
# dari host
docker compose restart <nama-service-anda>
# lalu di dalam container
nvidia-smi --query-gpu=uuid,pci.bus_id --format=csv,noheader,nounits
```

3) (Opsional) Paksa ganti identitas di container yang sedang berjalan:
```bash
rm -rf /var/run/gpu-spoof
nvidia-smi --query-gpu=uuid,pci.bus_id --format=csv,noheader,nounits
```

### ENV override (opsional)

Anda dapat memaksa nilai tertentu untuk debug atau kebutuhan khusus:
- `GPU_SPOOF_UUID` — paksa UUID, misal: `GPU-12345678-1234-1234-1234-1234567890AB`
- `GPU_SPOOF_PCI_BUS_ID` — paksa PCI bus id, misal: `00000000:02:05.1`
- `GPU_SPOOF_NAME` — nama GPU yang ditampilkan (default: `GeForce RTX 4090`)
- `GPU_SPOOF_DRIVER` — versi driver (default: `535.00`)
- `GPU_SPOOF_MEMORY_TOTAL` — total memori dalam MiB tanpa satuan (default: `24576`)
- `GPU_SPOOF_STATE_DIR` — lokasi state spoof (default: `/var/run/gpu-spoof`)

Contoh di `docker-compose.yml`:
```yaml
services:
  kuzco-main:
    environment:
      - GPU_SPOOF_UUID=GPU-12345678-1234-1234-1234-1234567890AB
      - GPU_SPOOF_PCI_BUS_ID=00000000:02:05.1
```

### Catatan

- Fitur ini ditujukan untuk lingkungan tanpa `nvidia-smi` fisik agar tooling yang memeriksa GPU tetap dapat berjalan.
- Jika layanan pihak ketiga masih melaporkan “Duplicate GPU detected”, lakukan recreate container (down lalu up) agar memperoleh identitas baru. Kebijakan “1 GPU = 1 instance” mungkin tetap diberlakukan oleh penyedia layanan.
