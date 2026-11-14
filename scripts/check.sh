#!/usr/bin/env bash
# check.sh: End-to-end verification for PXE provisioning repository.
# Performs:
#   1. Static file structure & iPXE syntax validation
#   2. Live HTTP endpoint testing with curl
#   3. Live TFTP fetch testing for x86_64 UEFI ipxe.efi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PXE_HOST="${PXE_HOST:-127.0.0.1}"
HTTP_PORT="${HTTP_PORT:-80}"

ERRORS=0

echo "=================================================================="
echo " [Stage 1] Local File & Configuration Sanity Check"
echo "=================================================================="

# Check boot.ipxe
printf "  Checking %-42s ... " "www/boot.ipxe"
if [[ -f "${REPO_ROOT}/www/boot.ipxe" ]]; then
    # Verify critical kernel parameters exist in the iPXE script
    if grep -q "archiso_http_srv=" "${REPO_ROOT}/www/boot.ipxe" && \
       grep -q "archisobasedir=" "${REPO_ROOT}/www/boot.ipxe" && \
       grep -q "script=" "${REPO_ROOT}/www/boot.ipxe"; then
        echo "[PASS]"
    else
        echo "[FAIL] (Missing required kernel parameters in boot.ipxe)"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "[FAIL] (File not found)"
    ERRORS=$((ERRORS + 1))
fi

# Check autoexec.ipxe
printf "  Checking %-42s ... " "www/autoexec.ipxe"
if [[ -f "${REPO_ROOT}/www/autoexec.ipxe" ]]; then
    echo "[PASS]"
else
    echo "[FAIL] (File not found)"
    ERRORS=$((ERRORS + 1))
fi

# Check authorized_keys
printf "  Checking %-42s ... " "www/provision/authorized_keys"
if [[ -f "${REPO_ROOT}/www/provision/authorized_keys" ]]; then
    if grep -qE "^(ssh-rsa|ssh-ed25519|ecdsa-)" "${REPO_ROOT}/www/provision/authorized_keys"; then
        echo "[PASS] (SSH key configured)"
    else
        echo "[WARN] (Contains placeholder comments only - update before deploying)"
    fi
else
    echo "[FAIL] (File not found)"
    ERRORS=$((ERRORS + 1))
fi

# Check shell scripts syntax
for script in "${REPO_ROOT}/scripts"/*.sh "${REPO_ROOT}/www/provision"/*.sh; do
    rel_path="${script#"${REPO_ROOT}/"}"
    printf "  Checking syntax: %-34s ... " "${rel_path}"
    if bash -n "${script}" 2>/dev/null; then
        echo "[PASS]"
    else
        echo "[FAIL]"
        ERRORS=$((ERRORS + 1))
    fi
done

# Check staged bootloader binary on disk
printf "  Checking %-42s ... " "tftp/ipxe.efi"
if [[ -f "${REPO_ROOT}/tftp/ipxe.efi" ]]; then
    magic="$(head -c 2 "${REPO_ROOT}/tftp/ipxe.efi" 2>/dev/null || true)"
    if [[ "${magic}" == "MZ" ]]; then
        echo "[PASS] ($(wc -c < "${REPO_ROOT}/tftp/ipxe.efi" | tr -d ' ') bytes)"
    else
        echo "[FAIL] (Invalid magic header)"
        ERRORS=$((ERRORS + 1))
    fi
else
    echo "[SKIP] (Not fetched yet - run 'make fetch')"
fi

# Check staged Arch ISO assets on disk
printf "  Checking %-42s ... " "www/arch/ kernel & rootfs"
if [[ -f "${REPO_ROOT}/www/arch/arch/boot/x86_64/vmlinuz-linux" && \
      -f "${REPO_ROOT}/www/arch/arch/boot/x86_64/initramfs-linux.img" && \
      ( -f "${REPO_ROOT}/www/arch/arch/x86_64/airootfs.sfs" || -f "${REPO_ROOT}/www/arch/arch/x86_64/airootfs.erofs" ) ]]; then
    echo "[PASS]"
else
    echo "[SKIP] (Not staged yet - run 'make stage')"
fi

echo ""
echo "=================================================================="
echo " [Stage 2] Live Service Endpoints (${PXE_HOST})"
echo "=================================================================="

# Check if HTTP port is reachable
if ! curl -s --connect-timeout 2 "http://${PXE_HOST}:${HTTP_PORT}/" >/dev/null 2>&1; then
    echo "  [INFO] HTTP service on ${PXE_HOST}:${HTTP_PORT} is not responding."
    echo "         To test live network endpoints, start containers with: make up"
    if [[ ${ERRORS} -gt 0 ]]; then
        echo "==> Static validation completed with ${ERRORS} error(s)."
        exit 1
    fi
    echo "==> Static validation passed successfully."
    exit 0
fi

# Helper for HTTP tests
check_http() {
    local url="$1"
    local desc="$2"
    local head_only="${3:-false}"

    printf "  Checking HTTP: %-41s ... " "${desc}"
    local curl_opts=(-fsS --connect-timeout 5)
    if [[ "${head_only}" == "true" ]]; then
        curl_opts+=(-I)
    fi

    if curl "${curl_opts[@]}" "${url}" >/dev/null 2>&1; then
        echo "[PASS]"
    else
        echo "[FAIL]"
        echo "    Failed URL: ${url}" >&2
        ERRORS=$((ERRORS + 1))
    fi
}

check_http "http://${PXE_HOST}:${HTTP_PORT}/boot.ipxe" "boot.ipxe"
check_http "http://${PXE_HOST}:${HTTP_PORT}/autoexec.ipxe" "autoexec.ipxe"
check_http "http://${PXE_HOST}:${HTTP_PORT}/provision/install.sh" "provision/install.sh"
check_http "http://${PXE_HOST}:${HTTP_PORT}/provision/convert.sh" "provision/convert.sh"
check_http "http://${PXE_HOST}:${HTTP_PORT}/provision/setup-llama-server.sh" "provision/setup-llama-server.sh"
check_http "http://${PXE_HOST}:${HTTP_PORT}/provision/config.env" "provision/config.env"
check_http "http://${PXE_HOST}:${HTTP_PORT}/provision/authorized_keys" "provision/authorized_keys"

# Ensure www/ipxe.efi is a real file rather than a symlink to tftp/ipxe.efi,
# because Nginx runs inside a container where ./tftp is not mounted.
if [[ -L "${REPO_ROOT}/www/ipxe.efi" && -f "${REPO_ROOT}/tftp/ipxe.efi" ]]; then
    rm -f "${REPO_ROOT}/www/ipxe.efi"
    cp -f "${REPO_ROOT}/tftp/ipxe.efi" "${REPO_ROOT}/www/ipxe.efi"
fi

if [[ -f "${REPO_ROOT}/www/ipxe.efi" ]]; then
    check_http "http://${PXE_HOST}:${HTTP_PORT}/ipxe.efi" "ipxe.efi (UEFI HTTP Boot)" "true"
fi

# Staged assets
check_http "http://${PXE_HOST}:${HTTP_PORT}/arch/arch/boot/x86_64/vmlinuz-linux" "Kernel (vmlinuz-linux)" "true"
check_http "http://${PXE_HOST}:${HTTP_PORT}/arch/arch/boot/x86_64/initramfs-linux.img" "Initramfs (initramfs-linux.img)" "true"

if curl -fsSI --connect-timeout 5 "http://${PXE_HOST}:${HTTP_PORT}/arch/arch/x86_64/airootfs.sfs" >/dev/null 2>&1; then
    printf "  Checking HTTP: %-41s ... [PASS]\n" "Rootfs (airootfs.sfs)"
elif curl -fsSI --connect-timeout 5 "http://${PXE_HOST}:${HTTP_PORT}/arch/arch/x86_64/airootfs.erofs" >/dev/null 2>&1; then
    printf "  Checking HTTP: %-41s ... [PASS]\n" "Rootfs (airootfs.erofs)"
else
    printf "  Checking HTTP: %-41s ... [FAIL]\n" "Rootfs (airootfs.sfs / erofs)"
    ERRORS=$((ERRORS + 1))
fi

# Live TFTP Test
printf "  Checking TFTP: %-41s ... " "ipxe.efi (Port 69/udp)"
TMP_TFTP="$(mktemp -t ipxe_test.XXXXXX)"
TFTP_OK=0

if curl -fsS --connect-timeout 5 -o "${TMP_TFTP}" "tftp://${PXE_HOST}/ipxe.efi" 2>/dev/null; then
    magic="$(head -c 2 "${TMP_TFTP}" 2>/dev/null || true)"
    if [[ "${magic}" == "MZ" ]]; then
        echo "[PASS] (via curl)"
        TFTP_OK=1
    fi
fi

if [[ ${TFTP_OK} -eq 0 ]] && command -v tftp >/dev/null 2>&1; then
    if tftp "${PXE_HOST}" -c get ipxe.efi "${TMP_TFTP}" 2>/dev/null; then
        echo "[PASS] (via tftp client)"
        TFTP_OK=1
    fi
fi

if [[ ${TFTP_OK} -eq 0 ]]; then
    echo "[FAIL]"
    echo "    TFTP fetch failed. Ensure container 'bc250-tftp' is running and port 69/udp is open." >&2
    ERRORS=$((ERRORS + 1))
fi
rm -f "${TMP_TFTP}"

echo "=================================================================="
if [[ ${ERRORS} -gt 0 ]]; then
    echo "==> Verification completed with ${ERRORS} error(s)."
    exit 1
fi
echo "==> All endpoint checks passed successfully!"
