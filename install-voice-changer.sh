#!/usr/bin/env bash
# =============================================================================
#  install-voice-changer.sh
#  Installs w-okada's Realtime Voice Changer (RVC server) from source on Linux.
#
#  - Installs system dependencies (apt / dnf / pacman)
#  - Gets an isolated Python 3.10 via uv (works even if the distro ships 3.12+)
#  - Detects hardware and installs the right PyTorch build:
#        NVIDIA (CUDA 11.8)  |  AMD (ROCm 5.4.2, experimental)  |  CPU only
#  - Fixes the known source-install pain points (pyworld build, fairseq vs
#    new pip, onnxruntime-gpu on CPU boxes, torch being overwritten)
#  - Generates start.sh and optionally a systemd service
#
#  Re-runnable: running it again updates the repo and repairs the venv.
# =============================================================================
set -Eeuo pipefail

# ---------------------------------------------------------------- defaults ---
REPO_URL="https://github.com/w-okada/voice-changer.git"
INSTALL_DIR="${VC_INSTALL_DIR:-$HOME/voice-changer}"
PORT="${VC_PORT:-18888}"
PY_VERSION="3.10"
TORCH_VERSION="2.0.1"
TORCHAUDIO_VERSION="2.0.2"
FORCE_BACKEND=""      # cpu | cuda | rocm
INSTALL_SERVICE=0
USE_HTTPS=1
GIT_REF=""

# ----------------------------------------------------------------- output ---
if [[ -t 1 ]]; then
  C_BLUE=$'\e[34m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_RED=$'\e[31m'; C_OFF=$'\e[0m'
else
  C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_OFF=""
fi
info() { echo "${C_BLUE}[*]${C_OFF} $*"; }
ok()   { echo "${C_GREEN}[+]${C_OFF} $*"; }
warn() { echo "${C_YELLOW}[!]${C_OFF} $*" >&2; }
die()  { echo "${C_RED}[x]${C_OFF} $*" >&2; exit 1; }
trap 'echo "${C_RED}[x]${C_OFF} Failed at line $LINENO: $BASH_COMMAND" >&2' ERR

usage() {
  cat <<EOF
Usage: $0 [options]

  --dir PATH        Install location (default: $INSTALL_DIR)
  --port N          Server port (default: $PORT)
  --cpu             Force CPU-only install
  --cuda            Force NVIDIA CUDA install
  --rocm            Force AMD ROCm install (experimental)
  --ref REF         Git branch/tag/commit to check out (default: repo default)
  --http            Serve plain HTTP instead of self-signed HTTPS
                    (browsers only allow mic access over HTTPS or localhost)
  --service         Install and enable a systemd service
  -h, --help        Show this help

Env overrides: VC_INSTALL_DIR, VC_PORT
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)     INSTALL_DIR="$2"; shift 2 ;;
    --port)    PORT="$2"; shift 2 ;;
    --cpu)     FORCE_BACKEND="cpu"; shift ;;
    --cuda)    FORCE_BACKEND="cuda"; shift ;;
    --rocm)    FORCE_BACKEND="rocm"; shift ;;
    --ref)     GIT_REF="$2"; shift 2 ;;
    --http)    USE_HTTPS=0; shift ;;
    --service) INSTALL_SERVICE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

[[ "$(uname -s)" == "Linux" ]] || die "This script supports Linux (including WSL2) only."
[[ "$(uname -m)" == "x86_64" ]] || warn "Non x86_64 CPU detected ($(uname -m)). PyTorch wheels may not exist for it."

if [[ $EUID -eq 0 ]]; then
  SUDO=""
  warn "Running as root. Prefer running as a normal user with sudo access."
else
  command -v sudo >/dev/null || die "sudo is required to install system packages."
  SUDO="sudo"
fi
RUN_USER="${SUDO_USER:-$(id -un)}"

# --------------------------------------------------------- system packages ---
install_system_deps() {
  info "Installing system dependencies..."
  if command -v apt-get >/dev/null; then
    $SUDO apt-get update -y
    $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y \
      git curl ca-certificates build-essential pkg-config pciutils \
      libportaudio2 portaudio19-dev libasound2-dev libsndfile1 ffmpeg openssl
  elif command -v dnf >/dev/null; then
    $SUDO dnf install -y \
      git curl ca-certificates gcc gcc-c++ make pkgconf-pkg-config pciutils \
      portaudio portaudio-devel alsa-lib-devel libsndfile openssl
    $SUDO dnf install -y ffmpeg || $SUDO dnf install -y ffmpeg-free || warn "ffmpeg not installed (enable RPM Fusion if needed)."
  elif command -v pacman >/dev/null; then
    $SUDO pacman -Sy --needed --noconfirm \
      git curl ca-certificates base-devel pciutils \
      portaudio alsa-lib libsndfile ffmpeg openssl
  else
    die "Unsupported package manager. Install git, curl, a C/C++ toolchain, portaudio, alsa dev headers, libsndfile and ffmpeg manually, then re-run."
  fi
  ok "System dependencies installed."
}

# --------------------------------------------------------- GPU detection ---
BACKEND="cpu"
detect_backend() {
  if [[ -n "$FORCE_BACKEND" ]]; then
    BACKEND="$FORCE_BACKEND"
    info "Backend forced: $BACKEND"
    return
  fi

  local pci=""
  command -v lspci >/dev/null && pci="$(lspci 2>/dev/null | grep -Ei 'vga|3d|display' || true)"

  # --- NVIDIA ---
  if command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1; then
    local name cc major
    name="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1)"
    cc="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 | tr -d ' ' || true)"
    info "NVIDIA GPU found: ${name:-unknown} (compute capability: ${cc:-unknown})"

    if [[ -z "$cc" || ! "$cc" =~ ^[0-9]+\.[0-9]+$ ]]; then
      # Old drivers can't report compute_cap. Catch known Kepler cards by name.
      if [[ "$name" =~ K80|K40|K20|K10|GTX\ 6[0-9]{2}|GTX\ 7[0-9]{2} ]]; then
        warn "Kepler-era GPU detected. Current PyTorch CUDA builds don't support it. Falling back to CPU."
        BACKEND="cpu"; return
      fi
      BACKEND="cuda"; return
    fi

    major="${cc%%.*}"
    if (( major < 5 )); then
      warn "Compute capability $cc is too old for PyTorch CUDA 11.8 builds (needs 5.0+). Falling back to CPU."
      BACKEND="cpu"
    elif (( major >= 12 )); then
      warn "RTX 50-series (sm_$major) isn't supported by the torch $TORCH_VERSION stack upstream pins."
      warn "Falling back to CPU. For GPU use on these cards, look at the deiteris fork's prebuilt release."
      BACKEND="cpu"
    else
      BACKEND="cuda"
    fi
    return
  fi
  if grep -qi nvidia <<<"$pci"; then
    warn "NVIDIA GPU present but nvidia-smi isn't working (driver not installed?). Using CPU."
    warn "Install the NVIDIA driver, reboot, then re-run this script to switch to CUDA."
    BACKEND="cpu"; return
  fi

  # --- AMD ---
  if command -v rocminfo >/dev/null && rocminfo 2>/dev/null | grep -q 'gfx'; then
    info "AMD GPU with ROCm found."
    BACKEND="rocm"; return
  fi
  if grep -Eqi 'amd|ati|radeon' <<<"$pci"; then
    warn "AMD GPU present but ROCm isn't installed. Using CPU."
    warn "Install ROCm, then re-run with --rocm (AMD support upstream is experimental)."
    BACKEND="cpu"; return
  fi

  info "No supported GPU found. Installing CPU-only build."
  BACKEND="cpu"
}

# ---------------------------------------------------------------- python ---
ensure_uv() {
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
  if ! command -v uv >/dev/null; then
    info "Installing uv (Python version manager)..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
  fi
  command -v uv >/dev/null || die "uv install failed."
  ok "uv $(uv --version | awk '{print $2}') ready."
}

# ------------------------------------------------------------------ repo ---
fetch_repo() {
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    info "Updating existing checkout in $INSTALL_DIR..."
    git -C "$INSTALL_DIR" fetch --all --tags
    if [[ -n "$GIT_REF" ]]; then
      git -C "$INSTALL_DIR" checkout "$GIT_REF"
    fi
    git -C "$INSTALL_DIR" pull --ff-only || warn "Couldn't fast-forward (detached ref or local changes). Keeping current checkout."
  else
    info "Cloning $REPO_URL into $INSTALL_DIR..."
    git clone --depth 1 ${GIT_REF:+--branch "$GIT_REF"} "$REPO_URL" "$INSTALL_DIR" \
      || git clone "$REPO_URL" "$INSTALL_DIR"
    [[ -n "$GIT_REF" ]] && git -C "$INSTALL_DIR" checkout "$GIT_REF" 2>/dev/null || true
  fi
  [[ -f "$INSTALL_DIR/server/requirements.txt" ]] || die "server/requirements.txt not found. Repo layout may have changed."
  ok "Repository ready."
}

# ---------------------------------------------------------- python deps ---
install_python_deps() {
  local venv="$INSTALL_DIR/.venv"
  local req="$INSTALL_DIR/server/requirements.txt"
  local filtered="$INSTALL_DIR/server/requirements.$BACKEND.txt"

  info "Creating Python $PY_VERSION virtual environment..."
  uv venv --seed --allow-existing --python "$PY_VERSION" "$venv"
  PY="$venv/bin/python"
  PIP=("$PY" -m pip)

  # fairseq 0.12.2 depends on omegaconf 2.0.x, whose metadata pip >= 24.1 rejects.
  # pyworld/fairseq also build from source and need numpy + cython present first.
  info "Pinning build tooling (pip<24.1, setuptools<70)..."
  "${PIP[@]}" install --upgrade "pip<24.1" "setuptools<70" wheel cython

  local numpy_spec
  numpy_spec="$(grep -Ei '^[[:space:]]*numpy[[:space:]]*[=<>~]' "$req" | head -n1 | tr -d '[:space:]' || true)"
  "${PIP[@]}" install "${numpy_spec:-numpy==1.23.5}"

  info "Installing PyTorch $TORCH_VERSION for backend: $BACKEND"
  case "$BACKEND" in
    cuda) local idx="https://download.pytorch.org/whl/cu118" ;;
    rocm) local idx="https://download.pytorch.org/whl/rocm5.4.2" ;;
    *)    local idx="https://download.pytorch.org/whl/cpu" ;;
  esac
  "${PIP[@]}" install "torch==$TORCH_VERSION" "torchaudio==$TORCHAUDIO_VERSION" --index-url "$idx"

  # Strip torch lines so requirements.txt can't swap our build for a different one
  # (torchcrepe / torchfcpe are kept). On non-NVIDIA, use plain onnxruntime.
  grep -Ev '^[[:space:]]*(torch|torchaudio|torchvision)[[:space:]]*([=<>~!].*)?$' "$req" > "$filtered" || true
  if [[ "$BACKEND" != "cuda" ]]; then
    sed -i -E 's/^[[:space:]]*onnxruntime-gpu/onnxruntime/' "$filtered"
  fi

  info "Installing voice changer requirements (pyworld/fairseq compile here, this takes a while)..."
  "${PIP[@]}" install --no-build-isolation -r "$filtered"

  # Make sure nothing in the requirements pulled torch back to a different build.
  "${PIP[@]}" install "torch==$TORCH_VERSION" "torchaudio==$TORCHAUDIO_VERSION" --index-url "$idx" --no-deps --force-reinstall -q

  ok "Python dependencies installed."
}

verify_install() {
  info "Verifying PyTorch..."
  local result
  result="$("$PY" -c 'import torch; print(torch.__version__, torch.cuda.is_available())' 2>&1)" \
    || die "PyTorch import failed: $result"
  info "torch: $result"
  if [[ "$BACKEND" != "cpu" && "$result" != *True ]]; then
    warn "GPU backend installed but torch can't see the GPU. Check drivers. The server will still run on CPU."
  fi
  "$PY" -c 'import sounddevice' 2>/dev/null || warn "sounddevice can't load PortAudio. Check libportaudio2 is installed."
}

# ---------------------------------------------------------------- launcher ---
write_launcher() {
  local launcher="$INSTALL_DIR/start.sh"
  local https_flags="--https true --httpsSelfSigned true"
  (( USE_HTTPS )) || https_flags="--https false"

  local wsl_line=""
  grep -qi microsoft /proc/version 2>/dev/null && wsl_line='export LD_LIBRARY_PATH="/usr/lib/wsl/lib:${LD_LIBRARY_PATH:-}"'

  cat > "$launcher" <<EOF
#!/usr/bin/env bash
# Generated by install-voice-changer.sh (backend: $BACKEND)
# Missing pretrained weights are downloaded into server/pretrain on first start.
set -e
cd "\$(dirname "\$(readlink -f "\$0")")/server"
$wsl_line
exec ../.venv/bin/python MMVCServerSIO.py -p \${VC_PORT:-$PORT} $https_flags \\
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
  "\$@"
EOF
  chmod +x "$launcher"
  printf 'backend=%s\ntorch=%s\nport=%s\ninstalled=%s\n' \
    "$BACKEND" "$TORCH_VERSION" "$PORT" "$(date -Is)" > "$INSTALL_DIR/.install-info"
  ok "Launcher written: $launcher"
}

install_service() {
  command -v systemctl >/dev/null || { warn "systemd not available, skipping service."; return; }
  local unit="/etc/systemd/system/voice-changer.service"
  info "Installing systemd service ($unit)..."
  $SUDO tee "$unit" >/dev/null <<EOF
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
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now voice-changer.service
  ok "Service enabled. Logs: journalctl -u voice-changer -f"
}

# ------------------------------------------------------------------- main ---
main() {
  info "Install dir: $INSTALL_DIR | Port: $PORT"
  install_system_deps
  detect_backend
  ensure_uv
  fetch_repo
  install_python_deps
  verify_install
  write_launcher
  (( INSTALL_SERVICE )) && install_service

  local ip scheme
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  scheme="https"; (( USE_HTTPS )) || scheme="http"

  echo
  ok "Done. Backend: ${BACKEND^^}"
  echo "   Start:   $INSTALL_DIR/start.sh"
  echo "   Open:    $scheme://localhost:$PORT   (or $scheme://${ip:-<server-ip>}:$PORT from another machine)"
  (( USE_HTTPS )) && echo "   The certificate is self-signed, so accept the browser warning. Use a Chromium-based browser."
  echo "   First start downloads the pretrained weights, so give it a few minutes."
  if command -v ufw >/dev/null && $SUDO ufw status 2>/dev/null | grep -q active; then
    echo "   ufw is active. To allow LAN access: sudo ufw allow $PORT/tcp"
  fi
  if [[ "$BACKEND" == "cpu" ]]; then
    echo
    warn "CPU mode tips: use the rmvpe_onnx or crepe_tiny f0 detector, raise the chunk size,"
    warn "and prefer ONNX models. Expect noticeably more latency than on a GPU."
  fi
}

main "$@"
