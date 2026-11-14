# Enabling PXE Network Boot on AMD BC-250 (Firmware v3.00)

This guide describes how to enable PXE (Preboot Execution Environment) network booting on AMD BC-250 boards running firmware version 3.00. This is a required step before the automated provisioning process can begin.

## Overview

In firmware version 3.00, the UEFI boot order and network stack settings have been reorganized. To boot from a network interface, you must explicitly enable the Network Stack and set the Network Interface as a high-priority boot option.

## Step-by-Step Instructions

### 1. Enter UEFI Setup
1. Power on or restart your AMD BC-250 board.
2. When the manufacturer logo appears, repeatedly press the **[DEL]** or **[F2]** key (refer to your specific board's manual if these do not work) to enter the UEFI BIOS Setup Utility.

### 2. Enable the Network Stack
1. Navigate to the **Advanced** tab using the arrow keys.
2. Select **Network Configuration** or **PCIe/PCI Subsystem Settings**.
3. Locate the entry labeled **Network Stack Configuration**.
4. Change the **IPv4 Network Stack** setting from `[Disabled]` to `[Enabled]`.
5. (Optional) If you are using IPv6, change **IPv6 Network Stack** to `[Enabled]`.

### 3. Configure Boot Priority
1. Navigate to the **Boot** tab.
2. Locate the **Boot Option Priorities** section.
3. Select **Boot Option #1**.
4. From the list of available devices, select **UEFI: Network Device** or **PXE IPv4 Network Stack**.
    * *Note: The exact name may vary depending on your onboard NIC (e.g., "Realtek PCIe GbE Family Controller" or "Intel Ethernet Connection").*
5. Ensure that your local NVMe drive is set as **Boot Option #2** to allow for normal booting once the OS is installed.

### 4. Save and Exit
1. Navigate to the **Save & Exit** tab.
2. Select **Save Changes and Reset**.
3. Confirm the action by selecting **Yes**.

## Troubleshooting & Known Quirks (v3.00)

### Issue: Network Stack option is greyed out
* **Cause**: The Network Stack can only be enabled if the onboard NIC is properly initialized.
* **Workaround**: Ensure that no other PCIe network cards are conflicting with the onboard NIC in the `Advanced -> PCIe Configuration` menu.

### Issue: PXE boot fails with "No DHCP/TFTP server found"
* **Cause**: The router/switch may not be responding to the DHCP request from the BC-250.
* **Check**: 
    * Verify that your Provisioning Server is running and reachable on the network.
    * Ensure your router's DHCP/TFTP settings match the requirements in the [Network Setup Guide](docs/network-setup.md).
    * Check if the BC-250 is receiving an IP address via a different method (e.g., manual assignment) to rule out hardware issues.

### Issue: UEFI Secure Boot interference
* **Cause**: Secure Boot may prevent the execution of unsigned iPXE binaries.
* **Workaround**: Navigate to **Security -> Secure Boot** and set **Secure Boot Control** to `[Disabled]`.
