# OpenTelemetry 可观测插件集成方案（已废止，保留参考）

> 分支：`feat/observability-plugin`
> 目标：为 Agent Manager 的 OpenClaw 代理容器注入 OpenTelemetry 可观测能力（Tracing + Metrics + Logging）
>
> **注**：本方案已被 `specs/observability-plugin-preinstall.md` 替代。仅保留 OpenClaw 部分供参考。

---

## 1. 架构总览

```
┌─────────────────────────────────────────────────────────────┐
│                     Agent Sandbox (K8s Pod)                  │
│                                                              │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────────────┐ │
│  │  OpenClaw    │  │  OTel        │  │  OTel Collector    │ │
│  │  Gateway     │──│  SDK (Auto)  │──│  (Sidecar 进程)    │ │
│  └──────────────┘  └──────────────┘  └─────────┬──────────┘ │
│                                                 │            │
│                                          supervisord 管理   │
└─────────────────────────────────────────────────┼───────────┘
                                                  │
                            ┌─────────────────────┼──────────┐
                            │     OTEL_EXPORTER_OTLP_ENDPOINT │
                            │     阿里云 SLS / ARMS / 自建   │
                            └─────────────────────────────────┘
```

**核心思路**：不改动 agent 源码，在容器构建时注入 OTEL SDK 并启动 Collector sidecar，由 supervisord 统一管理生命周期。

---

## 2. 组件说明

### 2.1 OTEL SDK 自动注入（Agent 侧）

| Agent 类型 | 运行时 | 注入方式 |
|-----------|--------|---------|
| OpenClaw | Node.js | `--require @opentelemetry/auto-instrumentations-node/register` |

SDK 负责自动采集：
- **Tracing**: HTTP/gRPC 请求链路、数据库查询、消息队列
- **Metrics**: HTTP 请求数/延迟、内存/CPU 使用率、GC 统计

### 2.2 OTEL Collector Sidecar（收集端）

作为 supervisord 管理的进程运行，负责：
- **接收** agent 发来的 OTLP 数据（gRPC `:4317`）
- **处理** batch、memory_limiter 等 processor
- **导出** 到指定的后端（SLS / ARMS / 自建）

### 2.3 后端对接（导出目标）

| 方案 | 适用场景 | 配置难度 |
|------|---------|---------|
| **阿里云 SLS（日志服务）** | 团队已有 SLS，日志+指标统一管理 | 低 |
| **阿里云 ARMS（应用实时监控）** | 需要完整的 APM 能力 | 中 |
| **自建 OTel Collector** | 私有化部署，数据不回传云 | 高 |

---

## 3. 配置体系

所有可观测配置通过环境变量注入，无需修改代码。

```bash
# ---- 导出端点 ----
OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4317   # OTLP gRPC 地址（指向本地 Collector）
OTEL_EXPORTER_OTLP_PROTOCOL=grpc

# ---- 服务标识 ----
OTEL_SERVICE_NAME=openclaw-agent-instance-{INSTANCE_ID}
OTEL_RESOURCE_ATTRIBUTES=service.namespace=openclaw,instance.id={INSTANCE_ID}

# ---- 采样策略 ----
OTEL_TRACES_SAMPLER=parentbased_traceidratio
OTEL_TRACES_SAMPLER_ARG=0.1                             # 10% 采样率（可调）

# ---- 指标 ----
OTEL_METRICS_EXPORTER=otlp
OTEL_METRIC_EXPORT_INTERVAL=15000                        # 15s 上报间隔
```

---

## 4. Dockerfile 改造

### 4.1 OpenClaw Dockerfile

在现有 Dockerfile 的基础上新增以下阶段：

```dockerfile
# ====== 新增：安装 OTEL Collector ======
ARG OTELCOL_VERSION=0.102.0
RUN ARCH=$(uname -m) && \
    case "$ARCH" in \
      aarch64) ARCH="arm64" ;; \
      x86_64)  ARCH="amd64" ;; \
    esac && \
    curl -Lo /tmp/otelcol.tar.gz \
      "https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v${OTELCOL_VERSION}/otelcol_${OTELCOL_VERSION}_linux_${ARCH}.tar.gz" && \
    tar -xzf /tmp/otelcol.tar.gz -C /usr/local/bin otelcol && \
    rm /tmp/otelcol.tar.gz

# ====== 新增：安装 Node.js OTEL 自动注入包 ======
RUN npm install -g \
    @opentelemetry/api \
    @opentelemetry/auto-instrumentations-node \
    @opentelemetry/sdk-node \
    @opentelemetry/exporter-trace-otlp-grpc \
    @opentelemetry/exporter-metrics-otlp-grpc \
    @opentelemetry/exporter-logs-otlp-grpc

# ====== 新增：OTel Collector 配置 ======
COPY agent-docker/openclaw/otelcol-config.yaml /etc/otelcol/config.yaml

# ====== 新增：supervisord 中追加 oTelCollector 进程 ======
COPY agent-docker/openclaw/supervisord-otel.conf /tmp/supervisord-otel.conf
RUN cat /tmp/supervisord-otel.conf >> /etc/supervisor/supervisord.conf && \
    rm /tmp/supervisord-otel.conf
```

### 4.2 OpenClaw supervisord 新增进程

```ini
[program:otel-collector]
command=/usr/local/bin/otelcol --config=/etc/otelcol/config.yaml
user=root
redirect_stderr=true
stdout_logfile=/proc/1/fd/1
stdout_logfile_maxbytes=0
autorestart=true
startretries=-1
```

修改 agent 启动命令（OpenClaw）以注入 OTEL SDK：

```ini
[program:openclaw]
command=openclaw gateway run --allow-unconfigured
user=node
environment=HOME="/home/node",
    OPENCLAW_NO_RESPAWN="1",
    NODE_OPTIONS="--require @opentelemetry/auto-instrumentations-node/register",
    OTEL_SERVICE_NAME="openclaw-agent",
    OTEL_EXPORTER_OTLP_ENDPOINT="http://127.0.0.1:4317",
    OTEL_EXPORTER_OTLP_PROTOCOL="grpc",
    OTEL_TRACES_SAMPLER="parentbased_traceidratio",
    OTEL_TRACES_SAMPLER_ARG="0.1",
    OTEL_METRICS_EXPORTER="otlp",
    OTEL_LOGS_EXPORTER="otlp",
    OTEL_RESOURCE_ATTRIBUTES="service.namespace=openclaw"
redirect_stderr=true
stdout_logfile=/proc/1/fd/1
stdout_logfile_maxbytes=0
autorestart=true
startretries=-1
stopasgroup=true
killasgroup=true
```

### 4.3 OTEL Collector 配置文件模板

```yaml
# agent-docker/openclaw/otelcol-config.yaml
receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
      http:
        endpoint: 0.0.0.0:4318

processors:
  batch:
    timeout: 5s
    send_batch_size: 512
  memory_limiter:
    check_interval: 1s
    limit_mib: 256
    spike_limit_mib: 64
  resource:
    attributes:
      - key: deployment.environment
        value: "${DEPLOY_ENV}"
        action: upsert
      - key: instance.id
        value: "${INSTANCE_ID}"
        action: upsert

extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  pprof:
    endpoint: 0.0.0.0:1777

exporters:
  # 方案 A: 阿里云 SLS
  # otlp/sls:
  #   endpoint: ${OTEL_EXPORTER_OTLP_ENDPOINT}
  #   headers:
  #     "x-sls-otel-project": "${SLS_PROJECT}"
  #     "x-sls-otel-instance-id": "${SLS_INSTANCE}"
  #     "x-sls-otel-ak-id": "${SLS_AK_ID}"
  #     "x-sls-otel-ak-secret": "${SLS_AK_SECRET}"
  #   tls:
  #     insecure: false

  # 方案 B: 通用 OTLP 导出（调试用）
  debug:
    verbosity: basic

  # 方案 C: 标准 OTLP 导出到自建后端
  otlp:
    endpoint: "${OTEL_BACKEND_ENDPOINT:http://otlp-backend:4317}"
    tls:
      insecure: true

  # 日志输出到 stdout（兼容现有日志流水线）
  logging:
    loglevel: info

service:
  extensions: [health_check, pprof]
  pipelines:
    traces:
      receivers: [otlp]
      processors: [memory_limiter, batch, resource]
      exporters: [otlp, debug]
    metrics:
      receivers: [otlp]
      processors: [memory_limiter, batch, resource]
      exporters: [otlp]
    logs:
      receivers: [otlp]
      processors: [memory_limiter, batch, resource]
      exporters: [otlp, logging]
```

---

## 5. SandboxSet 改造（K8s 层面）

### 5.1 新增环境变量

在 `SandboxSet.yaml` 中为容器注入可观测相关环境变量：

```yaml
env:
  # 可观测配置（新增）
  - name: OTEL_EXPORTER_OTLP_ENDPOINT
    value: "http://127.0.0.1:4317"
  - name: OTEL_SERVICE_NAME
    value: "openclaw-agent"
  - name: DEPLOY_ENV
    value: "production"
  - name: INSTANCE_ID
    valueFrom:
      fieldRef:
        fieldPath: metadata.uid
```

### 5.2 新增容器端口

```yaml
ports:
  # 可观测端口（新增）
  - name: otlp-grpc
    containerPort: 4317
    protocol: TCP
  - name: otlp-http
    containerPort: 4318
    protocol: TCP
  - name: otel-health
    containerPort: 13133
    protocol: TCP
```

### 5.3 健康检查增强

可以在现有 startupProbe 之外增加 readinessProbe：

```yaml
readinessProbe:
  httpGet:
    path: /
    port: 13133
  initialDelaySeconds: 5
  periodSeconds: 10
```

---

## 6. 可观测指标清单

### 6.1 自动采集指标（无需编码）

| 类别 | 指标 | 说明 |
|------|------|------|
| **HTTP 服务** | `http_server_duration_ms` | 请求延迟分布 (P50/P90/P99) |
| | `http_server_request_count` | 请求总数 |
| | `http_server_active_requests` | 当前并发请求数 |
| **HTTP 客户端** | `http_client_duration_ms` | 外部调用延迟 |
| | `http_client_request_count` | 外部调用次数 |
| **Node.js 运行时** | `nodejs_eventloop_delay` | Event Loop 延迟 |
| | `nodejs_heap_memory_used` | 堆内存使用 |
| | `nodejs_gc_duration` | GC 耗时 |
| **进程** | `process_cpu_usage` | CPU 使用率 |
| | `process_memory_usage` | 进程内存 |

### 6.2 建议补充的自定义指标

| 指标 | 说明 | 优先级 |
|------|------|--------|
| `agent.chat_request_count` | Agent 对话请求数 | 高 |
| `agent.chat_response_duration` | Agent 响应延迟 | 高 |
| `agent.model_invoke_count` | 模型调用次数 | 高 |
| `agent.model_invoke_error_count` | 模型调用错误次数 | 高 |
| `agent.channel_message_count` | 各渠道消息数（企微/QQ/飞书/钉钉） | 中 |
| `agent.plugin_error_count` | 插件错误次数 | 中 |

---

## 7. 文件变更清单

```
agent-docker/
├── openclaw/
│   ├── Dockerfile                    # [修改] 新增 OTEL SDK + Collector 安装
│   ├── supervisord.conf              # [修改] 原有 agent 配置（不再改动此文件）
│   ├── supervisord-otel.conf         # [新增] OTEL Collector + 注入的 agent 配置
│   ├── otelcol-config.yaml           # [新增] Collector 管道配置
│   └── SandboxSet.yaml              # [修改] 新增环境变量和端口
└── shared/
    └── otelcol-config.yaml           # [新增] 共享 Collector 配置模板
```

> **设计原则**：通过新增 `supervisord-otel.conf` 而非修改原有 `supervisord.conf`，保持向后兼容。平台可以选择是否启用可观测能力。

---

## 8. 实施步骤

| 阶段 | 步骤 | 产出 |
|------|------|------|
| **Phase 1: 基础设施** | 1. 确定 OTEL 后端（SLS/ARMS/自建）<br>2. 确认 Collector 版本<br>3. 确认网络连通性 | 后端目标地址 |
| **Phase 2: 容器改造** | 4. 修改 OpenClaw Dockerfile<br>5. 新增 `supervisord-otel.conf`<br>6. 新增 `otelcol-config.yaml` | 可构建的 Dockerfile |
| **Phase 3: K8s 配置** | 8. 修改 SandboxSet 环境变量<br>9. 新增可观测端口定义<br>10. 新增健康检查 | 可部署的 K8s 清单 |
| **Phase 4: 验证** | 11. 本地 Docker 构建测试<br>12. 测试环境部署<br>13. 验证 Traces/Metrics/Logs 数据到达后端<br>14. 压测验证性能开销 | 验证报告 |
| **Phase 5: 文档** | 15. 更新部署文档<br>16. 编写可观测配置说明 | 用户文档 |

---

## 9. 性能影响评估

| 项目 | 预估开销 | 缓解措施 |
|------|---------|---------|
| Collector 内存 | ~50-100 MB | memory_limiter 限制 256MB |
| Collector CPU | ~0.05-0.1 core | 仅在 agent 空闲时几乎无开销 |
| SDK 注入延迟 | <1ms per request | 采样率控制（默认 10%） |
| 网络带宽 | ~50-200 KB/s | batch processor 合并上报 |

---

## 10. 后续扩展

- **Grafana 仪表盘**：基于采集的指标构建 agent 健康面板
- **告警规则**：基于 PromQL/Prometheus 规则的 agent 异常告警
- **Profiling**：集成 Pyroscope 实现持续性能分析
- **分布式链路上下文传递**：agent → platform API 的端到端链路串联
