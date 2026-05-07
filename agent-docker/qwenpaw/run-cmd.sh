#!/bin/bash
# run-cmd.sh — Agent Manager 平台对 QwenPaw 做模型配置增量修改的入口脚本。
#
# 三件事，按顺序：
#   1. seed 三个默认 provider 模板到 /app/working.secret/providers/{builtin,custom}/
#      （emptyDir 卷会盖掉镜像里的预置文件，所以模板放 /opt/qwenpaw-providers/，
#       运行时再 cp 过来。已存在的不动，避免覆盖用户改动。）
#   2. 把"平台 provider name → qwenpaw 内部 provider id"映射到正确的 JSON 文件，
#      只覆写 platform 托管字段（id / api_key / base_url?），保留 models 等。
#   3. 写 active_model.json —— qwenpaw 真正读这个文件来决定"激活哪个模型"，
#      不是 config.json 的 llm_routing.local。

set -euo pipefail

PROVIDERS_ROOT="${QWENPAW_PROVIDERS_ROOT:-/app/working.secret/providers}"
SEED_DIR="${QWENPAW_SEED_DIR:-/opt/qwenpaw-providers}"
SUPERVISOR_PROGRAM="${QWENPAW_SUPERVISOR_PROGRAM:-app}"

# 平台 name → (相对路径, qwenpaw id, 是否覆盖 base_url)
# dashscope 在 qwenpaw 侧 freeze_url=true，端点固定，平台只能注 api_key。
declare -A PROVIDER_MAP=(
    [bailian]="builtin/dashscope.json|dashscope|0"
    [api_gateway]="custom/aliyun-ai-gateway.json|aliyun-ai-gateway|1"
    [litellm]="custom/litellm.json|litellm|1"
)

# ---------------------------------------------------------------------------
seed_providers() {
    mkdir -p "$PROVIDERS_ROOT/builtin" "$PROVIDERS_ROOT/custom"
    [ -d "$SEED_DIR" ] || { echo "skip seed: $SEED_DIR not found" >&2; return 0; }
    find "$SEED_DIR" -type f -name '*.json' | while read -r src; do
        dst="$PROVIDERS_ROOT/${src#${SEED_DIR}/}"
        [ -e "$dst" ] && continue
        mkdir -p "$(dirname "$dst")"
        cp -f "$src" "$dst"
        echo "seeded: $dst"
    done
}

# ---------------------------------------------------------------------------
restart_app() {
    if command -v supervisorctl >/dev/null 2>&1; then
        supervisorctl restart "$SUPERVISOR_PROGRAM" \
            || echo "warn: failed to restart $SUPERVISOR_PROGRAM" >&2
    else
        echo "warn: supervisorctl not found; please restart container manually" >&2
    fi
}

# ---------------------------------------------------------------------------
# modify-model <platform_provider> <model> <base_url> [<api_key>]
# api_key 优先从 _QWENPAW_API_KEY 环境变量读，避免出现在 ps/argv。
# ---------------------------------------------------------------------------
modify_model() {
    local platform="${1:-}" model="${2:-}" base_url="${3:-}"
    local api_key="${_QWENPAW_API_KEY:-${4:-}}"

    [ -n "$platform" ] && [ -n "$model" ] || {
        echo "Usage: run-cmd.sh modify-model <platform_provider> <model> <base_url> <api_key>" >&2
        exit 1
    }

    local entry="${PROVIDER_MAP[$platform]:-}"
    [ -n "$entry" ] || {
        echo "Error: unknown platform provider '$platform'. Supported: ${!PROVIDER_MAP[*]}" >&2
        exit 2
    }

    IFS='|' read -r rel_path qwenpaw_id override_url <<<"$entry"
    seed_providers

    # 走 env 传敏感值，不进 argv；JSON 合并用 python 完成原子写。
    _QP_TARGET="$PROVIDERS_ROOT/$rel_path" \
    _QP_ACTIVE="$PROVIDERS_ROOT/active_model.json" \
    _QP_ID="$qwenpaw_id" \
    _QP_MODEL="$model" \
    _QP_BASE_URL="$base_url" \
    _QP_API_KEY="$api_key" \
    _QP_OVERRIDE_URL="$override_url" \
    python3 - <<'PY'
import json, os
target   = os.environ["_QP_TARGET"]
active   = os.environ["_QP_ACTIVE"]
qid      = os.environ["_QP_ID"]
model    = os.environ["_QP_MODEL"]
base_url = os.environ["_QP_BASE_URL"]
api_key  = os.environ["_QP_API_KEY"]
override = os.environ["_QP_OVERRIDE_URL"] == "1"

def atomic_write(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
    os.replace(tmp, path)

# Provider 文件：load → 只覆写 platform 字段 → 写回，保留 models / extra_models 等。
cfg = {}
if os.path.isfile(target):
    try:
        cfg = json.load(open(target, encoding="utf-8")) or {}
        if not isinstance(cfg, dict): cfg = {}
    except Exception:
        cfg = {}
cfg["id"] = qid
cfg["api_key"] = api_key or cfg.get("api_key", "")
if override and base_url:
    cfg["base_url"] = base_url
atomic_write(target, cfg)

# 激活态：每次全量覆写。provider_id 必须用 qwenpaw 内部 id。
atomic_write(active, {"provider_id": qid, "model": model})
print(f"updated: {target}; active={qid}/{model}")
PY

    restart_app
}

# ---------------------------------------------------------------------------
case "${1:-}" in
    init-providers) seed_providers ;;
    modify-model)   shift; modify_model "$@" ;;
    modify-channel)
        # qwenpaw 不支持平台侧改渠道（agent_types.supports_channels=false）。
        echo "Error: qwenpaw does not support platform-managed channel modification." >&2
        exit 1 ;;
    help|-h|--help)
        cat <<EOF
Usage:
  run-cmd.sh init-providers
  run-cmd.sh modify-model <platform_provider> <model> <base_url> <api_key>
  run-cmd.sh modify-channel ...   (unsupported)

platform_provider: bailian | api_gateway | litellm
api_key 推荐通过 _QWENPAW_API_KEY 环境变量传入。

Env overrides:
  QWENPAW_PROVIDERS_ROOT      default: /app/working.secret/providers
  QWENPAW_SEED_DIR            default: /opt/qwenpaw-providers
  QWENPAW_SUPERVISOR_PROGRAM  default: app
EOF
        ;;
    *)
        echo "Usage: run-cmd.sh {init-providers|modify-model|modify-channel|help}" >&2
        exit 1 ;;
esac
