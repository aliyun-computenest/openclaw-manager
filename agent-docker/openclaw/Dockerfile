FROM registry-cn-shanghai.ack.aliyuncs.com/ack-demo/openclaw:2026.3.23-2

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

# Install channel connector plugins directly to extensions directory
RUN mkdir -p /root/.openclaw/extensions && \
    cd /root/.openclaw/extensions && \
    npm pack @wecom/wecom-openclaw-plugin && \
    npm pack @tencent-connect/openclaw-qqbot@latest && \
    npm pack @larksuite/openclaw-lark && \
    npm pack @dingtalk-real-ai/dingtalk-connector

# Extract and install dependencies for each plugin
RUN cd /root/.openclaw/extensions && \
    for pkg in *.tgz; do \
        dir=$(echo $pkg | sed 's/-[0-9].*//'); \
        mkdir -p $dir && tar -xzf $pkg -C $dir --strip-components=1 && rm $pkg && \
        if [ -f "$dir/package.json" ]; then cd $dir && npm install --production && cd ..; fi; \
    done
ENTRYPOINT ["supervisord", "-n"]