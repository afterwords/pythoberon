#!/usr/bin/env bash
# stage-iso.sh: Extract Arch Linux ISO contents into www/arch/ for HTTP serving.
# Checks for unprivileged extraction tools (bsdtar, 7z, xorriso) before
# attempting a loop mount fallback.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ISO_DIR="${REPO_ROOT}/iso"
TARGET_DIR="${REPO_ROOT}/www/arch"

# Step 1: Find latest ISO in iso/
ISO_FILE=""
if [[ -f "${ISO_DIR}/archlinux-latest.iso" ]]; then
    ISO_FILE="$(readlink -f "${ISO_DIR}/archlinux-latest.iso" 2>/dev/null || true)"
    if [[ -z "${ISO_FILE}" || ! -f "${ISO_FILE}" ]]; then
        ISO_FILE="${ISO_DIR}/archlinux-latest.iso"
    fi
else
    # Find most recently modified archlinux-*.iso
    ISO_FILE="$(find "${ISO_DIR}" -maxdepth 1 -name "archlinux-*.iso" 2>/dev/null | sort -r | head -n 1 || true)"
fi

if [[ -z "${ISO_FILE}" || ! -f "${ISO_FILE}" ]]; then
    echo "ERROR: No Arch Linux ISO found in ${ISO_DIR}." >&2
    echo "       Run 'make fetch' or 'scripts/fetch-arch-iso.sh' first." >&2
    exit 1
fi

echo "==> Staging Arch Linux ISO..."
echo "    Source ISO: ${ISO_FILE}"
echo "    Target Dir: ${TARGET_DIR}"

mkdir -p "${TARGET_DIR}"

# Step 2: Clean previous extracted files (preserving .gitkeep)
echo "==> Cleaning previous extracted files in ${TARGET_DIR}..."
find "${TARGET_DIR}" -mindepth 1 ! -name '.gitkeep' -delete

# Step 3: Extract ISO using best available unprivileged tool
extract_iso() {
    local iso="$1"
    local dest="$2"

    if command -v bsdtar >/dev/null 2>&1; then
        echo "==> Extracting via bsdtar (unprivileged)..."
        bsdtar -xf "${iso}" -C "${dest}"
        return 0
    elif command -v 7z >/dev/null 2>&1; then
        echo "==> Extracting via 7z (unprivileged)..."
        7z x -y -o"${dest}" "${iso}" >/dev/null
        return 0
    elif command -v xorriso >/dev/null 2>&1; then
        echo "==> Extracting via xorriso (unprivileged)..."
        xorriso -osirrox on -indev "${iso}" -extract / "${dest}" >/dev/null 2>&1
        return 0
    else
        echo "==> No unprivileged extractor found (bsdtar, 7z, xorriso)."
        echo "    Attempting loop mount extraction (requires sudo)..."
        if ! command -v sudo >/dev/null 2>&1; then
            echo "ERROR: Neither bsdtar/7z/xorriso nor sudo is available to extract the ISO." >&2
            echo "       Please install 'libarchive-tools' (for bsdtar) or 'p7zip-full'." >&2
            return 1
        fi
        local mnt
        mnt="$(mktemp -d)"
        sudo mount -o loop,ro "${iso}" "${mnt}"
        cp -a "${mnt}/." "${dest}/"
        sudo umount "${mnt}"
        rmdir "${mnt}"
        return 0
    fi
}

extract_iso "${ISO_FILE}" "${TARGET_DIR}"

# Step 4: Validate required boot artifacts inside extracted tree
REQUIRED_FILES=(
    "arch/boot/x86_64/vmlinuz-linux"
    "arch/boot/x86_64/initramfs-linux.img"
)

echo "==> Validating extracted boot artifacts..."
for rel_path in "${REQUIRED_FILES[@]}"; do
    full_path="${TARGET_DIR}/${rel_path}"
    if [[ ! -f "${full_path}" ]]; then
        echo "ERROR: Expected file missing: ${rel_path}" >&2
        exit 1
    fi
    echo "    [OK] ${rel_path} ($(wc -c < "${full_path}" | tr -d ' ') bytes)"
done

# Check for airootfs (SquashFS or newer EROFS format)
if [[ -f "${TARGET_DIR}/arch/x86_64/airootfs.sfs" ]]; then
    echo "    [OK] arch/x86_64/airootfs.sfs ($(wc -c < "${TARGET_DIR}/arch/x86_64/airootfs.sfs" | tr -d ' ') bytes)"
elif [[ -f "${TARGET_DIR}/arch/x86_64/airootfs.erofs" ]]; then
    echo "    [OK] arch/x86_64/airootfs.erofs ($(wc -c < "${TARGET_DIR}/arch/x86_64/airootfs.erofs" | tr -d ' ') bytes)"
else
    echo "ERROR: Neither airootfs.sfs nor airootfs.erofs found in ${TARGET_DIR}/arch/x86_64/" >&2
    exit 1
fi

echo "==> Arch Linux ISO successfully staged into ${TARGET_DIR}."

