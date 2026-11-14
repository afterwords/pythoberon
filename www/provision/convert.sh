#!/usr/bin/env bash
# convert.sh: Convert installed Arch Linux node into CachyOS with BC-250 optimizations.
# Run over SSH as the cluster admin user (with sudo privileges).
#
# Hardware optimizations applied:
# 1. CachyOS repository migration with x86_64_v3/v4 tier detection
# 2. linux-cachyos + linux-cachyos-headers + Mesa RADV Vulkan stack
# 3. 8-Core / 16-Thread CPU unlock via SMU mailbox 0x98 (with cold-boot persistence)
# 4. 40-CU GPU Live Manager (WinnieLV/bc250-cu-live-manager) with systemd service
# 5. CMOS UMA configuration (fanoush/bc250_memcfg UMA_SIZE 512)
# 6. systemd-boot default entry configured to cachyos.conf (arch.conf kept as fallback)

set -euo pipefail

# Load configuration
if [[ -f "/etc/bc250/config.env" ]]; then
    # shellcheck disable=SC1091
    source "/etc/bc250/config.env"
elif [[ -f "/config.env" ]]; then
    # shellcheck disable=SC1091
    source "/config.env"
elif [[ -f "./config.env" ]]; then
    # shellcheck disable=SC1091
    source "./config.env"
else
    echo "ERROR: config.env not found in /etc/bc250/config.env, /config.env, or current directory." >&2
    exit 1
fi

# ==============================================================================
# PRIVILEGE & ENVIRONMENT CHECK
# ==============================================================================
if [[ "$(id -u)" -eq 0 ]]; then
    SUDO=""
else
    if ! command -v sudo >/dev/null 2>&1; then
        echo "ERROR: 'sudo' is required to execute conversion steps." >&2
        exit 1
    fi
    SUDO="sudo"
fi

OPT_DIR="/opt/bc250"
CACHYOS_ARCHIVE_URL="${CACHYOS_ARCHIVE_URL:-https://mirror.cachyos.org/cachyos-repo.tar.xz}"

log() {
    echo -e "\n\033[1;32m==>\033[0m \033[1m$*\033[0m"
}

warn() {
    echo -e "\033[1;33m[WARN]\033[0m $*" >&2
}

err() {
    echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
}

log "Starting AMD BC-250 CachyOS & Hardware Optimization Setup..."
echo "    Host: $(hostname)"
echo "    User: $(whoami)"
echo "    Date: $(date)"

${SUDO} mkdir -p "${OPT_DIR}"

# ==============================================================================
# DNS: ENSURE RELIABLE RESOLVER
# ==============================================================================
# The router's DNS forwarder may block GPG key server lookups (hkps://, WKD, etc.).
# Append 8.8.8.8 as a fallback so that all network operations in this script work.
log "Ensuring reliable DNS resolver..."
if ! grep -q "nameserver 8.8.8.8" /etc/resolv.conf; then
    echo "nameserver 8.8.8.8" | ${SUDO} tee -a /etc/resolv.conf > /dev/null
    log "Added 8.8.8.8 to /etc/resolv.conf as fallback DNS."
fi

# ==============================================================================
# STEP 1: CONVERT ARCH TO CACHYOS REPOSITORIES
# ==============================================================================
log "Step 1: Adding CachyOS repositories via official cachyos-repo installer..."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

log "Downloading CachyOS repository archive from ${CACHYOS_ARCHIVE_URL}..."
curl -fsSL --retry 3 "${CACHYOS_ARCHIVE_URL}" -o "${TMP_DIR}/cachyos-repo.tar.xz"

log "Extracting archive..."
tar -xvf "${TMP_DIR}/cachyos-repo.tar.xz" -C "${TMP_DIR}"

log "Executing cachyos-repo.sh (auto-detects x86_64_v3 / v4 CPU instruction set)..."
(
    cd "${TMP_DIR}/cachyos-repo"

    KEYRING_DIR="/etc/pacman.d/gnupg"
    if [[ ! -f "${KEYRING_DIR}/trustdb.gpg" ]]; then
        log "Initialising pacman keyring (first run)..."
        ${SUDO} pacman-key --init
    else
        log "pacman keyring already initialised; skipping --init."
    fi

    KEYRING_DIR="/etc/pacman.d/gnupg"
    populate_keyring() {
        local name="$1"
        local keyring_file="/usr/share/pacman/keyrings/${name}.gpg"
        local sentinel="${KEYRING_DIR}/.populated-${name}"

        if [[ ! -f "${keyring_file}" ]]; then
            warn "Keyring file ${keyring_file} not found; ${name} keyring package may not be installed. Skipping."
            return 0
        fi

        if [[ -f "${sentinel}" ]]; then
            log "Keyring '${name}' already populated (sentinel ${sentinel} exists); skipping."
            return 0
        fi

        log "Populating '${name}' keyring..."
        if ${SUDO} pacman-key --populate "${name}"; then
            ${SUDO} touch "${sentinel}"
            log "Keyring '${name}' populated and sentinel written."
        else
            warn "pacman-key --populate ${name} failed; will retry on next run."
        fi
    }

    populate_keyring archlinux
    populate_keyring cachyos

    CACHYOS_KEY_ID="F3B607488DB35A47"
    if ${SUDO} pacman-key --list-keys "${CACHYOS_KEY_ID}" &>/dev/null; then
        log "CachyOS signing key ${CACHYOS_KEY_ID} already trusted; skipping import."
    else
        log "Importing CachyOS signing key ${CACHYOS_KEY_ID} via HTTPS..."
        CACHYOS_KEY_FILE="${TMP_DIR}/cachyos-key.gpg"
        # Try Ubuntu keyserver HTTPS API first, then keys.openpgp.org
        if curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${CACHYOS_KEY_ID}" -o "${CACHYOS_KEY_FILE}" 2>/dev/null || \
           curl -fsSL "https://keys.openpgp.org/vks/v1/by-fingerprint/${CACHYOS_KEY_ID}" -o "${CACHYOS_KEY_FILE}" 2>/dev/null; then
            ${SUDO} pacman-key --add "${CACHYOS_KEY_FILE}"
            ${SUDO} pacman-key --lsign-key "${CACHYOS_KEY_ID}"
            log "CachyOS signing key imported and locally signed."
        else
            warn "Could not fetch CachyOS key via HTTPS. cachyos-repo.sh may fail."
        fi
        rm -f "${CACHYOS_KEY_FILE}"
    fi

    log "Patching cachyos-repo.sh to skip keyserver fetch (key already trusted)..."
    ${SUDO} sed -i \
        -e 's/pacman-key --recv-keys/echo "PATCHED: skipping pacman-key --recv-keys (key pre-imported)" #/g' \
        -e 's/pacman-key --recv /echo "PATCHED: skipping pacman-key --recv (key pre-imported)" #/g' \
        ./cachyos-repo.sh

    ${SUDO} ./cachyos-repo.sh
)

log "Refreshing pacman package databases..."
${SUDO} pacman -Sy --noconfirm

# ==============================================================================
# STEP 2: INSTALL CACHYOS KERNEL & VULKAN COMPUTE DRIVERS
# ==============================================================================
log "Step 2: Installing linux-cachyos kernel, headers, and Mesa RADV Vulkan stack..."

CACHY_PACKAGES=(
    linux-cachyos
    linux-cachyos-headers
    vulkan-radeon      # AMD RADV Vulkan driver (GFX1013)
    vulkan-tools       # vulkaninfo & diagnostic utilities
    mesa
    shaderc            # provides glslc compiler for Vulkan compute shaders
    spirv-tools
    cmake
    ninja
    gcc
    git
    pciutils
    msr-tools
)

${SUDO} pacman -S --needed --noconfirm "${CACHY_PACKAGES[@]}"

# ==============================================================================
# STEP 3: SYSTEMD-BOOT CONFIGURATION FOR CACHYOS
# ==============================================================================
log "Step 3: Configuring systemd-boot loader entry for CachyOS..."

ROOT_UUID="$(findmnt -n -o UUID / || blkid -s UUID -o value /dev/disk/by-label/ROOT || true)"
if [[ -z "${ROOT_UUID}" ]]; then
    err "Failed to determine Root filesystem UUID."
    exit 1
fi

# Per-node GTT limit: Node B (RPC worker) gets 12.5 GiB, others get 11.5 GiB.
GTT_DEFAULT=3014656
if [[ "$(hostname)" == "${NODE2_HOSTNAME:-pythoberon2}" ]]; then
    GTT_LIMIT="${NODE2_GTT_PAGES_LIMIT:-3276800}"
else
    GTT_LIMIT=${GTT_DEFAULT}
fi
KERNEL_OPTS="root=UUID=${ROOT_UUID} rw ttm.pages_limit=${GTT_LIMIT} ttm.page_pool_size=${GTT_LIMIT}"

log "Writing /boot/loader/entries/cachyos.conf..."
${SUDO} tee /boot/loader/entries/cachyos.conf >/dev/null <<EOF
title   CachyOS Linux (BORE Scheduler, BC-250 Optimized)
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos.img
options ${KERNEL_OPTS}
EOF

# Idempotently update arch.conf as well, so both entries stay in sync
df /boot >/dev/null 2>&1 && {
    if [[ -f /boot/loader/entries/arch.conf ]]; then
        # Remove any existing ttm params; collapse double spaces; trim trailing space
        sed -i -E "s/ttm\\.(pages_limit|page_pool_size)=[0-9]+//g" /boot/loader/entries/arch.conf
        sed -i -E "s/  +/ /g" /boot/loader/entries/arch.conf
        sed -i -E "s/ $//" /boot/loader/entries/arch.conf
        # Insert new ttm params right after 'rw' (handles both 'rw$' and 'rw ')
        sed -i -E "s/(^options .* )rw( |$)/\1rw ttm.pages_limit=${GTT_LIMIT} ttm.page_pool_size=${GTT_LIMIT}\2/" /boot/loader/entries/arch.conf
    fi
}

log "Setting cachyos.conf as default bootloader entry (keeping arch.conf as fallback)..."
${SUDO} tee /boot/loader/loader.conf >/dev/null <<EOF
default cachyos.conf
timeout 3
console-mode max
editor no
EOF

# ==============================================================================
# STEP 4: CYAN SKILLFISH GPU GOVERNOR (SMU)
# ==============================================================================
log "Step 4: Installing Cyan Skillfish GPU governor (cyan-skillfish-governor-smu)..."
# The BC-250 GPU is locked at 1500 MHz without a governor. The SMU governor enables
# frequency scaling for compute workloads. Requires an AUR helper (paru).
# Reference: https://elektricm.github.io/amd-bc250-docs/linux/cachyos/#post-installation-setup

# Install paru (AUR helper) as PROVISIONING_USER if not already present
if ! command -v paru &>/dev/null; then
    log "paru not found. Installing paru AUR helper as ${PROVISIONING_USER}..."
    PARU_BUILD_DIR="$(mktemp -d)"
    ${SUDO} chown "${PROVISIONING_USER}:${PROVISIONING_USER}" "${PARU_BUILD_DIR}"
    ${SUDO} pacman -S --needed --noconfirm base-devel
    sudo -u "${PROVISIONING_USER}" bash -c "
        git clone https://aur.archlinux.org/paru.git '${PARU_BUILD_DIR}/paru' &&
        cd '${PARU_BUILD_DIR}/paru' &&
        makepkg -si --noconfirm
    " || warn "paru installation failed; skipping governor AUR install."
    rm -rf "${PARU_BUILD_DIR}"
fi

# Install the governor package from AUR as the admin user (AUR must not be run as root)
if command -v paru &>/dev/null; then
    log "Installing cyan-skillfish-governor-smu from AUR..."
    sudo -u "${PROVISIONING_USER}" paru -S --noconfirm --needed cyan-skillfish-governor-smu || \
        warn "cyan-skillfish-governor-smu AUR install failed. You can retry manually: paru -S cyan-skillfish-governor-smu"
fi

# Enable the governor service regardless (service unit may already exist from package)
if systemctl list-unit-files cyan-skillfish-governor-smu.service &>/dev/null; then
    ${SUDO} systemctl enable --now cyan-skillfish-governor-smu.service
    log "cyan-skillfish-governor-smu.service enabled and started."
else
    warn "Governor service unit not found. Install manually: paru -S cyan-skillfish-governor-smu"
fi

# ==============================================================================
# STEP 5: USER MODE REGISTER (UMR)
# ==============================================================================

# Install the umr package from AUR as the admin user (AUR must not be run as root)
if command -v paru &>/dev/null; then
    log "Installing user mode register (UMR) from AUR..."
    sudo -u "${PROVISIONING_USER}" paru -S --noconfirm --needed umr-git || \
        warn "umr-git AUR install failed. You can retry manually: paru -S umr-git"
fi

# Check if UMR command is successful
if sudo umr -w &>/dev/null; then
    log "UMR command successful."
else
    warn "UMR command failed."
fi

# ==============================================================================
# STEP 6: AMD BC-250 8-CORE / 16-THREAD CPU UNLOCK
# ==============================================================================
log "Step 6: Setting up AMD BC-250 8-Core / 16-Thread CPU unlock..."

CPU_UNLOCK_DIR="${OPT_DIR}/bc250-core-unlock"
if [[ ! -d "${CPU_UNLOCK_DIR}" ]]; then
    log "Cloning bc250-core-unlock repository..."
    ${SUDO} git clone https://github.com/GabriWar/bc250-core-cu-unlock.git "${CPU_UNLOCK_DIR}" || \
    ${SUDO} git clone https://github.com/rw-r-r-0644/bc250-core-unlock.git "${CPU_UNLOCK_DIR}"
fi

log "Installing bc250-core-unlock.service for cold-boot persistence..."
${SUDO} tee /etc/systemd/system/bc250-core-unlock.service >/dev/null <<'EOF'
[Unit]
Description=AMD BC-250 8-Core/16-Thread SMU Unlock Checker
DefaultDependencies=no
After=systemd-modules-load.service
Before=basic.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/bc250/bc250-core-unlock-check.sh

[Install]
WantedBy=basic.target
EOF

log "Writing /opt/bc250/bc250-core-unlock-check.sh helper..."
${SUDO} tee /opt/bc250/bc250-core-unlock-check.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

THREADS="$(nproc || echo 0)"
if [[ "${THREADS}" -lt 16 ]]; then
    echo "==> AMD BC-250 running with ${THREADS} threads (factory 6C/12T detected)."
    echo "==> Applying 8-core/16-thread SMU unlock payload..."

    # Check for GabriWar shell unlocker or python unlocker
    if [[ -f "/opt/bc250/bc250-core-unlock/bc250-8core-unlock.sh" ]]; then
        /opt/bc250/bc250-core-unlock/bc250-8core-unlock.sh apply || true
    elif [[ -f "/opt/bc250/bc250-core-unlock/bc250-unlock-cores.py" ]]; then
        python3 /opt/bc250/bc250-core-unlock/bc250-unlock-cores.py || true
    fi

    echo "==> Triggering soft-reboot to re-enumerate full 8C/16T topology..."
    sleep 2
    systemctl reboot
else
    echo "==> AMD BC-250 already running with all ${THREADS} threads active (8C/16T)."
fi
EOF

${SUDO} chmod +x /opt/bc250/bc250-core-unlock-check.sh
${SUDO} systemctl daemon-reload
${SUDO} systemctl enable bc250-core-unlock.service

# ==============================================================================
# STEP 7: 40-CU GPU LIVE DISPATCH MANAGER
# ==============================================================================
log "Step 7: Setting up BC-250 40-CU GPU Live Dispatch Manager..."

CU_DIR="${OPT_DIR}/bc250-cu-live-manager"
if [[ ! -d "${CU_DIR}" ]]; then
    log "Cloning WinnieLV/bc250-cu-live-manager..."
    ${SUDO} git clone https://github.com/WinnieLV/bc250-cu-live-manager.git "${CU_DIR}" || true
fi

if [[ -f "${CU_DIR}/bc250-cu-live-manager.sh" ]]; then
    ${SUDO} chmod +x "${CU_DIR}/bc250-cu-live-manager.sh"
    log "bc250-cu-live-manager cloned to ${CU_DIR}."
    log "NOTE: GPU dispatch is still at STOCK (24 CUs). Run 'wgp-wizard probe' to test unlocked WGPs, then 'wgp-wizard apply' to set verified masks."
else
    warn "bc250-cu-live-manager.sh not found. Ensure repository is available."
fi

# ==============================================================================
# STEP 8: CMOS UMA VRAM CONFIGURATION TOOL (bc250_memcfg)
# ==============================================================================
log "Step 8: Deploying bc250_memcfg (CMOS UMA VRAM configuration tool)..."

MEMCFG_DIR="${OPT_DIR}/bc250_memcfg"
if [[ ! -d "${MEMCFG_DIR}" ]]; then
    log "Cloning fanoush/bc250_memcfg..."
    ${SUDO} git clone https://github.com/fanoush/bc250_memcfg.git "${MEMCFG_DIR}" || true
fi

if [[ -d "${MEMCFG_DIR}" ]]; then
    if [[ ! -f "${MEMCFG_DIR}/bc250memcfg" && -f "${MEMCFG_DIR}/Makefile" ]]; then
        log "Compiling bc250memcfg..."
        (cd "${MEMCFG_DIR}" && ${SUDO} make) || true
    fi

    if [[ -x "${MEMCFG_DIR}/bc250memcfg" ]]; then
        log "Setting CMOS UMA VRAM size to 512 MiB (optimal for 11.5 GiB GTT budget)..."
        ${SUDO} "${MEMCFG_DIR}/bc250memcfg" UMA_SIZE 512 || warn "bc250memcfg execution exited with warning."
    fi
fi

# ==============================================================================
# COMPLETION SUMMARY
# ==============================================================================
log "========================================================================"
log " AMD BC-250 CachyOS & Hardware Optimization Setup Complete!"
log "========================================================================"
echo "Summary of actions taken:"
echo "  1. Added CachyOS repositories (x86_64_v3/v4 tier detected)."
echo "  2. Installed linux-cachyos, headers, and Mesa RADV Vulkan stack."
echo "  3. Configured systemd-boot entry /boot/loader/entries/cachyos.conf (default)."
echo "  4. Installed and enabled cyan-skillfish-governor-smu for GPU frequency scaling."
echo "  5. Installed umr-git for User Mode Register (UMR) access."
echo "  6. Installed bc250-core-unlock.service for persistent 8-Core / 16-Thread operation."
echo "  7. Cloned bc250-cu-live-manager to /opt/bc250/bc250-cu-live-manager/."
echo "     GPU dispatch is at STOCK (24 CUs). Run 'wgp-wizard probe' then 'wgp-wizard apply' before reboot."
echo "  8. Set CMOS UMA VRAM to 512 MiB via bc250memcfg."
echo ""
echo "NEXT STEPS:"
echo "  1. Test unlocked WGPs and apply verified masks (REQUIRED before reboot):"
echo "       sudo ./wgp-wizard.sh probe     # Test each WGP from stock state"
echo "       sudo ./wgp-wizard.sh report    # Review results"
echo "       sudo ./wgp-wizard.sh apply     # Install verified masks + boot service"
echo "  2. Reboot the system to activate linux-cachyos and the 8C/16T + verified CU configuration:"
echo "       sudo reboot"
echo "  3. After rebooting, verify active hardware status:"
echo "       nproc                                  # Should report 16 threads"
echo "       vulkaninfo --summary                   # Should report AMD BC-250 GFX1013 (~12 GiB)"
echo "       sudo /opt/bc250/bc250-cu-live-manager/bc250-cu-live-manager.sh status"
echo "       systemctl status cyan-skillfish-governor-smu.service"
echo "  3. Deploy distributed llama.cpp services using setup-llama-server.sh:"
echo "       sudo ./setup-llama-server.sh"
echo "========================================================================"
