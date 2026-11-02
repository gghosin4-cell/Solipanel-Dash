# syntax=docker/dockerfile:1
# ---------------------------------------------------------------------------
# Marzban panel - Railway deploy wrapper (build-time clone, like PasarGuard)
# ---------------------------------------------------------------------------
ARG PYTHON_VERSION=3.12

FROM python:${PYTHON_VERSION}-slim AS builder

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential gcc python3-dev libpq-dev git curl unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Node.js is needed only to build the React/Vite dashboard from source.
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build

# Always fetch the latest upstream source at build time (no vendored snapshot),
# so the image never goes stale the way a vendored copy would.
ARG MARZBAN_REPO=https://github.com/Gozargah/Marzban.git
ARG MARZBAN_REF=master
RUN git clone --depth 1 --branch ${MARZBAN_REF} ${MARZBAN_REPO} .

# Install Xray-core (official Gozargah helper script keeps the version current).
RUN curl -L https://github.com/Gozargah/Marzban-scripts/raw/master/install_latest_xray.sh | bash

# Build the dashboard's static assets.
RUN cd app/dashboard \
    && npm install --no-audit --no-fund \
    && VITE_BASE_API=/api/ npm run build --if-present -- --outDir build --assetsDir statics \
    && cp build/index.html build/404.html \
    && cd ../..

RUN python3 -m pip install --upgrade pip setuptools wheel \
    && pip install --no-cache-dir -r requirements.txt

# Upstream Marzban pins several libraries that carry published high/critical
# advisories (anyio, certifi, PyJWT, cryptography, pyOpenSSL, python-multipart,
# starlette, urllib3, requests). Upgrade them to the fixed releases on top of
# the upstream requirements so the final image is not blocked by the scanner.
RUN pip install --no-cache-dir --upgrade \
        "PyJWT==2.15.1" \
        "anyio==4.16.0" \
        "certifi==2026.10.23" \
        "cryptography==50.0.2" \
        "pyOpenSSL==26.4.0" \
        "python-multipart==0.0.33" \
        "urllib3==2.8.0" \
        "requests==2.34.2" \
        "fastapi==0.162.0" \
        "starlette==1.10.0"

# ---------------------------------------------------------------------------
# Runtime image
# ---------------------------------------------------------------------------
FROM python:${PYTHON_VERSION}-slim

ENV PYTHONUNBUFFERED=1 \
    PYTHON_LIB_PATH=/usr/local/lib/python3.12/site-packages \
    XRAY_EXECUTABLE_PATH=/usr/local/bin/xray \
    XRAY_ASSETS_PATH=/usr/local/share/xray \
    SQLALCHEMY_DATABASE_URL=sqlite:////code/db.sqlite3 \
    TZ=UTC

WORKDIR /code

RUN apt-get update && apt-get install -y --no-install-recommends \
        libpq5 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder $PYTHON_LIB_PATH $PYTHON_LIB_PATH
COPY --from=builder /usr/local/bin /usr/local/bin
COPY --from=builder /usr/local/share/xray /usr/local/share/xray
COPY --from=builder /build /code

# apscheduler (a Marzban dependency) still imports pkg_resources at import time.
# The newest setuptools releases REMOVED pkg_resources entirely, so merely
# upgrading setuptools doesn't help - we must pin a version that still ships it.
RUN pip install --no-cache-dir "setuptools==75.8.0"

COPY start-railway.sh /code/start-railway.sh
RUN chmod +x /code/start-railway.sh \
    && ln -sf /code/marzban-cli.py /usr/bin/marzban-cli \
    && chmod +x /usr/bin/marzban-cli

RUN useradd -m -u 1000 appuser \
    && mkdir -p /code/data /var/lib/marzban \
    && chown -R appuser:appuser /code /var/lib/marzban
USER appuser

# Keep the exposed port in sync with the configured AppJet deployment port.
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=40s --retries=5 \
    CMD curl -fsS "http://127.0.0.1:${PORT:-8080}/" || exit 1

ENTRYPOINT ["bash", "/code/start-railway.sh"]
