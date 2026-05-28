# HP RGB Lighting Driver (hp-rgb-lighting) Detailed Driver Documentation

This document describes the internal architecture, data structures, key functions, and usage guidelines of the `hp-rgb-lighting.c` Linux kernel companion module. This driver manages the per-zone RGB keyboard backlight and helper backlight attributes of HP Omen and Victus laptops via ACPI/WMI.

---

## 1. Overview and Architecture

The `hp-rgb-lighting` module is a lightweight companion driver designed specifically to handle keyboard lighting control for HP Omen/Victus laptops. 

Key architectural design decisions:
* **Coexistence by Design:** The driver operates alongside the standard `hp-wmi` kernel driver (which manages thermal profiles, hardware monitoring, fan controls, hotkeys, and rfkill). To avoid conflicting or claiming the main WMI interface exclusively, this companion driver does **not** register any `MODULE_ALIAS("wmi:...")`. Instead, it invokes the necessary BIOS methods dynamically over the shared BIOS GUID.
* **Sysfs User-Space Interface:** The module publishes a set of virtual files under `/sys/devices/platform/hp-rgb-lighting/` allowing normal userspace utilities or custom control scripts to query and configure keyboard colors and states.
* **Concurrency and Thread Safety:** All WMI method evaluations are synchronized using kernel mutexes (`hp_wmi_query_mutex` and `rgb_mutex`) to prevent simultaneous write collisions to the underlying ACPI interpreter.

---

## 2. Constants, Enumerations, and Data Structures

Below is a detailed breakdown of the module's core constants, commands, and structures:

### A. WMI GUID
```c
#define HPWMI_BIOS_GUID "5FB7F034-2C63-45E9-BE91-3D44E2C707E4"
```
The unique WMI GUID used to invoke the proprietary HP BIOS interface. This represents the channel through which queries are routed to the ACPI firmware.

### B. `enum hp_wmi_command` (WMI Primary Command Codes)
Specifies the broad type of transaction requested from the HP BIOS:
* **`HPWMI_READ` (`0x01`):** Initiates a read query to fetch state values from BIOS (e.g. read the Windows lock state).
* **`HPWMI_WRITE` (`0x02`):** Initiates a write query to alter BIOS variables.
* **`HPWMI_BACKLIGHT` (`0x20009`):** Command category dedicated to controlling keyboard colors and patterns.
* **`HPWMI_GAMING_KEY` (`0x2000B`):** Dedicated to controlling special gaming features, such as the Windows key lock.

### C. `enum hp_wmi_backlight_commandtype` (Backlight Sub-Commands)
Sub-queries used under the `HPWMI_BACKLIGHT` primary command to specify exact backlight operations:
* **`HPWMI_COLOR_GET_QUERY` (`0x02`):** Used to retrieve the entire active color map from the BIOS.
* **`HPWMI_COLOR_SET_QUERY` (`0x03`):** Used to write the entire modified color map back to the BIOS, triggering the hardware state change.
* **`HPWMI_BRIGHTNESS_GET_QUERY` (`0x04`):** Retrieves the master toggle state of the backlight.
* **`HPWMI_BRIGHTNESS_SET_QUERY` (`0x05`):** Sets the master toggle state (on/off) of the backlight.

### D. BIOS Communication Layouts
The memory mapping of the buffers sent to and received from the ACPI interface:

```c
struct bios_args {
  u32 signature;      // Verification signature. Must be 0x55434553 (ASCII for "SECU").
  u32 command;        // The primary command code (enum hp_wmi_command).
  u32 commandtype;    // The sub-query/command type (enum hp_wmi_backlight_commandtype).
  u32 datasize;       // Exact size in bytes of the payload copied into the data[] array.
  u8 data[];          // Flexible/variable-length payload array.
};
```

```c
struct bios_return {
  u32 sigpass;        // Signature validation code returned by the BIOS.
  u32 return_code;    // Execution result: 0 for success, non-zero indicating a BIOS error code.
};
```

---

## 3. Core Helper Functions

### `encode_outsize_for_pvsz`
```c
static inline int encode_outsize_for_pvsz(int outsize)
```
* **Purpose:** Maps the expected output size from the BIOS call to a specific ACPI Method ID.
* **Rationale:** The HP WMI interface uses different virtual methods (Method IDs 1 to 5) depending on the size of the buffer to allocate.
* **Behavior:**
  - Returns `-EINVAL` if `outsize > 4096`.
  - Otherwise returns corresponding Method IDs based on size: `> 1024` $\rightarrow$ 5, `> 128` $\rightarrow$ 4, `> 4` $\rightarrow$ 3, `> 0` $\rightarrow$ 2, `0` $\rightarrow$ 1.

### `hp_wmi_perform_query`
```c
static int hp_wmi_perform_query(int query, enum hp_wmi_command command, void *buffer, int insize, int outsize)
```
The central function through which all ACPI WMI requests are serialized:
1. Calls `encode_outsize_for_pvsz` to find the correct ACPI Method ID (`mid`).
2. Allocates a dynamic `struct bios_args` buffer using `kzalloc` with the input size (ensuring a minimum padding size of 128 bytes).
3. Fills in the security signature (`0x55434553`), command parameters, payload size, and copies the input buffer payload.
4. Locks `hp_wmi_query_mutex` to enforce serial BIOS execution.
5. Invokes `wmi_evaluate_method` with the BIOS GUID, Method ID, input buffer, and output buffer.
6. Validates the type of the returned ACPI object (must be `ACPI_TYPE_BUFFER`) and checks for memory integrity.
7. Parses `struct bios_return` and propagates any hardware execution errors (`return_code`).
8. Extracts the response data, copies it to the output `buffer`, and frees allocated kernel resources.

---

## 4. Sysfs Interface (The User-Space API)

Sürücü yüklendiğinde, `/sys/devices/platform/hp-rgb-lighting/` dizini altında kullanıcı alanı programlarının okuma ve yazma yapabileceği kontrol arayüzleri oluşturulur. Tüm arayüzlerde eşzamanlı yazma ve okuma işlemlerini korumak için `rgb_mutex` kilidi kullanılır.

### A. Keyboard RGB Zones (`zone0` through `zone7`)
Supports up to **8 customizable lighting zones** on the keyboard.
* **Permissions:** Read/Write (`0644`).
* **Value Format:** A 6-character, capitalized hexadecimal 24-bit RGB code (e.g. `"FF0000"` for pure Red, `"0000FF"` for Blue).
* **Reading (`zone_show`):** Loads a 128-byte color table from the BIOS via `HPWMI_COLOR_GET_QUERY`. The RGB data begins at **byte offset 25 (`COLOR_OFFSET`)**. Each zone occupies exactly 3 consecutive bytes (Red, Green, Blue). The function formats the corresponding 3 bytes as an uppercase hex string.
* **Writing (`zone_store`):** Parses the input hexadecimal string. It first pulls the active color table from the BIOS, updates the 3 bytes corresponding to the targeted zone (`tbl[25 + zone * 3]`), and then commits the entire updated table back using `HPWMI_COLOR_SET_QUERY`.

### B. Master Backlight Brightness (`brightness`)
* **Permissions:** Read/Write (RW).
* **Supported Values:**
  - `1`: Backlight fully ON (BIOS control byte set to `0xE4`).
  - `0`: Backlight fully OFF (BIOS control byte set to `0x64`).
* **Reading (`brightness_show`):** Queries the BIOS backlight state. Returns `1` if the state byte matches `0xE4`, otherwise returns `0`.
* **Writing (`brightness_store`):** Commits `0xE4` to the BIOS to activate lighting, or `0x64` to extinguish it.

### C. Windows Key Lock / Gaming Key (`win_lock`)
* **Permissions:** Read/Write (RW).
* **Purpose:** Toggles the keyboard's Windows Lock hardware feature to prevent accidental desktop context switching during active gameplay.
* **Supported Values:**
  - `1`: Windows key locked (BIOS byte set to `0x01`).
  - `0`: Windows key unlocked (BIOS byte set to `0x00`).

---

## 5. Platform Device Lifecycle

### A. Initialization (`hp_rgb_lighting_init`)
Upon loading the module (`insmod` or `modprobe`):
1. Verifies that the HP WMI BIOS interface is available on the system using `wmi_has_guid`. If not, returns `-ENODEV` (prevents initialization on non-HP hardware).
2. Registers a virtual platform device named `"hp-rgb-lighting"` (`platform_device_register_simple`).
3. Connects the sysfs attribute group (`hp_rgb_lighting_groups`) to the platform device's directory using `sysfs_create_groups`.

### B. Cleanup (`hp_rgb_lighting_exit`)
Upon unloading the module (`rmmod`):
1. Deletes the virtual sysfs files (`sysfs_remove_groups`).
2. Unregisters the platform device (`platform_device_unregister`), cleaning up kernel device tree nodes.

---

## 6. Build, Installation, and Usage Guide

### Sample `Makefile`
Save the following configuration as `Makefile` in the same directory as your source file:

```makefile
obj-m += hp-rgb-lighting.o

all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
```

### Steps to Compile and Load
Execute the following commands in your shell to build and register the driver:

```bash
# 1. Compile the driver
make

# 2. Insert the module into the running kernel
sudo insmod hp-rgb-lighting.ko

# 3. Confirm that the driver registered successfully
dmesg | grep hp-rgb-lighting
```

### Interactive Usage Examples

```bash
# Verify the generated sysfs files
ls -lh /sys/devices/platform/hp-rgb-lighting/

# Toggle the backlight on
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/brightness

# Change Zone 0 to Red
echo "FF0000" | sudo tee /sys/devices/platform/hp-rgb-lighting/zone0

# Change Zone 1 to Green
echo "00FF00" | sudo tee /sys/devices/platform/hp-rgb-lighting/zone1

# Enable Windows Lock
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/win_lock

# Read the current hex color of Zone 0
cat /sys/devices/platform/hp-rgb-lighting/zone0
```
