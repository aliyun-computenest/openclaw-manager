FROM registry-cn-shanghai.ack.aliyuncs.com/ack-demo/openclaw:2026.3.23-2

# Switch to root to install plugins
USER root


# Install supervisor and tini for process management
RUN apt update && \
    apt install -y supervisor tini && \
    rm -rf /var/cache/apt/*

# Append openclaw supervisor program config
COPY agent-docker/openclaw/supervisord.conf /tmp/supervisord.conf
RUN cat /tmp/supervisord.conf >> /etc/supervisor/supervisord.conf && \
    rm /tmp/supervisord.conf

# Install channel connector plugins directly to extensions directory
# NOTE: All plugin versions are pinned to ensure compatibility with OpenClaw 2026.3.23
#       and to keep builds reproducible (avoid version drift from @latest).
RUN mkdir -p /home/node/.openclaw/extensions && \
    cd /home/node/.openclaw/extensions && \
    npm pack @wecom/wecom-openclaw-plugin@2026.3.30 && \
    npm pack @tencent-connect/openclaw-qqbot@1.6.7 && \
    npm pack @larksuite/openclaw-lark@2026.3.31 && \
    npm pack @dingtalk-real-ai/dingtalk-connector@0.8.10

# Extract and install dependencies for each plugin
RUN cd /home/node/.openclaw/extensions && \
    for pkg in *.tgz; do \
        dir=$(echo $pkg | sed 's/-[0-9].*//'); \
        mkdir -p $dir && tar -xzf $pkg -C $dir --strip-components=1 && rm $pkg && \
        if [ -f "$dir/package.json" ]; then cd $dir && npm install --production && cd ..; fi; \
    done

# Fix ownership: openclaw runs as 'node' user and needs write access to /home/node/.openclaw
RUN chown -R node:node /home/node/.openclaw

ENTRYPOINT ["supervisord", "-n"]


