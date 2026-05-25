FROM nousresearch/hermes-agent:latest

# Switch to root to install plugins
USER root


# Install supervisor, tini and python3-yaml (required by run-cmd.sh for
# safely editing config.yaml without overwriting user customizations)
RUN apt update && \
    apt install -y supervisor tini python3 python3-yaml && \
    rm -rf /var/cache/apt/*

# Pre-install messaging platform dependencies (DingTalk + Feishu) into hermes venv.
#
# Background:
#   hermes v0.14.0 introduced a lazy_deps mechanism that installs platform SDKs
#   on first use. However, `gateway/platforms/dingtalk.py` defines
#       class _IncomingHandler(
#           dingtalk_stream.ChatbotHandler if DINGTALK_STREAM_AVAILABLE else object
#       )
#   at module import time. If dingtalk_stream is missing when the gateway
#   process starts, the base class is permanently frozen as `object`, and even
#   after lazy_deps installs the SDK, the handler still lacks `pre_start` /
#   `raw_process`, so every incoming DingTalk message is silently dropped.
#
# Fix: pre-install all required SDKs at build time so the first `import` at
# process startup always succeeds.
RUN VIRTUAL_ENV=/opt/hermes/.venv /usr/local/bin/uv pip install --no-cache \
        "dingtalk-stream==0.24.3" \
        "alibabacloud-dingtalk==2.2.42" \
        "lark-oapi==1.5.3" \
        "qrcode==7.4.2"

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

ENTRYPOINT ["supervisord", "-n"]

