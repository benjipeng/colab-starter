#!/usr/bin/env bash
set -euo pipefail

# Colab setup script (no sudo needed; Colab runs as root).
# Installs: zsh, oh-my-zsh, Codex CLI, Claude Code.
#
# Usage:
#   bash colab/setup_colab.sh
#   DRY_RUN=1 bash colab/setup_colab.sh

DRY_RUN="${DRY_RUN:-0}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ORIGINAL_PATH="${PATH:-}"

log() {
  printf '%s\n' "$*" >&2
}

run() {
  log "+ $*"
  if [[ "$DRY_RUN" == "1" ]]; then
    return 0
  fi
  "$@"
}

run_timed() {
  local duration="$1"
  shift
  if need_cmd timeout; then
    run timeout --preserve-status "$duration" "$@"
  else
    run "$@"
  fi
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

export DEBIAN_FRONTEND=noninteractive

APT_TIMEOUT="${APT_TIMEOUT:-900s}"
APT_RETRIES="${APT_RETRIES:-3}"
APT_HTTP_TIMEOUT_SECS="${APT_HTTP_TIMEOUT_SECS:-30}"
APT_ARGS=(
  "-o" "Acquire::Retries=${APT_RETRIES}"
  "-o" "Acquire::http::Timeout=${APT_HTTP_TIMEOUT_SECS}"
  "-o" "Acquire::https::Timeout=${APT_HTTP_TIMEOUT_SECS}"
)

run_timed "$APT_TIMEOUT" apt-get "${APT_ARGS[@]}" update
run_timed "$APT_TIMEOUT" apt-get "${APT_ARGS[@]}" install -y zsh curl git ca-certificates tar bzip2

if [[ -d "${ZSH:-$HOME/.oh-my-zsh}" ]]; then
  log "oh-my-zsh already present at: ${ZSH:-$HOME/.oh-my-zsh}"
else
  CURL_CONNECT_TIMEOUT_SECS="${CURL_CONNECT_TIMEOUT_SECS:-10}"
  CURL_MAX_TIME_SECS="${CURL_MAX_TIME_SECS:-120}"
  CURL_RETRIES="${CURL_RETRIES:-5}"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \"\$(curl -fsSL --retry $CURL_RETRIES --connect-timeout $CURL_CONNECT_TIMEOUT_SECS --max-time $CURL_MAX_TIME_SECS https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\""
  else
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(
      curl -fsSL \
        --retry "$CURL_RETRIES" \
        --connect-timeout "$CURL_CONNECT_TIMEOUT_SECS" \
        --max-time "$CURL_MAX_TIME_SECS" \
        https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh
    )"
  fi
fi

if ! need_cmd npm; then
  log "ERROR: npm not found. Install Node.js/npm, then re-run."
  exit 1
fi

NPM_TIMEOUT="${NPM_TIMEOUT:-1800s}"
run_timed "$NPM_TIMEOUT" npm install -g --no-fund --no-audit @openai/codex @anthropic-ai/claude-code

NPM_GLOBAL_PREFIX="$(npm prefix -g 2>/dev/null || true)"
NPM_GLOBAL_BIN=""
if [[ -n "$NPM_GLOBAL_PREFIX" ]]; then
  NPM_GLOBAL_BIN="${NPM_GLOBAL_PREFIX%/}/bin"
fi
if [[ -n "$NPM_GLOBAL_BIN" ]]; then
  log "npm global bin: $NPM_GLOBAL_BIN"
  export PATH="$NPM_GLOBAL_BIN:$PATH"
  hash -r 2>/dev/null || true
fi

if need_cmd codex; then
  run codex --version || true
else
  log "WARNING: codex not on PATH (try: export PATH=\"$NPM_GLOBAL_BIN:\$PATH\")"
fi

if need_cmd claude; then
  run claude --version || true
else
  log "WARNING: claude not on PATH (try: export PATH=\"$NPM_GLOBAL_BIN:\$PATH\")"
fi

persist_path_line() {
  local rc_file="$1"
  local line="export PATH=\"$NPM_GLOBAL_BIN:\$PATH\""
  if [[ -z "$NPM_GLOBAL_BIN" ]]; then
    return 0
  fi
  if [[ ! -f "$rc_file" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "+ create $rc_file"
    else
      : >"$rc_file"
    fi
  fi
  if grep -Fqx "$line" "$rc_file" 2>/dev/null; then
    return 0
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ append to $rc_file: $line"
    return 0
  fi
  {
    printf '\n# Added by colab/setup_colab.sh\n%s\n' "$line"
  } >>"$rc_file"
}

persist_path_line "$HOME/.zshrc"
persist_path_line "$HOME/.bashrc"

if [[ -n "$NPM_GLOBAL_BIN" ]] && [[ ":$ORIGINAL_PATH:" != *":$NPM_GLOBAL_BIN:"* ]]; then
  log "To refresh PATH in your current shell, run:"
  log "  export PATH=\"$NPM_GLOBAL_BIN:\$PATH\""
  log "or restart your shell (new shells will pick it up from your rc files)."
fi

if [[ -x "$SCRIPT_DIR/setup_micromamba_bashrc.sh" ]]; then
  run bash "$SCRIPT_DIR/setup_micromamba_bashrc.sh"
else
  log "NOTE: micromamba setup script not found at: $SCRIPT_DIR/setup_micromamba_bashrc.sh"
fi

log "Done."
