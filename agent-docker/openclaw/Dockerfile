FROM ghcr.io/openclaw/openclaw:2026.5.19

# Switch to root to install plugins
USER root

# ── 1. Install supervisor + tini ──
RUN apt update && \
    apt install -y supervisor tini && \
    rm -rf /var/cache/apt/*

# Copy run-cmd.sh for config modification
COPY agent-docker/openclaw/run-cmd.sh /usr/local/bin/run-cmd.sh
RUN chmod +x /usr/local/bin/run-cmd.sh

# Append openclaw supervisor program config
COPY agent-docker/openclaw/supervisord.conf /tmp/supervisord.conf
RUN cat /tmp/supervisord.conf >> /etc/supervisor/supervisord.conf && \
    rm /tmp/supervisord.conf

[program:openclaw]
command=openclaw gateway run --allow-unconfigured
user=node
environment=HOME="/home/node",OPENCLAW_NO_RESPAWN="1"
redirect_stderr=true
stdout_logfile=/proc/1/fd/1
stdout_logfile_maxbytes=0
autorestart=true
startretries=-1
stopasgroup=true
killasgroup=true
SUPERVISORD_EOF

# ── 3. Install channel connector plugins ──
# NOTE: All plugin versions are pinned to ensure compatibility with OpenClaw 2026.3.23
RUN mkdir -p /home/node/.openclaw/extensions && \
    cd /home/node/.openclaw/extensions && \
    npm pack @wecom/wecom-openclaw-plugin@2026.5.14 && \
    npm pack @tencent-connect/openclaw-qqbot@1.7.1 && \
    npm pack @larksuite/openclaw-lark@2026.5.13 && \
    npm pack @dingtalk-real-ai/dingtalk-connector@0.8.21

# Extract and install dependencies for each channel plugin
RUN cd /home/node/.openclaw/extensions && \
    for pkg in *.tgz; do \
        dir=$(echo $pkg | sed 's/-[0-9].*//'); \
        mkdir -p $dir && tar -xzf $pkg -C $dir --strip-components=1 && rm $pkg && \
        if [ -f "$dir/package.json" ]; then cd $dir && npm install --production && cd ..; fi; \
    done

# Expose the OpenClaw host package (/app, name="openclaw") to plugin extensions so that
# ESM bare specifiers like `import "openclaw/plugin-sdk/core"` used by newer plugin
# versions (e.g. dingtalk-connector >= 0.8.21) can be resolved by Node.js. Without this
# symlink the plugin fails to register with: Cannot find module 'openclaw/plugin-sdk/core'.
RUN mkdir -p /home/node/.openclaw/node_modules && \
    ln -sfn /app /home/node/.openclaw/node_modules/openclaw

# ── 4. Install ARMS observability plugin ──
RUN cd /home/node/.openclaw/extensions && \
    mkdir -p opentelemetry-instrumentation-openclaw && \
    cd opentelemetry-instrumentation-openclaw && \
    npm pack opentelemetry-instrumentation-openclaw@latest && \
    tar -xzf *.tgz --strip-components=1 && rm *.tgz && \
    npm install --omit=dev && \
    cd $(find . -path '*/diagnostics-otel' -type d | head -1) 2>/dev/null && \
    npm install --omit=dev || true

# ── 5. Write entrypoint.sh (generates openclaw.json on first boot, no-op on restart) ──
RUN cat > /usr/local/bin/entrypoint.sh <<'ENTRYEOF'
#!/bin/bash
set -e

CONFIG_FILE="${OPENCLAW_CONFIG_DIR:-/home/node/.openclaw/openclaw.json}"

ENDPOINT="${ARMS_ENDPOINT}"
LICENSE_KEY="${ARMS_LICENSE_KEY}"
PROJECT="${ARMS_PROJECT}"
WORKSPACE="${ARMS_WORKSPACE}"
SERVICE_NAME="${SERVICE_NAME}"

# All 5 parameters are required
if [ -z "$ENDPOINT" ] || [ -z "$LICENSE_KEY" ] || [ -z "$PROJECT" ] || [ -z "$WORKSPACE" ] || [ -z "$SERVICE_NAME" ]; then
    echo "[entrypoint] WARNING: Missing ARMS_* / SERVICE_NAME, skipping openclaw.json generation."
    exec supervisord -n
fi

# FIRST BOOT only: generate openclaw.json from env vars
# Platform writes the complete config on startup, replacing this initial file
if [ ! -f "${CONFIG_FILE}" ]; then
    cat > "${CONFIG_FILE}" <<JSONEOF
{
  "plugins": {
    "allow": ["opentelemetry-instrumentation-openclaw", "diagnostics-otel"],
    "load": { "paths": ["/home/node/.openclaw/extensions/opentelemetry-instrumentation-openclaw"] },
    "entries": {
      "opentelemetry-instrumentation-openclaw": {
        "enabled": true,
        "config": {
          "endpoint": "${ENDPOINT}",
          "headers": {
            "x-arms-license-key": "${LICENSE_KEY}",
            "x-arms-project": "${PROJECT}",
            "x-cms-workspace": "${WORKSPACE}"
          },
          "serviceName": "${SERVICE_NAME}"
        }
      }
    }
  },
  "diagnostics": {
    "enabled": true,
    "otel": {
      "enabled": true,
      "protocol": "http/protobuf",
      "endpoint": "${ENDPOINT}",
      "headers": {
        "x-arms-license-key": "${LICENSE_KEY}",
        "x-arms-project": "${PROJECT}",
        "x-cms-workspace": "${WORKSPACE}"
      },
      "serviceName": "${SERVICE_NAME}",
      "metrics": true,
      "traces": false,
      "logs": false
    }
  }
}
JSONEOF

    chown node:node "${CONFIG_FILE}" 2>/dev/null || true
    echo "[entrypoint] Generated ${CONFIG_FILE} with SERVICE_NAME=${SERVICE_NAME}"
fi

exec supervisord -n
ENTRYEOF
RUN chmod +x /usr/local/bin/entrypoint.sh

# ── 6. Fix ownership ──
RUN chown -R node:node /home/node/.openclaw

# ── 7. Entrypoint ──
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
