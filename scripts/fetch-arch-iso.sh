#!/usr/bin/env bash
# fetch-arch-iso.sh: Download Arch Linux x86_64 live install ISO and verify SHA256 checksum
# Large ISO artifacts are saved in ./iso/ (gitignored).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEST_DIR="${REPO_ROOT}/iso"
ARCH_VERSION="${ARCH_VERSION:-latest}"
MIRROR_URL="${ARCH_MIRROR:-https://geo.mirror.pkgbuild.com/iso/${ARCH_VERSION}}"

echo "==> Preparing to fetch Arch Linux ISO..."
echo "    Mirror URL: ${MIRROR_URL}"
echo "    Target Dir: ${DEST_DIR}"

mkdir -p "${DEST_DIR}"

# Step 1: Download sha256sums.txt
echo "==> Downloading sha256sums.txt..."
curl -fsSL --retry 3 -o "${DEST_DIR}/sha256sums.txt" "${MIRROR_URL}/sha256sums.txt"

# Step 2: Determine ISO filename from sha256sums.txt
ISO_NAME="$(awk '{print $2}' "${DEST_DIR}/sha256sums.txt" | grep -E '^(\*| )?archlinux-.*\.iso$' | sed 's/^\*//' | head -n 1 || true)"
if [[ -z "${ISO_NAME}" ]]; then
    ISO_NAME="archlinux-x86_64.iso"
fi

ISO_PATH="${DEST_DIR}/${ISO_NAME}"
echo "==> Identified ISO: ${ISO_NAME}"

# Step 3: Check if local ISO already exists and passes checksum
verify_checksum() {
    local target_iso="$1"
    local iso_file
    iso_file="$(basename "${target_iso}")"

    if command -v sha256sum >/dev/null 2>&1; then
        (cd "${DEST_DIR}" && grep -E "( |\*)${iso_file}\$" sha256sums.txt | sha256sum -c --status -)
        return $?
    elif command -v shasum >/dev/null 2>&1; then
        (cd "${DEST_DIR}" && grep -E "( |\*)${iso_file}\$" sha256sums.txt | shasum -a 256 -c --status -)
        return $?
    else
        echo "ERROR: Neither sha256sum nor shasum is available to verify checksum." >&2
        return 1
    fi
}

if [[ -f "${ISO_PATH}" ]]; then
    echo "==> Local ISO exists. Checking SHA256 integrity..."
    if verify_checksum "${ISO_PATH}"; then
        echo "==> Existing ISO matches SHA256 checksum. Skipping download."
    else
        echo "WARNING: Existing ISO failed checksum. Re-downloading..."
        rm -f "${ISO_PATH}"
    fi
fi

# Step 4: Download the ISO if not present or corrupt
if [[ ! -f "${ISO_PATH}" ]]; then
    echo "==> Downloading ${ISO_NAME} (this may take a few minutes)..."
    curl -fL --retry 3 --retry-delay 2 -C - -o "${ISO_PATH}" "${MIRROR_URL}/${ISO_NAME}"

    echo "==> Verifying SHA256 checksum..."
    if ! verify_checksum "${ISO_PATH}"; then
        echo "ERROR: Checksum verification failed for ${ISO_PATH}" >&2
        exit 1
    fi
    echo "==> SHA256 verification successful."
fi

# Step 5: Symlink to archlinux-latest.iso for stage script convenience
ln -sf "${ISO_NAME}" "${DEST_DIR}/archlinux-latest.iso"

# Step 6: Attempt GPG signature verification if signature exists & gpg is installed
SIG_NAME="${ISO_NAME}.sig"
SIG_PATH="${DEST_DIR}/${SIG_NAME}"

echo "==> Fetching ISO GPG signature (${SIG_NAME})..."
if curl -fsSL --retry 2 -o "${SIG_PATH}" "${MIRROR_URL}/${SIG_NAME}" 2>/dev/null; then
    if command -v gpg >/dev/null 2>&1; then
        echo "==> GPG found. Attempting signature verification..."
        if gpg --verify "${SIG_PATH}" "${ISO_PATH}" 2>/dev/null; then
            echo "==> GPG signature verified successfully."
        else
            echo "NOTE: GPG signature verification could not establish trust."
            echo "      (Arch release keys may not be in local GPG keyring; SHA256 check passed)."
        fi
    else
        echo "NOTE: 'gpg' not found on system. Skipping GPG signature check (SHA256 was verified)."
    fi
else
    echo "NOTE: Signature file ${SIG_NAME} not found on mirror; SHA256 verified."
fi

echo "==> Finished. ISO staged at: ${ISO_PATH}"

