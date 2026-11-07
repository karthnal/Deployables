#!/usr/bin/env bash
# =============================================================================
#  install-voice-changer.sh
#  Installs w-okada's Realtime Voice Changer (RVC server) from source on Linux.
#
#  - Full log of every command written to ~/voice-changer-logs/
#  - Step progress bar, live spinner, elapsed time, download meter and the
#    current line of output for every long-running task
#  - Never closes on its own: on success, failure, crash or Ctrl+C it reports
#    what happened and waits for Enter (use --no-pause for unattended runs)
#  - Detects NVIDIA (CUDA 11.8) / AMD (ROCm, experimental) / CPU-only
#  - Re-runnable: running it again updates the repo and repairs the venv
# =============================================================================

# No `set -e` on purpose: every step checks its own result so a failure is
# reported with context instead of the script silently disappearing.
set -uo pipefail

# ---------------------------------------------------------------- defaults ---
REPO_URL="https://github.com/w-okada/voice-changer.git"
INSTALL_DIR="${VC_INSTALL_DIR:-$HOME/voice-changer}"
PORT="${VC_PORT:-18888}"
PY_VERSION="3.10"
TORCH_VERSION="2.0.1"
TORCHAUDIO_VERSION="2.0.2"
FORCE_BACKEND=""
INSTALL_SERVICE=0
USE_HTTPS=1
GIT_REF=""
PAUSE_ON_EXIT=1
BACKEND="cpu"

export PIP_DISABLE_PIP_VERSION_CHECK=1
export PIP_DEFAULT_TIMEOUT=60
export PIP_RETRIES=5
export UV_NO_MODIFY_PATH=1

# ------------------------------------------------------------------ logging ---
LOG_DIR="${VC_LOG_DIR:-$HOME/voice-changer-logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
LOG_FILE="$LOG_DIR/install-$(date +%Y%m%d-%H%M%S).log"
if ! : >"$LOG_FILE" 2>/dev/null; then
  LOG_FILE="/tmp/voice-changer-install-$(date +%Y%m%d-%H%M%S).log"
  : >"$LOG_FILE"
fi

if [[ -t 1 ]]; then
  IS_TTY=1
  C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'
  C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'; C_OFF=$'\e[0m'
else
  IS_TTY=0; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_BOLD=""; C_DIM=""; C_OFF=""
fi
COLS="$(tput cols 2>/dev/null || echo 100)"; [[ "$COLS" =~ ^[0-9]+$ ]] || COLS=100

_log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | sed 's/\x1b\[[0-9;]*m//g' >>"$LOG_FILE"; }
info() { echo "${C_BLUE}[*]${C_OFF} $*"; _log "[*] $*"; }
ok()   { echo "${C_GREEN}[+]${C_OFF} $*"; _log "[+] $*"; }
warn() { echo "${C_YELLOW}[!]${C_OFF} $*"; _log "[!] $*"; }
err()  { echo "${C_RED}[x]${C_OFF} $*"; _log "[x] $*"; }

fmt_time() { printf '%dm%02ds' $(( $1 / 60 )) $(( $1 % 60 )); }
human() {
  awk -v b="${1:-0}" 'BEGIN{split("B KB MB GB TB",u," ");i=1;while(b>=1024&&i<5){b/=1024;i++}
    if(i==1)printf "%d%s",b,u[i]; else printf "%.1f%s",b,u[i]}'
}
rx_bytes() {
  awk -F'[: ]+' 'NR>2 && $2!="lo" {s+=$3} END{print s+0}' /proc/net/dev 2>/dev/null || echo 0
}

# ------------------------------------------------------- exit / pause logic ---
INSTALL_STATUS="running"
CURRENT_STEP="startup"
LAST_CMD=""
RUN_PID=""
KEEPALIVE_PID=""

pause() {
  (( PAUSE_ON_EXIT )) || return 0
  if { : </dev/tty; } 2>/dev/null; then
    printf '\n%sPress Enter to close...%s' "$C_BOLD" "$C_OFF"
    read -r _ </dev/tty || true
    echo
  fi
}

show_log_tail() {
  echo
  echo "${C_BOLD}---- Likely error lines ----${C_OFF}"
  tail -n 400 "$LOG_FILE" | tr '\r' '\n' \
    | grep -iE 'error|failed|not found|denied|no space|could not|unable|unsupported|killed|timed out' \
    | grep -vE '^\S+ \[(\*|\+|x|!)\]' | tail -n 15 || echo "(none matched)"
  echo
  echo "${C_BOLD}---- Last 25 lines of the log ----${C_OFF}"
  tail -n 400 "$LOG_FILE" | tr '\r' '\n' | grep -v '^[[:space:]]*$' | tail -n 25
  echo "${C_BOLD}----------------------------------${C_OFF}"
}

print_hints() {
  echo
  echo "${C_BOLD}Things to check:${C_OFF}"
  case "$CURRENT_STEP" in
    "Preflight checks")
      echo " - Make sure your user can use sudo and the machine has internet access."
      echo " - Free up disk space if the check reported it was low." ;;
    "System packages")
      echo " - Another package manager may be running (unattended upgrades). Wait and re-run."
      echo " - Run 'sudo apt-get update' (or dnf/pacman equivalent) by hand to see the raw error." ;;
    "Python toolchain (uv)")
      echo " - uv downloads from astral.sh and github.com. Check those aren't blocked." ;;
    "Voice changer source")
      echo " - Check github.com is reachable. If $INSTALL_DIR has local changes, move it aside and re-run." ;;
    "Python environment"|"PyTorch")
      echo " - Check download.pytorch.org and pypi.org are reachable."
      echo " - A 'Killed' line means you ran out of RAM. Add swap and re-run." ;;
    "Voice changer requirements")
      echo " - 'error: command gcc failed' or missing headers: a build dependency is missing."
      echo " - 'Killed' during a build means out of RAM. Add swap and re-run."
      echo " - Re-running is safe; already-built packages are reused." ;;
    *)
      echo " - Read the log above. Re-running the installer is safe." ;;
  esac
}

fail() {
  INSTALL_STATUS="failed"
  echo
  err "${C_BOLD}INSTALL FAILED${C_OFF} at step: $CURRENT_STEP"
  err "$1"
  [[ -n "$LAST_CMD" ]] && err "Last command: $LAST_CMD"
  show_log_tail
  print_hints
  exit 1
}

on_exit() {
  local rc=$?
  [[ -n "$RUN_PID" ]] && kill "$RUN_PID" 2>/dev/null
  [[ -n "$KEEPALIVE_PID" ]] && kill "$KEEPALIVE_PID" 2>/dev/null
  (( IS_TTY )) && printf '\r\e[K'
  case "$INSTALL_STATUS" in
    success|failed|usage) ;;
    interrupted) warn "Installer was interrupted during: $CURRENT_STEP" ;;
    *)
      echo
      err "${C_BOLD}Installer stopped unexpectedly${C_OFF} during: $CURRENT_STEP (exit code $rc)"
      [[ -n "$LAST_CMD" ]] && err "Last command: $LAST_CMD"
      show_log_tail ;;
  esac
  _log "===== EXIT: status=$INSTALL_STATUS code=$rc ====="
  echo
  echo "Full log: ${C_BOLD}$LOG_FILE${C_OFF}"
  pause
}
trap on_exit EXIT
trap 'INSTALL_STATUS="interrupted"; echo; exit 130' INT TERM HUP

# ------------------------------------------------------------- progress UI ---
STEPS=(
  "Preflight checks"
  "System packages"
  "Hardware detection"
  "Python toolchain (uv)"
  "Voice changer source"
  "Python environment"
  "PyTorch"
  "Voice changer requirements"
  "Verification"
  "Launcher and service"
)
TOTAL=${#STEPS[@]}

draw_bar() {   # $1 = completed steps
  local done=$1 width=30 filled
  filled=$(( done * width / TOTAL ))
  printf '[%s%s] %3d%%' \
    "$(printf '%*s' "$filled" '' | tr ' ' '#')" \
    "$(printf '%*s' $(( width - filled )) '' | tr ' ' '-')" \
    $(( done * 100 / TOTAL ))
}

step() {
  local n=$1
  CURRENT_STEP="${STEPS[n-1]}"
  LAST_CMD=""
  echo
  echo "${C_BOLD}$(draw_bar $(( n - 1 )))  Step $n/$TOTAL: $CURRENT_STEP${C_OFF}"
  _log "================ STEP $n/$TOTAL: $CURRENT_STEP ================"
}

# run "description" cmd args...
# Runs the command with all output going to the log, while showing a spinner,
# elapsed time, network download meter and the latest output line.
run() {
  local desc="$1"; shift
  LAST_CMD="$*"
  _log ">>> $desc"
  _log "    \$ $*"
  (( IS_TTY )) || echo "    ... $desc (running)"

  "$@" >>"$LOG_FILE" 2>&1 </dev/null &
  RUN_PID=$!

  local start=$SECONDS rx0 frames='|/-\' i=0
  rx0=$(rx_bytes)
  if (( IS_TTY )); then
    while kill -0 "$RUN_PID" 2>/dev/null; do
      local el=$(( SECONDS - start )) now dl rate last head width
      now=$(rx_bytes); dl=$(( now - rx0 )); (( dl < 0 )) && dl=0
      rate=$(( el > 0 ? dl / el : 0 ))
      last=$(tail -c 3000 "$LOG_FILE" 2>/dev/null | tr '\r' '\n' \
             | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' | grep -v '^[[:space:]]*$' | tail -n 1)
      head="  ${frames:i++%4:1} $desc  $(fmt_time "$el")  dl $(human "$dl") @ $(human "$rate")/s"
      width=$(( COLS - ${#head} - 3 )); (( width < 0 )) && width=0
      printf '\r\e[K%s  %s%s%s' "$head" "$C_DIM" "${last:0:width}" "$C_OFF"
      sleep 0.3
    done
  fi

  wait "$RUN_PID"; local rc=$?
  RUN_PID=""
  (( IS_TTY )) && printf '\r\e[K'
  local el=$(( SECONDS - start ))
  if (( rc == 0 )); then
    ok "$desc ($(fmt_time "$el"))"
  else
    err "$desc FAILED (exit code $rc after $(fmt_time "$el"))"
    _log "<<< FAILED rc=$rc"
  fi
  return $rc
}

run_root() {
  if (( EUID == 0 )); then "$@"; else sudo -n "$@"; fi
}

# ------------------------------------------------------------------- args ---
usage() {
  cat <<EOF
Usage: $0 [options]

  --dir PATH        Install location (default: $INSTALL_DIR)
  --port N          Server port (default: $PORT)
  --cpu             Force CPU-only install
  --cuda            Force NVIDIA CUDA install
  --rocm            Force AMD ROCm install (experimental)
  --ref REF         Git branch/tag/commit to check out
  --http            Serve plain HTTP instead of self-signed HTTPS
  --service         Install and enable a systemd service
  --no-pause        Don't wait for Enter at the end (unattended runs)
  -h, --help        Show this help

Logs: $LOG_DIR
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)      INSTALL_DIR="${2:?--dir needs a path}"; shift 2 ;;
    --port)     PORT="${2:?--port needs a number}"; shift 2 ;;
    --cpu)      FORCE_BACKEND="cpu"; shift ;;
    --cuda)     FORCE_BACKEND="cuda"; shift ;;
    --rocm)     FORCE_BACKEND="rocm"; shift ;;
    --ref)      GIT_REF="${2:?--ref needs a value}"; shift 2 ;;
    --http)     USE_HTTPS=0; shift ;;
    --service)  INSTALL_SERVICE=1; shift ;;
    --no-pause) PAUSE_ON_EXIT=0; shift ;;
    -h|--help)  INSTALL_STATUS="usage"; usage; exit 0 ;;
    *) INSTALL_STATUS="usage"; err "Unknown option: $1"; usage; exit 2 ;;
  esac
done
INSTALL_DIR="$(realpath -m "$INSTALL_DIR")"
RUN_USER="${SUDO_USER:-$(id -un)}"

# ===================================================================== steps ==

step_preflight() {
  info "Log file: $LOG_FILE"
  [[ "$(uname -s)" == "Linux" ]] || fail "This installer supports Linux (including WSL2) only."
  [[ "$(uname -m)" == "x86_64" ]] || warn "CPU architecture is $(uname -m). PyTorch wheels may not exist for it."

  {
    echo "---- system info ----"
    uname -a
    cat /etc/os-release 2>/dev/null
    echo "user=$(id -un) euid=$EUID install_dir=$INSTALL_DIR port=$PORT force_backend=${FORCE_BACKEND:-auto}"
    free -h 2>/dev/null
    df -h "$HOME" 2>/dev/null
    command -v lspci >/dev/null && lspci | grep -Ei 'vga|3d|display'
    command -v nvidia-smi >/dev/null && timeout 20 nvidia-smi
    echo "---------------------"
  } >>"$LOG_FILE" 2>&1

  local distro; distro="$(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
  info "System: $distro, $(nproc) CPU threads, $(free -g 2>/dev/null | awk '/Mem:/{print $2}')GB RAM"
  grep -qi microsoft /proc/version 2>/dev/null && info "WSL detected."

  # sudo, authenticated once up front so background tasks never hang on a prompt
  if (( EUID != 0 )); then
    command -v sudo >/dev/null || fail "sudo is not installed. Install it or run this as root."
    info "Checking sudo access (you may be asked for your password)..."
    sudo -v || fail "sudo authentication failed."
    ( while true; do sudo -n true 2>/dev/null; sleep 50; kill -0 "$$" 2>/dev/null || exit; done ) &
    KEEPALIVE_PID=$!
    ok "sudo access confirmed."
  else
    warn "Running as root. A normal user with sudo access is preferred."
  fi

  # disk space
  local d="$INSTALL_DIR" free_gb
  while [[ ! -d "$d" ]]; do d="$(dirname "$d")"; done
  free_gb=$(df -Pk "$d" | awk 'NR==2{print int($4/1048576)}')
  info "Free disk space at $d: ${free_gb}GB"
  (( free_gb < 5 ))  && fail "Only ${free_gb}GB free. At least 5GB (CPU) or 12GB (NVIDIA) is needed."
  (( free_gb < 12 )) && warn "Under 12GB free. Fine for CPU, may be tight for a CUDA install."

  # memory (building fairseq/pyworld can be heavy)
  local mem_mb; mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  local swap_mb; swap_mb=$(awk '/SwapTotal/{print int($2/1024)}' /proc/meminfo)
  (( mem_mb + swap_mb < 3500 )) && warn "Low RAM+swap (${mem_mb}MB+${swap_mb}MB). Builds may be killed. Consider adding swap."

  # network
  local host
  for host in github.com pypi.org download.pytorch.org; do
    if getent hosts "$host" >/dev/null 2>&1; then
      _log "DNS ok: $host"
    else
      fail "Cannot resolve $host. Check internet/DNS on this machine."
    fi
  done
  ok "Network looks reachable."

  # existing install dir sanity
  if [[ -d "$INSTALL_DIR" && ! -d "$INSTALL_DIR/.git" && -n "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]]; then
    fail "$INSTALL_DIR exists, isn't a git checkout and isn't empty. Move it aside or use --dir."
  fi
}

step_system_packages() {
  if command -v apt-get >/dev/null; then
    info "Package manager: apt"
    run "Updating package lists" \
      run_root apt-get -o DPkg::Lock::Timeout=300 update \
      || fail "apt-get update failed."
    run "Installing build tools, audio libraries and ffmpeg" \
      run_root env DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y \
        git curl ca-certificates build-essential pkg-config pciutils \
        libportaudio2 portaudio19-dev libasound2-dev libsndfile1 ffmpeg openssl \
      || fail "apt-get install failed."
  elif command -v dnf >/dev/null; then
    info "Package manager: dnf"
    run "Installing build tools and audio libraries" \
      run_root dnf install -y git curl ca-certificates gcc gcc-c++ make pkgconf-pkg-config pciutils \
        portaudio portaudio-devel alsa-lib-devel libsndfile openssl \
      || fail "dnf install failed."
    run "Installing ffmpeg" run_root dnf install -y ffmpeg \
      || run "Installing ffmpeg-free" run_root dnf install -y ffmpeg-free \
      || warn "ffmpeg not installed (enable RPM Fusion if you need it)."
  elif command -v pacman >/dev/null; then
    info "Package manager: pacman"
    run "Installing build tools, audio libraries and ffmpeg" \
      run_root pacman -Sy --needed --noconfirm git curl ca-certificates base-devel pciutils \
        portaudio alsa-lib libsndfile ffmpeg openssl \
      || fail "pacman install failed."
  else
    fail "Unsupported package manager. Install git, curl, a C/C++ toolchain, portaudio, alsa headers, libsndfile and ffmpeg manually, then re-run."
  fi
}

step_detect_backend() {
  if [[ -n "$FORCE_BACKEND" ]]; then
    BACKEND="$FORCE_BACKEND"; info "Backend forced by option: $BACKEND"; return
  fi

  local pci=""
  command -v lspci >/dev/null && pci="$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true)"
  [[ -n "$pci" ]] && info "Display devices:" && while IFS= read -r l; do echo "      $l"; done <<<"$pci"

  if command -v nvidia-smi >/dev/null && timeout 20 nvidia-smi -L >/dev/null 2>&1; then
    local name cc major
    name="$(timeout 20 nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)"
    cc="$(timeout 20 nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 | tr -d ' ')"
    info "NVIDIA GPU: ${name:-unknown} (compute capability ${cc:-unknown})"
    if [[ ! "$cc" =~ ^[0-9]+\.[0-9]+$ ]]; then
      if [[ "$name" =~ K80|K40|K20|K10|GTX\ 6[0-9]{2}|GTX\ 7[0-9]{2} ]]; then
        warn "Kepler-era GPU. Current PyTorch CUDA builds don't support it. Using CPU."
        BACKEND="cpu"
      else
        BACKEND="cuda"
      fi
    else
      major="${cc%%.*}"
      if (( major < 5 )); then
        warn "Compute capability $cc is below the 5.0 minimum for these CUDA builds. Using CPU."
        BACKEND="cpu"
      elif (( major >= 12 )); then
        warn "RTX 50-series isn't supported by the torch $TORCH_VERSION stack upstream pins. Using CPU."
        BACKEND="cpu"
      else
        BACKEND="cuda"
      fi
    fi
  elif grep -qi nvidia <<<"$pci"; then
    warn "NVIDIA GPU present but nvidia-smi isn't working (driver missing?). Using CPU."
    warn "Install the driver, reboot and re-run to switch to CUDA."
    BACKEND="cpu"
  elif command -v rocminfo >/dev/null && timeout 20 rocminfo 2>/dev/null | grep -q 'gfx'; then
    info "AMD GPU with ROCm found."
    BACKEND="rocm"
  elif grep -Eqi 'amd|ati|radeon' <<<"$pci"; then
    warn "AMD GPU present but ROCm isn't installed. Using CPU."
    BACKEND="cpu"
  else
    info "No supported GPU found."
    BACKEND="cpu"
  fi
  ok "Selected backend: ${C_BOLD}${BACKEND^^}${C_OFF}"
}

step_uv() {
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
  if command -v uv >/dev/null; then
    ok "uv already installed ($(uv --version 2>/dev/null))"
  else
    run "Downloading and installing uv" bash -o pipefail -c 'curl -LsSf https://astral.sh/uv/install.sh | sh' \
      || fail "uv installation failed."
    hash -r
    command -v uv >/dev/null || fail "uv installed but not found on PATH (looked in ~/.local/bin and ~/.cargo/bin)."
    ok "uv ready ($(uv --version 2>/dev/null))"
  fi
}

step_source() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    run "Fetching updates" git -C "$INSTALL_DIR" fetch --all --tags --progress \
      || fail "git fetch failed."
    if [[ -n "$GIT_REF" ]]; then
      run "Checking out $GIT_REF" git -C "$INSTALL_DIR" checkout "$GIT_REF" \
        || fail "Could not check out $GIT_REF."
    fi
    run "Updating checkout" git -C "$INSTALL_DIR" pull --ff-only \
      || warn "Couldn't fast-forward (pinned ref or local changes). Keeping current checkout."
  else
    if [[ -n "$GIT_REF" ]]; then
      run "Cloning repository (ref $GIT_REF)" git clone --progress "$REPO_URL" "$INSTALL_DIR" \
        || fail "git clone failed."
      run "Checking out $GIT_REF" git -C "$INSTALL_DIR" checkout "$GIT_REF" \
        || fail "Could not check out $GIT_REF."
    else
      run "Cloning repository" git clone --progress --depth 1 "$REPO_URL" "$INSTALL_DIR" \
        || fail "git clone failed."
    fi
  fi
  [[ -f "$INSTALL_DIR/server/requirements.txt" ]] \
    || fail "server/requirements.txt not found. The upstream repo layout may have changed."
  info "Source at commit $(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null)"
}

VENV=""; PY=""
step_python_env() {
  VENV="$INSTALL_DIR/.venv"
  PY="$VENV/bin/python"

  if [[ -x "$PY" ]] && "$PY" -c 'import sys; assert sys.version_info[:2]==(3,10)' 2>/dev/null; then
    ok "Existing Python 3.10 environment found, reusing it."
  else
    [[ -e "$VENV" ]] && { warn "Existing environment is broken or wrong version, recreating."; rm -rf "$VENV"; }
    run "Creating Python $PY_VERSION environment (downloads Python if needed)" \
      uv venv --seed --python "$PY_VERSION" "$VENV" \
      || fail "Could not create the Python environment."
  fi
  info "Python: $("$PY" --version 2>&1)"

  # fairseq 0.12.2 needs omegaconf 2.0.x, whose metadata pip >= 24.1 rejects.
  run "Installing build tooling (pip<24.1, setuptools<70, wheel, cython)" \
    "$PY" -m pip install --progress-bar off --upgrade "pip<24.1" "setuptools<70" wheel cython \
    || fail "Could not install Python build tooling."

  local req="$INSTALL_DIR/server/requirements.txt" numpy_spec
  numpy_spec="$(grep -Ei '^[[:space:]]*numpy[[:space:]]*[=<>~]' "$req" | head -n1 | tr -d '[:space:]' || true)"
  numpy_spec="${numpy_spec:-numpy==1.23.5}"
  run "Installing $numpy_spec" "$PY" -m pip install --progress-bar off "$numpy_spec" \
    || fail "Could not install numpy."
}

TORCH_INDEX=""
step_torch() {
  local size
  case "$BACKEND" in
    cuda) TORCH_INDEX="https://download.pytorch.org/whl/cu118";     size="~2.5GB" ;;
    rocm) TORCH_INDEX="https://download.pytorch.org/whl/rocm5.4.2"; size="~1.5GB" ;;
    *)    TORCH_INDEX="https://download.pytorch.org/whl/cpu";       size="~200MB" ;;
  esac
  info "Index: $TORCH_INDEX (download $size)"
  if "$PY" -c "import torch,sys; sys.exit(0 if torch.__version__.startswith('$TORCH_VERSION') and ('+cpu' in torch.__version__)==('$BACKEND'=='cpu') else 1)" 2>/dev/null; then
    ok "PyTorch $TORCH_VERSION for $BACKEND already installed."
    return
  fi
  run "Downloading and installing PyTorch $TORCH_VERSION ($BACKEND)" \
    "$PY" -m pip install --progress-bar off "torch==$TORCH_VERSION" "torchaudio==$TORCHAUDIO_VERSION" \
      --index-url "$TORCH_INDEX" \
    || fail "PyTorch installation failed."
}

step_requirements() {
  local req="$INSTALL_DIR/server/requirements.txt"
  local filtered="$INSTALL_DIR/server/requirements.$BACKEND.txt"

  # Drop torch lines so requirements can't replace our build (torchcrepe/torchfcpe kept).
  grep -Ev '^[[:space:]]*(torch|torchaudio|torchvision)[[:space:]]*([=<>~!].*)?$' "$req" >"$filtered" || true
  if [[ "$BACKEND" != "cuda" ]]; then
    sed -i -E 's/^[[:space:]]*onnxruntime-gpu/onnxruntime/' "$filtered"
    info "Using CPU onnxruntime instead of onnxruntime-gpu."
  fi
  info "$(grep -cEv '^[[:space:]]*(#|$)' "$filtered") packages to install."
  { echo "---- $filtered ----"; cat "$filtered"; echo "-------------------"; } >>"$LOG_FILE"

  run "Installing requirements (pyworld/fairseq compile here, can take 10-30 min)" \
    "$PY" -m pip install --progress-bar off --no-build-isolation -r "$filtered" \
    || fail "Installing the voice changer's Python requirements failed."

  run "Re-pinning PyTorch build" \
    "$PY" -m pip install --progress-bar off --no-deps --force-reinstall \
      "torch==$TORCH_VERSION" "torchaudio==$TORCHAUDIO_VERSION" --index-url "$TORCH_INDEX" \
    || fail "Could not re-pin PyTorch."
}

step_verify() {
  local out mod failed=0
  out="$("$PY" -c 'import torch; print(torch.__version__, "cuda_available=%s" % torch.cuda.is_available())' 2>&1)" \
    || { echo "$out" >>"$LOG_FILE"; fail "PyTorch fails to import."; }
  ok "torch $out"
  if [[ "$BACKEND" != "cpu" && "$out" != *"=True" ]]; then
    warn "GPU build installed but torch can't see the GPU. The server will fall back to CPU. Check drivers."
  fi

  for mod in torchaudio onnxruntime numpy pyworld fairseq faiss sounddevice; do
    if out="$("$PY" -c "import $mod" 2>&1)"; then
      ok "import $mod"
    else
      err "import $mod failed: $(tail -n1 <<<"$out")"
      _log "$out"
      failed=1
    fi
  done
  (( failed )) && warn "Some modules failed to import. The server may not start. See the log."

  LAST_CMD="MMVCServerSIO.py --help"
  if ( cd "$INSTALL_DIR/server" && timeout 180 "$PY" MMVCServerSIO.py --help ) >>"$LOG_FILE" 2>&1; then
    ok "Server code loads correctly."
  else
    warn "Server smoke test failed. It may still run, but check the log for missing modules."
  fi
}

step_launcher() {
  local launcher="$INSTALL_DIR/start.sh"
  local https_flags="--https true --httpsSelfSigned true"
  (( USE_HTTPS )) || https_flags="--https false"
  local wsl_line=""
  grep -qi microsoft /proc/version 2>/dev/null && wsl_line='export LD_LIBRARY_PATH="/usr/lib/wsl/lib:${LD_LIBRARY_PATH:-}"'

  cat >"$launcher" <<EOF
#!/usr/bin/env bash
# Generated by install-voice-changer.sh (backend: $BACKEND)
# Missing pretrained weights are downloaded into server/pretrain on first start.
# Server output is also saved to $LOG_DIR/server-*.log
cd "\$(dirname "\$(readlink -f "\$0")")/server" || exit 1
$wsl_line
export PYTHONUNBUFFERED=1
LOG="$LOG_DIR/server-\$(date +%Y%m%d-%H%M%S).log"
echo "Server log: \$LOG"
../.venv/bin/python MMVCServerSIO.py -p \${VC_PORT:-$PORT} $https_flags \\
  --content_vec_500 pretrain/checkpoint_best_legacy_500.pt \\
  --content_vec_500_onnx pretrain/content_vec_500.onnx \\
  --content_vec_500_onnx_on true \\
  --hubert_base pretrain/hubert_base.pt \\
  --hubert_base_jp pretrain/rinna_hubert_base_jp.pt \\
  --hubert_soft pretrain/hubert/hubert-soft-0d54a1f4.pt \\
  --nsf_hifigan pretrain/nsf_hifigan/model \\
  --crepe_onnx_full pretrain/crepe_onnx_full.onnx \\
  --crepe_onnx_tiny pretrain/crepe_onnx_tiny.onnx \\
  --rmvpe pretrain/rmvpe.pt \\
  --model_dir model_dir \\
  --samples samples.json \\
  "\$@" 2>&1 | tee -a "\$LOG"
rc=\${PIPESTATUS[0]}
if (( rc != 0 )) && [[ -t 0 ]]; then
  echo
  echo "Server exited with code \$rc. Log: \$LOG"
  read -rp "Press Enter to close..." _
fi
exit \$rc
EOF
  chmod +x "$launcher" || fail "Could not make $launcher executable."
  printf 'backend=%s\ntorch=%s\nport=%s\ninstalled=%s\ncommit=%s\n' \
    "$BACKEND" "$TORCH_VERSION" "$PORT" "$(date -Is)" \
    "$(git -C "$INSTALL_DIR" rev-parse --short HEAD 2>/dev/null)" >"$INSTALL_DIR/.install-info"
  ok "Launcher written: $launcher"

  (( INSTALL_SERVICE )) || return 0
  command -v systemctl >/dev/null || { warn "systemd not available, skipping service."; return 0; }
  local tmp unit="/etc/systemd/system/voice-changer.service"
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
[Unit]
Description=w-okada Realtime Voice Changer
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$RUN_USER
WorkingDirectory=$INSTALL_DIR/server
ExecStart=$INSTALL_DIR/start.sh
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  run "Installing systemd unit" run_root install -m 644 "$tmp" "$unit" || fail "Could not write $unit."
  rm -f "$tmp"
  run "Reloading systemd" run_root systemctl daemon-reload || fail "systemctl daemon-reload failed."
  run "Enabling and starting voice-changer service" run_root systemctl enable --now voice-changer.service \
    || fail "Could not start the service. Check: journalctl -u voice-changer -n 50"
  ok "Service running. Logs: journalctl -u voice-changer -f"
}

# ===================================================================== main ==
START_TIME=$SECONDS
_log "===== install-voice-changer.sh started ====="
echo "${C_BOLD}w-okada Voice Changer installer${C_OFF}"
echo "Log: $LOG_FILE"

step 1;  step_preflight
step 2;  step_system_packages
step 3;  step_detect_backend
step 4;  step_uv
step 5;  step_source
step 6;  step_python_env
step 7;  step_torch
step 8;  step_requirements
step 9;  step_verify
step 10; step_launcher

INSTALL_STATUS="success"
ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
scheme="https"; (( USE_HTTPS )) || scheme="http"
echo
echo "${C_GREEN}${C_BOLD}$(draw_bar "$TOTAL")  Install complete in $(fmt_time $(( SECONDS - START_TIME )))${C_OFF}"
_log "===== INSTALL SUCCEEDED ====="
echo "   Backend: ${BACKEND^^}"
echo "   Start:   $INSTALL_DIR/start.sh"
echo "   Open:    $scheme://localhost:$PORT  (or $scheme://${ip:-<server-ip>}:$PORT from another machine)"
(( USE_HTTPS )) && echo "   The certificate is self-signed, so accept the browser warning. Use a Chromium-based browser."
echo "   First start downloads the pretrained weights, so give it a few minutes."
if command -v ufw >/dev/null && run_root ufw status 2>/dev/null | grep -q "Status: active"; then
  echo "   ufw is active. To allow LAN access: sudo ufw allow $PORT/tcp"
fi
if [[ "$BACKEND" == "cpu" ]]; then
  echo
  warn "CPU mode: use the rmvpe_onnx or crepe_tiny f0 detector, raise the chunk size and prefer ONNX models."
fi
