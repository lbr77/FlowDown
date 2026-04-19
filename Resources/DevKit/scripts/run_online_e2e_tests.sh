#!/bin/zsh

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
REPO_ROOT=$(cd "$SCRIPT_DIR/../../.." && pwd -P)
SUPPORT_DIR="$HOME/.testing"
TOKEN_FILE="$SUPPORT_DIR/flowdown-online-e2e.token"
ENDPOINT_FILE="$SUPPORT_DIR/flowdown-online-e2e.endpoint"
E2E_SUPPORT_DIR="/tmp/flowdown-online-e2e"
ENABLE_MARKER="$E2E_SUPPORT_DIR/flowdown_e2e_enabled"
RUNTIME_TOKEN_FILE="$E2E_SUPPORT_DIR/flowdown-online-e2e.token"
RUNTIME_ENDPOINT_FILE="$E2E_SUPPORT_DIR/flowdown-online-e2e.endpoint"

if [[ -f "$HOME/.zprofile" ]]; then
    source "$HOME/.zprofile"
fi

if [[ -f "$HOME/.zshrc" ]]; then
    source "$HOME/.zshrc"
fi

mkdir -p "$SUPPORT_DIR"
mkdir -p "$E2E_SUPPORT_DIR"

if [[ -z "${FLOWDOWN_ONLINE_E2E_TOKEN:-}" && -f "$TOKEN_FILE" ]]; then
    FLOWDOWN_ONLINE_E2E_TOKEN=$(<"$TOKEN_FILE")
fi

if [[ -z "${FLOWDOWN_ONLINE_E2E_ENDPOINT:-}" && -f "$ENDPOINT_FILE" ]]; then
    FLOWDOWN_ONLINE_E2E_ENDPOINT=$(<"$ENDPOINT_FILE")
fi

if [[ -z "${FLOWDOWN_ONLINE_E2E_TOKEN:-}" ]]; then
    echo "[-] FLOWDOWN_ONLINE_E2E_TOKEN is not configured" >&2
    exit 1
fi

if [[ -z "${FLOWDOWN_ONLINE_E2E_ENDPOINT:-}" ]]; then
    echo "[-] FLOWDOWN_ONLINE_E2E_ENDPOINT is not configured" >&2
    exit 1
fi

export FLOWDOWN_ONLINE_E2E_TOKEN
export FLOWDOWN_ONLINE_E2E_ENDPOINT

printf '%s\n' "$FLOWDOWN_ONLINE_E2E_TOKEN" > "$TOKEN_FILE"
printf '%s\n' "$FLOWDOWN_ONLINE_E2E_TOKEN" > "$RUNTIME_TOKEN_FILE"
printf '%s\n' "$FLOWDOWN_ONLINE_E2E_ENDPOINT" > "$ENDPOINT_FILE"
printf '%s\n' "$FLOWDOWN_ONLINE_E2E_ENDPOINT" > "$RUNTIME_ENDPOINT_FILE"
chmod 600 "$TOKEN_FILE" "$ENDPOINT_FILE" "$RUNTIME_TOKEN_FILE" "$RUNTIME_ENDPOINT_FILE"
touch "$ENABLE_MARKER"

cleanup() {
    rm -f "$ENABLE_MARKER" "$RUNTIME_TOKEN_FILE" "$RUNTIME_ENDPOINT_FILE"
}

trap cleanup EXIT

echo "[+] running online e2e"

cd "$REPO_ROOT"

xcodebuild -downloadComponent MetalToolchain > /dev/null
DESTINATION=$(./Resources/DevKit/scripts/get_first_ios_simulator.sh)

XCBUILD_LABEL=test-online-e2e ./Resources/DevKit/scripts/run_xcodebuild.sh \
  -workspace FlowDown.xcworkspace \
  -scheme FlowDown \
  -configuration Debug \
  -destination "$DESTINATION" \
  test \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""
