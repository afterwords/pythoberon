#!/usr/bin/env bash
# fetch-ipxe.sh: Download pre-compiled x86_64 UEFI iPXE binary (ipxe.efi).
# NOTE: The server is aarch64, but the target BC-250 nodes are x86_64 UEFI.
# We fetch upstream x86_64 ipxe.efi and never build/fetch for host aarch64.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEST_DIR="${REPO_ROOT}/tftp"
DEST_FILE="${DEST_DIR}/ipxe.efi"
TMP_FILE="${DEST_FILE}.tmp.$$"

# Candidate download URLs for x86_64 UEFI iPXE
# boot.ipxe.org organizes EFI binaries under architecture folders (x86_64-efi/)
CANDIDATE_URLS=(
    "${IPXE_URL:-https://boot.ipxe.org/x86_64-efi/ipxe.efi}"
    "https://boot.ipxe.org/x86_64-efi/snponly.efi"
)

mkdir -p "${DEST_DIR}"

echo "==> Fetching x86_64 UEFI iPXE binary..."
echo "    Target: ${DEST_FILE}"

DOWNLOAD_SUCCESS=false

for url in "${CANDIDATE_URLS[@]}"; do
    echo "    Trying URL: ${url} ..."
    if curl -fsSL --retry 3 --retry-delay 2 -o "${TMP_FILE}" "${url}" 2>/dev/null; then
        # Check that file size is reasonable and has PE/COFF MZ magic header
        file_size="$(wc -c < "${TMP_FILE}" | tr -d ' ')"
        magic="$(head -c 2 "${TMP_FILE}" 2>/dev/null || true)"
        if [[ "${file_size}" -ge 50000 && "${magic}" == "MZ" ]]; then
            echo "    [PASS] Successfully downloaded from ${url} (${file_size} bytes)"
            DOWNLOAD_SUCCESS=true
            break
        else
            echo "    [WARN] Download from ${url} was invalid (size=${file_size}, magic=${magic}). Trying next..."
            rm -f "${TMP_FILE}"
        fi
    else
        echo "    [WARN] Fetch failed for ${url}. Trying next candidate..."
    fi
done

# If standalone EFI downloads failed, attempt fetching and extracting official ipxeboot.tar.gz release
if [[ "${DOWNLOAD_SUCCESS}" != "true" ]]; then
    RELEASE_TAR_URL="https://github.com/ipxe/ipxe/releases/latest/download/ipxeboot.tar.gz"
    echo "    Trying fallback release archive: ${RELEASE_TAR_URL} ..."
    TMP_TAR="${DEST_DIR}/ipxeboot.tar.gz.tmp.$$"
    if curl -fsSL --retry 3 --retry-delay 2 -o "${TMP_TAR}" "${RELEASE_TAR_URL}" 2>/dev/null; then
        echo "    Extracting x86_64-efi/ipxe.efi from release archive..."
        if tar -xzf "${TMP_TAR}" -O x86_64-efi/ipxe.efi > "${TMP_FILE}" 2>/dev/null || \
           tar -xzf "${TMP_TAR}" -O ./x86_64-efi/ipxe.efi > "${TMP_FILE}" 2>/dev/null || \
           tar -xzf "${TMP_TAR}" --wildcards -O "*x86_64-efi/ipxe.efi" > "${TMP_FILE}" 2>/dev/null; then
            file_size="$(wc -c < "${TMP_FILE}" | tr -d ' ')"
            magic="$(head -c 2 "${TMP_FILE}" 2>/dev/null || true)"
            if [[ "${file_size}" -ge 50000 && "${magic}" == "MZ" ]]; then
                echo "    [PASS] Extracted valid ipxe.efi (${file_size} bytes)"
                DOWNLOAD_SUCCESS=true
            fi
        fi
        rm -f "${TMP_TAR}"
    fi
fi

if [[ "${DOWNLOAD_SUCCESS}" != "true" ]]; then
    echo "ERROR: Failed to download a valid x86_64 UEFI ipxe.efi from all candidate URLs." >&2
    echo "       Please check network access or download ipxe.efi manually into: ${DEST_FILE}" >&2
    rm -f "${TMP_FILE}"
    exit 1
fi

mv "${TMP_FILE}" "${DEST_FILE}"
chmod 0644 "${DEST_FILE}"

# Also copy ipxe.efi into www/ for UEFI HTTP IPv4 boot
# (Must be a real file copy, not a symlink, so the Nginx container can read it)
mkdir -p "${REPO_ROOT}/www"
rm -f "${REPO_ROOT}/www/ipxe.efi"
cp -f "${DEST_FILE}" "${REPO_ROOT}/www/ipxe.efi"
chmod 0644 "${REPO_ROOT}/www/ipxe.efi"

echo "==> Successfully staged ${DEST_FILE} (${file_size} bytes)."
echo "==> Copied to ${REPO_ROOT}/www/ipxe.efi for UEFI HTTP Boot."

