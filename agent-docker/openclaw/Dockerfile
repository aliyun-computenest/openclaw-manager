FROM ghcr.io/openclaw/openclaw:latest

# Switch to root to install plugins
USER root


# Install supervisor and tini for process management
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

# Install channel connector plugins via openclaw's native plugin system.
# v5.18 plugins depend on openclaw/plugin-sdk/core which is only resolvable
# when installed through the official CLI (sets up proper module symlinks).
# NOTE: Versions are pinned for build reproducibility.
RUN su - node -s /bin/bash -c "\
    cd /home/node/.openclaw && \
    openclaw plugins install @dingtalk-real-ai/dingtalk-connector@0.8.21 && \
    openclaw plugins install @wecom/wecom-openclaw-plugin@2026.5.14 && \
    openclaw plugins install @tencent-connect/openclaw-qqbot@1.7.1 && \
    openclaw plugins install @larksuite/openclaw-lark@2026.5.13"

# Fix ownership: openclaw runs as 'node' user and needs write access to /home/node/.openclaw
RUN chown -R node:node /home/node/.openclaw

ENTRYPOINT ["supervisord", "-n"]