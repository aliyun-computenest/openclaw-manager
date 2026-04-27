#!/bin/bash
# run-cmd.sh - Hermes configuration modifier
#
# Selectively modifies Hermes configuration without overwriting user customizations:
#   - Model config lives in /opt/data/config.yaml, only the `model:` block is touched
#   - Channel config lives in /opt/data/.env, only the target channel's env vars are upserted
#
# Usage:
#   run-cmd.sh modify-model   <model_name> <provider> <base_url> <api_key>
#   run-cmd.sh modify-channel <channel_type> <client_id> <client_secret>
#
# Environment variables (override defaults):
#   HERMES_CONFIG_PATH - Path to config.yaml  (default: /opt/data/config.yaml)
#   HERMES_ENV_PATH    - Path to .env file    (default: /opt/data/.env)
#
# Sensitive values (api_key, client_secret) are passed via temporary files / env
# vars instead of command-line arguments whenever possible.

set -euo pipefail

CONFIG_PATH="${HERMES_CONFIG_PATH:-/opt/data/config.yaml}"
ENV_PATH="${HERMES_ENV_PATH:-/opt/data/.env}"

# ---------------------------------------------------------------------------
# modify-model: overwrite only the top-level `model:` block in config.yaml.
# Keeps any other user-defined top-level keys intact.
# ---------------------------------------------------------------------------
cmd_modify_model() {
    local model_name="${1:-}"
    local provider="${2:-}"
    local base_url="${3:-}"
    local api_key="${4:-}"

    if [ -z "$model_name" ] || [ -z "$provider" ]; then
        echo "Error: model_name and provider are required" >&2
        echo "Usage: run-cmd.sh modify-model <model_name> <provider> <base_url> <api_key>" >&2
        exit 1
    fi

    # Ensure config file exists (create empty YAML if not)
    if [ ! -f "$CONFIG_PATH" ]; then
        mkdir -p "$(dirname "$CONFIG_PATH")"
        echo "{}" > "$CONFIG_PATH"
    fi

    # Pass api_key via env var to avoid exposing it in `ps` output
    export _HERMES_API_KEY="$api_key"

    python3 - "$CONFIG_PATH" "$model_name" "$provider" "$base_url" <<'PY'
import os
import sys

try:
    import yaml
except ImportError:
    print("Error: PyYAML is required. Install via: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

path, model_name, provider, base_url = sys.argv[1:5]
api_key = os.environ.get("_HERMES_API_KEY", "")

try:
    with open(path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}
except Exception as e:
    print(f"Failed to parse {path}: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(cfg, dict):
    cfg = {}

# Replace ONLY the model block; other top-level keys stay untouched
cfg["model"] = {
    "default":  model_name,
    "provider": provider,
    "base_url": base_url,
    "api_key":  api_key,
}

tmp_path = path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

os.replace(tmp_path, path)
print(f"Model updated: provider={provider}, default={model_name}")
PY

    unset _HERMES_API_KEY
}

# ---------------------------------------------------------------------------
# modify-channel: upsert channel-related env vars in /opt/data/.env.
# Currently Hermes only supports dingtalk. When switching channels, old
# channel's *_CLIENT_ID / *_CLIENT_SECRET entries are removed.
# ---------------------------------------------------------------------------
cmd_modify_channel() {
    local channel_type="${1:-}"
    local client_id="${2:-}"
    local client_secret="${3:-}"

    if [ -z "$channel_type" ]; then
        echo "Error: channel_type is required" >&2
        echo "Usage: run-cmd.sh modify-channel <channel_type> <client_id> <client_secret>" >&2
        exit 1
    fi

    # Map channel_type → env var prefix
    local var_prefix
    case "$channel_type" in
        dingtalk) var_prefix="DINGTALK" ;;
        feishu)   var_prefix="FEISHU"   ;;
        qq)       var_prefix="QQ"       ;;
        wecom)    var_prefix="WECOM"    ;;
        *)
            echo "Error: unsupported channel_type: $channel_type" >&2
            echo "Supported: dingtalk (feishu, qq, wecom reserved)" >&2
            exit 1
            ;;
    esac

    # Ensure .env file exists
    mkdir -p "$(dirname "$ENV_PATH")"
    [ -f "$ENV_PATH" ] || touch "$ENV_PATH"

    # Pass secrets via env vars (avoid appearing in ps / bash history)
    export _HERMES_CLIENT_ID="$client_id"
    export _HERMES_CLIENT_SECRET="$client_secret"

    python3 - "$ENV_PATH" "$var_prefix" <<'PY'
import os
import re
import sys

path, prefix = sys.argv[1:3]
client_id     = os.environ.get("_HERMES_CLIENT_ID", "")
client_secret = os.environ.get("_HERMES_CLIENT_SECRET", "")

# All known channel env var prefixes — used to purge old channel when switching
KNOWN_PREFIXES = ("DINGTALK", "FEISHU", "QQ", "WECOM")

try:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
except FileNotFoundError:
    lines = []

# Filter out any existing *_CLIENT_ID / *_CLIENT_SECRET for any known channel
pattern = re.compile(
    r"^\s*(?:export\s+)?(" + "|".join(KNOWN_PREFIXES) + r")_CLIENT_(ID|SECRET)\s*="
)
kept = [ln for ln in lines if not pattern.match(ln)]

# Ensure file ends with newline before appending
if kept and not kept[-1].endswith("\n"):
    kept[-1] = kept[-1] + "\n"

kept.append(f"{prefix}_CLIENT_ID={client_id}\n")
kept.append(f"{prefix}_CLIENT_SECRET={client_secret}\n")

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.writelines(kept)
os.replace(tmp, path)

print(f"Channel updated: {prefix}_CLIENT_ID and {prefix}_CLIENT_SECRET set in {path}")
PY

    unset _HERMES_CLIENT_ID _HERMES_CLIENT_SECRET
}

# ---------------------------------------------------------------------------
# Main dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
    modify-model)
        shift
        cmd_modify_model "$@"
        ;;
    modify-channel)
        shift
        cmd_modify_channel "$@"
        ;;
    help|--help|-h)
        cat <<EOF
Hermes configuration modifier

Usage:
  run-cmd.sh modify-model   <model_name> <provider> <base_url> <api_key>
      Replace the 'model:' block in config.yaml. Other keys are preserved.

  run-cmd.sh modify-channel <channel_type> <client_id> <client_secret>
      Upsert <PREFIX>_CLIENT_ID / <PREFIX>_CLIENT_SECRET in .env file;
      old channel's credentials are purged.
      Supported channel_type: dingtalk (feishu/qq/wecom reserved)

Environment variables:
  HERMES_CONFIG_PATH  Path to config.yaml (default: /opt/data/config.yaml)
  HERMES_ENV_PATH     Path to .env file   (default: /opt/data/.env)
EOF
        ;;
    *)
        echo "Usage: run-cmd.sh {modify-model|modify-channel|help}" >&2
        exit 1
        ;;
esac
