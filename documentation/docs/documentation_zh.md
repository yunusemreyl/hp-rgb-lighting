# HP RGB 背光驱动程序 (hp-rgb-lighting) 详细技术文档

本文件旨在详细介绍用于控制 惠普 暗影精灵 (HP Omen) 和 光影精灵 (HP Victus) 笔记本电脑背光硬件的 `hp-rgb-lighting.c` Linux 内核模块的内部架构、数据结构、核心函数和使用说明。

---

## 1. 概述与架构

`hp-rgb-lighting` 模块是一个轻量级的辅助驱动程序，专为 HP Omen/Victus 笔记本电脑的键盘 RGB 背光控制而设计。

核心架构设计决策：
* **协同共存 (Coexistence by Design)：** 该驱动程序与 Linux 内核中默认的 `hp-wmi` 驱动程序（负责风扇控制、快捷键、电源配置文件和无线开关等）并存工作。为了避免冲突，本驱动程序**没有**声明任何独立的 WMI 别名 (`MODULE_ALIAS("wmi:...")`)。相反，它通过共享的 BIOS GUID 动态地调用必要的 WMI 方法，以实现无冲突的共存。
* **Sysfs 用户空间接口：** 驱动程序在 `/sys/devices/platform/hp-rgb-lighting/` 下创建虚拟文件系统接口，允许用户空间应用程序或自定义控制脚本读取或写入键盘背光的状态与色彩。
* **并发与线程安全：** 所有的 WMI 方法求值和操作都通过互斥锁（`hp_wmi_query_mutex` 和 `rgb_mutex`）进行保护，防止对底层 ACPI 执行环境进行多线程并发写入冲突。

---

## 2. 常量、枚举和数据结构

以下是该驱动程序中核心常量、命令代码和数据结构的详细解释：

### A. WMI GUID
```c
#define HPWMI_BIOS_GUID "5FB7F034-2C63-45E9-BE91-3D44E2C707E4"
```
用于调用 HP BIOS 的 WMI 专有接口的唯一 GUID。它是发送请求至 ACPI 固件的核心路由通道。

### B. `enum hp_wmi_command` (WMI 主命令代码)
指定与 HP BIOS 通信的基本操作类型：
* **`HPWMI_READ` (`0x01`)：** 读命令，用于从 BIOS 中读取状态数据（例如读取 Windows 键锁定状态）。
* **`HPWMI_WRITE` (`0x02`)：** 写命令，用于修改 BIOS 中的变量与配置。
* **`HPWMI_BACKLIGHT` (`0x20009`)：** 背光命令分类，专门用于控制键盘色彩与模式的底层读写。
* **`HPWMI_GAMING_KEY` (`0x2000B`)：** 游戏键控制命令，专门用于配置 Windows 键屏蔽（Win Lock）。

### C. `enum hp_wmi_backlight_commandtype` (背光子命令代码)
在 `HPWMI_BACKLIGHT` 主命令下，指定更具体的背光控制操作：
* **`HPWMI_COLOR_GET_QUERY` (`0x02`)：** 用于从 BIOS 读取当前的键盘色彩映射表（Color Map）。
* **`HPWMI_COLOR_SET_QUERY` (`0x03`)：** 用于将修改后的键盘色彩映射表写入 BIOS，应用新的颜色。
* **`HPWMI_BRIGHTNESS_GET_QUERY` (`0x04`)：** 获取键盘背光的全局开关状态。
* **`HPWMI_BRIGHTNESS_SET_QUERY` (`0x05`)：** 设置键盘背光的全局开关状态（开启/关闭）。

### D. BIOS 通信数据结构
发送至 ACPI BIOS 接口和接收自该接口的内存数据结构布局：

```c
struct bios_args {
  u32 signature;      // 安全验证签名，必须为 0x55434553（即 ASCII 字符 "SECU"）
  u32 command;        // WMI 主命令类型 (enum hp_wmi_command)
  u32 commandtype;    // 对应的子命令类型 (enum hp_wmi_backlight_commandtype)
  u32 datasize;       // 实际拷贝到 data[] 数组中的输入负载字节大小
  u8 data[];          // 可变长度的输入负载数据缓冲区
};
```

```c
struct bios_return {
  u32 sigpass;        // BIOS 返回的安全验证签名状态
  u32 return_code;    // 执行结果代码：0 表示成功，非零值代表 BIOS 发生的硬件错误代码
};
```

---

## 3. 核心辅助函数

### `encode_outsize_for_pvsz`
```c
static inline int encode_outsize_for_pvsz(int outsize)
```
* **功能：** 根据 BIOS 期望的输出字节大小 (`outsize`)，映射为最合适的 ACPI 方法 ID (Method ID)。
* **逻辑：** 惠普 BIOS 通过调用不同的虚拟方法 ID（方法 ID 1 至 5）来分配响应的内存大小。
* **返回值规则：**
  - 如果 `outsize > 4096`，则被判定为非法输入，返回 `-EINVAL`。
  - 大于 `1024` 返回 `5`，大于 `128` 返回 `4`，大于 `4` 返回 `3`，大于 `0` 返回 `2`，等于 `0` 返回 `1`。

### `hp_wmi_perform_query`
```c
static int hp_wmi_perform_query(int query, enum hp_wmi_command command, void *buffer, int insize, int outsize)
```
整个驱动程序与 BIOS 通信的核心逻辑处理中心：
1. 通过调用 `encode_outsize_for_pvsz` 确定所需的 ACPI 方法 ID (`mid`)。
2. 使用 `kzalloc` 动态分配包含输入负载大小的 `struct bios_args` 结构（同时确保最小分配填充空间为 128 字节）。
3. 填充验证签名 `"SECU"`，主命令，子命令，复制输入载荷数据。
4. 加锁 `hp_wmi_query_mutex` 以确保 BIOS 请求的互斥性。
5. 调用 `wmi_evaluate_method` 方法将数据包发送至 ACPI 固件并等待反馈。
6. 验证返回的 ACPI 对象类型是否为 `ACPI_TYPE_BUFFER`，并进行内存边界与指针的完整性检验。
7. 解析 `struct bios_return`，确认是否存在 BIOS 层级的错误代码。
8. 成功后，将返回的响应有效负载通过 `memcpy` 拷贝回传入的 `buffer` 指针中，并释放所有申请的内核内存。

---

## 4. Sysfs 用户空间 API 接口说明

驱动程序成功加载后，将在系统平台树下创建 `/sys/devices/platform/hp-rgb-lighting/` 目录。每次读写 sysfs 属性文件时，均使用互斥锁 `rgb_mutex` 以防止并发竞态引起的死锁或数据撕裂。

### A. 键盘 RGB 分区 (`zone0` 至 `zone7`)
最多支持控制键盘的 **8 个独立 RGB 背光分区**。
* **访问权限：** 可读、可写 (`0644`)。
* **色彩格式：** 6 位大写十六进制字符串（24-bit 颜色格式），如 `"FF0000"` 代表红色，`"00FF00"` 代表绿色。
* **读取色彩 (`zone_show`)：** 通过发送 `HPWMI_COLOR_GET_QUERY` 从 BIOS 加载 128 字节 (`COLOR_TABLE_SIZE`) 的色彩映射表。RGB 原始色彩数据从表的 **第 25 个字节偏移量 (`COLOR_OFFSET`)** 开始存储。每个分区占用 3 个字节（按顺序分别代表红、绿、蓝）。该函数读取相应分区的 3 字节，将其格式化为十六进制大写字符串输出。
* **写入色彩 (`zone_store`)：** 解析传入的十六进制字符串。首先读取当前 BIOS 的 128 字节色彩映射表，将对应的分区 3 字节数值修改为新的 RGB 分量（`tbl[25 + zone * 3 + 0/1/2]`），接着通过 `HPWMI_COLOR_SET_QUERY` 将整张表写回 BIOS 以立即刷新背光。

### B. 主背光全局亮度开关 (`brightness`)
* **访问权限：** 可读、可写。
* **支持值范围：**
  - `1`：键盘背光全面开启（在 BIOS 层级发送控制字 `0xE4`）。
  - `0`：键盘背光全面关闭（在 BIOS 层级发送控制字 `0x64`）。
* **读取状态 (`brightness_show`)：** 查询 BIOS，如果返回的状态控制字为 `0xE4` 则输出 `1`，否则输出 `0`。
* **写入状态 (`brightness_store`)：** 写入 `1` 则使 BIOS 执行 `0xE4`（点亮键盘），写入 `0` 则执行 `0x64`（熄灭键盘）。

### C. Win 键屏蔽锁 / 游戏控制键 (`win_lock`)
* **访问权限：** 可读、可写。
* **功能作用：** 打开或关闭 Windows 键锁定开关，防止在激烈的游戏对局中意外按下 Windows 键跳出游戏。
* **支持值范围：**
  - `1`：锁定 Windows 键（向 BIOS 发送控制字 `0x01`）。
  - `0`：解锁 Windows 键（向 BIOS 发送控制字 `0x00`）。

---

## 5. 平台设备生命周期管理

### A. 驱动初始化 (`hp_rgb_lighting_init`)
当内核模块加载时（通过 `insmod` 或 `modprobe`）：
1. 校验当前主机系统上是否存在专用的 HP WMI BIOS GUID。如果不存在，则返回 `-ENODEV` 退出（从而有效避免在非惠普设备上加载该驱动）。
2. 注册一个名称为 `"hp-rgb-lighting"` 的虚拟平台设备 (`platform_device_register_simple`)。
3. 调用 `sysfs_create_groups` 为新创建的平台设备生成关联的属性文件接口 (`zone0-7`, `brightness`, `win_lock`)。

### B. 驱动卸载销毁 (`hp_rgb_lighting_exit`)
当移除内核模块时（通过 `rmmod`）：
1. 从平台设备上移除所有的 sysfs 属性组文件 (`sysfs_remove_groups`)。
2. 撤销注册的虚拟平台设备 (`platform_device_unregister`)，将内核相关的内存和节点彻底释放。

---

## 6. 构建、编译、安装和测试指南

### `Makefile` 配置模板
在代码所在文件夹下创建 `Makefile` 并复制以下内容：

```makefile
obj-m += hp-rgb-lighting.o

all:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) modules

clean:
	make -C /lib/modules/$(shell uname -r)/build M=$(PWD) clean
```

### 模块编译和加载指令
在终端执行以下命令进行编译与模块注册：

```bash
# 1. 编译生成内核驱动模块 (.ko)
make

# 2. 将驱动模块加载至 Linux 内核
sudo insmod hp-rgb-lighting.ko

# 3. 检查系统日志 (dmesg) 确认模块是否注册并加载成功
dmesg | grep hp-rgb-lighting
```

### 常用测试与交互实例

```bash
# 检查在 sysfs 下生成的设备属性文件
ls -lh /sys/devices/platform/hp-rgb-lighting/

# 开启全局键盘背光
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/brightness

# 将键盘第 0 区设为纯红色
echo "FF0000" | sudo tee /sys/devices/platform/hp-rgb-lighting/zone0

# 将键盘第 1 区设为纯绿色
echo "00FF00" | sudo tee /sys/devices/platform/hp-rgb-lighting/zone1

# 屏蔽 Win 键 (开启游戏锁)
echo 1 | sudo tee /sys/devices/platform/hp-rgb-lighting/win_lock

# 查看当前键盘第 0 区的 RGB 颜色值
cat /sys/devices/platform/hp-rgb-lighting/zone0
```
