FROM compute-nest-registry.cn-hangzhou.cr.aliyuncs.com/computenest/hermes-agent:v0.10.8

# Switch to root to install plugins
USER root


# Install supervisor, tini and python3-yaml (required by run-cmd.sh for
# safely editing config.yaml without overwriting user customizations)
RUN apt update && \
    apt install -y supervisor tini python3 python3-yaml && \
    rm -rf /var/cache/apt/*

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

