# AMD BC-250 Cluster Recovery & Reinstall Procedures

This guide provides procedures for performing deliberate cluster node reinstallations, recovering from failed updates, using USB boot fallbacks, and diagnosing hardware unlock states.

---

## 1. Reinstallation Procedures & Guardrails

The installer [`www/provision/install.sh`](www/provision/install.sh) incorporates two strict guardrails to prevent accidental destruction:
1. **MAC Allowlist**: Halts immediately if the booting machine's MAC address is not listed in `NODE_MAP`.
2. **Existing Root Guardrail**: If an ext4 partition with label `ROOT` is found on `/dev/nvme0n1`, the installer exits safely with `exit 0` without modifying any partition tables or files.

### How to Force a Node Reinstall
To deliberately wipe and reinstall a node:
1. Edit [`www/boot.ipxe`](www/boot.ipxe) on the provisioning server:
   ```ipxe
   # Change:
   set extra_cmdline
   # To:
   set extra_cmdline reinstall
   ```
2. Reboot the target node via network boot (PXE or UEFI HTTP boot).
3. The kernel cmdline will receive the `reinstall` flag. `install.sh` will detect this flag, wipe `/dev/nvme0n1`, partition GPT (1 GiB ESP + ext4 ROOT), run `pacstrap`, configure networking and bootloader, and reboot into Arch Linux.
4. **Important**: Once the node finishes provisioning, remove `reinstall` from `www/boot.ipxe` (`set extra_cmdline`) so subsequent network boots will remain safe.

---

## 2. Bootloader Fallback & Kernel Recovery

When [`convert.sh`](www/provision/convert.sh) installs CachyOS, it configures `systemd-boot` with:
* **Default**: `cachyos.conf` (`vmlinuz-linux-cachyos`, BORE scheduler, `ttm.pages_limit=3014656 ttm.page_pool_size=3014656`)
* **Fallback**: `arch.conf` (`vmlinuz-linux`, upstream Arch Linux kernel)

### Selecting the Fallback Kernel
If an experimental kernel or module issue prevents CachyOS from booting:
1. Connect a display or monitor the console.
2. During system power-on, rapidly press `Space`, `Esc`, or the `Down Arrow` key to display the `systemd-boot` menu.
3. Select **Arch Linux** to boot into the upstream Arch Linux kernel.
4. Once booted, you have full SSH access to repair packages, rebuild initramfs, or inspect kernel logs (`journalctl -xb`).

---

## 3. Network Rescue via Arch Live Environment

If the local NVMe drive is unbootable, you can boot into the Arch live environment over the network for rescue:
1. Ensure `reinstall` is **not** present in `www/boot.ipxe`.
2. Boot the node via PXE.
3. `install.sh` will detect the existing `ROOT` partition and exit with `exit 0`, leaving you in the interactive root live shell on tty1.
4. Mount the installed system to inspect or repair:
   ```bash
   mount /dev/nvme0n1p2 /mnt
   mount /dev/nvme0n1p1 /mnt/boot
   arch-chroot /mnt
   ```
5. From inside the chroot, you can run `pacman -Syu`, update bootloader entries, or adjust network configs.

---

## 4. USB-Stick iPXE Fallback (If Onboard UEFI PXE Fails)

If the BC-250 BIOS cannot reliably PXE boot from the onboard network adapter:

### Creating the iPXE Boot USB Drive
1. Insert a USB flash drive into your workstation.
2. Format the USB drive as FAT32:
   ```bash
   # Example on Linux (adjust /dev/sdX):
   sudo mkfs.vfat -F 32 -n "IPXE_BOOT" /dev/sdX1
   ```
3. Create the standard UEFI boot directory structure:
   ```bash
   mkdir -p /mnt/usb/EFI/BOOT
   ```
4. Copy `ipxe.efi` from this repository (`tftp/ipxe.efi`) as the default UEFI bootloader:
   ```bash
   cp /path/to/your/workspace/tftp/ipxe.efi /mnt/usb/EFI/BOOT/BOOTX64.EFI
   ```
5. Insert the USB stick into the BC-250 and boot. When the iPXE shell launches, run:
   ```ipxe
   dhcp
   chain http://[YOUR_PROVISIONING_SERVER_IP]/boot.ipxe
   ```
   The node will chainload `boot.ipxe` from the provisioning server and continue the exact same automated provisioning process.

---

## 5. Hardware Troubleshooting & Status Verification

### Checking the 8-Core / 16-Thread CPU Unlock
Out of the box, the BC-250 runs with 6 cores / 12 threads (SMU mask `0x77`). The conversion script configures `bc250-core-unlock.service` to apply the `0xFF` mask on cold boot.

* Check active threads:
  ```bash
  nproc
  # Should output: 16
  ```
* Inspect unlock service logs:
  ```bash
  systemctl status bc250-core-unlock.service --no-pager
  ```
* If running on 12 threads after an AC power pull, manually trigger the unlock:
  ```bash
  sudo /opt/bc250/bc250-core-unlock-check.sh
  ```

### Checking 40-CU GPU Routing
The AMD BC-250 factory topology reports 24 CUs. The Live Manager routes the full 40 CUs (20 WGPs) at runtime:

* Verify live dispatch status:
  ```bash
  sudo /opt/bc250/bc250-cu-live-manager/bc250-cu-live-manager.sh status
  ```
  Expected output:
  ```
  SE0.SH0: SPI 0x1f => 10/10 CUs
  SE0.SH1: SPI 0x1f => 10/10 CUs
  SE1.SH0: SPI 0x1f => 10/10 CUs
  SE1.SH1: SPI 0x1f => 10/10 CUs
  CUs active & routed: 40/40
  ```
* Verify systemd service status:
  ```bash
  systemctl status bc250-cu-live-manager.service --no-pager
  ```

### Checking Vulkan Memory Budget (UMA + GTT)
* Run `vulkaninfo`:
  ```bash
  vulkaninfo --summary | grep -E "(deviceName|totalMem)"
  ```
* Verify GTT pool settings in `/proc/cmdline`:
  ```bash
  cat /proc/cmdline | grep "ttm.pages_limit"
  ```
* Expected Vulkan budget: ~12,288 MiB per node (~24 GiB across both nodes).

### Verifying the 2.5GbE Direct Interconnect
* On Node B (worker):
  ```bash
  iperf3 -s
  ```
* On Node A (primary):
  ```bash
  iperf3 -c <NODE_B_DIRECT_IP> -P 4 -t 10
  ```
  Expected throughput: ~1.95 Gbit/s without TCP retransmissions.
