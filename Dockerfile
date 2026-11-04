FROM debian:bookworm-slim

# Pin a cfst release (e.g. v2.3.5) or keep "latest".
ARG CFST_VERSION=latest
# Set automatically by docker buildx (amd64/arm64); empty for plain docker build.
ARG TARGETARCH=

RUN apt-get update \
 && apt-get install -y --no-install-recommends curl jq ca-certificates \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Download XIU2/CloudflareSpeedTest for the TARGET architecture:
# buildx passes TARGETARCH (multi-arch CI builds); a plain local build
# falls back to the build machine's uname -m.
RUN set -eux; \
    arch="${TARGETARCH:-}"; \
    if [ -z "$arch" ]; then \
      case "$(uname -m)" in \
        x86_64)        arch="amd64" ;; \
        aarch64|arm64) arch="arm64" ;; \
        *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;; \
      esac; \
    fi; \
    case "$arch" in \
      amd64|arm64) asset="$arch" ;; \
      *) echo "unsupported TARGETARCH: $arch" >&2; exit 1 ;; \
    esac; \
    if [ "$CFST_VERSION" = "latest" ]; then \
      url="https://github.com/XIU2/CloudflareSpeedTest/releases/latest/download/cfst_linux_${asset}.tar.gz"; \
    else \
      url="https://github.com/XIU2/CloudflareSpeedTest/releases/download/${CFST_VERSION}/cfst_linux_${asset}.tar.gz"; \
    fi; \
    curl -fsSL "$url" -o /tmp/cfst.tar.gz; \
    tar -xzf /tmp/cfst.tar.gz -C /app --strip-components=1; \
    rm -f /tmp/cfst.tar.gz; \
    chmod +x /app/cfst

COPY run.sh /app/run.sh
RUN chmod +x /app/run.sh
# NOTE: targets.conf is deliberately NOT baked into the image — it names the
# real domains. It is supplied at runtime only (bind mount, see compose).

ENTRYPOINT ["/app/run.sh"]
