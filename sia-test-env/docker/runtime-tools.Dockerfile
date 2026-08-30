FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      bash ca-certificates coreutils curl dnsutils findutils gawk grep iproute2 \
      iptables jq procps sed tini util-linux \
    && rm -rf /var/lib/apt/lists/*
