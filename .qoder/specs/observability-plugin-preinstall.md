# 镜像预装可观测插件 — 实施计划（OpenClaw only）

> 分支：`feat/observability-plugin`

## Context

当前 ARMS 插件运行时安装，有网关重启中断、流程复杂两个问题。本方案改为镜像预装 + entrypoint.sh 从 env 动态生成 `openclaw.json`。

---

## 文件变更

```
agent-docker/openclaw/
├── Dockerfile       ← 修改
└── SandboxSet.yaml  ← 修改
```

---

## 1. Dockerfile

```dockerfile
FROM registry-cn-shanghai.ack.aliyuncs.com/ack-demo/openclaw:2026.3.23-2
USER root

# Supervisor + tini
RUN apt update && \
    apt install -y supervisor tini && \
    rm -rf /var/cache/apt/*

# Supervisord config (inline)
RUN cat >> /etc/supervisor/supervisord.conf <<'SUPERVISORD_EOF'

[program:openclaw]
command=openclaw gateway run --allow-unconfigured
user=node
environment=HOME="/home/node",OPENCLAW_NO_RESPAWN="1"
redirect_stderr=true
stdout_logfile=/proc/1/fd/1
stdout_logfile_maxbytes=0
autorestart=true
startretries=-1
stopasgroup=true
killasgroup=true
SUPERVISORD_EOF

# Channel plugins
RUN mkdir -p /home/node/.openclaw/extensions && \
    cd /home/node/.openclaw/extensions && \
    npm pack @wecom/wecom-openclaw-plugin@2026.3.30 && \
    npm pack @tencent-connect/openclaw-qqbot@1.6.7 && \
    npm pack @larksuite/openclaw-lark@2026.3.30 && \
    npm pack @dingtalk-real-ai/dingtalk-connector@0.8.10

RUN cd /home/node/.openclaw/extensions && \
    for pkg in *.tgz; do \
        dir=$(echo $pkg | sed 's/-[0-9].*//'); \
        mkdir -p $dir && tar -xzf $pkg -C $dir --strip-components=1 && rm $pkg && \
        if [ -f "$dir/package.json" ]; then cd $dir && npm install --production && cd ..; fi; \
    done

# ARMS plugin
RUN cd /home/node/.openclaw/extensions && \
    mkdir -p openclaw-cms-plugin && \
    cd openclaw-cms-plugin && \
    npm pack openclaw-cms-plugin@0.1.2 && \
    tar -xzf *.tgz --strip-components=1 && rm *.tgz && \
    npm install --omit=dev && \
    cd $(find . -path '*/diagnostics-otel' -type d | head -1) 2>/dev/null && \
    npm install --omit=dev || true

# entrypoint.sh — generates openclaw.json on first boot, no-op on restart
RUN cat > /usr/local/bin/entrypoint.sh <<'ENTRYEOF'
#!/bin/bash
set -e

CONFIG_FILE="${OPENCLAW_CONFIG_DIR:-/home/node/.openclaw/openclaw.json}"

ENDPOINT="${ARMS_ENDPOINT}"
LICENSE_KEY="${ARMS_LICENSE_KEY}"
PROJECT="${ARMS_PROJECT}"
WORKSPACE="${ARMS_WORKSPACE}"
SERVICE_NAME="${SERVICE_NAME}"

if [ -z "$ENDPOINT" ] || [ -z "$LICENSE_KEY" ] || [ -z "$PROJECT" ] || [ -z "$WORKSPACE" ] || [ -z "$SERVICE_NAME" ]; then
    echo "[entrypoint] WARNING: Missing ARMS_* / SERVICE_NAME, skipping generation."
    exec supervisord -n
fi

if [ ! -f "${CONFIG_FILE}" ]; then
    cat > "${CONFIG_FILE}" <<JSONEOF
{
  "plugins": {
    "allow": ["openclaw-cms-plugin", "diagnostics-otel"],
    "load": { "paths": ["/home/node/.openclaw/extensions/openclaw-cms-plugin"] },
    "entries": {
      "openclaw-cms-plugin": {
        "enabled": true,
        "config": {
          "endpoint": "${ENDPOINT}",
          "headers": {
            "x-arms-license-key": "${LICENSE_KEY}",
            "x-arms-project": "${PROJECT}",
            "x-cms-workspace": "${WORKSPACE}"
          },
          "serviceName": "${SERVICE_NAME}"
        }
      }
    }
  },
  "diagnostics": {
    "enabled": true,
    "otel": {
      "enabled": true,
      "protocol": "http/protobuf",
      "endpoint": "${ENDPOINT}",
      "headers": {
        "x-arms-license-key": "${LICENSE_KEY}",
        "x-arms-project": "${PROJECT}",
        "x-cms-workspace": "${WORKSPACE}"
      },
      "serviceName": "${SERVICE_NAME}",
      "metrics": true,
      "traces": false,
      "logs": false
    }
  }
}
JSONEOF
    chown node:node "${CONFIG_FILE}" 2>/dev/null || true
    echo "[entrypoint] Generated ${CONFIG_FILE} with SERVICE_NAME=${SERVICE_NAME}"
fi

exec supervisord -n
ENTRYEOF
RUN chmod +x /usr/local/bin/entrypoint.sh

RUN chown -R node:node /home/node/.openclaw

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

**entrypoint.sh 逻辑**：校验 5 个 env 全非空 → openclaw.json 不存在则 heredoc 生成 → exec supervisord。配置文件已存在时（平台已写入/容器重启）不做任何操作。

> 若 npm registry 为私有，需在 Dockerfile 中添加 `RUN echo "//<registry>/:_authToken=${NPM_TOKEN}" > /root/.npmrc`。

---

## 2. SandboxSet.yaml

将 `command` 改为 entrypoint.sh，新增 ARMS_* 和 SERVICE_NAME 环境变量：

```yaml
# 修改
command: ["/usr/local/bin/entrypoint.sh"]

# 在 env 下新增
env:
  - name: ARMS_ENDPOINT
    value: ""
  - name: ARMS_LICENSE_KEY
    value: ""
  - name: ARMS_PROJECT
    value: ""
  - name: ARMS_WORKSPACE
    value: ""
  - name: SERVICE_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
```

`ARMS_*` 初始为空，平台通过 `buildSandboxSet()` 调用 `getApmInstallParameters()` 动态注入。`SERVICE_NAME` 由 Downward API 自动注入。

---

## 3. 平台侧（openclaw-platform）

| 文件 | 变更 |
|------|------|
| `agents/openclaw/SandboxSet.yaml` | 同步添加 command + env |
| `server/services/sandbox.js` | `buildSandboxSet()` 注入 `ARMS_*` env |
| `server/services/instance-provisioner.js` | 注释掉 `installArmsPluginBackground()` |
| `server/services/gateway-config.js` | `buildApmObservabilityUrl()` 增加 Pod 名称候选 |

**约束**：
- admin 模板必须保留 `openclaw-cms-plugin` 和 `diagnostics.otel` 段，且 `serviceName` 不能为空（由平台填入 Pod 名称）
- 若平台侧未适配 admin 模板，平台写入配置后将覆盖 entrypoint.sh 生成的 ARMS 段，导致监控丢失——首版部署前必须确认平台侧已就绪

**降级恢复**：若部署时 `getApmInstallParameters()` 未拿到参数导致 ARMS_* env 为空，entrypoint.sh 会跳过生成，Pod 无监控。后续平台拿到参数后，通过已有的"重写 admin 配置"通道更新该 Pod 的 `openclaw.json` 即可，无需重建 Pod、不丢数据。

---

## 4. 验证

| # | 项 | 预期 |
|---|----|------|
| 1 | `docker build` | 成功 |
| 2 | 无 env 启动 `cat openclaw.json` | 文件不存在 |
| 3 | 完整 env 启动 | 日志 `Generated ... with SERVICE_NAME=` |
| 4 | 包含 env 启动后 `cat openclaw.json` | 所有字段正确填充 |
| 5 | 缺 env 启动 | `WARNING`，不崩溃 |
| 6 | 预写 openclaw.json 后重启容器 | 文件完全不变 |

---

## 5. 回退

1. command 改回 `["supervisord", "-n"]`
2. 移除 `ARMS_*` / `SERVICE_NAME` env
3. 恢复 `installArmsPluginBackground()` 调用
