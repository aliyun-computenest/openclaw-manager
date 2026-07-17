# 镜像预装可观测插件 — 完整流程

> 分支：`feat/observability-plugin`
> 方案详情：[specs/observability-plugin-preinstall.md](specs/observability-plugin-preinstall.md)

---

## 阶段 1：镜像构建

```
Dockerfile（本仓库 agent-docker/openclaw/Dockerfile）
  │
  ├─ FROM 基础镜像 (openclaw:2026.3.23-2)
  ├─ apt install supervisor + tini
  ├─ 写入 supervisord.conf（内联 heredoc）
  ├─ npm pack 频道插件（企微/QQ/飞书/钉钉）→ 解压 → npm install
  ├─ npm pack openclaw-cms-plugin@0.1.2 → 解压 → npm install
  │   └─ cd diagnostics-otel/ → npm install
  ├─ 写入 /usr/local/bin/entrypoint.sh（内联 heredoc）
  ├─ chown node:node
  └─ ENTRYPOINT = /usr/local/bin/entrypoint.sh
```

**产出**：一个通用镜像，含频道插件 + ARMS 插件 + entrypoint.sh。镜像里**没有** ARMS 参数，**没有** openclaw.json。

---

## 阶段 2：平台部署 SandboxSet

```
openclaw-platform 部署时
  │
  └─ buildSandboxSet()
       ├─ 读取 SandboxSet.yaml 模板
       ├─ 调用 getApmInstallParameters() 获取 ARMS 参数
       │    → endpoint, licenseKey, project, workspace
       ├─ 把参数填入 env 段
       │    ARMS_ENDPOINT   = "https://xxx/apm/trace/opentelemetry"
       │    ARMS_LICENSE_KEY = "lic-abc"
       │    ARMS_PROJECT     = "proj-1"
       │    ARMS_WORKSPACE   = "ws-1"
       └─ 写入 K8s（创建 SandboxSet 资源）
```

此时 K8s 中有一个 SandboxSet 模板，`command` 指向 entrypoint.sh，`env` 中 5 个变量已就绪（SERVICE_NAME 由 Downward API 自动填）。

---

## 阶段 3：用户创建实例 → Pod 启动

```
用户点击"创建"
  │
  └─ instance-provisioner.js
       ├─ 创建实例记录
       ├─ ~~installArmsPluginBackground()~~   ← 已注释掉
       └─ Sandbox.create() → K8s 按模板创建 Pod

K8s 创建 Pod
  │
  ├─ Downward API 注入 SERVICE_NAME = metadata.name（如 "pod-7f8g9h"）
  ├─ 容器环境变量就绪：
  │    ARMS_ENDPOINT   = "https://xxx/apm/trace/opentelemetry"
  │    ARMS_LICENSE_KEY = "lic-abc"
  │    ARMS_PROJECT     = "proj-1"
  │    ARMS_WORKSPACE   = "ws-1"
  │    SERVICE_NAME     = "pod-7f8g9h"
  │
  └─ 容器运行时拉起进程：/usr/local/bin/entrypoint.sh
```

---

## 阶段 4：entrypoint.sh 执行

```bash
#!/bin/bash
# 5 个 env 变量已在进程环境中，无需 fetch

# ① 校验：任一缺失则跳过，网关照样启动（无 ARMS 监控）
if [ -z "$ARMS_ENDPOINT" ] || ... ; then
    echo WARNING → exec supervisord -n
fi

# ② 首次启动：openclaw.json 不存在
if [ ! -f "/home/node/.openclaw/openclaw.json" ]; then
    # 从 env 生成 openclaw.json
    #   ├─ plugins.entries.openclaw-cms-plugin.config → endpoint/headers/serviceName
    #   └─ diagnostics.otel → endpoint/headers/serviceName
    heredoc > openclaw.json
    chown node:node
fi

# ③ 替换当前进程为 supervisord（保持 PID 1）
exec supervisord -n
```

---

## 阶段 5：OpenClaw 网关启动

```
supervisord（PID 1）
  │
  └─ [program:openclaw]
       command=openclaw gateway run --allow-unconfigured
       ↓
       网关读取 openclaw.json
       ↓
       加载 openclaw-cms-plugin + diagnostics-otel
       ↓
       开始向 ARMS 上报指标（serviceName=pod-7f8g9h）
       ↓
       用户发起对话，正常使用
```

---

## 阶段 6：平台写入完整配置

```
平台检测到网关就绪
  │
  └─ 用 admin 模板覆盖 openclaw.json
       （含模型配置、渠道配置、ARMS 配置段）
       ↓
       openclaw.json：初版 ARMS-only → 完整版
```

---

## 阶段 7：容器重启

```
Pod 重启（Pod 名称不变，"pod-7f8g9h"）
  │
  └─ entrypoint.sh 再次执行
       ├─ 检查 openclaw.json → 已存在
       └─ 跳过，直接 exec supervisord -n
            ↓
            网关用平台写入的完整配置直接启动
```

---

## 一图总结

```
镜像构建            平台部署              用户创建实例          Pod 启动             网关运行
   │                  │                    │                    │                    │
   ▼                  ▼                    ▼                    ▼                    ▼
┌──────┐         ┌──────────┐         ┌──────────┐         ┌──────────┐         ┌──────────┐
│Docker │  ──→   │SandboxSet│  ──→    │创建 Pod  │  ──→    │entrypoint│  ──→    │openclaw  │
│build  │        │注入 ARMS │         │env 注入  │         │.sh 生成  │         │gateway   │
│插件+脚本│       │env 到模板│         │SERVICE   │         │JSON      │         │读取JSON  │
│零参数  │        │          │         │_NAME     │         │→supervisord│       │上报ARMS  │
└──────┘         └──────────┘         └──────────┘         └──────────┘         └──────────┘
                                                                                     │
                                                                         平台写 admin 模板覆盖
```

---

## 与原流程对比

| | 原流程（无可观测） | 新流程（预装可观测） |
|---|---|---|
| 镜像内容 | 基础 + supervisor + 频道插件 | + ARMS 插件 + entrypoint.sh |
| ENTRYPOINT | `supervisord -n` | `entrypoint.sh` |
| 容器启动 | 网关直接跑 | entrypoint.sh 生成 JSON → 网关跑 |
| 实例创建 | 正常 | 跳过 installArmsPluginBackground |
| 重启 | 网关重启 | entrypoint.sh 跳过，网关直接重启 |

**核心变化**：镜像多了一个插件和一个 70 行脚本，Pod 启动时多花 <1 秒生成一份 JSON。其余完全不变。
