# AMD BC-250 Cluster Troubleshooting Guide

A complete stage-by-stage diagnostic manual for the AMD BC-250 PXE provisioning pipeline, CachyOS hardware optimization, and distributed llama.cpp inference.

---

## Stage 1: UEFI PXE / HTTP Boot & DD-WRT dnsmasq

### 1.1 Watching Live Server Logs
On the provisioning server, stream container activity:
```bash
make logs
# Or:
docker compose logs -f tftp web
```
* **Normal TFTP activity**: You should see incoming read requests (`RRQ`) for `ipxe.efi` from the node's IP.
* **Normal HTTP activity**: You should see HTTP GET requests for `/boot.ipxe`, followed by `/arch/arch/boot/x86_64/vmlinuz-linux`, `/arch/arch/boot/x86_64/initramfs-linux.img`, and `/arch/arch/x86_64/airootfs.sfs`.

### 1.2 Node Loops Infinitely Between UEFI and iPXE
* **Symptom**: Node boots `ipxe.efi`, starts iPXE, re-queries DHCP, and loads `ipxe.efi` again in an infinite loop.
* **Cause**: DD-WRT is serving `ipxe.efi` to iPXE instead of serving `boot.ipxe`.
* **Fix**: Ensure `tag:!ipxe` is present on the TFTP boot line in DD-WRT **Additional DNSMasq Options**:
  ```ini
  dhcp-boot=tag:efi64,tag:!ipxe,ipxe.efi,,[YOUR_PROVISIONING_SERVER_IP]
  dhcp-boot=tag:ipxe,http://[YOUR_PROVISIONING_SERVER_IP]/boot.ipxe
  ```
  The exclamation mark (`!ipxe`) tells dnsmasq **not** to match when the client has already identified itself as `iPXE`.

### 1.3 TFTP Open Timeout / Connection Refused
* **Symptom**: Node displays `PXE-E32: TFTP open timeout` or fails during initial file transfer.
* **Checks**:
  1. Verify the TFTP container is running:
     ```bash
     docker compose ps tftp
     ```
  2. Verify UDP port 69 is listening on the provisioning server:
     ```bash
     sudo ss -ulpn | grep :69
     ```
  3. Ensure host firewall (`ufw` or `iptables`) allows incoming UDP traffic on port 69:
     ```bash
     sudo ufw allow 69/udp
     ```

### 1.4 UEFI HTTP IPv4 Boot Fails
* **Symptom**: BIOS fails to fetch `ipxe.efi` when booting in UEFI HTTP IPv4 mode.
* **Fix**: In DD-WRT, ensure client-arch `16` is tagged and the vendor-class is forced:
  ```ini
  dhcp-match=set:efi64_http,option:client-arch,16
  dhcp-option-force=tag:efi64_http,option:vendor-class,HTTPClient
  dhcp-boot=tag:efi64_http,tag:!ipxe,http://[YOUR_PROVISIONING_SERVER_IP]/ipxe.efi
  ```
  Also verify that `www/ipxe.efi` exists on the server (created automatically by `make fetch` / `scripts/fetch-ipxe.sh`).

### 1.5 iPXE Requests `/autoexec.ipxe` (UEFI HTTP Boot Default Behavior)
* **Symptom**: Nginx logs show `GET /autoexec.ipxe 404`.
* **Explanation**: When `ipxe.efi` is launched via native UEFI HTTP Boot, iPXE automatically requests `/autoexec.ipxe` from the server URL it was booted from.
* **Resolution**: The repository includes [`www/autoexec.ipxe`](www/autoexec.ipxe) containing `chain --autofree boot.ipxe`. This instantly redirects iPXE into the cluster installer.

---

## Stage 2: iPXE Execution & HTTP Boot Script

### 2.1 "No configuration methods succeeded" in iPXE
* **Symptom**: `ipxe.efi` starts, prints `Configuring (net0)...`, and fails with `No configuration methods succeeded`.
* **Checks**:
  1. The node may take a few seconds for the switch port to negotiate link state (Spanning Tree / STP delay). If using managed switches, enable PortFast / edge port mode.
  2. Press `Ctrl-B` when prompted during iPXE boot to drop to the interactive shell. Then run:
     ```ipxe
     ifstat
     dhcp net0
     route
     ```
     This will display PHY negotiation, packets received, and IP assignments.

### 2.2 Error 0x3d0c4302 (Connection Timed Out on HTTP)
* **Symptom**: iPXE cannot reach `http://[YOUR_PROVISIONING_SERVER_IP]/boot.ipxe`.
* **Checks**:
  1. In the iPXE shell, ping the server: `ping [YOUR_PROVISIONING_SERVER_IP]`.
  2. From another machine on the LAN, verify Nginx is serving the script:
     ```bash
     curl -i http://[YOUR_PROVISIONING_SERVER_IP]/boot.ipxe
     ```
  3. Verify Nginx port 80 is not blocked by host firewall:
     ```bash
     sudo ufw allow 80/tcp
     ```

---

## Stage 3: Archiso Live Kernel & Rootfs Mount

### 3.1 Kernel Panics or "Failed to mount /run/archiso/airootfs"
* **Symptom**: Kernel and initramfs load, but the boot stops with an error looking for `airootfs.sfs`.
* **Cause**: In `www/boot.ipxe`, `archiso_http_srv` must point to the base directory containing the `arch/` tree and must include a trailing slash:
  ```ipxe
  archiso_http_srv=http://[YOUR_PROVISIONING_SERVER_IP]/arch/ archisobasedir=arch
  ```
  The initramfs hook automatically appends `arch/x86_64/airootfs.sfs` to `archiso_http_srv`.
* **Fix**: Verify on the server that `www/arch/arch/x86_64/airootfs.sfs` exists. Run `make stage` or `scripts/stage-iso.sh` to extract the ISO correctly.

---

## Stage 4: `install.sh` Execution & Guardrail Failures

### 4.1 "No local network interface matches authorized cluster node allowlist"
* **Symptom**: Installer stops with exit code 1 immediately after booting.
* **Cause**: Safety Guardrail 1 refused to run because the onboard NIC's MAC address is not listed in `NODE_MAP`.
* **Fix**:
  1. In the live environment console, run:
     ```bash
     ip link show
     ```
  2. Copy the MAC address of the active interface.
  3. On the server, edit [`www/provision/install.sh`](www/provision/install.sh) and update `NODE_MAP` with the exact MAC.

### 4.2 "Target disk already contains an installed filesystem labeled 'ROOT'"
* **Symptom**: Installer exits with code 0 without modifying disks.
* **Explanation**: Safety Guardrail 2 detected that the system is already provisioned and avoided re-wiping your storage.
* **How to Reinstall**: If you deliberately want to wipe and re-provision, edit [`www/boot.ipxe`](www/boot.ipxe) on the server:
  ```ipxe
  set extra_cmdline reinstall
  ```
  Reboot the node via PXE. The installer will detect `reinstall` in `/proc/cmdline` and proceed with the disk wipe.

### 4.3 Automated Script Does Not Run (`script=` Parameter Fallback)
* **Symptom**: The node boots into the Arch Linux live environment login prompt on tty1, but does not run `install.sh`.
* **Manual Fallback**:
  1. The Arch live console automatically logs in as `root`.
  2. Verify connectivity:
     ```bash
     ping -c 3 192.168.42.100
     ```
  3. Execute the installer manually:
     ```bash
     bash <(curl -fsSL http://192.168.42.100/provision/install.sh)
     ```

---

## Stage 5: Local NVMe Boot & UEFI Firmware Order

### 5.1 Machine Boots Back into PXE After Installation
* **Symptom**: After `install.sh` completes and reboots, the node boots over PXE again instead of the NVMe drive.
* **Fix**:
  1. Enter the BC-250 AMI BIOS setup during POST (press `Del` or `F2`).
  2. Navigate to the **Boot** tab.
  3. Set **Boot Option #1** to: `Linux Boot Manager` (or the NVMe drive).
  4. Move `UEFI Network / PXE` to a lower priority (or use the one-time boot menu `F11` when provisioning).
  5. Save and exit (`F10`).

---

## Stage 6: CachyOS Conversion & Hardware Optimization

### 6.1 GPG Keyring Error During `cachyos-repo.sh`
* **Symptom**: `pacman -Sy` fails with invalid or unverified keys after running `cachyos-repo.sh`.
* **Fix**:
  ```bash
  sudo pacman-key --init
  sudo pacman-key --populate archlinux cachyos
  sudo pacman -Syu
  ```

### 6.2 CPU Remaining at 6 Cores / 12 Threads After Conversion
* **Symptom**: `nproc` reports `12` instead of `16`.
* **Cause**: A cold boot (cutting AC power or unplugging PSU) resets the SMU core mask register back to `0x77`.
* **Fix**:
  1. Verify the persistent service status:
     ```bash
     systemctl status bc250-core-unlock.service --no-pager
     ```
  2. Manually test the unlock script:
     ```bash
     sudo /opt/bc250/bc250-core-unlock-check.sh
     ```
  3. Ensure no conflicting background governor (such as `cyan-skillfish-governor-smu`) is locking the PCI index/data registers `0xB8`/`0xBC`.

### 6.3 40-CU Dispatch Table Not Restoring on Reboot
* **Symptom**: `sudo /opt/bc250/bc250-cu-live-manager/bc250-cu-live-manager.sh status` reports fewer than 40 CUs active.
* **Fix**:
  1. Check the systemd service:
     ```bash
     systemctl status bc250-cu-live-manager.service --no-pager
     ```
  2. Re-generate the service table and re-enable:
     ```bash
     cd /opt/bc250/bc250-cu-live-manager
     sudo ./bc250-cu-live-manager.sh enable all
     sudo ./bc250-cu-live-manager.sh write-service-table
     sudo ./bc250-cu-live-manager.sh install-service
     ```

### 6.4 Vulkan Memory Accounting Confusion
* **Observation**: `vulkaninfo` reports ~12,288 MiB total, but `lspci` or system tools report 512 MiB VRAM.
* **Explanation**: On the AMD BC-250 (Oberon APU), 512 MiB is the firmware UMA VRAM configured in CMOS via `bc250memcfg`. The remaining ~11.5 GiB is provided by the kernel GTT pool via `ttm.pages_limit=3014656 ttm.page_pool_size=3014656`. Mesa RADV combines these into a single 12 GiB Vulkan memory budget. This is the expected and verified behavior.

---

## Stage 7: Distributed llama.cpp & Interconnect

### 7.1 Node A Cannot Connect to Node B RPC Service
* **Symptom**: `llama-server` on Node A fails with `Connection refused` to `<NODE_B_DIRECT_IP>:50052`.
* **Checks**:
  1. On Node B, verify `ggml-rpc-server` is actively listening:
     ```bash
     sudo ss -tulpn | grep :50052
     ```
  2. On Node A, test direct TCP connectivity:
     ```bash
     nc -zv <NODE_B_DIRECT_IP> 50052
     ```
  3. `scripts/setup-llama-server.sh` assigns the configured direct IP (`NODE1_DIRECT_IP` or `NODE2_DIRECT_IP`, with `/30`) to the node's single USB Ethernet interface using systemd-networkd. Verify it with `ip -4 addr show` and check `/etc/systemd/network/20-bc250-direct.network`. The script expects exactly one USB Ethernet interface; disconnect other USB network adapters before running it.

### 7.2 Systemd Unit Fails with status=203/EXEC or Permission Denied
* **Cause**: Running binaries directly from a user's home directory under a systemd service can fail due to permissions or execution path restrictions.
* **Fix**: Install compiled binaries (`llama-server`, `ggml-rpc-server`) to `/usr/local/bin` and libraries to `/usr/local/lib64`, and update `/etc/ld.so.conf.d/llama-cpp.conf` followed by `sudo ldconfig` (as detailed in Section 5.1 of the report).
