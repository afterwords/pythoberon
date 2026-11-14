#!/usr/bin/env bash
# setup-llama-server.sh: Build & deploy distributed llama.cpp services for AMD BC-250 cluster.
# Installs Vulkan + RPC binaries and configures either bc250-llm (Node 1 router mode) or bc250-rpc (Node 2 worker).

set -euo pipefail

# ==============================================================================
# LOAD CONFIGURATION
# ==============================================================================
if [[ -f "/etc/bc250/config.env" ]]; then
    # shellcheck disable=SC1091
    source "/etc/bc250/config.env"
elif [[ -f "/config.env" ]]; then
    # shellcheck disable=SC1091
    source "/config.env"
elif [[ -f "./config.env" ]]; then
    # shellcheck disable=SC1091
    source "./config.env"
elif [[ -f "$(dirname "${BASH_SOURCE[0]}")/../config.env" ]]; then
    # shellcheck disable=SC1091
    source "$(dirname "${BASH_SOURCE[0]}")/../config.env"
else
    echo "ERROR: config.env not found in /etc/bc250/config.env, /config.env, ./config.env, or repo root." >&2
    exit 1
fi

# ==============================================================================
# LOGGING & ERROR HANDLING
# ==============================================================================
log() {
    echo -e "\n\033[1;32m==>\033[0m \033[1m$*\033[0m"
}

warn() {
    echo -e "\033[1;33m[WARN]\033[0m $*" >&2
}

err() {
    echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
    exit 1
}

# ==============================================================================
# PRE-FLIGHT CHECKS & ENVIRONMENT SETUP
# ==============================================================================
if [[ $EUID -ne 0 ]]; then
   err "This script must be run as root (use sudo)."
fi

# Ensure server user exists and has a home directory
if ! id "${LLAMA_SERVER_USER}" >/dev/null 2>&1; then
    log "Creating server user '${LLAMA_SERVER_USER}'..."
    useradd -m -s /bin/bash "${LLAMA_SERVER_USER}"
fi

# Ensure server user has GPU/Vulkan device access (video, render groups)
for grp in video render; do
    if getent group "${grp}" >/dev/null 2>&1; then
        usermod -aG "${grp}" "${LLAMA_SERVER_USER}" || true
    fi
done

# Resolve server user home directory
if getent passwd "${LLAMA_SERVER_USER}" >/dev/null 2>&1; then
    SERVER_HOME="$(getent passwd "${LLAMA_SERVER_USER}" | cut -d: -f6)"
else
    SERVER_HOME="/home/${LLAMA_SERVER_USER}"
fi

# Models directory and ini config must live in the llama server user's home folder
if [[ -n "${MODEL_DIR:-}" ]]; then
    MODELS_DIR="${MODEL_DIR}"
else
    MODELS_DIR="${SERVER_HOME}/models"
fi

if [[ -n "${MODELS_CONFIG:-}" ]]; then
    MODELS_CONFIG="${MODELS_CONFIG}"
else
    MODELS_CONFIG="${SERVER_HOME}/models.ini"
fi

LLAMA_DIR="/opt/llama.cpp"
OPT_DIR="/opt/bc250"
TEMPLATES_DIR="${OPT_DIR}/templates"

CURRENT_HOST="$(cat /etc/hostname 2>/dev/null || hostname)"
ROLE="${1:-auto}"
IS_NODE2=false
if [[ "${ROLE}" == "node2" || "${ROLE}" == "worker" || "${ROLE}" == "rpc" || ( "${ROLE}" == "auto" && ( "${CURRENT_HOST}" == "${NODE2_HOSTNAME}" || "${CURRENT_HOST}" =~ 2$ ) ) ]]; then
    IS_NODE2=true
fi

log "Starting llama.cpp cluster setup..."
echo "    Host:        ${CURRENT_HOST}"
echo "    Server User: ${LLAMA_SERVER_USER} (${SERVER_HOME})"
echo "    Models Dir:  ${MODELS_DIR}"
echo "    Config File: ${MODELS_CONFIG}"

# ==============================================================================
# DIRECT RPC INTERCONNECT (USB ETHERNET)
# ==============================================================================
if [[ "${IS_NODE2}" == true ]]; then
    DIRECT_IP="${NODE2_DIRECT_IP}"
else
    DIRECT_IP="${NODE1_DIRECT_IP}"
fi

if ! systemctl is-active --quiet systemd-networkd; then
    err "systemd-networkd must be active to configure the dedicated USB Ethernet link."
fi
if ! command -v udevadm >/dev/null 2>&1; then
    err "udevadm is required to identify the USB Ethernet adapter."
fi

USB_INTERFACES=()
USB_INTERFACE_PATHS=()
for net_path in /sys/class/net/*; do
    [[ -e "${net_path}/device" ]] || continue
    udev_properties="$(udevadm info --query=property --path="$(readlink -f "${net_path}")")" \
        || err "Could not read udev properties for ${net_path##*/}."
    if grep -qx "ID_BUS=usb" <<<"${udev_properties}"; then
        interface_path="$(sed -n 's/^ID_PATH=//p' <<<"${udev_properties}")"
        [[ -n "${interface_path}" ]] || err "USB network interface ${net_path##*/} has no udev ID_PATH."
        USB_INTERFACES+=("${net_path##*/}")
        USB_INTERFACE_PATHS+=("${interface_path}")
    fi
done

if [[ "${#USB_INTERFACES[@]}" -ne 1 ]]; then
    err "Expected exactly one USB Ethernet interface for the direct link; found ${#USB_INTERFACES[@]}. Disconnect extra USB network adapters and retry."
fi

DIRECT_INTERFACE="${USB_INTERFACES[0]}"
DIRECT_INTERFACE_PATH="${USB_INTERFACE_PATHS[0]}"
DIRECT_NETWORK_FILE="/etc/systemd/network/20-bc250-direct.network"
log "Configuring USB Ethernet interface ${DIRECT_INTERFACE} (${DIRECT_IP}/30)..."
cat <<EOF > "${DIRECT_NETWORK_FILE}"
[Match]
Path=${DIRECT_INTERFACE_PATH}

[Network]
Address=${DIRECT_IP}/30
LinkLocalAddressing=no
IPv6AcceptRA=no
EOF
networkctl reload
networkctl reconfigure "${DIRECT_INTERFACE}"

# ==============================================================================
# BUILD LLAMA.CPP (VULKAN + RPC)
# ==============================================================================
log "Installing build dependencies..."
pacman -S --needed --noconfirm git cmake base-devel vulkan-devel vulkan-icd-loader mesa vulkan-radeon

if [[ ! -d "${LLAMA_DIR}" ]]; then
    log "Cloning llama.cpp repository..."
    git clone https://github.com/ggml-org/llama.cpp.git "${LLAMA_DIR}"
else
    log "Updating existing llama.cpp repository..."
    (cd "${LLAMA_DIR}" && git pull || true)
fi

log "Compiling llama.cpp with Vulkan and GGML RPC support..."
cmake -B "${LLAMA_DIR}/build" -S "${LLAMA_DIR}" -DGGML_VULKAN=ON -DGGML_RPC=ON
cmake --build "${LLAMA_DIR}/build" --config Release -j "$(nproc)"

log "Installing binaries to /usr/local/bin..."
install -m 755 "${LLAMA_DIR}/build/bin/llama-server" /usr/local/bin/llama-server
install -m 755 "${LLAMA_DIR}/build/bin/ggml-rpc-server" /usr/local/bin/ggml-rpc-server

# ==============================================================================
# API KEY CONFIGURATION
# ==============================================================================
mkdir -p /etc/bc250
API_KEY_FILE="/etc/bc250/api_key.txt"
API_KEY_FLAG=""

if [[ -n "${LLAMA_API_KEY:-}" ]]; then
    echo "${LLAMA_API_KEY}" > "${API_KEY_FILE}"
    chown "${LLAMA_SERVER_USER}:${LLAMA_SERVER_USER}" "${API_KEY_FILE}"
    chmod 0600 "${API_KEY_FILE}"
    API_KEY_FLAG="--api-key-file ${API_KEY_FILE}"
else
    # Remove file if key is not set to prevent accidental usage of stale data
    rm -f "${API_KEY_FILE}"
fi

# ==============================================================================
# MODELS DIRECTORY & PRESET CONFIGURATION
# ==============================================================================
log "Configuring models storage at ${MODELS_DIR}..."
mkdir -p "${MODELS_DIR}"
chown "${LLAMA_SERVER_USER}:${LLAMA_SERVER_USER}" "${MODELS_DIR}"
chmod 0755 "${MODELS_DIR}"

if [[ ! -f "${MODELS_CONFIG}" ]]; then
    log "Writing model definitions configuration to ${MODELS_CONFIG}..."
    mkdir -p "$(dirname "${MODELS_CONFIG}")"
    cat <<EOF > "${MODELS_CONFIG}"
# ==============================================================================
# llama-server model preset configuration
# Location: ${MODELS_CONFIG}
# ==============================================================================

# Global hardware and cluster defaults applied to all models
[*]
rpc = ${NODE2_DIRECT_IP}:${RPC_PORT}
device = Vulkan0,RPC0
split-mode = layer
n-gpu-layers = all
fit = off
parallel = ${LLAMA_PARALLEL}
cache-type-k = ${LLAMA_CACHE_K}
cache-type-v = ${LLAMA_CACHE_V}
flash-attn = ${LLAMA_FLASH_ATTN}
jinja = true
cache-ram = 512

# Primary model definition (points to local GGUF in ${LLAMA_MODEL_DIR} or remote Hugging Face reference)
[${DEFAULT_MODEL}]
model = ${LLAMA_MODEL_DIR}/${LLAMA_MODEL_NAME}.gguf
# Remote Hugging Face reference (optional fallback):
# hf = ${DEFAULT_MODEL_HF}
ctx-size = ${DEFAULT_MODEL_CTX_SIZE}
tensor-split = ${DEFAULT_MODEL_TENSOR_SPLIT}
no-mmproj = true
temp = 0.6
top-p = 0.95
top-k = 20
min-p = 0
reasoning = ${DEFAULT_MODEL_REASONING}
reasoning-budget = ${DEFAULT_MODEL_REASONING_BUDGET}
repeat-penalty = ${DEFAULT_MODEL_REPEAT_PENALTY}

EOF
    chown "${LLAMA_SERVER_USER}:${LLAMA_SERVER_USER}" "${MODELS_CONFIG}"
    chmod 0644 "${MODELS_CONFIG}"
    log "Created model definitions configuration file at ${MODELS_CONFIG}."
else
    log "Model configuration ${MODELS_CONFIG} already exists; preserving existing file."
fi

# ==============================================================================
# SYSTEMD SERVICE DEFINITIONS
# ==============================================================================
mkdir -p "${TEMPLATES_DIR}"

# 1. RPC Worker service template (Node 2 / Worker)
cat <<EOF > "${TEMPLATES_DIR}/bc250-rpc.service"
[Unit]
Description=BC250 Vulkan RPC worker
Wants=network-online.target
Requires=bc250-cu-live-manager.service
After=network-online.target bc250-cu-live-manager.service

[Service]
Type=simple
User=${LLAMA_SERVER_USER}
Environment=HOME=${SERVER_HOME}
WorkingDirectory=/usr/local/bin
ExecStart=/usr/local/bin/ggml-rpc-server -H ${NODE2_DIRECT_IP} -p ${RPC_PORT} -c
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

# 2. Primary llama-server service template (Node 1 / Leader)
# Runs llama-server in router mode without preloading a model.
cat <<EOF > "${TEMPLATES_DIR}/bc250-llm.service"
[Unit]
Description=BC250 distributed llama.cpp inference service
Wants=network-online.target
Requires=bc250-cu-live-manager.service
After=network-online.target bc250-cu-live-manager.service

[Service]
Type=simple
User=${LLAMA_SERVER_USER}
Environment=HOME=${SERVER_HOME}
WorkingDirectory=${SERVER_HOME}
# Wait for Node 2's RPC port to be open before starting
ExecStartPre=/usr/bin/bash -c 'if [[ -n "${NODE2_DIRECT_IP}" && "${NODE2_DIRECT_IP}" != "127.0.0.1" ]]; then for i in {1..60}; do (: > /dev/tcp/${NODE2_DIRECT_IP}/${RPC_PORT}) 2>/dev/null && exit 0; sleep 2; done; fi; exit 0'
ExecStart=/usr/local/bin/llama-server \\
    --host ${NODE1_IP} \\
    --port ${LLAMA_SERVER_PORT} \\
    --models-dir ${LLAMA_MODEL_DIR} \\
    --models-preset ${MODELS_CONFIG} \\
    --models-max 1 \\
    ${API_KEY_FLAG}
Restart=on-failure
RestartSec=10
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

# ==============================================================================
# DEPLOY AND ENABLE SYSTEMD SERVICE
# ==============================================================================
if [[ "${IS_NODE2}" == true ]]; then
    log "Configuring Node 2 role: Enabling bc250-rpc.service (RPC Worker)..."
    cp "${TEMPLATES_DIR}/bc250-rpc.service" /etc/systemd/system/bc250-rpc.service
    systemctl daemon-reload
    systemctl enable --now bc250-rpc.service
    log "bc250-rpc.service enabled and started on port ${RPC_PORT}."
else
    log "Configuring Node 1 role: Enabling bc250-llm.service (Inference Primary)..."
    cp "${TEMPLATES_DIR}/bc250-llm.service" /etc/systemd/system/bc250-llm.service
    systemctl daemon-reload
    systemctl enable --now bc250-llm.service
    log "bc250-llm.service enabled and started on port ${LLAMA_SERVER_PORT}."
fi

log "========================================================================"
log " Llama.cpp cluster setup complete for ${CURRENT_HOST}!"
log "========================================================================"
echo "Summary:"
echo "  Binaries:      /usr/local/bin/llama-server, /usr/local/bin/ggml-rpc-server"
echo "  Models Dir:    ${MODELS_DIR}"
echo "  Models Config: ${MODELS_CONFIG}"
echo "  API Key:       /etc/bc250/api_key.txt"
if [[ "${IS_NODE2}" == true ]]; then
    echo "  Active Unit:   bc250-rpc.service (listening on port ${RPC_PORT})"
else
    echo "  Active Unit:   bc250-llm.service (listening on port ${LLAMA_SERVER_PORT})"
    echo "  Mode:          Router mode (no model loaded until requested)"
fi
echo "========================================================================"
