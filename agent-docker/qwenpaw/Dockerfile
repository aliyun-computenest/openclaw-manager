FROM agentscope-registry.ap-southeast-1.cr.aliyuncs.com/agentscope/qwenpaw:latest

# Switch to root for any customization
USER root

# Install supervisor (for supervisorctl) and tini. 镜像已经内置了 supervisord 主进程，
# 我们只需要 supervisorctl 客户端，用于 run-cmd.sh 在修改模型后重启 qwenpaw `app` 子进程。
RUN apt-get update && \
    apt-get install -y supervisor tini && \
    rm -rf /var/cache/apt/*

# Ensure qwenpaw data directories exist (will be overlaid by emptyDir volumes at runtime)
RUN mkdir -p /app/working /app/working.secret /app/working.secret/providers/custom /app/working.backups

# Seed 3 个平台默认 provider 模板。
#   - /app/working.secret 在 SandboxSet 里是 emptyDir 挂载，镜像里预置的
#     /app/working.secret/providers/** 运行时会被空卷盖掉，因此 COPY
#     到 不被挂载的 /opt/qwenpaw-providers/ 做为“seed 模板”。
#   - run-cmd.sh 在 modify-model 时会把该目录的模板拷到
#     /app/working.secret/providers/{builtin,custom}/，仅当目标文件不存在
#     时拷——保留用户文档进去的任何改动。
#   - 3 个默认提供商：
#     builtin/dashscope.json         ← 百炼 (平台 name: bailian)
#     custom/aliyun-ai-gateway.json  ← 阿里云 AI 网关 (平台 name: api_gateway)
#     custom/litellm.json            ← LiteLLM 网关 (平台 name: litellm)
COPY agent-docker/qwenpaw/providers /opt/qwenpaw-providers
RUN chmod -R a+r /opt/qwenpaw-providers

# Copy run-cmd.sh - selective model config modifier.
# qwenpaw 不支持在线修改渠道，因此 run-cmd.sh 只实现 modify-model 与 init-providers：
#   1. init-providers：将 /opt/qwenpaw-providers/ 里的 3 个模板 seed 到
#      /app/working.secret/providers/ 对应子目录（幂等，目标已存在则跳过）。
#   2. modify-model：按映射表把平台传入的 MODEL_PROVIDER 解析为 (target_rel_path,
#      qwenpaw_id, override_base_url) 三元组，合并写回目标 provider JSON，并
#      写 /app/working.secret/providers/active_model.json，最后 supervisorctl
#      restart app 让 qwenpaw 重新加载。
COPY agent-docker/qwenpaw/run-cmd.sh /usr/local/bin/run-cmd.sh
RUN chmod +x /usr/local/bin/run-cmd.sh

# Entrypoint wrapper：在原生 entrypoint 之前先 seed providers，让 qwenpaw init
# 对 /app/working.secret/providers/ 的首次扫描就能看到完整的 3 个默认
# provider；否则 emptyDir 挂载后 app 会缓存“只有 dashscope”的列表，
# 平台之后再 supervisorctl restart 可能无法刷新前端可见的 provider。
COPY agent-docker/qwenpaw/entrypoint-wrapper.sh /usr/local/bin/entrypoint-wrapper.sh
RUN chmod +x /usr/local/bin/entrypoint-wrapper.sh
ENTRYPOINT ["/usr/local/bin/entrypoint-wrapper.sh"]

# 说明：
#   qwenpaw 官方镜像已内置完整启动链：
#     ENTRYPOINT ["docker-entrypoint.sh"]   ← 被本镜像 wrapper 取代，但在 wrapper 末尾 exec 回来
#     CMD        ["/entrypoint.sh"]         ← 保持不变，wrapper 原样透传
#   /entrypoint.sh 会自动完成：
#     1. 检查 /app/working/config.json，缺失则执行 `qwenpaw init --defaults --accept-security`
#     2. 用 QWENPAW_PORT 渲染 /etc/supervisor/conf.d/supervisord.conf.template
#     3. exec 镜像自带 supervisord，启动 dbus / xvfb / xfce4 / app 四个进程
#   wrapper 只在此之前插入 `init-providers`，不修改它之后的任何行为。
