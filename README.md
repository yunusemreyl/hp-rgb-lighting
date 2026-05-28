<div align="center">

# ⌨️ hp-rgb-lighting
### **Standalone Keyboard RGB Backlight & Control Driver for HP Laptops**

*A lightweight, standalone Linux kernel companion driver that enables rich keyboard RGB customization, brightness toggling, and Windows-key lock control.*

[![GitHub Release](https://img.shields.io/github/v/release/yunusemreyl/hp-rgb-lighting?style=for-the-badge&color=8A2BE2&logo=github)](https://github.com/yunusemreyl/hp-rgb-lighting/releases)
[![License: GPL-2.0](https://img.shields.io/github/license/yunusemreyl/hp-rgb-lighting?style=for-the-badge&color=FF4500&logo=gnu)](LICENSE)
[![Stars](https://img.shields.io/github/stars/yunusemreyl/hp-rgb-lighting?style=for-the-badge&color=FFD700&logo=githubstars)](https://github.com/yunusemreyl/hp-rgb-lighting/stargazers)
[![Issues](https://img.shields.io/github/issues/yunusemreyl/hp-rgb-lighting?style=for-the-badge&color=00FF7F&logo=github)](https://github.com/yunusemreyl/hp-rgb-lighting/issues)

---
</div>

> [!IMPORTANT]  
> **No Driver Conflicts!**  
> This driver works completely **standalone** and coexists perfectly alongside the stock kernel `hp-wmi` driver or any patched WMI driver. It does not claim any WMI GUID, avoiding driver registration conflicts entirely.

---

## ✨ Features

| Feature | Description | Interface |
| :--- | :--- | :--- |
| 🎨 **Multi-Zone RGB** | Set custom Hex colors individually for up to **8 zones** (`zone0` to `zone7`). | `sysfs` platform device |
| 💡 **Brightness Toggle** | A simple power interface to quickly enable or disable the keyboard backlight. | `sysfs` platform device |
| 🔒 **Windows Key Lock** | Enable or disable the Windows Key lock (Gaming Mode) on supported keyboard profiles. | `sysfs` platform device |

---

## 🐧 Distro Compatibility

This driver has native support for major Linux distributions and their derivatives:

<p align="left">
  <img src="https://img.shields.io/badge/Arch%20Linux-1793D1?style=for-the-badge&logo=arch-linux&logoColor=white" alt="Arch Linux" />
  <img src="https://img.shields.io/badge/Ubuntu-E95420?style=for-the-badge&logo=ubuntu&logoColor=white" alt="Ubuntu" />
  <img src="https://img.shields.io/badge/Debian-A81D33?style=for-the-badge&logo=debian&logoColor=white" alt="Debian" />
  <img src="https://img.shields.io/badge/Fedora-3C50B0?style=for-the-badge&logo=fedora&logoColor=white" alt="Fedora" />
  <img src="https://img.shields.io/badge/Red%20Hat-EE0000?style=for-the-badge&logo=red-hat&logoColor=white" alt="RHEL" />
  <img src="https://img.shields.io/badge/openSUSE-73BA46?style=for-the-badge&logo=opensuse&logoColor=white" alt="openSUSE" />
  <img src="https://img.shields.io/badge/NixOS-5277C3?style=for-the-badge&logo=nixos&logoColor=white" alt="NixOS" />
</p>

---

## 🚀 Installation

### 1. Quick Install (All Distros)
The helper script `setup.sh` auto-detects your distro, installs the required compiler toolchain + kernel headers, and sets up **DKMS** for automatic rebuilds on kernel updates.

```bash
# Clone the repository
git clone https://github.com/yunusemreyl/hp-rgb-lighting
cd hp-rgb-lighting

# Install the driver
sudo ./setup.sh
```
To clean up and uninstall:

```bash
sudo ./setup.sh uninstall
```
## 2. Tailored Installations ##
⚡ Optimized Kernels (CachyOS, Arch Clang, etc.)
🛠️ Manual DKMS Install
🏔️ Arch Linux (AUR)
❄️ NixOS Flake
⚙️ Usage
All driver controls are located under the platform device directory: cd /sys/devices/platform/hp-rgb-lighting/

## 🎨 RGB Keyboard Colors ##
Control custom colors for up to 8 zones (zone0 to zone7) using HEX values.

```bash
# Read current color of Zone 0
cat /sys/devices/platform/hp-rgb-lighting/zone0
# Set Zone 0 to Red (FF0000)
echo "FF0000" | sudo tee /sys/devices/platform/hp-rgb-lighting/zone0
# Set Zone 1 to Green (00FF00)
echo "00FF00" | sudo tee /sys/devices/platform/hp-rgb-lighting/zone1
# Set Zone 2 to Blue (0000FF)
echo "0000FF" | sudo tee /sys/devices/platform/hp-rgb-lighting/zone2
```
## 💡 Backlight Brightness ##
Quickly toggle the keyboard backlight state.

```bash
# Get current backlight state (1 = ON, 0 = OFF)
cat /sys/devices/platform/hp-rgb-lighting/brightness
# Turn backlight OFF
echo 0 | sudo tee /sys/devices/platform/hp-rgb-lighting/brightness
# Turn backlight ON
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/brightness
```
## 🔒 Windows Key Lock (Gaming Mode) ##
Enable/disable gaming lock for the Windows Key.

```bash
# Check current lock state (1 = LOCKED, 0 = UNLOCKED)
cat /sys/devices/platform/hp-rgb-lighting/win_lock
# Lock Windows Key (Disable it)
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/win_lock
# Unlock Windows Key (Enable it)
echo 0 | sudo tee /sys/devices/platform/hp-rgb-lighting/win_lock
```

## 📜 License & Disclaimer ##
License: Distributed under the 
GPL-2.0-or-later
 License.

Disclaimer: USE AT YOUR OWN RISK. THE AUTHORS ACCEPT NO RESPONSIBILITY FOR ANY DAMAGES.
## ✨ Show Your Support ##
If this driver works for your laptop, please consider giving this repository a ⭐ to help others discover it!
