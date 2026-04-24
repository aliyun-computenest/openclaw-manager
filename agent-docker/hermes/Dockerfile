FROM compute-nest-registry.cn-hangzhou.cr.aliyuncs.com/computenest/hermes-agent:v0.10.8

# Switch to root to install plugins
USER root


# Install supervisor and tini for process management
RUN apt update && \
    apt install -y supervisor tini && \
    rm -rf /var/cache/apt/*

# Append hermes supervisor program config
COPY agent-docker/hermes/supervisord.conf /tmp/supervisord.conf
RUN cat /tmp/supervisord.conf >> /etc/supervisor/supervisord.conf && \
    rm /tmp/supervisord.conf

# Create hermes data directory
RUN mkdir -p /opt/data

ENTRYPOINT ["supervisord", "-n"]

