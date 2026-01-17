#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Defaults (override with env vars if needed).
# Install under the user's home directory by default (keeps the repo clean).
MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$HOME/micromamba}"
MICROMAMBA_BIN="${MICROMAMBA_BIN:-$HOME/bin/micromamba}"
BASHRC_PATH="${BASHRC_PATH:-$HOME/.bashrc}"
BASH_PROFILE_PATH="${BASH_PROFILE_PATH:-$HOME/.bash_profile}"
PROFILE_PATH="${PROFILE_PATH:-$HOME/.profile}"
ZSHRC_PATH="${ZSHRC_PATH:-$HOME/.zshrc}"
ZSHENV_PATH="${ZSHENV_PATH:-$HOME/.zshenv}"

# A minimal, POSIX-compatible env file that makes `micromamba` available in:
# - interactive shells (sourced by bashrc/zshrc blocks)
# - non-interactive zsh (sourced by ~/.zshenv)
# - non-interactive bash (via BASH_ENV exported from ~/.profile/.bash_profile)
MICROMAMBA_ENV_FILE="${MICROMAMBA_ENV_FILE:-$HOME/.mv-sam3d_micromamba_env.sh}"

# Optional: Patch Colab's system IPython config so non-Colab Python kernels can start.
PATCH_COLAB_IPYTHON_CONFIG="${PATCH_COLAB_IPYTHON_CONFIG:-1}"

# Optional: Install ipykernel in the base env and register a Jupyter kernelspec.
INSTALL_IPYKERNEL="${INSTALL_IPYKERNEL:-1}"
REGISTER_KERNEL="${REGISTER_KERNEL:-1}"
KERNEL_NAME="${KERNEL_NAME:-micromamba}"
KERNEL_DISPLAY_NAME="${KERNEL_DISPLAY_NAME:-Python (micromamba)}"
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
  1) Ensures micromamba exists (installs into ~/bin by default)
  2) Patches your bashrc and zshrc so `micromamba` is available in new shells
  3) Adds a minimal env file so micromamba is available in non-interactive shells
  3) Optionally auto-activates the base environment in new shells
  4) Optionally installs Python into base (default: 3.12)
  5) Optionally installs ipykernel and registers a Jupyter kernel

Common overrides:
  MAMBA_ROOT_PREFIX=~/micromamba
  MICROMAMBA_BIN=~/bin/micromamba
  BASHRC_PATH=~/.bashrc
  BASH_PROFILE_PATH=~/.bash_profile
  PROFILE_PATH=~/.profile
  ZSHRC_PATH=~/.zshrc
  ZSHENV_PATH=~/.zshenv
  MICROMAMBA_ENV_FILE=~/.mv-sam3d_micromamba_env.sh
  AUTO_ACTIVATE_BASE=1
  INSTALL_BASE_PYTHON=1
  BASE_PYTHON_VERSION=3.12
  BASE_PYTHON_CHANNEL=conda-forge
  INSTALL_IPYKERNEL=1
  REGISTER_KERNEL=1
  KERNEL_NAME=micromamba
  KERNEL_DISPLAY_NAME="Python (micromamba)"
  PATCH_COLAB_IPYTHON_CONFIG=1
  MICROMAMBA_TIMEOUT=3600s
  DRY_RUN=1
EOF
}

print_config() {
  log "SCRIPT_DIR: $SCRIPT_DIR"
  log "MAMBA_ROOT_PREFIX: $MAMBA_ROOT_PREFIX"
  log "MICROMAMBA_BIN: $MICROMAMBA_BIN"
  log "MICROMAMBA_ENV_FILE: $MICROMAMBA_ENV_FILE"
  log "BASHRC_PATH: $BASHRC_PATH"
  log "BASH_PROFILE_PATH: $BASH_PROFILE_PATH"
  log "PROFILE_PATH: $PROFILE_PATH"
  log "ZSHRC_PATH: $ZSHRC_PATH"
  log "ZSHENV_PATH: $ZSHENV_PATH"
  log "AUTO_ACTIVATE_BASE: $AUTO_ACTIVATE_BASE"
  log "INSTALL_BASE_PYTHON: $INSTALL_BASE_PYTHON"
  log "BASE_PYTHON_VERSION: $BASE_PYTHON_VERSION"
  log "BASE_PYTHON_CHANNEL: $BASE_PYTHON_CHANNEL"
  log "INSTALL_IPYKERNEL: $INSTALL_IPYKERNEL"
  log "REGISTER_KERNEL: $REGISTER_KERNEL"
  log "KERNEL_NAME: $KERNEL_NAME"
  log "KERNEL_DISPLAY_NAME: $KERNEL_DISPLAY_NAME"
  log "PATCH_COLAB_IPYTHON_CONFIG: $PATCH_COLAB_IPYTHON_CONFIG"
  log "MICROMAMBA_TIMEOUT: $MICROMAMBA_TIMEOUT"
}

ensure_micromamba() {
  if [[ -x "$MICROMAMBA_BIN" ]]; then
    MICROMAMBA="$MICROMAMBA_BIN"
    log "Using existing micromamba: $MICROMAMBA"
  elif command -v micromamba >/dev/null 2>&1; then
    local existing
    existing="$(command -v micromamba)"
    log "Found micromamba on PATH: $existing"
    log "Copying micromamba into $MICROMAMBA_BIN"
    run mkdir -p "$(dirname "$MICROMAMBA_BIN")"
    if [[ "$DRY_RUN" == "1" ]]; then
      log "+ cp \"$existing\" \"$MICROMAMBA_BIN\""
      log "+ chmod +x \"$MICROMAMBA_BIN\""
    else
      cp "$existing" "$MICROMAMBA_BIN"
      chmod +x "$MICROMAMBA_BIN"
    fi
    MICROMAMBA="$MICROMAMBA_BIN"
  else
    require_command curl
    require_command tar

    local install_dir
    install_dir="$(dirname "$MICROMAMBA_BIN")"
    log "Installing micromamba into $install_dir"
    run mkdir -p "$install_dir"
    arch="$(uname -m)"
    case "$arch" in
      x86_64) platform="linux-64" ;;
      aarch64|arm64) platform="linux-aarch64" ;;
      *)
        die "Unsupported architecture: $arch"
        ;;
    esac

    if [[ "$DRY_RUN" == "1" ]]; then
      log "+ curl -fLsS --retry $CURL_RETRIES --connect-timeout $CURL_CONNECT_TIMEOUT_SECS --max-time $CURL_MAX_TIME_SECS \"https://micro.mamba.pm/api/micromamba/${platform}/latest\" | tar -xvj -C \"$install_dir\" --strip-components=1 bin/micromamba"
      MICROMAMBA="$MICROMAMBA_BIN"
    else
      curl -fLsS \
        --retry "$CURL_RETRIES" \
        --connect-timeout "$CURL_CONNECT_TIMEOUT_SECS" \
        --max-time "$CURL_MAX_TIME_SECS" \
        "https://micro.mamba.pm/api/micromamba/${platform}/latest" \
        | tar -xvj -C "$install_dir" --strip-components=1 bin/micromamba
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

write_micromamba_env_file() {
  local env_path="$MICROMAMBA_ENV_FILE"
  local env_dir
  env_dir="$(dirname "$env_path")"

  local micromamba_dir
  micromamba_dir="$(dirname "$MICROMAMBA")"
  if [[ -d "$micromamba_dir" ]]; then
    micromamba_dir="$(cd "$micromamba_dir" && pwd -P)"
  fi

  run mkdir -p "$env_dir"

  local tmp=""
  tmp="$(mktemp)"
  cleanup() {
    rm -f -- "${tmp:-}"
  }
  trap cleanup RETURN

  cat >"$tmp" <<EOF
# Generated by colab/setup_micromamba_bashrc.sh
# This file is safe to source from sh/bash/zsh and should not print anything.
#
# It makes the micromamba binary available on PATH for non-interactive shells.
# Activation + shell hooks are handled in interactive rc files.
#
# >>> MV-SAM3D micromamba env >>>
export MAMBA_ROOT_PREFIX="\${MAMBA_ROOT_PREFIX:-$MAMBA_ROOT_PREFIX}"
export MAMBA_EXE="\${MAMBA_EXE:-$MICROMAMBA}"
export AUTO_ACTIVATE_BASE="\${AUTO_ACTIVATE_BASE:-$AUTO_ACTIVATE_BASE}"

case ":\${PATH:-}:" in
  *":${micromamba_dir}:"*) ;;
  *) export PATH="${micromamba_dir}:\${PATH:-}" ;;
esac
# <<< MV-SAM3D micromamba env <<<
EOF

  if [[ -f "$env_path" ]] && cmp -s "$tmp" "$env_path"; then
    log "micromamba env file already configured: $env_path"
    return 0
  fi

  local backup="${env_path}.bak.mv-sam3d"
  if [[ -f "$env_path" ]] && [[ ! -f "$backup" ]]; then
    if [[ "$DRY_RUN" == "1" ]]; then
      log "+ cp \"$env_path\" \"$backup\""
      log "Would back up $env_path to $backup"
    else
      cp "$env_path" "$backup"
      log "Backed up $env_path to $backup"
    fi
  fi

  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ write env file: $env_path"
  else
    cat "$tmp" >"$env_path"
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "Would write micromamba env file: $env_path"
  else
    log "Wrote micromamba env file: $env_path"
  fi
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
    cat <<EOF
# Generated by colab/setup_micromamba_bashrc.sh
if [[ -f "$MICROMAMBA_ENV_FILE" ]]; then
  source "$MICROMAMBA_ENV_FILE"
else
  export MAMBA_ROOT_PREFIX="${MAMBA_ROOT_PREFIX:-$MAMBA_ROOT_PREFIX}"
  export MAMBA_EXE="${MAMBA_EXE:-$MICROMAMBA}"
  export AUTO_ACTIVATE_BASE="${AUTO_ACTIVATE_BASE:-$AUTO_ACTIVATE_BASE}"
  case ":\${PATH:-}:" in
    *":${micromamba_dir}:"*) ;;
    *) export PATH="${micromamba_dir}:\${PATH:-}" ;;
  esac
fi

# Only run the shell hook + activation in interactive shells.
case "\$-" in
  *i*)
    if __mamba_setup="\$("\$MAMBA_EXE" shell hook --shell ${shell_name} --root-prefix "\$MAMBA_ROOT_PREFIX" 2> /dev/null)"; then
      eval "\$__mamba_setup"
    else
      alias micromamba="\$MAMBA_EXE"
    fi
    unset __mamba_setup
    if [ "\$AUTO_ACTIVATE_BASE" = "1" ]; then
      micromamba activate >/dev/null 2>&1 || true
    fi
    ;;
esac
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

patch_env_rc() {
  local rc_path="$1"
  local rc_label="$2"

  local backup
  backup="${rc_path}.bak.mv-sam3d"

  local start_marker end_marker
  start_marker="# >>> MV-SAM3D micromamba env >>>"
  end_marker="# <<< MV-SAM3D micromamba env <<<"

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
    cat <<EOF
# Generated by colab/setup_micromamba_bashrc.sh (${rc_label})
if [ -f "$MICROMAMBA_ENV_FILE" ]; then
  . "$MICROMAMBA_ENV_FILE"
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
    die "Found a partial MV-SAM3D micromamba env block in $rc_path; remove it and rerun."
  elif [[ "$start_count" -eq 1 ]]; then
    awk -v start="$start_marker" -v end="$end_marker" '
      $0 == start {inside=1}
      inside {print}
      inside && $0 == end {exit}
    ' "$rc_in" >"$existing_block"

    if cmp -s "$desired_block" "$existing_block"; then
      log "env rc already configured: $rc_path"
      return 0
    fi
  else
    log "Found ${start_count} existing MV-SAM3D micromamba env blocks in $rc_path; rewriting to a single block."
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
    log "Would patch env rc: $rc_path"
  else
    log "Patched env rc: $rc_path"
  fi
}

patch_profile_rc() {
  local rc_path="$1"
  local rc_label="$2"

  local backup
  backup="${rc_path}.bak.mv-sam3d"

  local start_marker end_marker
  start_marker="# >>> MV-SAM3D micromamba profile >>>"
  end_marker="# <<< MV-SAM3D micromamba profile <<<"

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
    cat <<EOF
# Generated by colab/setup_micromamba_bashrc.sh (${rc_label})
if [ -f "$MICROMAMBA_ENV_FILE" ]; then
  . "$MICROMAMBA_ENV_FILE"
fi

# Make sure non-interactive bash shells can find micromamba too.
if [ -z "\${BASH_ENV:-}" ]; then
  export BASH_ENV="$MICROMAMBA_ENV_FILE"
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
    die "Found a partial MV-SAM3D micromamba profile block in $rc_path; remove it and rerun."
  elif [[ "$start_count" -eq 1 ]]; then
    awk -v start="$start_marker" -v end="$end_marker" '
      $0 == start {inside=1}
      inside {print}
      inside && $0 == end {exit}
    ' "$rc_in" >"$existing_block"

    if cmp -s "$desired_block" "$existing_block"; then
      log "profile rc already configured: $rc_path"
      return 0
    fi
  else
    log "Found ${start_count} existing MV-SAM3D micromamba profile blocks in $rc_path; rewriting to a single block."
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
    log "Would patch profile rc: $rc_path"
  else
    log "Patched profile rc: $rc_path"
  fi
}

patch_colab_ipython_config() {
  if [[ "$PATCH_COLAB_IPYTHON_CONFIG" != "1" ]]; then
    log "Skipping Colab IPython config patch (PATCH_COLAB_IPYTHON_CONFIG=$PATCH_COLAB_IPYTHON_CONFIG)"
    return 0
  fi

  local target="/etc/ipython/ipython_config.py"
  if [[ ! -f "$target" ]]; then
    log "No system IPython config at $target; skipping Colab patch."
    return 0
  fi

  if ! grep -Fq "google.colab._kernel.Kernel" "$target"; then
    log "No Colab kernel_class setting found in $target; skipping."
    return 0
  fi

  if grep -Fq "When running outside the Colab Python environment" "$target"; then
    log "Colab IPython config already patched: $target"
    return 0
  fi

  local backup="${target}.bak.mv-sam3d"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ patch $target (backup: $backup)"
    return 0
  fi

  if [[ ! -f "$backup" ]]; then
    cp "$target" "$backup"
    log "Backed up $target to $backup"
  fi

  local py="python3"
  if ! command -v "$py" >/dev/null 2>&1; then
    py="python"
  fi
  require_command "$py"

  "$py" - <<'PY'
from __future__ import annotations

from pathlib import Path

path = Path("/etc/ipython/ipython_config.py")
text = path.read_text(encoding="utf-8")

old_kernel = "c.IPKernelApp.kernel_class = 'google.colab._kernel.Kernel'\\n"
if old_kernel in text:
  text = text.replace(
      old_kernel,
      "try:\\n"
      "  import google.colab._kernel  # pylint:disable=unused-import\\n"
      "except Exception:  # pylint:disable=broad-exception-caught\\n"
      "  # When running outside the Colab Python environment (e.g. a micromamba env),\\n"
      "  # the google.colab package may not be installed. In that case, keep the\\n"
      "  # default kernel_class so IPKernelApp can start.\\n"
      "  pass\\n"
      "else:\\n"
      "  # Register a custom kernel_class.\\n"
      "  c.IPKernelApp.kernel_class = 'google.colab._kernel.Kernel'\\n",
  )

old_ext = (
    "c.InteractiveShellApp.extensions = [\\n"
    "    'google.colab',\\n"
    "]\\n"
)
if old_ext in text:
  text = text.replace(
      old_ext,
      "try:\\n"
      "  import google.colab  # pylint:disable=unused-import\\n"
      "except Exception:  # pylint:disable=broad-exception-caught\\n"
      "  # Avoid failing kernel startup when google.colab isn't available.\\n"
      "  c.InteractiveShellApp.extensions = []\\n"
      "else:\\n"
      "  # Implicitly imported packages.\\n"
      "  c.InteractiveShellApp.extensions = [\\n"
      "      'google.colab',\\n"
      "  ]\\n",
  )

path.write_text(text, encoding="utf-8")
PY

  log "Patched Colab IPython config: $target"
}

ensure_ipykernel_and_kernel() {
  if [[ "$INSTALL_IPYKERNEL" != "1" && "$REGISTER_KERNEL" != "1" ]]; then
    log "Skipping ipykernel install and kernel registration."
    return 0
  fi

  local base_python="${MAMBA_ROOT_PREFIX%/}/bin/python"
  if [[ ! -x "$base_python" ]]; then
    die "Base Python not found at $base_python. Set INSTALL_BASE_PYTHON=1 and rerun."
  fi

  if [[ "$INSTALL_IPYKERNEL" == "1" ]]; then
    if "$base_python" -c "import ipykernel" >/dev/null 2>&1; then
      log "ipykernel already installed in base: $base_python"
    else
      log "Installing ipykernel into base at: $MAMBA_ROOT_PREFIX"
      run_timed "$MICROMAMBA_TIMEOUT" "$MICROMAMBA" install -y \
        -p "$MAMBA_ROOT_PREFIX" \
        -c "$BASE_PYTHON_CHANNEL" \
        ipykernel
    fi
  fi

  if [[ "$REGISTER_KERNEL" != "1" ]]; then
    return 0
  fi

  log "Registering Jupyter kernel: $KERNEL_NAME ($KERNEL_DISPLAY_NAME)"
  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ \"$base_python\" -m ipykernel install --user --name \"$KERNEL_NAME\" --display-name \"$KERNEL_DISPLAY_NAME\""
  else
    "$base_python" -m ipykernel install --user --name "$KERNEL_NAME" --display-name "$KERNEL_DISPLAY_NAME"
  fi

  local kernelspec_dir="${HOME}/.local/share/jupyter/kernels/${KERNEL_NAME}"
  local kernel_json="${kernelspec_dir%/}/kernel.json"
  if [[ ! -f "$kernel_json" ]]; then
    log "NOTE: kernel.json not found at $kernel_json (you may need to restart Jupyter to see the kernel)."
    return 0
  fi

  local micromamba_dir
  micromamba_dir="$(dirname "$MICROMAMBA")"
  if [[ -d "$micromamba_dir" ]]; then
    micromamba_dir="$(cd "$micromamba_dir" && pwd -P)"
  fi
  local kernel_path="${MAMBA_ROOT_PREFIX%/}/bin:${micromamba_dir}:${PATH:-}"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "+ patch kernelspec env: $kernel_json"
    return 0
  fi

  "$base_python" - <<PY
import json
from pathlib import Path

kernel_json = Path(${kernel_json@Q})
data = json.loads(kernel_json.read_text(encoding="utf-8"))
env = dict(data.get("env") or {})
env["MAMBA_ROOT_PREFIX"] = ${MAMBA_ROOT_PREFIX@Q}
env["MAMBA_EXE"] = ${MICROMAMBA@Q}
env["PATH"] = ${kernel_path@Q}
data["env"] = env
kernel_json.write_text(json.dumps(data, indent=1) + "\\n", encoding="utf-8")
PY

  log "Patched kernelspec env: $kernel_json"
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
  write_micromamba_env_file
  patch_profile_rc "$PROFILE_PATH" "profile"
  patch_profile_rc "$BASH_PROFILE_PATH" "bash_profile"
  patch_env_rc "$ZSHENV_PATH" "zshenv"
  patch_shell_rc "$BASHRC_PATH" "bash"
  patch_shell_rc "$ZSHRC_PATH" "zsh"
  patch_colab_ipython_config
  ensure_ipykernel_and_kernel

  log "Done."
  log "Restart your shell or run:"
  log "  source \"$BASHRC_PATH\"   # bash"
  log "  source \"$ZSHRC_PATH\"    # zsh"
  log "Verify with:"
  log "  micromamba --version"
  if [[ "$REGISTER_KERNEL" == "1" ]]; then
    log "If the kernel doesn't show up immediately, restart Jupyter/VS Code and check:"
    log "  jupyter kernelspec list"
  fi
  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1: no changes were made."
  fi
}

main "$@"
