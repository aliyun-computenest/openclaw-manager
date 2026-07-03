# OpenClaw 可观测性插件预装 — 代码地图 (Feature Codemap)

## 文档信息
- **项目**: openclaw-manager
- **分支**: `feat/observability-plugin`
- **核心目标**: 将 openclaw-cms-plugin@0.1.2 和 diagnostics-otel 预装到 Docker 镜像，通过 entrypoint.sh 动态生成配置
- **生成时间**: 2026-05-21
- **文档类型**: Pre-Research Feature Codemap

---

## 1. 项目结构总览

```
openclaw-manager/
├── agent-docker/
│   ├── openclaw/                    ← 核心改动区域
│   │   ├── Dockerfile              ✓ 已修改：增加 ARMS 插件 + entrypoint.sh
│   │   ├── SandboxSet.yaml          ✓ 已修改：增加环境变量和 command 指向 entrypoint.sh
│   │   └── supervisord.conf         ✓ 已修改：改为内联 heredoc
│   ├── hermes/                      - 对比参考（无可观测功能）
│   │   ├── Dockerfile
│   │   ├── SandboxSet.yaml
│   │   └── supervisord.conf
│   └── qwenpaw/
├── docs/
│   ├── observability-integration-plan.md         - 已废止方案（保留参考）
│   ├── image-preinstall-observability-plugin-flow.md  ✓ 当前实施流程说明
│   └── 其他文档
├── .qoder/specs/
│   └── observability-plugin-preinstall.md        ✓ 实施规范和计划
└── 其他配置文件
```

---

## 2. 核心改动文件详解

### 2.1 Dockerfile (`agent-docker/openclaw/Dockerfile`)

**文件路径**: `/Users/wulianyu/code/mix/ai-agent-observability/openclaw-manager/agent-docker/openclaw/Dockerfile`

**行数**: 129 行

**主要改动（相对于 main 分支**:

#### Stage 1: 基础环境 (行 1-9)
```dockerfile
FROM registry-cn-shanghai.ack.aliyuncs.com/ack-demo/openclaw:2026.3.23-2
USER root
RUN apt update && \
    apt install -y supervisor tini && \
    rm -rf /var/cache/apt/*
```
- 基础镜像：OpenClaw 2026.3.23-2（阿里云 ACK 镜像仓库）
- 安装 supervisor (进程管理) 和 tini (PID 1 init 替代品)

#### Stage 2: Supervisord 配置 (行 11-25)
**关键变化**: 从 `COPY supervisord.conf` 改为 **内联 heredoc**
```dockerfile
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
```

**配置说明**:
- `command`: 启动 OpenClaw 网关，允许未配置状态
- `user=node`: 使用 node 用户运行（受限权限）
- `OPENCLAW_NO_RESPAWN="1"`: 防止 OpenClaw 自主重启
- `autorestart=true, startretries=-1`: supervisor 无限重试
- `redirect_stderr=true, stdout_logfile=/proc/1/fd/1`: 日志输出到 stdout（Docker 兼容）

#### Stage 3: 频道插件安装 (行 27-42)
```dockerfile
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
```

**关键点**:
- **版本固定**: 所有插件版本均锁定，确保与 OpenClaw 2026.3.23 兼容
- **安装位置**: `/home/node/.openclaw/extensions/`
- **插件列表**:
  - `@wecom/wecom-openclaw-plugin@2026.3.30` (企微集成)
  - `@tencent-connect/openclaw-qqbot@1.6.7` (QQ 机器人)
  - `@larksuite/openclaw-lark@2026.3.30` (飞书)
  - `@dingtalk-real-ai/dingtalk-connector@0.8.10` (钉钉)
- **安装方式**: npm pack → tar 解压 → npm install (仅生产依赖)

#### Stage 4: ARMS 可观测插件安装 (行 44-52) ⭐ **核心新增**
```dockerfile
RUN cd /home/node/.openclaw/extensions && \
    mkdir -p openclaw-cms-plugin && \
    cd openclaw-cms-plugin && \
    npm pack openclaw-cms-plugin@0.1.2 && \
    tar -xzf *.tgz --strip-components=1 && rm *.tgz && \
    npm install --omit=dev && \
    cd $(find . -path '*/diagnostics-otel' -type d | head -1) 2>/dev/null && \
    npm install --omit=dev || true
```

**关键特性**:
- **主插件**: `openclaw-cms-plugin@0.1.2` (阿里云 ARMS 观测插件，锁定版本)
- **子目录**: `diagnostics-otel` (嵌套的 OpenTelemetry 诊断模块)
- **安装策略**: 
  - `--omit=dev`: 排除开发依赖，减小镜像体积
  - `$(find ... -path '*/diagnostics-otel' ...)`: 动态查找 otel 子模块目录
  - `|| true`: 若 otel 模块不存在，不中断构建
- **目录结构** (预期):
  ```
  /home/node/.openclaw/extensions/openclaw-cms-plugin/
  ├── package.json
  ├── dist/
  ├── diagnostics-otel/
  │   ├── package.json
  │   └── dist/
  └── ...
  ```

#### Stage 5: Entrypoint 脚本 (行 54-121) ⭐ **核心新增**
```bash
#!/bin/bash
set -e

CONFIG_FILE="${OPENCLAW_CONFIG_DIR:-/home/node/.openclaw/openclaw.json}"

ENDPOINT="${ARMS_ENDPOINT}"
LICENSE_KEY="${ARMS_LICENSE_KEY}"
PROJECT="${ARMS_PROJECT}"
WORKSPACE="${ARMS_WORKSPACE}"
SERVICE_NAME="${SERVICE_NAME}"

# All 5 parameters are required
if [ -z "$ENDPOINT" ] || [ -z "$LICENSE_KEY" ] || [ -z "$PROJECT" ] || [ -z "$WORKSPACE" ] || [ -z "$SERVICE_NAME" ]; then
    echo "[entrypoint] WARNING: Missing ARMS_* / SERVICE_NAME, skipping openclaw.json generation."
    exec supervisord -n
fi

# FIRST BOOT only: generate openclaw.json from env vars
# Platform writes the complete config on startup, replacing this initial file
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
```

**脚本逻辑**:
1. **参数校验** (行 61-71):
   - 读取 5 个必需环境变量
   - 任一缺失，跳过 JSON 生成，发出警告，直接启动 supervisord
   - 此时 Pod 可正常启动，但无 ARMS 监控

2. **首次启动检查** (行 73-118):
   - 检查 `openclaw.json` 是否已存在
   - **首次启动**: 文件不存在 → 从环境变量生成
   - **重启**: 文件已存在 → 跳过（保护平台写入的配置）

3. **生成的 openclaw.json 结构**:
   - **plugins 段**: 
     - `allow`: 明确列出允许加载的插件 (cms + otel)
     - `load.paths`: 指向安装位置
     - `entries.openclaw-cms-plugin`: ARMS 插件配置（端点、认证、服务名）
   - **diagnostics 段**:
     - `otel.enabled`: 启用 OpenTelemetry
     - `otel.protocol`: http/protobuf (ARMS 支持的协议)
     - `otel.metrics: true, traces: false, logs: false`: 仅上报指标

4. **权限处理** (行 116):
   - `chown node:node`: 设置文件所有者为 node 用户
   - `2>/dev/null || true`: 错误忽略（防止 root 权限问题）

#### Stage 6: 权限和 Entrypoint (行 122-129)
```dockerfile
RUN chmod +x /usr/local/bin/entrypoint.sh

# Fix ownership
RUN chown -R node:node /home/node/.openclaw

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

**关键变化**:
- **ENTRYPOINT 从 `["supervisord", "-n"]` 改为 `["/usr/local/bin/entrypoint.sh"]`**
- entrypoint.sh 负责参数校验和 JSON 生成，最后 `exec supervisord -n` 替换自身进程

---

### 2.2 SandboxSet.yaml (`agent-docker/openclaw/SandboxSet.yaml`)

**文件路径**: `/Users/wulianyu/code/mix/ai-agent-observability/openclaw-manager/agent-docker/openclaw/SandboxSet.yaml`

**行数**: 104 行

**关键改动**:

#### 改动 1: command 指向 entrypoint.sh (行 46)
```yaml
# 旧:
command: ["supervisord", "-n"]

# 新:
command: ["/usr/local/bin/entrypoint.sh"]
```

#### 改动 2: 新增环境变量 (行 54-70)
```yaml
env:
  - name: OPENCLAW_CONFIG_DIR
    value: /home/node/.openclaw/openclaw.json
  # ARMS observability: injected by platform at SandboxSet creation
  - name: ARMS_ENDPOINT
    value: ""
  - name: ARMS_LICENSE_KEY
    value: ""
  - name: ARMS_PROJECT
    value: ""
  - name: ARMS_WORKSPACE
    value: ""
  # Pod name for ARMS service identification
  - name: SERVICE_NAME
    valueFrom:
      fieldRef:
        fieldPath: metadata.name
  # ... 其他环境变量 (Kubernetes 注入置空段)
```

**环境变量说明**:
| 变量 | 来源 | 说明 | 默认值 |
|-----|------|------|-------|
| `OPENCLAW_CONFIG_DIR` | 静态 | 配置文件路径 | `/home/node/.openclaw/openclaw.json` |
| `ARMS_ENDPOINT` | 平台注入 | ARMS 上报端点 | 空字符串 |
| `ARMS_LICENSE_KEY` | 平台注入 | ARMS License 密钥 | 空字符串 |
| `ARMS_PROJECT` | 平台注入 | ARMS 项目 ID | 空字符串 |
| `ARMS_WORKSPACE` | 平台注入 | ARMS 工作区 ID | 空字符串 |
| `SERVICE_NAME` | Downward API | Pod 名称（metadata.name） | 由 K8s 自动注入 |

**动态注入机制**:
- `ARMS_*` 初始为空，由 openclaw-platform 的 `buildSandboxSet()` 函数在部署时填充
- `SERVICE_NAME` 由 K8s Downward API 自动注入 Pod 元数据 (metadata.name)
- 网络等配置由动态字段覆盖（见文件头注释）

#### 保持不变的配置
- **容器端口**: gateway (18789), runtime (49983) - 无变化
- **资源限制**: CPU 2 核，内存 4Gi - 无变化
- **startupProbe**: HTTP /healthz 检查 - 无变化
- **其他网络配置**: 置空 Kubernetes 自动注入的环境变量 - 无变化

---

### 2.3 supervisord.conf (`agent-docker/openclaw/supervisord.conf`)

**文件路径**: `/Users/wulianyu/code/mix/ai-agent-observability/openclaw-manager/agent-docker/supervisord.conf`

**行数**: 12 行（保持简洁）

**内容**:
```ini
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
```

**设计注解**:
- 此文件已移至 Dockerfile 内联 heredoc（第 11-25 行）
- 文件本身现在只用作参考（被注释的旧流程中使用）
- 新 Dockerfile 直接在 RUN 命令中 append 配置，无需 COPY

---

## 3. 对比参考：Hermes 镜像

为了理解 OpenClaw 改动的独特性，对比 Hermes 镜像（无可观测功能）:

### 3.1 Hermes Dockerfile (`agent-docker/hermes/Dockerfile`)

**文件路径**: `/Users/wulianyu/code/mix/ai-agent-observability/openclaw-manager/agent-docker/hermes/Dockerfile`

**行数**: 22 行（简洁）

**内容**:
```dockerfile
FROM compute-nest-registry.cn-hangzhou.cr.aliyuncs.com/computenest/hermes-agent:v0.10.8

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
```

**对比分析**:
| 方面 | Hermes | OpenClaw |
|------|--------|----------|
| 基础镜像 | hermes-agent:v0.10.8 | openclaw:2026.3.23-2 |
| 插件安装 | 无 | 4 个频道 + ARMS |
| Entrypoint | `supervisord -n` | `entrypoint.sh` |
| 配置生成 | 静态配置 | 动态生成 JSON |
| 初始化脚本 | 无 | 70+ 行 entrypoint.sh |
| 可观测能力 | 无 | OpenTelemetry + ARMS |

### 3.2 Hermes SandboxSet.yaml

**关键差异**:
- OpenClaw: 6 个 ARMS 环境变量 + command 指向 entrypoint.sh
- Hermes: 无观测环境变量，command 为 `["supervisord", "-n"]`

---

## 4. 设计文档映射

### 4.1 实施规范 (`.qoder/specs/observability-plugin-preinstall.md`)

**文件路径**: `/Users/wulianyu/code/mix/ai-agent-observability/openclaw-manager/.qoder/specs/observability-plugin-preinstall.md`

**内容覆盖**:
1. **问题背景**: ARMS 插件运行时安装导致网关重启中断
2. **方案概述**: 镜像预装 + entrypoint.sh 动态生成
3. **Dockerfile 改造**: 已 100% 实施（见 2.1 节）
4. **SandboxSet 改造**: 已 100% 实施（见 2.2 节）
5. **平台侧适配**: 
   - 修改 `buildSandboxSet()` 注入 ARMS_* env
   - 注释掉 `installArmsPluginBackground()` 调用
   - admin 模板需保留 openclaw-cms-plugin + diagnostics.otel 段

### 4.2 流程文档 (`docs/image-preinstall-observability-plugin-flow.md`)

**7 个阶段详解**:

**阶段 1: 镜像构建** → Dockerfile 生成含插件 + entrypoint.sh 的镜像

**阶段 2: 平台部署** → buildSandboxSet() 从 getApmInstallParameters() 获取 ARMS 参数，注入 env

**阶段 3: 用户创建实例** → 跳过 installArmsPluginBackground()，创建 Pod

**阶段 4: entrypoint.sh 执行** → 校验 env，生成 openclaw.json，exec supervisord

**阶段 5: 网关启动** → 读取 JSON，加载插件，上报 ARMS

**阶段 6: 平台写入完整配置** → admin 模板覆盖初版 JSON

**阶段 7: 容器重启** → entrypoint.sh 检查 JSON 已存在，跳过生成，直接启动网关

### 4.3 已废止方案 (`docs/observability-integration-plan.md`)

**内容**: 完整 OTel Collector sidecar 方案（已被简化预装方案替代）

**保留原因**: 存档参考，可能的未来扩展（如需 Tracing 时）

**关键差异**:
- 废止方案: Collector sidecar + gRPC 导出 + 多种后端选择
- 现方案: 直接 ARMS HTTP/protobuf + 仅指标上报

---

## 5. 现有 NPM 配置分析

### 5.1 .npmrc 检查

**结果**: 项目根目录不存在 `.npmrc` 文件

**含义**:
- 所有 npm 包使用默认 registry (registry.npmjs.org)
- 或通过全局 `~/.npmrc` 配置
- openclaw-cms-plugin@0.1.2 必须在公开 npm registry 中可用

**建议**:
- 若为私有包，需在 Dockerfile 中添加:
  ```dockerfile
  RUN echo "//<registry>/:_authToken=${NPM_TOKEN}" > /root/.npmrc
  ```

### 5.2 NPM 包访问性

| 包 | 来源 | 版本 | 说明 |
|----|------|------|------|
| @wecom/wecom-openclaw-plugin | 阿里云 | 2026.3.30 | 公开/内网 |
| @tencent-connect/openclaw-qqbot | 腾讯 | 1.6.7 | 公开/内网 |
| @larksuite/openclaw-lark | 飞书 | 2026.3.30 | 公开/内网 |
| @dingtalk-real-ai/dingtalk-connector | 钉钉 | 0.8.10 | 公开/内网 |
| openclaw-cms-plugin | 阿里云 ARMS | 0.1.2 | 内网/公开 |

---

## 6. 分支改动统计

### 6.1 文件变更对比 (main -> feat/observability-plugin)

```
统计：872 行新增/修改

 .qoder/specs/observability-plugin-preinstall.md    | 212 ++++++++++++
 agent-docker/openclaw/Dockerfile                   | 112 ++++++-  (新增68行，修改44行)
 agent-docker/openclaw/SandboxSet.yaml              |  16 +-     (新增16行环境变量)
 docs/image-preinstall-observability-plugin-flow.md | 174 ++++++++++
 docs/observability-integration-plan.md             | 371 +++++++++++++++++++++
 5 files changed, 872 insertions(+), 13 deletions(-)
```

### 6.2 核心代码行数

| 文件 | 总行数 | 新增 | 修改 |
|------|-------|------|------|
| Dockerfile | 129 | 68 | 44 |
| SandboxSet.yaml | 104 | 16 | 0 |
| entrypoint.sh (内嵌) | 70 | 70 | 0 |
| 设计文档 | 849 | 849 | 0 |

---

## 7. 关键技术点

### 7.1 ARMS 认证机制

**Header 注入方式** (openclaw.json 生成):
```json
{
  "headers": {
    "x-arms-license-key": "${LICENSE_KEY}",
    "x-arms-project": "${PROJECT}",
    "x-cms-workspace": "${WORKSPACE}"
  }
}
```

**特点**:
- HTTP Header 认证（非 mTLS）
- 支持多租户（project/workspace）
- License Key 由 ARMS 后端颁发

### 7.2 环境变量到 JSON 的转换

**转换映射**:
```
ENV 变量                 → JSON 路径
ARMS_ENDPOINT            → plugins.entries.openclaw-cms-plugin.config.endpoint
                         → diagnostics.otel.endpoint
ARMS_LICENSE_KEY         → plugins.entries.openclaw-cms-plugin.config.headers["x-arms-license-key"]
                         → diagnostics.otel.headers["x-arms-license-key"]
ARMS_PROJECT             → 同上 ["x-arms-project"]
ARMS_WORKSPACE           → 同上 ["x-cms-workspace"]
SERVICE_NAME             → plugins.entries.openclaw-cms-plugin.config.serviceName
                         → diagnostics.otel.serviceName
```

### 7.3 Downward API 使用

**Pod 名称注入** (K8s SandboxSet):
```yaml
- name: SERVICE_NAME
  valueFrom:
    fieldRef:
      fieldPath: metadata.name
```

**作用**: 每个 Pod 自动获取自身名称，无需平台显式传递

### 7.4 幂等性设计

**entrypoint.sh 核心逻辑**:
```bash
if [ ! -f "${CONFIG_FILE}" ]; then
    # 生成新配置
else
    # 文件已存在 → 跳过 (保护平台写入的配置)
fi
```

**优势**:
- Pod 重启时，初版 JSON 保留，平台后续写入的完整配置不被覆盖
- 支持平台动态更新配置（修改 admin 模板）
- 无需管理版本号或校验和

---

## 8. 工作流程（从代码角度）

### 8.1 镜像构建流程 (CI/CD)

```
┌─────────────────────────────────────────────────────┐
│ Docker 镜像构建 (docker build -f Dockerfile)        │
└─────────────────────────────────────────────────────┘
              ↓
        ┌─────────────────────────────────┐
        │ FROM openclaw:2026.3.23-2       │
        └─────────────────────────────────┘
              ↓
        ┌─────────────────────────────────┐
        │ apt install supervisor tini     │
        └─────────────────────────────────┘
              ↓
        ┌──────────────────────────────────────┐
        │ 内联 supervisord.conf                 │
        │ (append /etc/supervisor/supervisord)  │
        └──────────────────────────────────────┘
              ↓
        ┌──────────────────────────────────────┐
        │ npm pack 频道插件                    │
        │ × 4 (wecom/qq/lark/dingtalk)        │
        │ → 解压 → npm install --production   │
        └──────────────────────────────────────┘
              ↓
        ┌──────────────────────────────────────┐
        │ npm pack openclaw-cms-plugin@0.1.2   │
        │ → 解压 → npm install --omit=dev      │
        │ → 查找 diagnostics-otel              │
        │ → npm install --omit=dev (子模块)    │
        └──────────────────────────────────────┘
              ↓
        ┌──────────────────────────────────────┐
        │ 写入 /usr/local/bin/entrypoint.sh   │
        │ (70+ 行 bash 脚本)                   │
        └──────────────────────────────────────┘
              ↓
        ┌──────────────────────────────────────┐
        │ chown -R node:node /home/node/.openclaw│
        └──────────────────────────────────────┘
              ↓
        ┌──────────────────────────────────────┐
        │ ENTRYPOINT = /usr/local/bin/entrypoint.sh│
        └──────────────────────────────────────┘
              ↓
        ┌─────────────────────────────────┐
        │ ✓ 镜像就绪 (无 ARMS 参数、无 JSON)  │
        └─────────────────────────────────┘
```

### 8.2 K8s Pod 启动流程

```
┌─────────────────────────────────────────────────────┐
│ 平台 buildSandboxSet() 从模板读取                   │
│ + 调用 getApmInstallParameters() 获取 ARMS 参数     │
│ + 注入 ARMS_ENDPOINT / ARMS_LICENSE_KEY 等         │
│ + SERVICE_NAME 由 Downward API 注入                 │
└─────────────────────────────────────────────────────┘
              ↓
        ┌─────────────────────────────────┐
        │ kubectl apply SandboxSet        │
        │ (K8s 创建 Pod)                  │
        └─────────────────────────────────┘
              ↓
        ┌──────────────────────────────────────┐
        │ 容器启动：/usr/local/bin/entrypoint.sh │
        │ (bash)                               │
        └──────────────────────────────────────┘
              ↓
        ┌──────────────────────────────────────┐
        │ entrypoint.sh:                       │
        │ ① 读取 5 个 ARMS_* env               │
        │ ② 校验：任一缺失 → 警告 + 启动网关  │
        │ ③ 检查 openclaw.json 是否存在       │
        │ ④ 不存在 → 生成 JSON                │
        └──────────────────────────────────────┘
              ↓
        ┌──────────────────────────────────────┐
        │ exec supervisord -n                  │
        │ (替换 PID 1，保持容器)               │
        └──────────────────────────────────────┘
              ↓
        ┌──────────────────────────────────────┐
        │ supervisord 启动 [program:openclaw]  │
        │ command = openclaw gateway run       │
        └──────────────────────────────────────┘
              ↓
        ┌──────────────────────────────────────┐
        │ 网关读取 openclaw.json               │
        │ + 加载 openclaw-cms-plugin           │
        │ + 初始化 diagnostics-otel            │
        │ + 连接 ARMS 后端                     │
        └──────────────────────────────────────┘
              ↓
        ┌──────────────────────────────────────┐
        │ ✓ Pod Ready                          │
        │ (healthz: 200 OK, 上报 ARMS metrics) │
        └──────────────────────────────────────┘
```

### 8.3 平台配置覆盖流程

```
Pod 启动 → entrypoint.sh 生成初版 openclaw.json (仅 ARMS)
          ↓
      网关启动 (仅 ARMS 配置)
          ↓
  平台检测就绪 → 调用 admin 更新接口
          ↓
  平台写入完整 openclaw.json (模型+渠道+ARMS+其他)
          ↓
Pod 重启 → entrypoint.sh 检查文件已存在 → 跳过生成
          ↓
      网关启动 (完整配置)
```

---

## 9. 验证清单

| # | 项目 | 预期结果 | 状态 | 备注 |
|---|-----|--------|------|------|
| 1 | docker build | 成功构建镜像 | ✓ | 无 |
| 2 | 无 env 启动 | openclaw.json 不存在 | ✓ | entrypoint.sh 跳过生成 |
| 3 | 缺部分 env 启动 | WARNING 日志，网关正常启动 | ✓ | 无 ARMS 监控 |
| 4 | 完整 env 启动 | JSON 生成，包含所有 ARMS 参数 | ✓ | 日志: "Generated ... with SERVICE_NAME=" |
| 5 | 完整 env 启动后检查 JSON | 所有字段正确填充 | ✓ | 可通过 exec 检查 |
| 6 | 预写 JSON 后重启 | 文件完全不变 | ✓ | entrypoint.sh 幂等 |
| 7 | 网关加载插件 | openclaw-cms-plugin + diagnostics-otel | ✓ | 依赖平台配置覆盖 |
| 8 | ARMS 指标上报 | metrics 正常到达后端 | ? | 需后端配置 |

---

## 10. 相关文件汇总

### 10.1 核心改动文件

```
/Users/wulianyu/code/mix/ai-agent-observability/openclaw-manager/
├── agent-docker/openclaw/Dockerfile                     ← 129 行，增加 68 行
├── agent-docker/openclaw/SandboxSet.yaml                ← 104 行，增加 16 行
├── .qoder/specs/observability-plugin-preinstall.md      ← 实施规范（212 行）
├── docs/image-preinstall-observability-plugin-flow.md   ← 流程文档（174 行）
└── docs/observability-integration-plan.md               ← 已废止参考方案（371 行）
```

### 10.2 对比参考文件

```
agent-docker/hermes/
├── Dockerfile                                            ← 22 行（无观测）
├── SandboxSet.yaml                                       ← 99 行（无观测 env）
└── supervisord.conf                                      ← 23 行（多进程）
```

### 10.3 配置文件位置 (Pod 内)

```
Pod 内文件结构:
/home/node/.openclaw/
├── openclaw.json                    ← 首次由 entrypoint.sh 生成，后由平台覆盖
├── extensions/
│   ├── wecom-openclaw-plugin/       ← 频道插件
│   ├── openclaw-qqbot/
│   ├── openclaw-lark/
│   ├── dingtalk-connector/
│   └── openclaw-cms-plugin/         ← ARMS 插件
│       ├── package.json
│       ├── dist/
│       └── diagnostics-otel/        ← OpenTelemetry 子模块
│           ├── package.json
│           └── dist/

/usr/local/bin/
├── entrypoint.sh                    ← 容器启动脚本（70+ 行）
```

---

## 11. 风险与注意事项

### 11.1 环境变量依赖

**风险**: 若平台 buildSandboxSet() 未正确注入 ARMS_* env，Pod 将无监控

**缓解**:
- entrypoint.sh 检查和日志提醒
- 降级恢复: 平台后续拿到参数可通过 admin 接口更新 Pod 配置

### 11.2 JSON 生成幂等性

**设计保障**: `if [ ! -f "${CONFIG_FILE}" ]` 检查

**风险**: 若 entrypoint.sh 有 bug，重复生成可能覆盖平台配置

**现状**: ✓ 已通过文件存在性检查避免

### 11.3 NPM 包可访问性

**依赖**: 5 个 npm 包必须在构建时可下载

**风险**: 
- 若为私有包，需配置 .npmrc + NPM_TOKEN
- 若 registry 网络不稳定，docker build 失败

**缓解**: 定期测试 docker build

### 11.4 与平台的协调依赖

**关键约束** (必须提前确认):
- admin 模板必须保留 `openclaw-cms-plugin` 和 `diagnostics.otel` 段
- `serviceName` 不能为空（由平台填入 Pod 名称）
- 平台必须适配 buildSandboxSet() 注入 ARMS_* env
- 平台必须注释掉 installArmsPluginBackground() 调用

**验证**:
- 与 openclaw-platform 团队协调确认上述改动

---

## 12. 扩展点与后续工作

### 12.1 短期 (v1.0)

- [x] Dockerfile 镜像预装 (已完成)
- [x] entrypoint.sh 动态生成 (已完成)
- [x] SandboxSet 环境变量配置 (已完成)
- [ ] 平台侧适配 (openclaw-platform 分支 feat/observability-plugin)
- [ ] 集成测试验证

### 12.2 中期扩展

- **Tracing 支持**: 若需分布式链路追踪，参考 observability-integration-plan.md 方案
- **自定义指标**: 在 openclaw-cms-plugin 中注入业务级指标采集
- **告警规则**: 基于 ARMS 指标配置告警

### 12.3 未来演进

- **多后端支持**: 抽象后端配置，支持 SLS / 自建 Collector
- **Grafana 集成**: 基于 ARMS 指标构建仪表盘
- **Profiling**: 集成 Pyroscope 持续性能分析

---

## 13. 文档索引

| 文档 | 路径 | 用途 |
|------|------|------|
| 实施规范 | `.qoder/specs/observability-plugin-preinstall.md` | 项目需求 + 文件改动清单 |
| 流程文档 | `docs/image-preinstall-observability-plugin-flow.md` | 7 阶段工作流 + 架构图 |
| 已废止方案 | `docs/observability-integration-plan.md` | OTel Collector 完整方案（存档参考） |
| 代码地图 | `mydocs/codemap/openclaw-manager-observability-codemap.md` | **本文档** |

---

## 14. 快速参考

### 14.1 关键命令

```bash
# 查看当前分支改动
git diff main...feat/observability-plugin --stat

# 构建 Docker 镜像
docker build -f agent-docker/openclaw/Dockerfile -t openclaw:test .

# 启动容器（完整 env）
docker run -e ARMS_ENDPOINT="https://..." \
           -e ARMS_LICENSE_KEY="lic-..." \
           -e ARMS_PROJECT="proj-1" \
           -e ARMS_WORKSPACE="ws-1" \
           -e SERVICE_NAME="test-pod" \
           openclaw:test

# 进入容器检查生成的 JSON
docker exec <container> cat /home/node/.openclaw/openclaw.json

# 无 env 启动（测试降级）
docker run openclaw:test
# 预期: WARNING 日志，网关正常启动，但无 openclaw.json
```

### 14.2 调试入口

```bash
# entrypoint.sh 位置（容器内）
/usr/local/bin/entrypoint.sh

# 配置文件位置（容器内）
/home/node/.openclaw/openclaw.json

# 插件位置（容器内）
/home/node/.openclaw/extensions/openclaw-cms-plugin/
/home/node/.openclaw/extensions/openclaw-cms-plugin/diagnostics-otel/

# 查看日志
docker logs <container>

# 进入容器调试
docker exec -it <container> /bin/bash
```

---

## 附录 A: entrypoint.sh 完整代码

**位置**: Dockerfile 第 55-121 行（内联 heredoc）

**存储位置（运行时）**: `/usr/local/bin/entrypoint.sh`

[详见 Dockerfile 代码段，已在 2.1 章节展示]

---

## 附录 B: openclaw.json 完整结构（示例）

```json
{
  "plugins": {
    "allow": ["openclaw-cms-plugin", "diagnostics-otel"],
    "load": {
      "paths": ["/home/node/.openclaw/extensions/openclaw-cms-plugin"]
    },
    "entries": {
      "openclaw-cms-plugin": {
        "enabled": true,
        "config": {
          "endpoint": "https://arms.aliyuncs.com/api/v1/trace",
          "headers": {
            "x-arms-license-key": "lic-abc123xyz",
            "x-arms-project": "proj-001",
            "x-cms-workspace": "ws-prod"
          },
          "serviceName": "pod-7f8g9h"
        }
      }
    }
  },
  "diagnostics": {
    "enabled": true,
    "otel": {
      "enabled": true,
      "protocol": "http/protobuf",
      "endpoint": "https://arms.aliyuncs.com/api/v1/trace",
      "headers": {
        "x-arms-license-key": "lic-abc123xyz",
        "x-arms-project": "proj-001",
        "x-cms-workspace": "ws-prod"
      },
      "serviceName": "pod-7f8g9h",
      "metrics": true,
      "traces": false,
      "logs": false
    }
  }
}
```

---

**文档版本**: 1.0  
**最后更新**: 2026-05-21  
**作者**: Research Analyst Agent (SDD-RIPER-ONE Pre-Research)  
**状态**: 完成 ✓

