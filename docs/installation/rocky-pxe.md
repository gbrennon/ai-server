# Rocky Linux 10.2 Network Installation for GMKtec EVO X2

This guide installs Rocky Linux without a USB drive. Your workstation temporarily
serves the Rocky installer over the LAN using PXE. The target must be connected
by Ethernet to the same LAN as the workstation.

## 1. Prepare the workstation

Install the required tools on Fedora/Rocky:

```bash
sudo dnf install -y curl dnsmasq python3 bsdtar
```

Find the wired interface and its IP:

```bash
ip -br addr
```

Use the interface connected to the same switch/router as the EVO X2 (for
example, `enp6s0`, not `lo` or a Wi-Fi interface where possible).

The script defaults to proxy-DHCP mode, which leaves address assignment to the
existing router DHCP server. This is the safer mode for a normal home LAN:

```bash
sudo ./scripts/prepare-rocky-pxe.sh --interface enp6s0
```

The script downloads and verifies the Rocky Linux 10.2 x86_64 Boot ISO, serves
its kernel and initrd, and starts temporary HTTP and PXE services. Leave it
running while the EVO X2 boots. Press `Ctrl-C` after the installer has loaded;
the services are stopped automatically.

If the isolated install network has no existing DHCP server, use a range on the
workstation's LAN instead:

```bash
sudo ./scripts/prepare-rocky-pxe.sh \
  --interface enp6s0 \
  --server-ip 192.168.50.1 \
  --dhcp-range 192.168.50.100,192.168.50.150
```

Do **not** use DHCP mode on a LAN where another DHCP server is active. It can
interfere with other devices. Use proxy-DHCP mode or an isolated switch.

## 2. EVO X2 BIOS and network boot

1. Connect Ethernet to the EVO X2 and to the same LAN as the workstation.
2. Power the EVO X2 completely off.
3. Power it on and immediately **tap `Delete` repeatedly** to enter BIOS.
4. If that does not work, restart and **tap `Esc` repeatedly** instead. These
   are alternatives, not keys pressed together. Use a wired USB keyboard.
5. In BIOS, confirm the onboard Ethernet/iGPU devices are enabled.
6. In the Boot section, enable network/PXE boot and move **UEFI IPv4 Network**
   or **PXE IPv4** above the local disk temporarily.
7. Save and reboot. Alternatively, use the one-time boot menu and select
   **UEFI IPv4 Network**.

The PXE loader boots the Rocky Linux installer directly. The kernel and initrd
come from the Boot ISO; the package repository is downloaded from Rocky's
network mirror.

## 3. Rocky installer choices (SSH-only server)

In Anaconda:

- Select **Minimal Install** or the server/minimal environment.
- Do not select GNOME, KDE, Workstation, or any desktop environment.
- Configure the wired Ethernet connection and hostname.
- Use DHCP initially unless you need a fixed address; record the assigned IP.
- Create your normal user and grant administrator/sudo privileges.
- Set a root password or disable root SSH login later; use the normal sudo user.
- In **Software Selection**, leave Add-ons empty unless you specifically need
  one. No GUI is required.
- In **Network & Host Name**, make sure the Ethernet interface is connected.
- Complete disk partitioning and installation, then reboot from the local disk.

After the first boot, log in locally once if needed and enable SSH:

```bash
sudo dnf install -y openssh-server
sudo systemctl enable --now sshd
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --reload
ip -br addr
```

## 4. Verify SSH and deploy ai-server

From the workstation:

```bash
ssh-copy-id <user>@<mini-pc-ip>
ssh <user>@<mini-pc-ip> 'sudo -n true'
```

If sudo asks for a password during unattended deployment, configure it on the
EVO X2 after reviewing the security implications:

```bash
ssh <user>@<mini-pc-ip> \
  "echo '<user> ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/90-<user>"
ssh <user>@<mini-pc-ip> 'sudo chmod 440 /etc/sudoers.d/90-<user>'
```

Deploy the Vulkan profile from this repository:

```bash
./scripts/deploy-remote.sh <mini-pc-ip> <user> profiles/gmktec-evo-x2.yml
```

The deployment compiles llama.cpp with Vulkan, downloads the configured model,
and starts the API service. Verify it with:

```bash
curl http://<mini-pc-ip>:8080/health
ssh <user>@<mini-pc-ip> \
  'grep -iE "vulkan|offload|layers" /var/log/llama.cpp/llama-server.log | head'
```

## Troubleshooting and cleanup

- If PXE is not offered, confirm the Ethernet link, use UEFI IPv4 Network, and
  check that the script is still running on the workstation.
- If the target receives an IP but cannot load the installer, check the
  workstation firewall and allow TCP port `8088` temporarily.
- If dnsmasq reports an address or DHCP conflict, stop it with `Ctrl-C` and use
  the default proxy-DHCP mode or an isolated network.
- Generated files, ISO, logs, and the extracted installer remain in:
  `~/.local/share/rocky-pxe/10.2` (or the `--work-dir` supplied).
- The installed system has no desktop GUI. After deployment, the API is at
  `http://<mini-pc-ip>:8080/` and the OpenAI-compatible endpoint is at
  `http://<mini-pc-ip>:8080/v1/chat/completions`.
