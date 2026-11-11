# 04 · 设备实测事实清单（OPPO PCLM50）

> 全部数据来自设备实测读取（`adb` + Magisk/APatch root + `/proc` + 全盘镜像备份），非查阅资料。
> 可直接作为同类 OPPO/高通设备的对照参考。

## 1. 身份

| 项 | 值 |
|---|---|
| 型号 | `ro.product.model` = `PCLM50` |
| 项目号 | `ro.product.sku` = `19125` |
| 设备代号 | `ro.product.device` = `OP4AB5` |
| 市场名 | Reno3 元气版 / Reno3 Young 5G（= OPPO K7 同 project 19125） |
| 平台 | Qualcomm **lito / SM7250**（骁龙 765G），arm64 |
| 系统 | ColorOS 11.1 / Android 11（SDK 30），`PCLM50_11_C.12` |
| 内核 | `4.19.113-perf+`，clang 10.0.7（= AOSP clang-r383902），2021-12-24，**非 GKI** |
| 安全补丁 | 2022-01 |

## 2. 分区表（关键项）

| 分区 | 块设备 | 大小 | 说明 |
|---|---|---|---|
| `boot` | `sde11` | 100,663,296 | APatch root 打在这里 |
| **`recovery`** | **`sde25`** | **100,663,296** | 有独立 recovery 分区（A-only，无 `_a/_b`） |
| **`recoverybak`** | **`sde48`** | **100,663,296** | **第二份合法 OPPO recovery（回退用？见 docs/01）** |
| `vbmeta` | `sde18` | 65,536 | |
| `dtbo` | `sde19` | 25,165,824 | |
| `misc` | `sda3` | — | BCB |
| `cache` | `sda6` | — | |
| `super` | `sda9` | 8 GiB | 14 个逻辑分区 |

```bash
# 读取方法
adb shell "su -c 'ls -l /dev/block/bootdevice/by-name/ | grep -iE \"boot|recovery|dtbo|vbmeta\"'"
adb shell "su -c 'blockdev --getsize64 /dev/block/bootdevice/by-name/recovery'"
```

## 3. Bootloader 与校验链

```
ro.boot.flash.locked      = 0            → 已解锁
ro.boot.verifiedbootstate = orange       → Android 启动时
androidboot.vbmeta.device_state = unlocked
androidboot.veritymode    = enforcing    → dm-verity 对 super 生效
androidboot.secboot       = enabled
```

**注意 `verifiedbootstate` 会随启动目标变化：**

| 启动目标 | verifiedbootstate | vbmeta.device_state | vbmeta.size |
|---|---|---|---|
| 原厂 recovery | `green` | `locked` | **2880** |
| Android（解锁后） | `orange` | `unlocked` | 18048 |
| 自制 recovery（历史成功案例） | `orange` | `unlocked` | 2880 |

**`vbmeta.size` 是判断"lk 用了哪个 vbmeta"的决定性字段**（详见 docs/01）。

## 4. 内核模块策略（决定了 `.ko` 能否加载）

```
CONFIG_MODULES=y
CONFIG_MODULES_USE_ELF_RELA=y
CONFIG_MODULE_UNLOAD=y
CONFIG_MODULE_SIG=y
CONFIG_MODULE_SIG_FORCE=y          ← 强制签名，运行时不可关
CONFIG_MODULE_SIG_ALL=y
CONFIG_MODULE_SIG_SHA512=y
CONFIG_MODULE_SIG_HASH="sha512"
CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"
CONFIG_MODVERSIONS=y               ← 符号 CRC 指纹比对
# CONFIG_MODULE_FORCE_LOAD is not set
CONFIG_MODVERSIONS=y
```

```bash
adb shell "cat /sys/module/module/parameters/sig_enforce"     # → Y
adb shell "cat /proc/sys/kernel/kptr_restrict"                # → 2（kallsyms 地址全 0）
```

`sig_enforce` 类型是 `bool_enable_only`：**只能 0→1**，`echo 0` 返回 EROFS；
启动参数 `module.sig_enforce=0` 同样无效。**运行时无法关闭。**

`/vendor/lib/modules/` 下有数百个厂商 `.ko`，全部用 OPPO 私钥签名。

## 5. 显示栈（决定了 recovery 能不能"看得见"）

```
CONFIG_DRM=y
CONFIG_DRM_MSM=y
CONFIG_DRM_MSM_DSI=y
# CONFIG_DRM_FBDEV_EMULATION is not set     ← 没有 fbdev 模拟
# CONFIG_VT is not set                       ← 连虚拟终端都没有
```

设备节点实测：

```
$ ls -l /dev/dri/
crw-rw-rw- 1 root graphics 226,   0  card0
crw-rw-rw- 1 root graphics 226, 128  renderD128

$ ls /dev/graphics/     → No such file or directory
$ ls /dev/fb*           → No such file or directory
```

**含义：**
- 依赖 fbdev（`/dev/graphics/fb0`）的 recovery 在这台机器上**必然黑屏**
- 只能走 **DRM/KMS** 路径（`/dev/dri/card0`）
- 但 DRM 路径是可用的 —— 原厂 recovery 的图形 UI 实测正常（`recovery_last_log_ok.txt` 里
  `oppo_mainmenu` / `lang_ui` / `power_ui` 全部正常执行）
- 内核 cmdline 里有 `video=vfb:640x400,bpp=32,memsize=3072000`，但 **`CONFIG_FB_VIRTUAL` 未启用**，
  这个参数实际是空的

## 6. OPPO 自愈机制

### `/vendor/bin/install-recovery.sh`（780 B）

```sh
if ! applypatch --check EMMC:/dev/block/bootdevice/by-name/recovery:100663296:10356e302b5b3c4e8a343e16eb46459effd5b391; then
  applypatch --patch /vendor/recovery-from-boot.p \
    --source EMMC:/dev/block/bootdevice/by-name/boot:100663296:1a32dd59f628d3fc6774cf652c1e8a8f3767bf56 \
    --target EMMC:/dev/block/bootdevice/by-name/recovery:100663296:10356e302b5b3c4e8a343e16eb46459effd5b391 && ...
```

| 分区 | 期望 SHA1 | 实测 SHA1（root 后） | 状态 |
|---|---|---|---|
| `boot` | `1a32dd59f628d3fc6774cf652c1e8a8f3767bf56` | `eea404d0c33978c238395ceb78135fb2f5808df3` | ❌ 不匹配 → 机制失效 |
| `recovery` | `10356e302b5b3c4e8a343e16eb46459effd5b391` | `10356e302b5b3c4e8a343e16eb46459effd5b391` | ✅ 匹配 → 不动作 |

配套文件：`/vendor/recovery-from-boot.p`（26,411,030 B，补丁包）

**结论：因为 `boot` 被 root 改过，这个自愈机制不会还原 recovery。**

### 相关属性

```
ro.boot.recovery.updated = true       # 由上面的脚本 setprop
ro.boot.recoveryreason   = 000
persist.sys.boot.reason.history = cold, …, recovery, recovery
```

### `init.svc.vendor_flash_recovery = stopped`

存在一个 `vendor_flash_recovery` 服务，但**在 `/vendor/etc/init/`、`/odm/etc/init/` 里都搜不到定义**
（可能内建于 vendor init 二进制）。状态为 `stopped`。

## 7. 原厂 recovery 镜像结构（完整）

`recovery_stock.img` = md5 `cdfceb5ffc7fc9cb788595a37a5d1f3d`，100,663,296 B

| 段 | 偏移 | 大小 | 备注 |
|---|---|---|---|
| boot header v2 | 0 | 1,660 | page=4096，`os_version=0x16000161`（11.0.0 / 2022-01） |
| kernel | 4,096 | 40,960,012 | **裸 arm64 Image**（magic `ARMd`，未压缩） |
| ramdisk | 40,968,192 | 24,638,063 | gzip，解压后 63,992,576 |
| recovery_dtbo | 65,609,728 | 15,213,348 | |
| dtb | 80,826,368 | 8,526,635 | 22 个 FDT 拼接，md5 `67e4aa2160f9395f1b588a5f1275bf1b` |
| **内嵌 vbmeta (AVB0)** | **89,354,240** | **2,880** | `algo=2` = SHA256_RSA4096, auth=576, aux=2048 |
| **AVBf footer** | **100,663,232** | 64 | `original_image_size=89,354,240` |

装载地址：`kernel 0x8000` / `ramdisk 0x1000000` / `tags 0x100` / `dtb_offset 0x1f00000`

cmdline（原厂，必须原样保留）：

```
console=ttyMSM0,115200,n8 earlycon=msm_geni_serial,0x888000 androidboot.hardware=qcom
androidboot.console=ttyMSM0 androidboot.memcg=1 lpm_levels.sleep_disabled=1
video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 service_locator.enable=1
androidboot.usbcontroller=a600000.dwc3 swiotlb=2048 cgroup.memory=nokmem,nosocket
loop.max_part=7 buildvariant=user
```

> ⚠️ 注意：`kpti=off` **不在原厂 recovery.img 的 cmdline 里**（那可能来自 boot.img），
> 但 lk 在 recovery 启动时**会**追加 `kpti=off`。以镜像实测为准，不要照抄二手文档。

`recoverybak`（sde48）内容不同：kernel 36,091,916 / ramdisk 27,178,377 / dtbo 5,221,914，
内嵌 vbmeta 在 73,191,424 处、大小 2,112，SHA1 `2fa0c55da292cdedee7adb4539f52b6eafb1d0de`。

## 8. root / KPM 运行状态

```
root 方案   : APatch (KernelPatch)，包名 me.bmax.apatch
              su 路径自定义为 /system/bin/yk
              SELinux 域复用 u:r:magisk:s0（易误判为 Magisk）
守护进程    : /data/adb/apd (3,714,528 B)
KPM 目录    : /data/adb/ap/kpm/{kpm-rootstealth,selinux_maf}
原始 boot   : /data/adb/ap/ori.img (100,663,296 B)
```

开机时的 KPM 加载日志（`dmesg | grep -i kpm`）：

```
[+] KP D load_module_path_event: /data/adb/ap/kpm/kpm-rootstealth/kpm-rootstealth.kpm
[+] KP D     name: kpm-rootstealth
[rootstealth] init event=post-fs-data args=none
[rootstealth] 23 default entries loaded
[rootstealth] hooks active: openat(56) faccessat(48) newfstatat(79) statx(291) readlinkat(78) inotify_add_watch(27)
[+] KP I load_module_ex: [kpm-rootstealth] succeed with [(null)]
KP load AP KPM: …/kpm-rootstealth.kpm, event: post-fs-data, rc: 0
[+] KP I load_module_ex: [selinux_MAF_fork] succeed with [(null)]
KP AP KPM loading done: loaded=2 skipped=0 total=2
```

## 9. 常用排查命令速查

```bash
D=<serial>

# 身份
adb -s $D shell 'getprop ro.product.device; getprop ro.product.sku; getprop ro.build.display.id'
adb -s $D shell 'getprop ro.boot.verifiedbootstate; getprop ro.boot.flash.locked'

# 分区 & 校验
adb -s $D shell "su -c 'sha1sum /dev/block/bootdevice/by-name/recovery'"
adb -s $D shell "su -c 'md5sum  /dev/block/bootdevice/by-name/vbmeta'"

# 内核
adb -s $D shell 'cat /proc/version'
adb -s $D shell "zcat /proc/config.gz | grep -E 'MODULE_SIG|MODVERSIONS|^CONFIG_DRM|CONFIG_FB|CONFIG_VT'"
adb -s $D shell 'cat /proc/cmdline'

# 模块 / root
adb -s $D shell "su -c 'id'"
adb -s $D shell "su -c 'lsmod; cat /proc/modules'"
adb -s $D shell "su -c 'dmesg | grep -iE \"KPM|module|vermagic|signature\"'"

# pstore（硬复位后仍留存的内核日志）
adb -s $D shell "su -c 'ls -la /sys/fs/pstore/'"
adb -s $D shell "su -c 'cat /sys/fs/pstore/console-ramoops-0'"

# OPPO 自愈 / 守卫
adb -s $D shell "su -c 'cat /vendor/bin/install-recovery.sh'"
adb -s $D shell "su -c 'tail -30 /data/adb/boot-guard/log'"

# ⚠️ /proc/last_kmsg 在 Android 11 内核上**已不存在**，别再用它取证
#    正确位置是 /sys/fs/pstore/console-ramoops-*
```

## 10. 踩过的操作坑（非技术，但浪费了大量时间）

1. **`/proc/last_kmsg` 不存在**（Android 11 内核早已移除）。用它取证会得到"未取到"，误判为"设备没日志"。
   正确的是 `/sys/fs/pstore/console-ramoops-*`。
2. **超时的 `fastboot` 进程会霸占 USB 接口**，导致后续所有 fastboot 命令挂死。
   而且 `pkill -f fastboot` 会把自己的 shell 也一起杀掉（命令行里含该词）。
   必须用 `pgrep -x fastboot` 或按 PID 清。
3. **Linux 侧 `authorized` 位复位 / unbind-bind 救不回来**卡死的 fastboot，只能物理断电。
4. **`u:r:magisk:s0` 不代表是 Magisk**（APatch 复用了这个域名）。
5. **`dd` 只写镜像长度会留旧尾部** —— 对带 AVB footer 的分区是危险的（见 docs/01）。
6. **recovery 模式的 adbd 是 `shell` 用户**，读不了块设备，也 `adb root` 不了
   （`adbd cannot run as root in production builds`）。取分区数据必须在 Android 侧用 `su`。
7. **"设备从 lsusb 消失"不等于启动失败** —— 自制 recovery 可能起来了但 USB gadget 没绑定
   （configfs 的 `write /sys/class/udc` 那一步缺失）。
