#!/usr/bin/env bash
# BC-250 WGP Probe Wizard
#
# Interactive guided tool to isolate bad WGPs on BC-250 GPUs, run correctness
# tests, and apply verified dispatch masks to the boot service.
#
# Usage:
#   sudo ./wgp-wizard.sh probe           # Run full WGP probe cycle from stock
#   sudo ./wgp-wizard.sh resume          # Resume interrupted probe
#   ./wgp-wizard.sh report               # Show probe results summary
#   sudo ./wgp-wizard.sh apply           # Apply verified masks to boot service
#   sudo ./wgp-wizard.sh force-disable SE.SH.WGP  # Force-disable a single WGP
#   ./wgp-wizard.sh status               # Show current live-manager status
#
# State file: state/wgp-probe.log (created in the working directory)
# Requires: bc250-cu-live-manager.sh, compute-verify.sh, systemctl

set -euo pipefail

# ==============================================================================
# Constants
# ==============================================================================
STOCK_MASK=7        # 0x07 = WGP0+WGP1+WGP2 per row (24 CUs stock)
FULL_MASK=31         # 0x1f = all 5 WGPs per row (40 CUs)

STATE_DIR="state"
STATE_FILE="${STATE_DIR}/wgp-probe.log"

# Compute-verify.sh parameters for fast probing
ELEMENTS=1048576     # 1M elements (~6-8s per probe)
PASSES=3

# Paths (overridable via environment)
LIVE_MANAGER_SH="${LIVE_MANAGER_SH:-/opt/bc250/bc250-cu-live-manager/bc250-cu-live-manager.sh}"
COMPUTE_VERIFY="${COMPUTE_VERIFY:-$(command -v bc250-compute-verify.sh 2>/dev/null || echo /opt/bc250/bc250-compute-verify.sh)}"

# Service config
SERVICE_CONF="/etc/bc250/bc250-cu-live-manager.conf"

# WGP rows: SE.SH → 4 rows, each with WGP 0-4
# Candidates are WGP 3 and WGP4 on each row (WGP 0-2 are stock)
ROWS=("0.0" "0.1" "1.0" "1.1")
CANDIDATE_WGPS=(3 4)

# ==============================================================================
# Helpers
# ==============================================================================
log()  { echo "[wgp-wizard] $(date '+%H:%M:%S') $*"; }
info() { log "INFO:  $*"; }
warn() { log "WARN:  $*"; }
err()  { log "ERROR: $*" >&2; }

die() { err "$*"; exit 1; }

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "This command requires root (sudo)."
}

require_command() {
    command -v "$1" &>/dev/null || die "Required command '$1' not found in PATH."
}

# Check that live-manager script exists and is executable
require_live_manager() {
    [[ -x "${LIVE_MANAGER_SH}" ]] || die \
        "Live manager script not found or not executable: ${LIVE_MANAGER_SH}\n" \
        "  Set LIVE_MANAGER_SH env var, or clone bc250-cu-live-manager to /opt/bc250/"
}

# Check that compute-verify.sh exists and is executable
require_compute_verify() {
    if [[ ! -x "${COMPUTE_VERIFY}" ]]; then
        # Try common locations
        for candidate in \
            "/opt/bc250/bc250-compute-verify.sh" \
            "/usr/local/bin/bc250-compute-verify.sh" \
            "$(command -v bc250-compute-verify.sh 2>/dev/null)"; do
            if [[ -x "${candidate}" ]]; then
                COMPUTE_VERIFY="${candidate}"
                break
            fi
        done
    fi
    [[ -x "${COMPUTE_VERIFY}" ]] || die \
        "compute-verify.sh not found. Set COMPUTE_VERIFY env var or place it in PATH.\n" \
        "  Source: https://github.com/duggasco/bc250-40cu-unlock"
}

# Ensure state directory exists
ensure_state_dir() {
    mkdir -p "${STATE_DIR}"
}

# ==============================================================================
# State file management
# ==============================================================================

# Initialize state file header (idempotent — only if file doesn't exist)
init_state_file() {
    if [[ ! -f "${STATE_FILE}" ]]; then
        ensure_state_dir
        cat > "${STATE_FILE}" <<EOF
# BC-250 WGP Probe Results
# Generated: $(date '+%Y-%m-%d %H:%M:%S %Z')
# Start state: stock (24 CUs, mask 0x07 per row)
# Test params: elements=${ELEMENTS} passes=${PASSES}
# Format: SE.SH.WGP RESULT ERROR_COUNT DETAILS
EOF
    fi
}

# Append a result line to the state file
append_result() {
    local wgp="$1" result="$2" errors="${3:-}" details="${4:-}"
    echo "${wgp} ${result} ${errors} ${details}" >> "${STATE_FILE}"
}

# Check if a specific WGP has been tested (PASS or FAIL)
is_tested() {
    local wgp="$1"
    grep -qE "^${wgp} (PASS|FAIL)" "${STATE_FILE}" 2>/dev/null
}

# Get last result for a WGP (handles retests — last line wins)
get_last_result() {
    local wgp="$1"
    grep "^${wgp} \(PASS\|FAIL\)" "${STATE_FILE}" | tail -1 | awk '{print $2}'
}

# Count how many unique WGPs have been tested (unique first column)
count_tested() {
    grep -cE "^[0-9]+\.[0-9]+\.[0-9]+ (PASS|FAIL)" "${STATE_FILE}" 2>/dev/null || echo 0
}

# ==============================================================================
# Probe helpers — interact with live-manager
# ==============================================================================

# Ensure the system is at STOCK state (mask 0x07 per row)
ensure_stock_state() {
    info "Verifying stock GPU state (24 CUs, mask 0x07 per row)..."
    
    # Apply stock masks via live-manager
    "${LIVE_MANAGER_SH}" stock-dispatch 2>/dev/null || {
        # Fallback: set masks directly
        info "stock-dispatch not available, setting masks manually..."
        for row in "${ROWS[@]}"; do
            "${LIVE_MANAGER_SH}" disable-wgp "${row}.0" 2>/dev/null || true
            "${LIVE_MANAGER_SH}" disable-wgp "${row}.1" 2>/dev/null || true
            "${LIVE_MANAGER_SH}" disable-wgp "${row}.2" 2>/dev/null || true
            "${LIVE_MANAGER_SH}" enable-wgp "${row}.0" 2>/dev/null || true
            "${LIVE_MANAGER_SH}" enable-wgp "${row}.1" 2>/dev/null || true
            "${LIVE_MANAGER_SH}" enable-wgp "${row}.2" 2>/dev/null || true
        done
    }
    
    # Verify: should show 24 CUs active
    local cu_count
    cu_count=$("${LIVE_MANAGER_SH}" status 2>/dev/null | grep -oP '\d+ CU' | head -1 | grep -oP '\d+' || echo "?")
    if [[ "${cu_count}" == "24" ]]; then
        info "Confirmed: 24 CUs active (stock state)."
    elif [[ "${cu_count}" == "?" ]]; then
        warn "Could not verify CU count from live-manager status. Proceeding anyway."
    else
        warn "GPU shows ${cu_count} CUs — expected 24 (stock). Ensure no boot service is overriding."
    fi
}

# Enable a single WGP (add its 2 CUs to current state)
enable_wgp() {
    local wgp="$1"  # e.g., "1.0.3"
    info "Enabling WGP ${wgp}..."
    "${LIVE_MANAGER_SH}" enable-wgp "${wgp}"
    sleep 1
}

# Disable a single WGP (remove its 2 CUs from current state)
disable_wgp() {
    local wgp="$1"
    info "Disabling WGP ${wgp}..."
    "${LIVE_MANAGER_SH}" disable-wgp "${wgp}"
    sleep 1
}

# Run compute-verify.sh and capture result
# Returns: exit 0 = pass, exit 2 = fail
# Outputs: error counts to stdout for parsing
run_compute_verify() {
    local wgp="$1"
    info "Running compute-verify.sh on WGP ${wgp} (elements=${ELEMENTS}, passes=${PASSES})..."
    
    local output
    local exit_code
    
    # Run with captured output — parse error counts from summary line
    output=$("${COMPUTE_VERIFY}" --elements "${ELEMENTS}" --passes "${PASSES}" 2>&1) || true
    exit_code=${PIPESTATUS[0]}
    
    # Parse the summary line: "summary elements=N passes=P total_checked=M errors=E int_errors=F fp_errors=G"
    local summary_line
    summary_line=$(echo "${output}" | grep "^summary " | tail -1)
    
    local total_errors int_errors fp_errors
    if [[ -n "${summary_line}" ]]; then
        total_errors=$(echo "${summary_line}" | grep -oP 'errors=\K\d+' || echo "0")
        int_errors=$(echo "${summary_line}" | grep -oP 'int_errors=\K\d+' || echo "0")
        fp_errors=$(echo "${summary_line}" | grep -oP 'fp_errors=\K\d+' || echo "0")
    else
        # Fallback: check exit code
        if [[ ${exit_code} -eq 0 ]]; then
            total_errors=0; int_errors=0; fp_errors=0
        else
            total_errors=1; int_errors=0; fp_errors=0
        fi
    fi
    
    # Determine pass/fail
    local result="PASS"
    if [[ ${total_errors} -gt 0 ]] || [[ ${exit_code} -eq 2 ]]; then
        result="FAIL"
    fi
    
    # Output: RESULT TOTAL_ERRORS INT_ERRORS FP_ERRORS
    echo "${result} ${total_errors} ${int_errors} ${fp_errors}"
}

# ==============================================================================
# Subcommand: probe
# ==============================================================================
cmd_probe() {
    require_root
    require_live_manager
    require_compute_verify
    
    ensure_state_dir
    init_state_file
    
    # --- Pre-flight checks ---
    echo ""
    echo "=============================================="
    echo " BC-250 WGP Probe Wizard"
    echo "=============================================="
    echo ""
    echo "This will test each unlocked WGP (WGP3, WGP4) on all 4 rows."
    echo "Starting from STOCK state (24 CUs). Each test takes ~${PASSES} × $(echo "scale=1; ${ELEMENTS} * 0.006" | bc 2>/dev/null || echo "~7")s."
    echo ""
    
    # Count total tests: 4 rows × 2 candidates = 8 probes
    local total_tests=0
    for row in "${ROWS[@]}"; do
        for wgp in "${CANDIDATE_WGPS[@]}"; do
            total_tests=$((total_tests + 1))
        done
    done
    
    info "Total tests: ${total_tests} (4 rows × 2 candidates)"
    info "Estimated time: ~$(echo "${total_tests} * 20" | bc 2>/dev/null || echo "~160")s (~$((total_tests * 20 / 60))min)"
    echo ""
    
    # Confirm with user
    read -r -p "Proceed? (yes/no): " confirm
    [[ "${confirm}" == "yes" ]] || die "Aborted by user."
    
    # --- Step 1: Ensure stock state ---
    echo ""
    info "=== STEP 1: Ensuring stock GPU state ==="
    ensure_stock_state
    
    # --- Step 2: Probe each candidate WGP ---
    echo ""
    info "=== STEP 2: Probing candidate WGPs ==="
    echo ""
    
    local tested=0
    for row in "${ROWS[@]}"; do
        for wgp_idx in "${CANDIDATE_WGPS[@]}"; do
            local wgp="${row}.${wgp_idx}"
            tested=$((tested + 1))
            
            # Skip if already tested (unless force)
            if is_tested "${wgp}"; then
                local existing
                existing=$(get_last_result "${wgp}")
                info "[${tested}/${total_tests}] ${wgp} already tested: ${existing}. Skipping."
                continue
            fi
            
            echo ""
            echo "--- Test ${tested}/${total_tests}: ${wgp} ---"
            
            # Enable candidate WGP (now 26 CUs active)
            enable_wgp "${wgp}"
            
            # Run compute-verify.sh
            local verify_output
            verify_output=$(run_compute_verify "${wgp}")
            
            # Parse result
            local result total_err int_err fp_err
            read -r result total_err int_err fp_err <<< "${verify_output}"
            
            # Record result
            if [[ "${result}" == "PASS" ]]; then
                append_result "${wgp}" "PASS" "0" ""
                info "  Result: PASS (no errors)"
            else
                append_result "${wgp}" "FAIL" "${total_err}" "int_errors=${int_err} fp_errors=${fp_err}"
                warn "  Result: FAIL (${total_err} errors, int=${int_err}, fp=${fp_err})"
                
                # Offer retest
                read -r -p "  Retest this WGP? (yes/no): " retest
                if [[ "${retest}" == "yes" ]]; then
                    info "  Retesting ${wgp}..."
                    verify_output=$(run_compute_verify "${wgp}")
                    read -r result total_err int_err fp_err <<< "${verify_output}"
                    
                    if [[ "${result}" == "PASS" ]]; then
                        append_result "${wgp} (retest)" "PASS" "0" ""
                        info "  Retest: PASS (may have been transient)"
                    else
                        append_result "${wgp} (retest)" "FAIL" "${total_err}" "int_errors=${int_err} fp_errors=${fp_err}"
                        warn "  Retest: FAIL (${total_err} errors) — WGP likely bad"
                    fi
                fi
            fi
            
            # Disable candidate WGP (back to stock)
            disable_wgp "${wgp}"
            
        done
    done
    
    # --- Step 3: Summary ---
    echo ""
    info "=== STEP 3: Probe complete ==="
    echo ""
    show_report
    
    local good_count bad_count
    good_count=$(grep -cE "^[0-9]+\.[0-9]+\.[0-9]+ (PASS)" "${STATE_FILE}" 2>/dev/null || echo 0)
    bad_count=$(grep -cE "^[0-9]+\.[0-9]+\.[0-9]+ FAIL" "${STATE_FILE}" 2>/dev/null || echo 0)
    
    echo ""
    info "Good WGPs: ${good_count} | Bad WGPs: ${bad_count}"
    echo ""
    if [[ ${bad_count} -gt 0 ]]; then
        info "Run 'sudo ./wgp-wizard.sh apply' to install verified masks and disable bad WGPs."
    else
        info "All candidate WGPs passed! Run 'sudo ./wgp-wizard.sh apply' to enable all 40 CUs."
    fi
}

# ==============================================================================
# Subcommand: resume
# ==============================================================================
cmd_resume() {
    require_root
    require_live_manager
    require_compute_verify
    
    [[ -f "${STATE_FILE}" ]] || die "No state file found at ${STATE_FILE}. Run 'probe' first."
    
    local tested
    tested=$(count_tested)
    
    info "Resuming probe. ${tested} tests already completed."
    echo ""
    
    # Ensure we're back at stock before resuming
    ensure_stock_state
    
    # Continue probing from where we left off
    for row in "${ROWS[@]}"; do
        for wgp_idx in "${CANDIDATE_WGPS[@]}"; do
            local wgp="${row}.${wgp_idx}"
            
            if is_tested "${wgp}"; then
                continue
            fi
            
            echo ""
            info "Testing ${wgp}..."
            enable_wgp "${wgp}"
            
            local verify_output result total_err int_err fp_err
            verify_output=$(run_compute_verify "${wgp}")
            read -r result total_err int_err fp_err <<< "${verify_output}"
            
            if [[ "${result}" == "PASS" ]]; then
                append_result "${wgp}" "PASS" "0" ""
                info "  PASS"
            else
                append_result "${wgp}" "FAIL" "${total_err}" "int_errors=${int_err} fp_errors=${fp_err}"
                warn "  FAIL (${total_err} errors)"
            fi
            
            disable_wgp "${wgp}"
        done
    done
    
    echo ""
    info "Resume complete."
    cmd_report
}

# ==============================================================================
# Subcommand: report
# ==============================================================================
cmd_report() {
    [[ -f "${STATE_FILE}" ]] || die "No state file found at ${STATE_FILE}. Run 'probe' first."
    
    echo ""
    echo "=============================================="
    echo " BC-250 WGP Probe Report"
    echo "=============================================="
    echo ""
    
    # Print header
    head -5 "${STATE_FILE}"
    echo ""
    echo "--- Results ---"
    echo ""
    
    # Print results in a table
    printf "%-10s %-8s %-10s %s\n" "WGP" "RESULT" "ERRORS" "DETAILS"
    printf "%-10s %-8s %-10s %s\n" "---" "------" "------" "-------"
    
    grep -E "^[0-9]+\.[0-9]+\.[0-9]+ (PASS|FAIL)" "${STATE_FILE}" | while read -r wgp result errors details; do
        local display_wgp="${wgp}"
        # Skip retest lines in summary (they're duplicates for verification)
        if [[ "${wgp}" == *"(retest)" ]]; then
            continue
        fi
        printf "%-10s %-8s %-10s %s\n" "${display_wgp}" "${result}" "${errors}" "${details}"
    done
    
    echo ""
    
    # Summary by row
    echo "--- Summary by Row ---"
    echo ""
    
    local total_good=0 total_bad=0
    for row in "${ROWS[@]}"; do
        local row_good=0 row_bad=0
        for wgp_idx in "${CANDIDATE_WGPS[@]}"; do
            local wgp="${row}.${wgp_idx}"
            local result
            # Get last non-retest result
            result=$(grep "^${wgp} " "${STATE_FILE}" | grep -E "(PASS|FAIL)" | grep -v "(retest)" | tail -1 | awk '{print $2}')
            
            case "${result}" in
                PASS) row_good=$((row_good + 1)) ;;
                FAIL) row_bad=$((row_bad + 1)) ;;
                *) continue ;;
            esac
        done
        
        total_good=$((total_good + row_good))
        total_bad=$((total_bad + row_bad))
        
        # Compute mask for this row
        local row_mask=${STOCK_MASK}
        for wgp_idx in "${CANDIDATE_WGPS[@]}"; do
            local wgp="${row}.${wgp_idx}"
            local result
            result=$(grep "^${wgp} " "${STATE_FILE}" | grep -E "(PASS|FAIL)" | grep -v "(retest)" | tail -1 | awk '{print $2}')
            if [[ "${result}" == "PASS" ]]; then
                row_mask=$((row_mask | (1 << wgp_idx)))
            fi
        done
        
        local status="ALL GOOD"
        [[ ${row_bad} -gt 0 ]] && status="${row_good} good, ${row_bad} bad"
        
        printf "  %s: mask=0x%02x (%d CUs) — %s\n" "${row}" "${row_mask}" $(( (row_good * 2) + 12 )) "${status}"
    done
    
    echo ""
    echo "Total: ${total_good} good, ${total_bad} bad out of $((total_good + total_bad)) tested."
    echo ""
}

# ==============================================================================
# Subcommand: apply
# ==============================================================================
cmd_apply() {
    require_root
    require_live_manager
    
    [[ -f "${STATE_FILE}" ]] || die "No state file found at ${STATE_FILE}. Run 'probe' first."
    
    echo ""
    echo "=============================================="
    echo " Apply Verified WGP Masks"
    echo "=============================================="
    echo ""
    
    # Read results and compute new masks
    local new_masks=()
    local changes=()
    
    for row in "${ROWS[@]}"; do
        local row_mask=${STOCK_MASK}
        local disabled_wgps=()
        
        for wgp_idx in "${CANDIDATE_WGPS[@]}"; do
            local wgp="${row}.${wgp_idx}"
            local result
            result=$(grep "^${wgp} " "${STATE_FILE}" | grep -E "(PASS|FAIL)" | grep -v "(retest)" | tail -1 | awk '{print $2}')
            
            if [[ "${result}" == "PASS" ]]; then
                row_mask=$((row_mask | (1 << wgp_idx)))
            elif [[ "${result}" == "FAIL" ]]; then
                disabled_wgps+=("${wgp}")
            fi
        done
        
        new_masks+=("${row_mask}")
        
        if [[ ${row_mask} -ne ${STOCK_MASK} ]] && [[ ${#disabled_wgps[@]} -eq 0 ]]; then
            changes+=("${row}: enabling WGP${CANDIDATE_WGPS[*]} (+$(( (${#CANDIDATE_WGPS[@]} * 2)) ) CUs)")
        elif [[ ${#disabled_wgps[@]} -gt 0 ]]; then
            changes+=("${row}: disabling ${disabled_wgps[*]} (mask 0x${STOCK_MASK} → 0x$(printf '%02x' "${row_mask}"))")
        fi
    done
    
    # Show what will change
    echo "Current boot service config:"
    if [[ -f "${SERVICE_CONF}" ]]; then
        local current_masks
        current_masks=$(grep "^BC250_WGP_MASKS=" "${SERVICE_CONF}" | cut -d= -f2)
        echo "  BC250_WGP_MASKS=${current_masks}"
    else
        echo "  (stock — no custom config)"
        current_masks="0x07,0x07,0x07,0x07"
    fi
    
    local new_mask_str=""
    for i in "${!new_masks[@]}"; do
        [[ -n "${new_mask_str}" ]] && new_mask_str+=","
        new_mask_str+="0x$(printf '%02x' "${new_masks[$i]}")"
    done
    
    echo ""
    echo "New masks: BC250_WGP_MASKS=${new_mask_str}"
    echo ""
    
    if [[ ${#changes[@]} -gt 0 ]]; then
        echo "Changes:"
        for change in "${changes[@]}"; do
            echo "  ${change}"
        done
        echo ""
    else
        echo "No changes from stock. All candidates passed or none tested."
        echo ""
    fi
    
    # Confirm
    read -r -p "Apply these masks and update boot service? (yes/no): " confirm
    [[ "${confirm}" == "yes" ]] || die "Aborted by user."
    
    # --- Apply ---
    echo ""
    info "Applying masks..."
    
    # Step 1: Set runtime masks via live-manager
    for i in "${!ROWS[@]}"; do
        local row="${ROWS[$i]}"
        local mask="${new_masks[$i]}"
        info "Setting ${row} mask to 0x$(printf '%02x' "${mask}")..."
        
        # Disable all WGPs first, then enable wanted ones
        for wgp_idx in 0 1 2 3 4; do
            "${LIVE_MANAGER_SH}" disable-wgp "${row}.${wgp_idx}" 2>/dev/null || true
        done
        
        # Enable WGPs based on mask bits
        for wgp_idx in 0 1 2 3 4; do
            if (( mask & (1 << wgp_idx) )); then
                "${LIVE_MANAGER_SH}" enable-wgp "${row}.${wgp_idx}" 2>/dev/null || true
            fi
        done
    done
    
    # Step 2: Update/create service config
    info "Updating ${SERVICE_CONF}..."
    ${SUDO} mkdir -p /etc/bc250
    ${SUDO} tee "${SERVICE_CONF}" >/dev/null <<EOF
# BC-250 GPU Live Manager Service Configuration
# Generated by wgp-wizard.sh on $(date '+%Y-%m-%d %H:%M:%S %Z')
# DO NOT EDIT MANUALLY — run 'wgp-wizard apply' to update.
BC250_WGP_MASKS=${new_mask_str}
EOF
    
    # Step 3: Reinstall/update boot service
    info "Installing boot service..."
    if [[ -f "${LIVE_MANAGER_SH}" ]]; then
        (cd "$(dirname "${LIVE_MANAGER_SH}")/.." && ${SUDO} ./bc250-cu-live-manager.sh write-service-table || true)
        ${SUDO} systemctl daemon-reload
        ${SUDO} systemctl enable --now bc250-cu-live-manager.service 2>/dev/null || \
            warn "Failed to enable service. Check with: systemctl status bc250-cu-live-manager.service"
    fi
    
    echo ""
    info "Masks applied and boot service updated."
    echo ""
    cmd_report
}

# ==============================================================================
# Subcommand: force-disable
# ==============================================================================
cmd_force_disable() {
    require_root
    require_live_manager
    
    local target_wgp="${1:-}"
    [[ -n "${target_wgp}" ]] || die "Usage: sudo ./wgp-wizard.sh force-disable SE.SH.WGP"
    
    # Validate format
    if ! echo "${target_wgp}" | grep -qE '^[0-1]\.[0-1]\.[0-4]$'; then
        die "Invalid WGP format. Expected SE.SH.WGP (e.g., 1.0.3)"
    fi
    
    local row="${target_wgp%.*}"  # Remove last component → SE.SH
    local wgp_idx="${target_wgp##*.}"  # Last component → WGP number
    
    info "Force-disabling WGP ${target_wgp}..."
    
    # Disable the specific WGP
    "${LIVE_MANAGER_SH}" disable-wgp "${target_wgp}"
    
    # Record in state file
    init_state_file
    append_result "${target_wgp}" "FAIL" "0" "FORCE_DISABLED by user"
    
    # Ask if user wants to apply these changes to boot service
    echo ""
    info "WGP ${target_wgp} disabled."
    read -r -p "Apply this change to boot service config? (yes/no): " confirm
    if [[ "${confirm}" == "yes" ]]; then
        cmd_apply
    fi
}

# ==============================================================================
# Subcommand: status
# ==============================================================================
cmd_status() {
    require_live_manager
    
    echo ""
    echo "=============================================="
    echo " BC-250 GPU Live Manager Status"
    echo "=============================================="
    echo ""
    
    # Run live-manager status
    "${LIVE_MANAGER_SH}" status 2>/dev/null || warn "live-manager status failed."
    
    echo ""
    
    # Check service config
    if [[ -f "${SERVICE_CONF}" ]]; then
        echo "Boot service config (${SERVICE_CONF}):"
        cat "${SERVICE_CONF}" | grep -v "^#" | grep -v "^$"
    else
        echo "No boot service config at ${SERVICE_CONF}."
    fi
    
    echo ""
    
    # Check state file
    if [[ -f "${STATE_FILE}" ]]; then
        local tested
        tested=$(count_tested)
        echo "Probe state: ${STATE_FILE} (${tested} tests completed)"
    else
        echo "No probe state file. Run 'probe' first."
    fi
    
    echo ""
}

# ==============================================================================
# Usage / main
# ==============================================================================
usage() {
    cat <<EOF
BC-250 WGP Probe Wizard

Usage:
  sudo ./wgp-wizard.sh probe           Run full WGP probe cycle from stock
  sudo ./wgp-wizard.sh resume          Resume interrupted probe
  ./wgp-wizard.sh report               Show probe results summary
  sudo ./wgp-wizard.sh apply           Apply verified masks to boot service
  sudo ./wgp-wizard.sh force-disable SE.SH.WGP  Force-disable a single WGP
  ./wgp-wizard.sh status               Show current live-manager status

Environment variables:
  LIVE_MANAGER_SH   Path to bc250-cu-live-manager.sh (default: /opt/bc250/.../bc250-cu-live-manager.sh)
  COMPUTE_VERIFY    Path to compute-verify.sh (default: /opt/bc250/bc250-compute-verify.sh)

State file: ${STATE_FILE}
EOF
}

main() {
    local cmd="${1:-help}"
    shift || true
    
    case "${cmd}" in
        probe)          cmd_probe ;;
        resume)         cmd_resume ;;
        report)         cmd_report ;;
        apply)          cmd_apply ;;
        force-disable)  cmd_force_disable "$@" ;;
        status)         cmd_status ;;
        help|--help|-h) usage ;;
        *)              die "Unknown command: ${cmd}. Run './wgp-wizard.sh help' for usage." ;;
    esac
}

main "$@"
