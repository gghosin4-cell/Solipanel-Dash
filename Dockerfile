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

# Upstream Marzban (master, 0.8.4) was written against Starlette < 1.0. The
# Starlette 1.x releases are the only ones without published high-severity
# advisories, so we upgrade to them and apply the minimal compatibility fix:
# app.routes can now contain an included-router placeholder that has no .path.
RUN python3 - <<'PY'
import io, sys
p = "app/__init__.py"
src = io.open(p, encoding="utf-8").read()
old = 'paths = [f"{r.path}/" for r in app.routes]'
new = 'paths = [f"{getattr(r, \'path\', \'\')}/" for r in app.routes]'
if new in src:
    print("compat patch already applied")
elif old in src:
    io.open(p, "w", encoding="utf-8").write(src.replace(old, new))
    print("compat patch applied")
else:
    sys.exit("could not locate the route-path block to patch")
PY

# Install Xray-core (official Gozargah helper script keeps the version current).
RUN curl -L https://github.com/Gozargah/Marzban-scripts/raw/master/install_latest_xray.sh | bash

# Build the dashboard's static assets, then drop the build-only npm tree: the
# React/Vite node_modules directory is not needed at runtime and its bundled
# toolchain packages carry advisories the image scanner blocks on.
RUN cd app/dashboard \
    && npm install --no-audit --no-fund \
    && VITE_BASE_API=/api/ npm run build --if-present -- --outDir build --assetsDir statics \
    && cp build/index.html build/404.html \
    && cd ../.. \
    && rm -rf app/dashboard/node_modules app/dashboard/.vite

RUN python3 -m pip install --upgrade pip setuptools wheel \
    && pip install --no-cache-dir -r requirements.txt

# Upstream Marzban pins several libraries that carry published high/critical
# advisories (Jinja2, PyJWT, anyio, certifi, cryptography, pyOpenSSL,
# python-dotenv, python-multipart, requests, starlette, urllib3). Upgrade every
# affected pin to the fixed release on top of the upstream requirements so the
# final image is not blocked by the image scanner.
RUN pip install --no-cache-dir --upgrade \
        "Jinja2==3.1.6" \
        "PyJWT==2.15.1" \
        "anyio==4.16.0" \
        "certifi==2026.10.23" \
        "cryptography==50.0.2" \
        "pyOpenSSL==26.4.0" \
        "python-dotenv==1.2.4" \
        "python-multipart==0.0.33" \
        "requests==2.34.2" \
        "urllib3==2.8.0" \
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

# Apply the distributor's fixed packages and deliberately do NOT install curl:
# the image only used it for the healthcheck, and the current Debian curl/libcurl
# carries unfixed critical CVEs. The healthcheck below uses the Python stdlib.
RUN apt-get update \
    && apt-get install -y --no-install-recommends libpq5 ca-certificates \
    && apt-get upgrade -y \
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

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=5 \
    CMD python3 -c 'import os,sys,urllib.request; port=os.environ.get("PORT","8080"); sys.exit(0 if urllib.request.urlopen("http://127.0.0.1:%s/" % port, timeout=4).status < 400 else 1)'

ENTRYPOINT ["bash", "/code/start-railway.sh"]
