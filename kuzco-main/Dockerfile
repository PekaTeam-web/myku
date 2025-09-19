FROM debian:stable-slim

# Tambah xz-utils (untar Node), iproute2 (perintah ss), dan iptables (NAT redirect)
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl ca-certificates bash coreutils procps lsof git python3-minimal xz-utils iproute2 iptables \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
RUN mkdir -p /app/cache

# (Opsional) simpan repo lama jika suatu saat dibutuhkan
RUN git clone https://github.com/direkturcrypto/vikey-inference || true

# Inference CLI
RUN curl -fsSL https://devnet.inference.net/install.sh | sh

# Node.js (arsip resmi)
ENV NODE_VERSION=20.16.0
RUN curl -fsSL https://nodejs.org/dist/v$NODE_VERSION/node-v$NODE_VERSION-linux-x64.tar.xz -o node.tar.xz \
 && tar -xJf node.tar.xz -C /usr/local --strip-components=1 \
 && rm node.tar.xz \
 && node -v && npm -v

# Novita proxy
WORKDIR /app/novita-proxy
COPY novita-proxy/package.json ./package.json
RUN npm install --omit=dev
COPY novita-proxy/server.js ./server.js

# Skrip runtime
WORKDIR /app
COPY execute.sh /app/execute.sh
COPY gpu-spoof.sh /app/gpu-spoof.sh
RUN chmod +x /app/execute.sh /app/gpu-spoof.sh

# Env default
ENV UPSTREAM_BASE_MODEL="meta-llama/llama-3.2-3b-instruct" \
    PUBLIC_MODEL="meta-llama/llama-3.2-3b-instruct/fp-16-fast-vllm-1" \
    MODEL_ALIASES="llama3.2-3b-instruct,llama-3.2-3b-instruct,meta-llama-llama-3.2-3b-instruct,meta-llama/llama-3.2-3b-instruct,meta-llama/llama-3.2-3b-instruct/fp-16-fast-vllm-1" \
    PROXY_PORT="14000" \
    STREAM_CHUNK_SIZE="64" \
    STREAM_DELAY_MS="30" \
    NODE_ENV="production"

EXPOSE 14000
CMD ["/app/execute.sh"]
