#!/bin/bash
# run-cmd.sh - Hermes configuration modifier
#
# Selectively modifies Hermes configuration without overwriting user customizations:
#   - Model config lives in /opt/data/config.yaml, only the `model.default` field
#     is touched (provider / base_url / api_key are preserved since the platform
#     forbids cross-provider switches and initializes them on instance creation).
#   - Channel config lives in /opt/data/.env, only the target channel's env vars
#     are upserted.
#
# Usage:
#   run-cmd.sh modify-model   <model_name>
#   run-cmd.sh modify-channel <channel_type> <client_id> <client_secret>
#
# Environment variables (override defaults):
#   HERMES_CONFIG_PATH - Path to config.yaml  (default: /opt/data/config.yaml)
#   HERMES_ENV_PATH    - Path to .env file    (default: /opt/data/.env)
#
# Sensitive values (client_secret) are passed via env vars instead of
# command-line arguments whenever possible.

set -euo pipefail

CONFIG_PATH="${HERMES_CONFIG_PATH:-/opt/data/config.yaml}"
ENV_PATH="${HERMES_ENV_PATH:-/opt/data/.env}"

# ---------------------------------------------------------------------------
# modify-model: update ONLY `model.default` in config.yaml.
# provider / base_url / api_key were set at instance-creation time and must not
# change (cross-provider switch is forbidden by the platform), so they are
# preserved verbatim. If the model block doesn't exist yet, we bail out with a
# clear error instead of guessing provider/base_url.
# ---------------------------------------------------------------------------
cmd_modify_model() {
    local model_name="${1:-}"

    if [ -z "$model_name" ]; then
        echo "Error: model_name is required" >&2
        echo "Usage: run-cmd.sh modify-model <model_name>" >&2
        exit 1
    fi

    if [ ! -f "$CONFIG_PATH" ]; then
        echo "Error: config file not found: $CONFIG_PATH" >&2
        echo "Hermes config.yaml should be initialized at instance creation time." >&2
        exit 1
    fi

    python3 - "$CONFIG_PATH" "$model_name" <<'PY'
import os
import sys

try:
    import yaml
except ImportError:
    print("Error: PyYAML is required. Install via: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

path, model_name = sys.argv[1:3]

try:
    with open(path, "r", encoding="utf-8") as f:
        cfg = yaml.safe_load(f) or {}
except Exception as e:
    print(f"Failed to parse {path}: {e}", file=sys.stderr)
    sys.exit(1)

if not isinstance(cfg, dict):
    cfg = {}

model_block = cfg.get("model")
if not isinstance(model_block, dict):
    print(
        "Error: config.yaml has no existing `model` block; refusing to create "
        "one because provider/base_url/api_key must come from the platform's "
        "initial provisioning step.",
        file=sys.stderr,
    )
    sys.exit(1)

# Only touch the model name; everything else (provider, base_url, api_key,
# and any extra user fields) stays exactly as-is.
model_block["default"] = model_name
cfg["model"] = model_block

tmp_path = path + ".tmp"
with open(tmp_path, "w", encoding="utf-8") as f:
    yaml.safe_dump(cfg, f, default_flow_style=False, sort_keys=False, allow_unicode=True)

os.replace(tmp_path, path)
print(f"Model updated: default={model_name}")
PY
}

# ---------------------------------------------------------------------------
# modify-channel: upsert a specific channel's env vars in /opt/data/.env.
#
# IMPORTANT: different channels use DIFFERENT env var names — there is NO
# generic "<PREFIX>_CLIENT_ID / <PREFIX>_CLIENT_SECRET" convention:
#   - dingtalk : DINGTALK_CLIENT_ID / DINGTALK_CLIENT_SECRET
#   - feishu   : FEISHU_APP_ID / FEISHU_APP_SECRET        (reserved, not yet supported)
#   - wecom    : (TBD, reserved)
#   - qq       : (TBD, reserved)
#
# So each supported channel declares its own (id_var, secret_var) pair
# explicitly. Hermes currently supports ONLY dingtalk; any other channel_type
# is rejected until the corresponding variable names are confirmed.
#
# On every call we:
#   1. purge ALL env var names known to belong to ANY channel (so switching
#      channels doesn't leave the previous channel's credentials behind);
#   2. append the two target env vars for the requested channel.
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

    # Declare per-channel env variable names here. To add a new channel,
    # add a case branch with its real (id_var, secret_var) names — do NOT
    # fall back to generic "<PREFIX>_CLIENT_ID".
    local id_var secret_var
    case "$channel_type" in
        dingtalk)
            id_var="DINGTALK_CLIENT_ID"
            secret_var="DINGTALK_CLIENT_SECRET"
            ;;
        feishu|wecom|qq)
            echo "Error: channel '$channel_type' is not yet supported by Hermes" >&2
            echo "Supported channels: dingtalk" >&2
            exit 1
            ;;
        *)
            echo "Error: unsupported channel_type: $channel_type" >&2
            echo "Supported channels: dingtalk" >&2
            exit 1
            ;;
    esac

    # Ensure .env file exists
    mkdir -p "$(dirname "$ENV_PATH")"
    [ -f "$ENV_PATH" ] || touch "$ENV_PATH"

    # Pass secrets via env vars (avoid appearing in ps / bash history)
    export _HERMES_CHANNEL_ID_VAR="$id_var"
    export _HERMES_CHANNEL_SECRET_VAR="$secret_var"
    export _HERMES_CHANNEL_ID_VALUE="$client_id"
    export _HERMES_CHANNEL_SECRET_VALUE="$client_secret"

    python3 - "$ENV_PATH" <<'PY'
import os
import re
import sys

path = sys.argv[1]
id_var        = os.environ.get("_HERMES_CHANNEL_ID_VAR", "")
secret_var    = os.environ.get("_HERMES_CHANNEL_SECRET_VAR", "")
id_value      = os.environ.get("_HERMES_CHANNEL_ID_VALUE", "")
secret_value  = os.environ.get("_HERMES_CHANNEL_SECRET_VALUE", "")

if not id_var or not secret_var:
    print("Error: channel env var names missing", file=sys.stderr)
    sys.exit(1)

# Complete registry of env var names owned by every (current or reserved)
# channel. When switching channels we purge every line matching any of these
# names so the old channel's credentials don't linger in .env.
# Extend this list in lockstep with the `case` branches above.
ALL_CHANNEL_VARS = {
    "DINGTALK_CLIENT_ID", "DINGTALK_CLIENT_SECRET",
    "FEISHU_APP_ID",      "FEISHU_APP_SECRET",
    # "WECOM_..." and "QQ_..." to be added when those channels are wired up.
}

try:
    with open(path, "r", encoding="utf-8") as f:
        lines = f.readlines()
except FileNotFoundError:
    lines = []

name_alt = "|".join(re.escape(v) for v in ALL_CHANNEL_VARS)
pattern = re.compile(r"^\s*(?:export\s+)?(" + name_alt + r")\s*=")
kept = [ln for ln in lines if not pattern.match(ln)]

# Ensure file ends with newline before appending
if kept and not kept[-1].endswith("\n"):
    kept[-1] = kept[-1] + "\n"

kept.append(f"{id_var}={id_value}\n")
kept.append(f"{secret_var}={secret_value}\n")

tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.writelines(kept)
os.replace(tmp, path)

print(f"Channel updated: {id_var} and {secret_var} set in {path}")
PY

    unset _HERMES_CHANNEL_ID_VAR _HERMES_CHANNEL_SECRET_VAR \
          _HERMES_CHANNEL_ID_VALUE _HERMES_CHANNEL_SECRET_VALUE
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
  run-cmd.sh modify-model   <model_name>
      Update ONLY `model.default` in config.yaml. provider/base_url/api_key
      are preserved from the initial provisioning and never changed here.

  run-cmd.sh modify-channel <channel_type> <client_id> <client_secret>
      Upsert the two env vars that the given channel uses in .env, and
      remove any env vars belonging to the previously configured channel.
      Supported channel_type: dingtalk
        dingtalk → DINGTALK_CLIENT_ID / DINGTALK_CLIENT_SECRET
        feishu / wecom / qq are reserved (will use their own var names, e.g.
        FEISHU_APP_ID / FEISHU_APP_SECRET) but are not wired up yet.

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
