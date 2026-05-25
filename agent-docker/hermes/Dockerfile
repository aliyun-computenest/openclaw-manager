FROM nousresearch/hermes-agent:latest

# Switch to root to install plugins
USER root


# Install supervisor, tini and python3-yaml (required by run-cmd.sh for
# safely editing config.yaml without overwriting user customizations)
RUN apt update && \
    apt install -y supervisor tini python3 python3-yaml && \
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

# Disable tirith (Terraform policy checker) — not needed, avoids 12MB download on
# every cold start (~70s delay).
ENV TIRITH_ENABLED=false

ENTRYPOINT ["supervisord", "-n"]

