#!/usr/bin/env bash
# install.sh: Automated unattended Arch Linux installer for AMD BC-250 nodes.
# Executed as root inside the Arch live environment (via kernel 'script=' parameter).
#
# SAFETY GUARDRAILS:
# 1. MAC Allowlist: Refuses execution unless a local NIC matches NODE_MAP.
# 2. Reinstall Guardrail: Refuses to wipe disks if a 'ROOT' filesystem exists,
#    unless 'reinstall' is passed on the kernel command line.

set -euo pipefail

# ==============================================================================
# CONFIGURATION DISCOVERY & LOADING
# ==============================================================================
# In a network live-boot environment, /config.env is downloaded from the HTTP server.
if [[ ! -f "/config.env" ]]; then
    PROV_SRV=""
    if [[ -f /proc/cmdline ]]; then
        PROV_SRV="$(grep -oE '(script|archiso_http_srv)=https?://[^/]+' /proc/cmdline 2>/dev/null | head -n 1 | cut -d= -f2 || true)"
    fi
    PROV_SRV="${PROV_SRV}"

    echo "Fetching cluster configuration from ${PROV_SRV}/provision/config.env..."
    if curl -fsSL --retry 3 --retry-delay 2 "${PROV_SRV}/provision/config.env" -o "/config.env" 2>/dev/null; then
        echo "Successfully fetched /config.env"
    elif [[ -f "./config.env" ]]; then
        cp "./config.env" "/config.env"
    fi
fi

if [[ -f "/config.env" ]]; then
    # shellcheck disable=SC1091
    source "/config.env"
else
    echo "ERROR: Could not locate or download /config.env from provisioning server." >&2
    exit 1
fi

# ==============================================================================
# CONFIGURATION VARIABLES
# ==============================================================================
SRV="${PROV_SRV:-http://${PROVISIONING_SERVER_IP}}"
DISK="${TARGET_DISK:-/dev/nvme0n1}"       # Target NVMe drive
TZ="${TIMEZONE:-UTC}"

# MAC-to-hostname mapping for the AMD BC-250 cluster nodes (onboard Gigabit NICs).
# Populated from config.env (NODE1_MAC, NODE2_MAC).
declare -A NODE_MAP
if [[ -n "${NODE1_MAC:-}" ]]; then
    NODE_MAP["${NODE1_MAC}"]="${NODE1_HOSTNAME:-pythoberon1}"
fi
if [[ -n "${NODE2_MAC:-}" ]]; then
    NODE_MAP["${NODE2_MAC}"]="${NODE2_HOSTNAME:-pythoberon2}"
fi

# AMD BC-250 memory/Vulkan optimization parameters (from inference cluster report):
# Default: 11.5 GiB GTT pool limit for Mesa RADV Vulkan allocation.
# Node B (RPC worker) gets 12.5 GiB via NODE2_GTT_PAGES_LIMIT in config.env.
GTT_DEFAULT=3014656
if [[ "${TARGET_HOSTNAME}" == "${NODE2_HOSTNAME:-pythoberon2}" ]]; then
    GTT_LIMIT="${NODE2_GTT_PAGES_LIMIT:-3276800}"
else
    GTT_LIMIT=${GTT_DEFAULT}
fi
KERNEL_EXTRA_OPTS="ttm.pages_limit=${GTT_LIMIT} ttm.page_pool_size=${GTT_LIMIT}"

# ==============================================================================
# HELPER LOGGING
# ==============================================================================
log() {
    echo -e "\n\033[1;32m==>\033[0m \033[1m$*\033[0m"
}

warn() {
    echo -e "\033[1;33m[WARN]\033[0m $*" >&2
}

err() {
    echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
}

# ==============================================================================
# DNS: ENSURE RELIABLE RESOLVER IN LIVE ENVIRONMENT
# ==============================================================================
# The router's DNS forwarder may block or fail to resolve external GPG key servers.
# Append 8.8.8.8 as a fallback so that pacstrap, curl, and GPG fetches all work.
log "Ensuring reliable DNS in live environment..."
if ! grep -q "nameserver 8.8.8.8" /etc/resolv.conf; then
    echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    log "Added 8.8.8.8 to /etc/resolv.conf as fallback DNS."
fi

# ==============================================================================
# GUARDRAIL 1: MAC ALLOWLIST CHECK
# ==============================================================================
log "Running Guardrail 1: Checking local network interfaces against MAC allowlist..."

MATCHED_MAC=""
TARGET_HOSTNAME=""

# Collect all local MAC addresses (normalized to lowercase)
LOCAL_MACS=()
for iface in /sys/class/net/*; do
    if [[ -f "${iface}/address" ]]; then
        mac="$(tr '[:upper:]' '[:lower:]' < "${iface}/address" | tr -d ' ')"
        if [[ -n "${mac}" && "${mac}" != "00:00:00:00:00:00" ]]; then
            LOCAL_MACS+=("${mac}")
        fi
    fi
done

for mac in "${LOCAL_MACS[@]}"; do
    for allowed_mac in "${!NODE_MAP[@]}"; do
        normalized_allowed="$(echo "${allowed_mac}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')"
        if [[ "${mac}" == "${normalized_allowed}" ]]; then
            MATCHED_MAC="${mac}"
            TARGET_HOSTNAME="${NODE_MAP[${allowed_mac}]}"
            break 2
        fi
    done
done

if [[ -z "${MATCHED_MAC}" || -z "${TARGET_HOSTNAME}" ]]; then
    err "No local network interface matches the authorized cluster node allowlist."
    err "Detected local MACs: ${LOCAL_MACS[*]:-none}"
    err "Authorized MACs:     ${!NODE_MAP[*]}"
    err "Aborting installation to prevent accidental data loss."
    exit 1
fi

log "Authorized node detected!"
echo "    Assigned Hostname: ${TARGET_HOSTNAME}"
echo "    PXE Interface MAC: ${MATCHED_MAC}"

# ==============================================================================
# GUARDRAIL 2: EXISTING INSTALLATION CHECK
# ==============================================================================
log "Running Guardrail 2: Checking for existing installation on ${DISK}..."

CMDLINE="$(cat /proc/cmdline)"
REINSTALL_REQUESTED=false

if grep -qE "(^|[[:space:]])reinstall([[:space:]]|$)" <<< "${CMDLINE}"; then
    REINSTALL_REQUESTED=true
fi

# Check if any block device or partition has filesystem label 'ROOT'
EXISTING_ROOT="$(blkid -L ROOT || true)"

if [[ -n "${EXISTING_ROOT}" ]]; then
    if [[ "${REINSTALL_REQUESTED}" == "true" ]]; then
        warn "Existing 'ROOT' filesystem detected at ${EXISTING_ROOT}."
        warn "'reinstall' flag found in kernel command line. Proceeding with disk wipe."
    else
        log "Target disk already contains an installed filesystem labeled 'ROOT' (${EXISTING_ROOT})."
        log "Skipping installation (exit 0). To force re-provisioning, append 'reinstall' to boot.ipxe."
        exit 0
    fi
fi

# ==============================================================================
# TARGET DISK VALIDATION & PARTITION NAMES
# ==============================================================================
if [[ ! -b "${DISK}" ]]; then
    err "Target disk '${DISK}' does not exist as a block device."
    exit 1
fi

# Determine partition naming suffix (nvme0n1 -> nvme0n1p1, sda -> sda1)
if [[ "${DISK}" =~ [0-9]$ ]]; then
    PART_ESP="${DISK}p1"
    PART_ROOT="${DISK}p2"
else
    PART_ESP="${DISK}1"
    PART_ROOT="${DISK}2"
fi

log "Target Disk Layout:"
echo "    Disk Device: ${DISK}"
echo "    ESP Part:    ${PART_ESP} (1 GiB, FAT32)"
echo "    Root Part:   ${PART_ROOT} (Remaining space, ext4)"

# ==============================================================================
# PARTITIONING & FILESYSTEM CREATION
# ==============================================================================
log "Unmounting any existing mounts on ${DISK}..."
swapoff -a || true
umount -q "${PART_ESP}" 2>/dev/null || true
umount -q "${PART_ROOT}" 2>/dev/null || true
umount -q /mnt/boot 2>/dev/null || true
umount -q /mnt 2>/dev/null || true

log "Wiping partition table and creating GPT layout on ${DISK}..."
wipefs -af "${DISK}"

# Create GPT label, 1 GiB EFI System Partition, and ext4 Root partition
parted -s "${DISK}" mklabel gpt
parted -s "${DISK}" mkpart "ESP" fat32 1MiB 1025MiB
parted -s "${DISK}" set 1 esp on
parted -s "${DISK}" mkpart "ROOT" ext4 1025MiB 100%

# Allow kernel to reread partition table
udevadm settle
sleep 2

log "Formatting partitions..."
mkfs.fat -F 32 -n "ESP" "${PART_ESP}"
mkfs.ext4 -F -L "ROOT" "${PART_ROOT}"

log "Mounting filesystems to /mnt..."
mount "${PART_ROOT}" /mnt
mkdir -p /mnt/boot
mount "${PART_ESP}" /mnt/boot

# ==============================================================================
# BASE SYSTEM INSTALLATION (PACSTRAP)
# ==============================================================================
log "Installing base packages via pacstrap..."
# Wait for pacman keyring initialization if needed
systemctl start archlinux-keyring-wkd-sync.service 2>/dev/null || true

PACKAGES=(
    base
    linux
    linux-firmware
    amd-ucode
    openssh
    sudo
    python
    git
    curl
    vim
    efibootmgr
    pciutils
    which
)

pacstrap -K /mnt "${PACKAGES[@]}"

log "Generating fstab (by UUID)..."
genfstab -U /mnt >> /mnt/etc/fstab

# ==============================================================================
# BASE CONFIGURATION
# ==============================================================================
log "Configuring timezone (${TZ}) and hardware clock..."
arch-chroot /mnt ln -sf "/usr/share/zoneinfo/${TZ}" /etc/localtime
arch-chroot /mnt hwclock --systohc

log "Configuring locale (en_US.UTF-8)..."
sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /mnt/etc/locale.gen
arch-chroot /mnt locale-gen
echo "LANG=en_US.UTF-8" > /mnt/etc/locale.conf

log "Configuring hostname (${TARGET_HOSTNAME})..."
echo "${TARGET_HOSTNAME}" > /mnt/etc/hostname

cat <<EOF > /mnt/etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${TARGET_HOSTNAME}.localdomain ${TARGET_HOSTNAME}
EOF

# ==============================================================================
# USER ACCOUNT & SSH SECURITY
# ==============================================================================
log "Creating admin user '${PROVISIONING_USER}' with passwordless sudo..."
arch-chroot /mnt useradd -m -G wheel -s /bin/bash "${PROVISIONING_USER}"
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /mnt/etc/sudoers.d/10-wheel-nopasswd
chmod 0440 /mnt/etc/sudoers.d/10-wheel-nopasswd

log "Locking root account password..."
arch-chroot /mnt passwd -l root

log "Deploying authorized SSH key from ${SRV}/provision/authorized_keys..."
USER_SSH_DIR="/mnt/home/${PROVISIONING_USER}/.ssh"
mkdir -p "${USER_SSH_DIR}"
if curl -fsSL --retry 3 "${SRV}/provision/authorized_keys" -o "${USER_SSH_DIR}/authorized_keys"; then
    chmod 0700 "${USER_SSH_DIR}"
    chmod 0600 "${USER_SSH_DIR}/authorized_keys"
    arch-chroot /mnt chown -R "${PROVISIONING_USER}:${PROVISIONING_USER}" "/home/${PROVISIONING_USER}/.ssh"
    log "SSH authorized_keys deployed successfully."
else
    warn "Failed to download authorized_keys from ${SRV}/provision/authorized_keys."
fi

# ==============================================================================
# NETWORK CONFIGURATION (systemd-networkd)
# ==============================================================================
log "Configuring systemd-networkd for PXE NIC (${MATCHED_MAC})..."
# Only manage the onboard PXE NIC via DHCP. The secondary 2.5GbE direct interconnect
# is intentionally unmanaged here and configured later.
mkdir -p /mnt/etc/systemd/network
cat <<EOF > /mnt/etc/systemd/network/10-lan-pxe.network
[Match]
MACAddress=${MATCHED_MAC}

[Network]
DHCP=yes
DNS=8.8.8.8
DNS=8.8.4.4
FallbackDNS=1.1.1.1

[DHCPv4]
UseDNS=yes
UseDomains=yes
EOF

log "Enabling systemd core services..."
arch-chroot /mnt systemctl enable sshd systemd-networkd systemd-resolved systemd-timesyncd

# ==============================================================================
# BOOTLOADER INSTALLATION (systemd-boot)
# ==============================================================================
log "Installing systemd-boot to /boot..."
arch-chroot /mnt bootctl --path=/boot install

cat <<EOF > /mnt/boot/loader/loader.conf
default arch.conf
timeout 3
console-mode max
editor no
EOF

ROOT_UUID="$(blkid -s UUID -o value "${PART_ROOT}")"

log "Creating bootloader entry for Arch Linux (UUID=${ROOT_UUID})..."
cat <<EOF > /mnt/boot/loader/entries/arch.conf
title   Arch Linux
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options root=UUID=${ROOT_UUID} rw ${KERNEL_EXTRA_OPTS}
EOF

# ==============================================================================
# PERSIST CLUSTER CONFIGURATION & POST-BOOT SCRIPTS
# ==============================================================================
log "Persisting cluster configuration to target filesystem..."
mkdir -p /mnt/etc/bc250
if [[ -f "/config.env" ]]; then
    cp "/config.env" /mnt/etc/bc250/config.env
    chmod 0600 /mnt/etc/bc250/config.env
    arch-chroot /mnt ln -sf /etc/bc250/config.env /config.env
fi

log "Staging convert.sh into target user home directory..."
if curl -fsSL --retry 3 "${SRV}/provision/convert.sh" -o "/mnt/home/${PROVISIONING_USER}/convert.sh"; then
    chmod 0755 "/mnt/home/${PROVISIONING_USER}/convert.sh"
    arch-chroot /mnt chown "${PROVISIONING_USER}:${PROVISIONING_USER}" "/home/${PROVISIONING_USER}/convert.sh"
fi

log "Staging setup-llama-server.sh into target user home directory..."
if curl -fsSL --retry 3 "${SRV}/provision/setup-llama-server.sh" -o "/mnt/home/${PROVISIONING_USER}/setup-llama-server.sh"; then
    chmod 0755 "/mnt/home/${PROVISIONING_USER}/setup-llama-server.sh"
    arch-chroot /mnt chown "${PROVISIONING_USER}:${PROVISIONING_USER}" "/home/${PROVISIONING_USER}/setup-llama-server.sh"
fi

# ==============================================================================
# COMPLETION & REBOOT
# ==============================================================================
log "Cleaning up and unmounting filesystems..."
sync
umount /mnt/boot
umount /mnt

log "========================================================================"
log " Arch Linux unattended installation complete for ${TARGET_HOSTNAME}!"
log " The system will now reboot from local NVMe (${DISK})."
log " Post-boot: Run convert.sh over SSH to convert node to CachyOS."
log "========================================================================"

sleep 5
reboot
