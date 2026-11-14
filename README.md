# AMD BC-250 AI Cluster Provisioning Guide

This repository provides an automated guide and toolset for building a high-performance, 2-node AMD BC-250 AI compute cluster. The goal is to go from bare hardware to a fully operational distributed inference cluster with Open WebUI and SearXNG in under 2 hours.

---

## 🚀 Architecture Overview

The system is split into two independent Docker Compose stacks:

1. **`pxe-server` Stack (`docker-compose.pxe.yml`):**
   - **TFTP Service (`alpine + tftp-hpa`)**: Serves x86_64 UEFI iPXE bootloader (`ipxe.efi`).
   - **Web Service (`nginx:alpine`)**: Serves `boot.ipxe`, Arch Linux kernel/initramfs/airootfs, and unattended provision scripts.
   - Can run on any machine on your network (e.g. Raspberry Pi, laptop, NAS, or workstation).

2. **`ai-server` Stack (`docker-compose.ai.yml`):**
   - **Open WebUI**: Connects directly to Node 1's `llama-server` OpenAI-compatible endpoint.
   - **SearXNG**: Privacy-respecting metasearch engine configured out-of-the-box for Open WebUI web search.
   - Can run on Node 1 directly or on any secondary host.

3. **Distributed Hardware Inference:**
   - **Node 1 (`pythoberon1`)**: Primary inference server running `llama-server` with Qwen 3.6 35B split across Vulkan0 (Node 1) and RPC0 (Node 2).
   - **Node 2 (`pythoberon2`)**: RPC compute worker running `ggml-rpc-server` connected via a dedicated 2.5GbE direct interconnect cable.

---

## 🛠 Prerequisites & Hardware

- **2x AMD BC-250 Boards** (x86_64 UEFI, Oberon/PS5 APU derivative)
- **1x Provisioning Host** (Any Linux/macOS machine running Docker)
- **Dedicated 2.5GbE Direct Link**: USB-to-2.5GbE adapters connecting Node 1 and Node 2 directly.
- **NVMe Storage**: Fast NVMe drive in each BC-250 board.
- **Local Network**: Router/switch capable of PXE/DHCP (e.g. OpenWrt, DD-WRT, OPNsense, or standard DHCP server). See [Network Boot Configuration](docs/network-boot-configuration.md).

---

## ⚙️ Configuration (`config.env`)

All cluster variables are centrally defined in `config.env`:

| Variable | Description | Default |
|---|---|---|
| `PROVISIONING_SERVER_IP` | IP of machine running PXE stack | `192.168.42.100` |
| `NODE1_IP` / `NODE2_IP` | Primary LAN IPs for Node 1 and Node 2 | `192.168.42.101` / `.102` |
| `NODE1_DIRECT_IP` / `NODE2_DIRECT_IP` | Static `/30` IPs assigned to each node's USB Ethernet adapter for the dedicated 2.5GbE RPC link | `10.0.42.1` / `10.0.42.2` |
| `RPC_PORT` | Port for `ggml-rpc-server` communication | `50052` |
| `LLAMA_SERVER_PORT` | Port for `llama-server` API on Node 1 | `8080` |
| `DEFAULT_MODEL_HF` | Hugging Face repo ID for Qwen 3.6 35B GGUF | `unsloth/Qwen3.6-35B-A3B-GGUF:UD-Q4_K_M` |
| `LLAMA_CTX_SIZE` | Context window size | `65536` |
| `LLAMA_TENSOR_SPLIT` | VRAM layer split ratio between Node 1 & Node 2 | `48,52` |
| `LLAMA_CACHE_K` / `LLAMA_CACHE_V` | KV cache quantization precision | `q8_0` |
| `OPENWEBUI_PORT` | Port for Open WebUI | `3000` |
| `SEARXNG_PORT` | Port for SearXNG | `8088` |
| `PROVISIONING_USER` | Admin user created on nodes | `admin` |

---

## 📖 Step-by-Step Deployment

### Step 1: Configure SSH Keys and MAC Addresses

1. **Deploy your SSH key**:
   ```bash
   cat ~/.ssh/id_ed25519.pub > www/provision/authorized_keys
   ```

2. **Set Hardware MAC Addresses**:
   In [config.env](config.env), configure the physical onboard Ethernet MACs of your two BC-250 boards:
   ```bash
   NODE1_MAC="A8:A1:59:B4:00:00"
   NODE2_MAC="A8:A1:59:B4:00:01"
   ```

### Step 2: Fetch Boot Artifacts & Stage PXE Server

On your provisioning machine:
```bash
# 1. Download x86_64 UEFI ipxe.efi and Arch Linux live ISO
make fetch

# 2. Extract ISO filesystem into www/arch/
make stage

# 3. Start the PXE server stack (tftp + nginx)
make up-pxe

# 4. Verify endpoints and network readiness
make check
```

### Step 3: PXE Boot the BC-250 Nodes

1. Connect Node 1 and Node 2 to your network and power them on.
2. Enter the UEFI boot menu (`F11` during POST) and select **UEFI IPv4 Network Boot**.
3. Each node will:
   - Chainload `ipxe.efi` via TFTP $\rightarrow$ load `boot.ipxe` via HTTP.
   - Boot Arch Linux kernel and initramfs over HTTP.
   - Execute unattended `install.sh`: partition NVMe, install base Arch, install SSH keys, deploy `/etc/bc250/config.env`, and reboot into NVMe.

### Step 4: Convert Nodes to CachyOS & Enable Hardware Unlocks

Once the nodes reboot into NVMe, SSH into each node as `admin` (or your configured `PROVISIONING_USER`):

```bash
# On Node 2 (pythoberon2):
ssh admin@192.168.42.102
./convert.sh

# On Node 1 (pythoberon1):
ssh admin@192.168.42.101
./convert.sh
```

`convert.sh` automatically performs all hardware optimizations:
- Migrates repositories to optimized CachyOS (x86_64_v3 / v4).
- Installs `linux-cachyos` kernel and Mesa RADV Vulkan stack.
- Configures 8-Core / 16-Thread SMU CPU unlock (`bc250-core-unlock.service`).
- Clones `bc250-cu-live-manager` (GPU dispatch — **not yet enabled**).
- Configures CMOS UMA VRAM to 512 MiB via `bc250memcfg`.

#### WGP Probe Wizard (GPU Isolation Testing)

After `convert.sh`, the GPU is at **stock 24 CUs** (WGP0–WGP2 per row enabled). The 4 unlocked WGPs (WGP3, WGP4 on each of 2 sides × 2 shader halves) must be individually tested for correctness before enabling.

```bash
# 1. Run the interactive probe wizard (tests each candidate WGP from stock state)
sudo ./wgp-wizard.sh probe

# 2. Review the results
./wgp-wizard.sh report

# 3. Apply verified masks to boot service (installs systemd unit with correct masks)
sudo ./wgp-wizard.sh apply

# 4. Reboot to activate verified configuration
sudo reboot
```

**Makefile shortcuts:**
```bash
make wgp-probe        # Run full probe cycle (sudo)
make wgp-report       # Show results summary
make wgp-apply        # Apply masks + install boot service (sudo)
make wgp-status       # Check current GPU state
make wgp-force-disable ARGS=1.0.3  # Force-disable a single WGP (sudo)
```

**How the probe works:**
1. Starts from **stock 24 CUs** (mask `0x07` per row: WGP0+WGP1+WGP2).
2. For each candidate WGP (WGP3, WGP4 × 4 rows = 8 tests):
   - Enables that single WGP via `bc250-cu-live-manager` → 26 CUs active.
   - Runs Vulkan compute correctness test (`bc250-compute-verify.sh`, ~20s).
   - Records PASS/FAIL in `state/wgp-probe.log`.
   - Disables that WGP → back to stock.
3. After all probes, `apply` computes per-row masks: `0x07 + bits for each GOOD candidate`.
4. Updates `/etc/bc250/bc250-cu-live-manager.conf` and installs the boot service.

**Example report output:**
```
--- Results ---

WGP          RESULT   ERRORS     DETAILS
---          ------   ------     -------
0.0.3        PASS     0
0.0.4        PASS     0
0.1.3        PASS     0
0.1.4        PASS     0
1.0.3        PASS     0
1.0.4        FAIL     234        int_errors=12 fp_errors=222
1.1.3        PASS     0
1.1.4        PASS     0

--- Summary by Row ---
  0.0: mask=0x0f (26 CUs) — 2 good, 0 bad
  0.1: mask=0x0f (26 CUs) — 2 good, 0 bad
  1.0: mask=0x0f (26 CUs) — 2 good, 0 bad
  1.1: mask=0x07 (24 CUs) — 0 good, 2 bad
```

**Important:** Always run the WGP probe and apply masks **before rebooting**. Without this step, the boot service is not installed and the GPU remains at stock 24 CUs.

`setup-llama-server.sh` builds and configures distributed llama.cpp cluster services:
- Compiles `llama.cpp` with Vulkan & GGML RPC support.
- **Node 2 role**: Enables `bc250-rpc.service` (`ggml-rpc-server`).
- **Node 1 role**: Enables `bc250-llm.service` (`llama-server` in dynamic router mode without a model loaded on startup).
- Model definitions are managed in the server user's home folder (e.g. `/home/llama/models.ini`) along with a models directory (`/home/llama/models`) for GGUF model files.

### Step 5: Start Open WebUI & SearXNG (`ai-server`)

On Node 1 (or any machine on the network):
```bash
make up-ai
```
Or run:
```bash
./scripts/setup-webui.sh
```

Access the interfaces:
- **Open WebUI**: [http://localhost:3000](http://localhost:3000) (or `http://<NODE1_IP>:3000`)
- **SearXNG**: [http://localhost:8088](http://localhost:8088)
- **Llama Server API**: `http://<NODE1_IP>:8080/v1`

---

## 🛡️ Safety Guardrails & Reinstallation

1. **MAC Allowlist**: The installer halts (`exit 1`) if the booting machine's MAC is not in `NODE_MAP`.
2. **Existing Installation Guard**: The installer exits (`exit 0`) without touching disks if an existing partition labeled `ROOT` is found.

To deliberately wipe and reinstall a node:
1. In [www/boot.ipxe](www/boot.ipxe), uncomment:
   ```ipxe
   set extra_cmdline reinstall
   ```
2. Network boot the node via PXE.
3. Re-comment `reinstall` in `boot.ipxe` once complete.

See [docs/recovery-and-reinstall.md](docs/recovery-and-reinstall.md) for recovery procedures and USB emergency boot instructions.

---

## 📚 Documentation Reference

- [Network Boot Configuration](docs/network-boot-configuration.md): DHCP/dnsmasq router setup and boot architecture.
- [PXE 3.00 Firmware Guide](docs/pxe-3.00-firmware.md): Enabling UEFI network boot in BC-250 BIOS.
- [Troubleshooting Guide](docs/troubleshooting.md): Stage-by-stage diagnostic checks.
- [Recovery & Reinstallation](docs/recovery-and-reinstall.md): Re-provisioning, systemd-boot kernel fallbacks, and USB live boot.
