FROM registry-cn-shanghai.ack.aliyuncs.com/ack-demo/openclaw:2026.3.23-2

# Switch to root to install plugins
USER root

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

# Switch back to the default user (node)
USER node