# Network Boot Configuration for AMD BC-250 Cluster

This document outlines the general configuration required on your **network infrastructure** (router, DHCP server, or dedicated provisioning machine) to enable unattended network booting for the AMD BC-250 nodes pointing to your provisioning server.

---

## 1. Network Topology

* **DHCP/TFTP Server**: Your local router or a dedicated machine running a DHCP/TFTP service (e.g., dnsmasq, ISC DHCP, or built-in router services).
* **Subnet**: Configurable via `config.env` (default: `192.168.42.0/24`).
* **Provisioning Server**: A machine running the Docker stack (TFTP + Nginx) at the IP specified by `PROVISIONING_SERVER_IP` in `config.env`.
* **Target Nodes**: 2x AMD BC-250 nodes (x86_64 UEFI) booting via onboard Gigabit Ethernet.

---

## 2. Boot Flow & Logic Explained

The network boot sequence uses a two-stage chainload to avoid TFTP bottlenecks:

```
[Target BC-250 Node]
       │
       │ 1. Broadcasts DHCP Discover with Client Architecture option 7 or 9 (UEFI x86_64)
       ▼
[DHCP/TFTP Server]
       │
       │ 2. Detects 'efi64' architecture, but NOT 'ipxe' userclass
       │    Responds with Next-Server=[PROVISIONING_SERVER_IP], Bootfile=ipxe.efi
       ▼
[BC-250 UEFI Firmware]
       │
       │ 3. Downloads ipxe.efi over TFTP from PROVISIONING_SERVER_IP:69
       │ 4. Executes ipxe.efi in memory
       ▼
[iPXE Executing on Node]
       │
       │ 5. Issues secondary DHCP Discover containing User-Class option: "iPXE"
       ▼
[DHCP/TFTP Server]
       │
       │ 6. Recognizes 'ipxe' user-class tag
       │    Responds with Bootfile=http://PROVISIONING_SERVER_IP/boot.ipxe
       ▼
[iPXE Executing on Node]
       │
       │ 7. Fetches http://PROVISIONING_SERVER_IP/boot.ipxe over HTTP
       │ 8. Downloads kernel/initramfs and boots into Arch Linux live environment
```

---

## 3. Configuration Implementation

To support this flow, your DHCP/TFTP server must implement the following logic:

1.  **Identify UEFI x86_64 clients**: Match on Client Architecture Option 93 (values `7` or `9`).
2.  **Stage 1 (TFTP)**: For these clients, provide the path to `ipxe.efi` via TFTP.
3.  **Identify iPXE clients**: Match on the `User-Class` option (value `iPXE`).
4.  **Stage 2 (HTTP)**: For iPXE clients, provide the path to `boot.ipxe` via HTTP.

### Example: dnsmasq Configuration

If you are using `dnsmasq` (common in OpenWrt, DD-WRT, or Linux), add the following to your configuration:

```ini
# ==============================================================================
# AMD BC-250 Cluster PXE / iPXE Network Boot Configuration
# Provisioning Server: [YOUR_PROVISIONING_SERVER_IP]
# ==============================================================================

# Match standard x86_64 UEFI PXE clients (Option 93 / client-arch: 7 = EFI BC, 9 = EFI x86-64)
dhcp-match=set:efi64,option:client-arch,7
dhcp-match=set:efi64,option:client-arch,9

# Match iPXE user class when ipxe.efi takes over execution
dhcp-userclass=set:ipxe,iPXE

# Stage 1 (Standard UEFI PXE): Direct firmware to fetch ipxe.efi via TFTF
# The '!ipxe' tag ensures we don't loop by serving ipxe.efi to an already running iPXE client
dhcp-boot=tag:efi64,tag:!ipxe,ipxe.efi,,[YOUR_PROVISIONING_SERVER_IP]

# Stage 2 (iPXE Running): Direct iPXE to fetch boot.ipxe via HTTP
dhcp-boot=tag:ipxe,http://[YOUR_PROVISIONING_SERVER_IP]/boot.ipxe

# ------------------------------------------------------------------------------
# OPTIONAL: Native UEFI HTTP Boot Support (Client Architecture 16)
# ------------------------------------------------------------------------------
dhcp-match=set:efi64_http,option:client-arch,16
dhcp-option-force=tag:efi64_http,option:vendor-class,HTTPClient
dhcp-boot=tag:efi64_http,tag:!ipxe,http://[YOUR_PROVISIONING_SERVER_IP]/ipxe.efi
```

---

## 4. (Optional) Static IP Assignments

If you wish to assign predictable static IP addresses to the two BC-250 nodes, configure **DHCP Reservations** (also known as Static Leases) on your DHCP server using the MAC addresses of your nodes.

---

## 5. Verification & Troubleshooting

### Common Issues

1.  **Node repeatedly reboots to TFTP `ipxe.efi` (infinite loop)**:
    * **Cause**: The DHCP server is serving `ipxe.efi` to the client even after it has identified as `iPXE`.
    * **Fix**: Ensure the `tag:!ipxe` condition is correctly implemented in your DHCP configuration to distinguish between the initial UEFI boot and the subsequent iPXE execution.

2.  **TFTP Open Timeout**:
    * **Cause**: The node cannot reach the TFTP server on UDP port 69.
    * **Fix**: Verify the TFTP service is running on your provisioning server and that no firewalls (host or network) are blocking UDP 69.

3.  **HTTP Download Failure**:
    * **Cause**: iPXE cannot reach the provisioning server via HTTP.
    * **Fix**: Verify the web server (Nginx) is running and that `boot.ipxe` is accessible from any machine on the same subnet.
