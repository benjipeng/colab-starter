#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Defaults (override with env vars if needed).
MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$SCRIPT_DIR/micromamba}"
MICROMAMBA_BIN="${MICROMAMBA_BIN:-$SCRIPT_DIR/bin/micromamba}"
BASHRC_PATH="${BASHRC_PATH:-$HOME/.bashrc}"
ZSHRC_PATH="${ZSHRC_PATH:-$HOME/.zshrc}"
AUTO_ACTIVATE_BASE="${AUTO_ACTIVATE_BASE:-1}"
INSTALL_BASE_PYTHON="${INSTALL_BASE_PYTHON:-1}"
BASE_PYTHON_VERSION="${BASE_PYTHON_VERSION:-3.12}"
BASE_PYTHON_CHANNEL="${BASE_PYTHON_CHANNEL:-conda-forge}"
DRY_RUN="${DRY_RUN:-0}"

# Network hardening for downloads.
CURL_CONNECT_TIMEOUT_SECS="${CURL_CONNECT_TIMEOUT_SECS:-10}"
CURL_MAX_TIME_SECS="${CURL_MAX_TIME_SECS:-120}"
CURL_RETRIES="${CURL_RETRIES:-5}"

MICROMAMBA_TIMEOUT="${MICROMAMBA_TIMEOUT:-3600s}"

log() {
  printf "[MV-SAM3D/colab] %s\n" "$*"
}

die() {
  echo "[MV-SAM3D/colab] ERROR: $*" >&2
  exit 1
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
  if command -v timeout >/dev/null 2>&1; then
    run timeout --preserve-status "$duration" "$@"
  else
    run "$@"
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "Missing required command: $1"
  fi
}

usage() {
  cat <<'EOF'
Usage:
  bash colab/setup_micromamba_bashrc.sh [--help] [--print-config]

What it does:
  1) Ensures micromamba exists (downloads into colab/bin if needed)
  2) Patches your bashrc and zshrc so `micromamba` is available in new shells
  3) Optionally auto-activates the base environment in new shells
  4) Optionally installs Python into base (default: 3.12)

Common overrides:
  MAMBA_ROOT_PREFIX=colab/micromamba
  MICROMAMBA_BIN=colab/bin/micromamba
  BASHRC_PATH=~/.bashrc
  ZSHRC_PATH=~/.zshrc
  AUTO_ACTIVATE_BASE=1
  INSTALL_BASE_PYTHON=1
  BASE_PYTHON_VERSION=3.12
  BASE_PYTHON_CHANNEL=conda-forge
  MICROMAMBA_TIMEOUT=3600s
  DRY_RUN=1
EOF
}

print_config() {
  log "SCRIPT_DIR: $SCRIPT_DIR"
  log "MAMBA_ROOT_PREFIX: $MAMBA_ROOT_PREFIX"
  log "MICROMAMBA_BIN: $MICROMAMBA_BIN"
  log "BASHRC_PATH: $BASHRC_PATH"
  log "ZSHRC_PATH: $ZSHRC_PATH"
  log "AUTO_ACTIVATE_BASE: $AUTO_ACTIVATE_BASE"
  log "INSTALL_BASE_PYTHON: $INSTALL_BASE_PYTHON"
  log "BASE_PYTHON_VERSION: $BASE_PYTHON_VERSION"
  log "BASE_PYTHON_CHANNEL: $BASE_PYTHON_CHANNEL"
  log "MICROMAMBA_TIMEOUT: $MICROMAMBA_TIMEOUT"
}

ensure_micromamba() {
  if command -v micromamba >/dev/null 2>&1; then
    MICROMAMBA="$(command -v micromamba)"
    log "Found micromamba on PATH: $MICROMAMBA"
  elif [[ -x "$MICROMAMBA_BIN" ]]; then
    MICROMAMBA="$MICROMAMBA_BIN"
    log "Using existing micromamba: $MICROMAMBA"
  else
    require_command curl
    require_command tar

    log "Installing micromamba into $SCRIPT_DIR/bin"
    run mkdir -p "$SCRIPT_DIR/bin"
    arch="$(uname -m)"
    case "$arch" in
      x86_64) platform="linux-64" ;;
      aarch64|arm64) platform="linux-aarch64" ;;
      *)
        die "Unsupported architecture: $arch"
        ;;
    esac

    if [[ "$DRY_RUN" == "1" ]]; then
      log "+ curl -fLsS --retry $CURL_RETRIES --connect-timeout $CURL_CONNECT_TIMEOUT_SECS --max-time $CURL_MAX_TIME_SECS \"https://micro.mamba.pm/api/micromamba/${platform}/latest\" | tar -xvj -C \"$SCRIPT_DIR/bin\" --strip-components=1 bin/micromamba"
      MICROMAMBA="$MICROMAMBA_BIN"
    else
      curl -fLsS \
        --retry "$CURL_RETRIES" \
        --connect-timeout "$CURL_CONNECT_TIMEOUT_SECS" \
        --max-time "$CURL_MAX_TIME_SECS" \
        "https://micro.mamba.pm/api/micromamba/${platform}/latest" \
        | tar -xvj -C "$SCRIPT_DIR/bin" --strip-components=1 bin/micromamba
      MICROMAMBA="$MICROMAMBA_BIN"
    fi
  fi

  export MAMBA_ROOT_PREFIX
  log "micromamba: $MICROMAMBA"
  log "MAMBA_ROOT_PREFIX: $MAMBA_ROOT_PREFIX"
}

ensure_base_python() {
  if [[ "$INSTALL_BASE_PYTHON" != "1" ]]; then
    log "Skipping base Python install (INSTALL_BASE_PYTHON=$INSTALL_BASE_PYTHON)"
    return 0
  fi

  local base_python="${MAMBA_ROOT_PREFIX%/}/bin/python"
  if [[ -x "$base_python" ]]; then
    log "Base Python already present: $base_python"
    return 0
  fi

  log "Installing Python ${BASE_PYTHON_VERSION} into base at: $MAMBA_ROOT_PREFIX"
  run mkdir -p "$MAMBA_ROOT_PREFIX"
  run_timed "$MICROMAMBA_TIMEOUT" "$MICROMAMBA" install -y \
    -p "$MAMBA_ROOT_PREFIX" \
    -c "$BASE_PYTHON_CHANNEL" \
    "python=${BASE_PYTHON_VERSION}"
}

patch_shell_rc() {
  local rc_path="$1"
  local shell_name="$2" # "bash" or "zsh"

  local backup
  backup="${rc_path}.bak.mv-sam3d"

  local start_marker end_marker
  start_marker="# >>> MV-SAM3D micromamba >>>"
  end_marker="# <<< MV-SAM3D micromamba <<<"

  run mkdir -p "$(dirname "$rc_path")"

  local rc_in tmp_rc_in=""
  if [[ -f "$rc_path" ]]; then
    rc_in="$rc_path"
  else
    tmp_rc_in="$(mktemp)"
    : >"$tmp_rc_in"
    rc_in="$tmp_rc_in"
    if [[ "$DRY_RUN" == "1" ]]; then
      log "+ create $rc_path"
    fi
  fi

  local micromamba_dir
  micromamba_dir="$(dirname "$MICROMAMBA")"
  if [[ -d "$micromamba_dir" ]]; then
    micromamba_dir="$(cd "$micromamba_dir" && pwd -P)"
  fi

  local tmp="" desired_block="" existing_block=""
  tmp="$(mktemp)"
  desired_block="$(mktemp)"
  existing_block="$(mktemp)"
  cleanup() {
    rm -f -- "${tmp:-}" "${desired_block:-}" "${existing_block:-}"
    if [[ -n "${tmp_rc_in:-}" ]]; then
      rm -f -- "${tmp_rc_in:-}"
    fi
  }
  trap cleanup RETURN

  {
    printf "%s\n" "$start_marker"
    printf 'export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-%s}"\n' "$MAMBA_ROOT_PREFIX"
    printf 'export MAMBA_EXE="${MAMBA_EXE:-%s}"\n' "$MICROMAMBA"
    printf 'export AUTO_ACTIVATE_BASE="${AUTO_ACTIVATE_BASE:-%s}"\n' "$AUTO_ACTIVATE_BASE"
    cat <<EOF
case ":\$PATH:" in
  *":${micromamba_dir}:"*) ;;
  *) export PATH="${micromamba_dir}:\$PATH" ;;
esac
if __mamba_setup="\$("\$MAMBA_EXE" shell hook --shell ${shell_name} --root-prefix "\$MAMBA_ROOT_PREFIX" 2> /dev/null)"; then
  eval "\$__mamba_setup"
else
  alias micromamba="\$MAMBA_EXE"
fi
unset __mamba_setup
if [ "\$AUTO_ACTIVATE_BASE" = "1" ]; then
  micromamba activate >/dev/null 2>&1 || true
fi
${end_marker}
EOF
  } >"$desired_block"

  local start_count end_count
  start_count="$(grep -Fxc "$start_marker" "$rc_in" || true)"
  end_count="$(grep -Fxc "$end_marker" "$rc_in" || true)"

  if [[ "$start_count" -eq 0 && "$end_count" -eq 0 ]]; then
    :
  elif [[ "$start_count" -eq 0 || "$end_count" -eq 0 || "$start_count" -ne "$end_count" ]]; then
    die "Found a partial MV-SAM3D micromamba block in $rc_path; remove it and rerun."
  elif [[ "$start_count" -eq 1 ]]; then
    awk -v start="$start_marker" -v end="$end_marker" '
      $0 == start {inside=1}
      inside {print}
      inside && $0 == end {exit}
    ' "$rc_in" >"$existing_block"

    if cmp -s "$desired_block" "$existing_block"; then
      log "shell rc already configured: $rc_path"
      return 0
    fi
  else
    log "Found ${start_count} existing MV-SAM3D micromamba blocks in $rc_path; rewriting to a single block."
  fi

  if [[ -f "$rc_path" ]] && [[ ! -f "$backup" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "+ cp \"$rc_path\" \"$backup\""
      log "Would back up $rc_path to $backup"
    else
      cp "$rc_path" "$backup"
      log "Backed up $rc_path to $backup"
    fi
  fi

  awk -v start="$start_marker" -v end="$end_marker" '
    $0 == start {skip=1; next}
    skip && $0 == end {skip=0; next}
    !skip {print}
  ' "$rc_in" >"$tmp"

  cat "$desired_block" >>"$tmp"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ write updated rc: $rc_path"
  else
    cat "$tmp" >"$rc_path"
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "Would patch shell rc: $rc_path"
  else
    log "Patched shell rc: $rc_path"
  fi
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      return 0
      ;;
    --print-config)
      print_config
      return 0
      ;;
    "")
      ;;
    *)
      die "Unknown argument: ${1}. Use --help."
      ;;
  esac

  ensure_micromamba
  ensure_base_python
  patch_shell_rc "$BASHRC_PATH" "bash"
  patch_shell_rc "$ZSHRC_PATH" "zsh"

  log "Done. Restart your shell or run:"
  log "  source \"$BASHRC_PATH\"   # for bash"
  log "  source \"$ZSHRC_PATH\"    # for zsh"
  log "Verify with: micromamba --version"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1: no changes were made."
  fi
}

main "$@"
