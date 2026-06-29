FROM compute-nest-registry.cn-hangzhou.cr.aliyuncs.com/computenest/hermes-agent:v0.14.0

# Switch to root to install plugins
USER root


# Install supervisor, tini and python3-yaml (required by run-cmd.sh for
# safely editing config.yaml without overwriting user customizations)
RUN apt update && \
    apt install -y supervisor tini python3 python3-yaml curl ca-certificates && \
    rm -rf /var/cache/apt/*

# Pre-install messaging platform dependencies (DingTalk + Feishu) into hermes venv.
# hermes v0.14.0 lazy_deps installs SDKs on first use, but _IncomingHandler's base
# class is frozen at module import time — if dingtalk_stream is missing then, the
# handler permanently inherits from object and silently drops all messages.
RUN VIRTUAL_ENV=/opt/hermes/.venv /usr/local/bin/uv pip install --no-cache \
        "dingtalk-stream==0.24.3" \
        "alibabacloud-dingtalk==2.2.42" \
        "lark-oapi==1.5.3" \
        "qrcode==7.4.2" \
        "edge-tts==7.2.7"

# Copy run-cmd.sh - selective model/channel config modifier.
# Invoked by the platform when users change model or channel, so that
# user-level customizations in config.yaml / .env are preserved.
COPY agent-docker/hermes/run-cmd.sh /usr/local/bin/run-cmd.sh
RUN chmod +x /usr/local/bin/run-cmd.sh

# Append hermes supervisor program config
COPY agent-docker/hermes/supervisord.conf /tmp/supervisord.conf
RUN cat /tmp/supervisord.conf >> /etc/supervisor/supervisord.conf && \
    rm /tmp/supervisord.conf

# Create hermes data directory
RUN mkdir -p /opt/data

# ── Install ARMS Python agent (CMS 2.0 observability) ──
# The aliyun-python-agent is a prebuilt wheel package hosted on cn-hangzhou OSS.
# It provides automatic LLM call tracing via PYTHONPATH injection.
RUN curl -fsSL https://arms-apm-cn-hangzhou.oss-cn-hangzhou.aliyuncs.com/aliyun-python-agent/aliyun-python-agent.tar.gz \
    -o /tmp/aliyun-python-agent.tar.gz && \
    mkdir -p /tmp/aliyun-python-agent && \
    tar -zxf /tmp/aliyun-python-agent.tar.gz -C /tmp/aliyun-python-agent && \
    uv pip install --python /opt/hermes/.venv/bin/python /tmp/aliyun-python-agent/target/*.whl && \
    rm -rf /tmp/aliyun-python-agent /tmp/aliyun-python-agent.tar.gz && \
    echo "ARMS Python agent installed" && \
    /opt/hermes/.venv/bin/python -c "import aliyun.opentelemetry; print('agent importable')" || echo "WARN: agent import check failed"

# ── Write entrypoint.sh (set ARMS env + PYTHONPATH at runtime) ──
# ARMS connection parameters (endpoint, license key, project, workspace) are
# injected at runtime via SandboxSet environment variables. If not set,
# the entrypoint starts hermes without monitoring (graceful degradation).
RUN cat > /usr/local/bin/entrypoint.sh <<'ENTRYEOF'
#!/bin/bash
set -e

# Graceful degradation: if ARMS env not set, start without monitoring
if [ -z "$ARMS_LICENSE_KEY" ] || [ -z "$ARMS_ENDPOINT" ]; then
    echo "[entrypoint] WARNING: Missing ARMS_* env, skipping Python agent."
    exec supervisord -n
fi

# Detect Python version from the venv (not hardcoded to 3.13)
PY_VERSION=$(/opt/hermes/.venv/bin/python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
SITE_PACKAGES="/opt/hermes/.venv/lib/python${PY_VERSION}/site-packages"
AUTO_INSTR="${SITE_PACKAGES}/aliyun/opentelemetry/instrumentation/auto_instrumentation"

# Set PYTHONPATH for auto-instrumentation (Python agent auto-loads on import)
export PYTHONPATH="${AUTO_INSTR}:${SITE_PACKAGES}"

# Set ARMS env for the Python agent
export ARMS_APP_NAME="${SERVICE_NAME:-hermes}"

echo "[entrypoint] Python agent configured: service=${ARMS_APP_NAME}, endpoint=${ARMS_ENDPOINT}, py=${PY_VERSION}"
exec supervisord -n
ENTRYEOF
RUN chmod +x /usr/local/bin/entrypoint.sh

# Disable tirith (Terraform policy checker) — not needed, avoids 12MB download on
# every cold start (~70s delay).
ENV TIRITH_ENABLED=false

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]

