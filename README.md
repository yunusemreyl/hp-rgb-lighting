# Standalone hp-rgb-lighting Driver — Keyboard RGB for HP Laptops

A standalone companion Linux kernel driver that adds keyboard RGB backlight (single-zone & multi-zone), brightness, and Win-lock controls for HP Omen, Victus, and similar laptops.

This driver works completely **standalone** and **coexists alongside either the stock kernel `hp-wmi` driver or any patched WMI driver**. It does not claim any WMI GUID, avoiding driver registration conflicts entirely.

**Please ⭐ star the repo if this driver works for you!**

---

## Features

- 🎨 **Multi-Zone Keyboard RGB** — set hex colors individually for up to 8 zones (`zone0` to `zone7`) via the sysfs platform device.
- 💡 **Brightness Toggle** — simple toggle interface to quickly enable or disable the keyboard backlight.
- 🔒 **Win Lock (Gaming Key)** — enable or disable the Windows key lock (gaming mode toggle) on supported keyboard profiles.

---

## Installation

### Distro Compatibility
Supported distros: **Arch Linux/Manjaro**, **Ubuntu/Debian**, **Fedora/RHEL**, **openSUSE**, **Void Linux**, **Gentoo**, and derivatives.

### Quick Install (All Distros)

The included `setup.sh` script auto-detects your distro, installs compiler dependencies + kernel headers, and sets up DKMS for automatic rebuilding upon kernel updates:

```bash
git clone https://github.com/yunusemreyl/hp-rgb-lighting
cd hp-rgb-lighting
sudo ./setup.sh
```

To uninstall and clean up the module:
```bash
sudo ./setup.sh uninstall
```

### Optimized Kernels (CachyOS, Arch Clang, etc.)

If your kernel was compiled with Clang/LLVM, the build process must use the same toolchain. The `setup.sh` and `Makefile` automatically detect this by checking `/proc/version`.
If the automatic detection fails, you can force it manually with:
```bash
sudo LLVM=1 ./setup.sh
```

### Manual DKMS Install

```bash
git clone https://github.com/yunusemreyl/hp-rgb-lighting
cd hp-rgb-lighting
make
sudo make install-dkms
```

### Arch Linux (AUR)

```bash
git clone https://github.com/yunusemreyl/hp-rgb-lighting
cd hp-rgb-lighting
make install-arch
```

### NixOS Flake

Add this repository as an input to your NixOS flake:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    hp_rgb_lighting.url = "github:yunusemreyl/hp-rgb-lighting";
  };
  outputs = { self, nixpkgs, hp_rgb_lighting, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        hp_rgb_lighting.nixosModules.default
        {
          hardware.hp-rgb-lighting = {
            enable = true;
          };
        }
      ];
    };
  };
}
```

---

## Usage

All control nodes reside under the platform device directory `/sys/devices/platform/hp-rgb-lighting/`.

### 1. RGB Keyboard Colors

You can set custom HEX colors for each zone (`zone0` through `zone7`).

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

### 2. Backlight Brightness

Control backlighting power state.

```bash
# Get current backlight state (1 = ON, 0 = OFF)
cat /sys/devices/platform/hp-rgb-lighting/brightness

# Turn backlight OFF
echo 0 | sudo tee /sys/devices/platform/hp-rgb-lighting/brightness

# Turn backlight ON
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/brightness
```

### 3. Windows Key Lock (Gaming Mode)

Enable or disable gaming keyboard lock.

```bash
# Check current lock state (1 = LOCKED/DISABLED, 0 = UNLOCKED/ENABLED)
cat /sys/devices/platform/hp-rgb-lighting/win_lock

# Lock Windows Key (Disable it)
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/win_lock

# Unlock Windows Key (Enable it)
echo 0 | sudo tee /sys/devices/platform/hp-rgb-lighting/win_lock
```

---

## Tested On

- Victus 16-s1 (9Z791EA)
- Victus 16-r0053nt (i5-13500H, RTX 4050) — *Tested by yunusemreyl*

---

## License

GPL-2.0-or-later — see [LICENSE](LICENSE)

---

## Disclaimer

**USE AT YOUR OWN RISK. THE AUTHORS ACCEPT NO RESPONSIBILITY FOR ANY DAMAGES.**
