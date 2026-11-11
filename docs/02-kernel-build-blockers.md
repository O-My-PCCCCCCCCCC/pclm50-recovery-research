# 02 · 自编 permissive 内核：12 个构建卡点与解法

> 目标：编出一个内核，使**任意 aarch64 `.ko` 都能 `insmod`**。
> 本文档的价值：**这 12 个卡点是按实际踩到的顺序记录的**，手册类文档通常一个都不会提。
> 最后一个卡点（第 12）没修完，但成因已完全确定。

## 背景：为什么要自编内核

设备原厂内核的模块策略（实测自 `/proc/config.gz`）：

```
CONFIG_MODULES=y
CONFIG_MODULE_SIG=y
CONFIG_MODULE_SIG_FORCE=y          ← 元凶：未签名模块一律 EKEYREJECTED
CONFIG_MODULE_SIG_ALL=y
CONFIG_MODULE_SIG_SHA512=y
CONFIG_MODVERSIONS=y               ← 第二道门：符号 CRC 指纹
# CONFIG_MODULE_FORCE_LOAD is not set   ← 所以 insmod -f 也无效
CONFIG_MODULES_USE_ELF_RELA=y
```

`/sys/module/module/parameters/sig_enforce` 当前 `Y`，类型 `bool_enable_only`：**只能 0→1，运行时无法关闭**；
启动参数 `module.sig_enforce=0` 同样无效。

> **结论：普通 `.ko` 在这台设备上永远无法加载。**
> 要跑内核代码只有 APatch **KPM**（KernelPatch Module，不是内核模块，是内核补丁）一条路。
> 而 KPM 通路在设备上**一直是正常的**（`loaded=2 skipped=0 total=2`）。
> **所以在动手编内核之前，先确认你的目标真的必须是"真 LKM"而不是"在内核里干活"。**

## 三道门（这是唯一需要改的代码逻辑）

| 门 | 现象 | 改法 |
|---|---|---|
| ① 印章门 | `Loading of unsigned module is rejected` | defconfig：`CONFIG_MODULE_SIG_FORCE=y` → `=n` |
| ② 指纹门 | `disagrees about version of symbol module_layout` | defconfig：`CONFIG_MODVERSIONS=y` → `=n` |
| ③ 版本号门 | `version magic '...' should be '...'` | `kernel/module.c` 的 `check_modinfo()` 里短路 vermagic 比较 |

### 门 ① ② 的具体位置

`arch/arm64/configs/vendor/lito-perf_defconfig` 第 99–101 行：

```diff
-CONFIG_MODVERSIONS=y
+CONFIG_MODVERSIONS=n
 CONFIG_MODULE_SIG=y                      # 保留，只是不再强制
-CONFIG_MODULE_SIG_FORCE=y
+CONFIG_MODULE_SIG_FORCE=n
```

> 关掉 `MODVERSIONS` 后 `VERMAGIC_STRING` 里不再含 `modversions`，所以门 ③ 必须一起放，
> 否则连厂商自己的 `.ko` 都会因版本串不匹配被拒。

### 门 ③ 的实际代码（4.19.157 与手册给的写法不同！）

很多手册给的是老版本的 `strncmp` 写法。**这个树里用的是 `same_magic()`**：

```c
/* kernel/module.c : check_modinfo() */
	if (!modmagic) {
		err = try_to_force_load(mod, "bad vermagic");
		if (err)
			return err;
	} else if (!same_magic(modmagic, vermagic, info->index.vers)) {   // ← 改这行
		pr_err("%s: version magic '%s' should be '%s'\n", ...);
		return -ENOEXEC;
	}
```

改成：

```c
	/* PCLM50 permissive: vermagic check disabled */
	} else if (0 && !same_magic(modmagic, vermagic, info->index.vers)) {
```

保留 `pr_err` 分支便于观察（不执行）。改完 `.config` 里应确认：

```
# CONFIG_MODULE_SIG_FORCE is not set
# CONFIG_MODVERSIONS is not set
```

本项目最后一次编译时这两项**已确认生效**。

---

## 12 个构建卡点

### 卡点 1 · 拉源码：`git clone` 慢到不可用

- **现象**：`git clone --depth 1` 两小时只下了 4 MB（45 KB/s）
- **解法**：改用 `codeload.github.com/<owner>/<repo>/tar.gz/refs/heads/<branch>` 下载**树-only tarball**
  - 内核树 170 MB（带历史 2.1 GB）、驱动仓库 45 MB
  - 挂梯子后实测 **5.9 MB/s**，44 秒下完
- 脚本：`scripts/fetch-sources.sh`（自动探测 TUN / 本地代理端口、断点续传、解包校验）

### 卡点 2 · 113 个 Kconfig `source` 引用缺失

- **现象**：`make vendor/lito-perf_defconfig` 报
  ```
  block/Kconfig:251: can't open file "block/uxio_first/Kconfig"
  ```
  逐个修会修到崩溃 —— 全量审计共 **113 处**，全部是 OPPO 私有驱动。
- **本质**：OPPO 把内核拆成两个仓库 —— 主内核树 + `android_kernel_modules_and_devicetree_oppo_sm7250`，
  后者要按**目录结构**挂进前者的对应位置。
- **解法**：反复跑 defconfig，解析 `can't open file "<path>"`，按缺失路径的目录名去驱动仓库里找同名目录并建软链。
  - 按**目录深度从浅到深**处理：挂上 `drivers/soc/oplus/system` 后，其下 30 多个子路径自动全部解决
  - 必须带**特例映射表**（同名匹配失效时）：
    ```python
    "net/oplus_modules":  "vendor/oplus/kernel/network",          # 目录名叫 network
    "drivers/power/oplus": "vendor/oplus/kernel/charger",
    "fs/oext4":           "vendor/oplus/kernel_4.19/ext4",
    "fs/erofs":           "vendor/oplus/kernel_4.19/erofs",
    "fs/exfat":           "vendor/oplus/kernel_4.19/exfat",
    "drivers/scsi/oufs":  "vendor/oplus/kernel_4.19/ufs",
    "drivers/input/oplus_fp_drivers":     "vendor/oplus/secure/biometrics/fingerprints/bsp/drivers",
    "drivers/input/oplus_secure_drivers": "vendor/oplus/secure/common/bsp/drivers",
    ...
    ```
  - **"反向嵌套"特例**：`mm/healthinfo` 对应的是 `oplus_performance/healthinfo/mm`（不是 `healthinfo` 本身），
    `fs/proc/healthinfo` 对应 `oplus_performance/healthinfo/fs`。判据：目标目录名 == 候选的**父目录名**。
- 脚本：`scripts/fix_kernel_tree.py`（含完整 MANUAL 表，35 轮内收敛）

### 卡点 3 · 内核树必须位于 AOSP 布局（最容易卡住的一点）

- **现象**：`include/` 下 22 个软链全部悬空，例如
  ```
  include/linux/sched_assist -> ../../../../vendor/oplus/kernel/oplus_performance/sched_assist/
  ```
  解析结果是 `/mnt/工作区/vendor/...`（跑到了上层目录）
- **本质**：仓库**自带**这些组装软链，它们假设内核树真实位于 `<aosp>/kernel/msm-4.19/`，
  驱动在 `<aosp>/vendor/`。`../../../../` 从 `include/linux/` 往上正好 4 层到 `<aosp>`。
- **关键陷阱**：如果你把内核树放在 `<aosp>/kernel/msm-4.19` 是个**软链**，
  `../../..` 会按**物理路径**解析（OS 先解开软链再继续），多一层 → 全部解析到错误位置。
  **内核树必须是真实目录，不能是软链。**
- **正确做法**：
  ```bash
  mkdir -p <aosp>/kernel
  mv  <kernel-tree> <aosp>/kernel/msm-4.19       # 真实搬移
  ln -sfn <modules>/vendor <aosp>/vendor
  # 然后从 <aosp>/kernel/msm-4.19 里 make
  ```
- 修正后 **21/22 软链自动通**，只剩 1 个（`include/linux/cpu_jank_info.h`，仓库里本就不存在的悬空链，无人引用，无害）

### 卡点 4 · CRLF 换行让 kconfig 崩溃

- **现象**：
  ```
  drivers/soc/oplus/system/cmdline_parser/Kconfig:30:warning: ignoring unsupported character '
  '
  make[3]: *** [scripts/kconfig/Makefile:69: syncconfig] 错误 1
  ```
- **本质**：Windows 侧打包，部分文件是 CRLF。kconfig 不认 `\r`。
- **解法**：把内核树 + 驱动树里 `Kconfig*` / `Makefile*` / `*.mk/.c/.h/.rc/.sh/.dts*/.txt` 全部 CRLF→LF（本项目转换了 220 个文件）

### 卡点 5 · `scripts/gcc-wrapper.py` 是 Python 2

- **现象**：
  ```
  File ".../scripts/gcc-wrapper.py", line 34
      print "error, forbidden warning:", m.group(2)
  SyntaxError: Missing parentheses in call to 'print'
  ```
  连带 `init/Kconfig:17: syntax error` / `invalid option` —— 因为那一行要展开
  `$(shell,$(srctree)/scripts/gcc-version.sh -p $(CC) | ...)`，`$(CC)` 崩了，shell 返回垃圾。
- **解法**：把 `print x` 改成 `print(x)`（5 处）

### 卡点 6 · `Makefile:412` 强制套 wrapper，而 `REAL_CC` 指向不存在的编译器

- **现象**：
  ```
  ../scripts/gcc-version.sh: 30: printf: PATH: expected numeric value
  ../scripts/gcc-version.sh: 30: printf: set: expected numeric value
  ...
  init/Kconfig:17: syntax error
  ```
  那串 `PATH: expected numeric value` 实际来自 wrapper 自己的报错文本 "Is your PATH set correctly?"。
- **本质**：`Makefile:412` **无条件**覆盖 `CC`：
  ```make
  CC = $(PYTHON) $(srctree)/scripts/gcc-wrapper.py $(REAL_CC)
  ```
  而 `REAL_CC = $(CROSS_COMPILE)gcc`，AOSP 的 prebuilt 交叉工具链**只有 binutils、没有 gcc 驱动**，
  `aarch64-linux-android-gcc` 不存在 → wrapper `exec` 失败。
- **解法**：注释掉 412 行，用 `CC=clang` + GNU binutils（Android 内核的标准配置）：
  ```bash
  make O=out ARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- \
       CROSS_COMPILE=<prebuilts>/aarch64/aarch64-linux-android-4.9/bin/aarch64-linux-android- \
       CROSS_COMPILE_ARM32=<prebuilts>/arm/arm-linux-androideabi-4.9/bin/arm-linux-androideabi- \
       -j4 Image
  ```
- **附带发现**：`gcc-version.sh` 对 clang 其实工作正常（`sh scripts/gcc-version.sh -p clang` → `040201`）

### 卡点 7 · 头文件缺失（并且在这里踩了最大的坑）

- **现象**：`../include/linux/mutex.h:95: fatal error: 'linux/sched_assist/sched_assist_mutex.h' file not found`
- **解法**：与卡点 2 同思路，按缺失路径去驱动仓库找文件
- **⚠️ 血的教训**：本项目第一版自动修复脚本用"目标目录已存在但缺文件 → 删掉重建"的逻辑，
  当缺失头文件的相对目录只有一层（如 `linux/xxx.h`）时 `dst_dir` 落到真实目录 `include/linux`，
  结果 **两次 `rmtree` 删掉了整个 `include/`（5303 文件）和 `include/linux/`（2604 文件）**。
  修正后的铁律：
  1. **只创建、只复制，绝不 `rmtree` 真实目录**
  2. 护栏按**词法路径** `abspath` 判断，不能用 `realpath`（否则合法的外链软链被误判越界）
  3. 操作前 `os.path.lexists` + 显式区分软链 / 真实目录 / 断链

### 卡点 8 · `techpack/Kbuild` 的 `find` 不匹配软链目录

- **现象**：`msm_drm_register_client` / `msm_drm_unregister_client` undefined；`out/techpack/display/` 里 0 个 `.o`
- **本质**：`techpack/Kbuild` 用 `find` 自动发现子系统：
  ```make
  techpack-dirs := $(shell find $(srctree)/techpack -maxdepth 1 -mindepth 1 -type d -not -name ".*")
  ```
  **`-type d` 不匹配软链**，而 `techpack/display` 是我们从驱动仓库软链过来的 → 整个显示驱动没编。
- **解法**：改为 `\( -type d -o -type l \)`
- **或者**：直接把 `techpack/{display,camera,video}` 用**真实拷贝**而非软链

### 卡点 9 · `drivers/gpu/drm/Makefile` 里 `msm/` 被注释掉

```make
# drivers/gpu/drm/Makefile:91
#obj-$(CONFIG_DRM_MSM) += msm/
```

OPPO 把显示驱动整体挪去了 `techpack/display`，但 `techpack/Kbuild` 又没编它（卡点 8）
→ **两边都没编**，于是 `CONFIG_DRM_MSM=y` 却找不到任何 DRM 符号。
修好卡点 8 后**不要**再取消这行注释，否则会重复编译冲突。

### 卡点 10 · 两套开关不同步（**本次最本质的失败点**）

OPPO 的私有驱动有**两套独立的开关**，必须同时满足：

| 开关 | 形式 | 作用 |
|---|---|---|
| C 预处理器宏 | `-DOPLUS_FEATURE_X` | 决定**调用方**代码是否编进去 |
| Make 变量 | `ifneq ($(OPLUS_FEATURE_X),)` 或 `ifeq ($(OPLUS_FEATURE_X),yes)` | 决定**提供方**目录是否编进去 |

`OplusKernelEnvConfig.mk` 只负责给编译器加 `-D` 宏，**make 变量得由上层构建系统传**。
于是只给宏不给变量时：调用方编了、提供方没编 → 一堆 `undefined reference`：

```
undefined reference to `oplus_router_boost_handler'      (net/oplus_router_boost)
undefined reference to `msm_drm_register_client'         (techpack/display)
undefined reference to `create_signal_quality_proc'
undefined reference to `register_lcdinfo_notifier'
undefined reference to `ufsf_check_query' / `recordUniproErr' / ...
```

**两个必须知道的细节：**

1. **值的写法是 `yes`，不是 `1`**
   ```make
   ifeq ($(OPLUS_FEATURE_WIFI_MTUDETECT), yes)    ← 传 =1 这里全是假
   ```
   虽然 `ifneq ($(X),)` 用 `=1` 也行，但为了同时满足两种写法，**统一传 `yes`**。

2. **绝不能传"派生/聚合变量"** —— 本项目就栽在这：
   ```make
   # OplusKernelEnvConfig.mk:21
   OPLUS_CONNECTIVITY_NATIVE_FEATURE_SET :=        ← 本该空，由下面 += 填
   # :29
   OPLUS_CONNECTIVITY_NATIVE_FEATURE_SET += OPLUS_FEATURE_WIFI_MTUDETECT
   # :32
   $(foreach myfeature,$(OPLUS_CONNECTIVITY_NATIVE_FEATURE_SET), ... -D$(myfeature) ...)
   ```
   如果在命令行传 `OPLUS_CONNECTIVITY_NATIVE_FEATURE_SET=yes`，**命令行变量会覆盖 `:=` 赋值**，
   `foreach` 遍历的对象从"名字列表"变成了 `yes`，展开成 `-Dyes`：

   ```
   <command line>:4:9: error: macro name must be an identifier
   #define yes yes
   ```

   本项目实际传的是 `=1`，于是报 `#define 1 1`。**这就是最后一次编译失败的确切原因。**

### 卡点 11 · `modpost: Section mismatches detected` 是致命的

```
WARNING: modpost: Found 1 section mismatch(es).
FATAL: modpost: Section mismatches detected.
Set CONFIG_SECTION_MISMATCH_WARN_ONLY=y to allow them.
```

不是代码错误，是严格性开关。解法：

```bash
./scripts/config --file out/.config --enable SECTION_MISMATCH_WARN_ONLY
make O=out ARCH=arm64 ... olddefconfig
```

### 卡点 12 · 版本跨度（尚未被检验的风险）

源码树是 `oppo/sm7250_s_12.1_reno4_5g` → **4.19.157**，设备跑 **4.19.113**（ColorOS 11）。

因为这轮没走到"能开机验证"的阶段，**这层风险一次都没被检验**。
下一轮强烈建议改用**同版本**源码树：

```bash
git ls-remote --heads https://github.com/oppo-source/kernel_msm-4.19.git
# → reno5-r-c, reno5-r-g, find-x2-r
git clone --depth 1 -b reno5-r-g https://github.com/oppo-source/kernel_msm-4.19.git
```

Reno5 5G 也是 SM7250，`reno5-r-g` 是 Android 11（R）分支，**应为 4.19.113**。

---

## 进度证据

最后一轮编译（`logs/build8.log`）已达到：

- **2831 个 `.o` 全部编译成功**（含 `drivers/`、`fs/`、`net/`、`mm/`、`techpack/`）
- 一路推进到 **链接 `vmlinux.o` / `vmlinux`** 阶段
- 未定义符号在"开 make 变量"之后**全部消失**
- 唯一失败是我自己的变量注入 bug（卡点 10 的第 2 个细节）

**这说明代码本身完全能编，剩下的全是构建编排问题，且每一个都有确定解法。**

## 下一步清单（按顺序，全部是确定性问题）

1. 变量注入改为：只取**开关变量**、值传 `yes`、**排除派生/聚合变量**（如 `OPLUS_CONNECTIVITY_NATIVE_FEATURE_SET`）
2. `techpack/Kbuild` 的 `find` 加 `-o -type l`
3. `CONFIG_SECTION_MISMATCH_WARN_ONLY=y`
4. 编 `Image`
5. 用 `mkbootimg` 按**原厂 boot 头参数**重打包，ramdisk / cmdline / dtb **全部沿用原厂，只换 kernel 段**
6. **用 APatch Manager 给新 boot.img 重新打补丁**（否则丢 root，KPM 全失效）
7. `fastboot flash boot`；起不来就 `fastboot flash boot boot_stock.img`（30 秒回滚）

> 注意：这台设备**不适合用 `fastboot boot` 试机**（部分环境下 fastboot 驱动不全）。
> 本项目实测 **Linux 下 `fastboot` 完全可用，无需装驱动** —— 这比 Windows 省事得多。
> 但要注意：**超时的 `fastboot` 进程会霸占 USB 接口**，导致后续命令全部挂死；
> 清理时 `pkill -f fastboot` 会把自己的 shell 一起杀掉，必须用 `pgrep -x fastboot` 或按 PID 清。

## 验收方法

```bash
# 1) 确认新内核起来了
adb shell cat /proc/version
adb shell "zcat /proc/config.gz | grep -E 'MODULE_SIG_FORCE|MODVERSIONS'"
# 期望：MODULE_SIG_FORCE 不存在；MODVERSIONS 不存在

# 2) 负测试：拿厂商模块复制并破坏签名
adb shell "su -c 'cp /vendor/lib/modules/audio_apr.ko /data/local/tmp/t.ko; echo x >> /data/local/tmp/t.ko'"
adb shell "su -c 'insmod /data/local/tmp/t.ko'"
# 期望：签名已不校验；若失败，看是 vermagic 还是 ABI

# 3) 真正的目标
adb shell "su -c 'insmod /data/local/tmp/your.ko'"
adb shell cat /proc/modules
```

## 风险清单

1. **ABI 风险**：别人的预编译 `.ko` 与你的内核结构体布局不同时，`insmod` 成功但一调用就 **kernel panic**
2. **版本跨度**：4.19.157 跑在 ColorOS 11 上可能起不来或部分功能异常
3. **安全**：关掉签名强制 + 放开 vermagic 后，**任何拿到 root 的程序都能把任意代码塞进内核**。这是代价，不是漏洞
4. **OTA**：刷了自编内核后不要接受系统更新
__sess_status=$?; __t="__SESSION_EXIT_"; printf '\n%s%s:%s__\n' "$__t" "be46c1cc" "$__sess_status"

---

## 补记（2026-11-11 复查）：卡点 10 的真正根因与正解

上一轮把失败归因为"make 变量得由上层构建系统传"，方向对了一半，**根因找错了**。

### 根因

内核树 `Makefile` 只有这一行（12.1 树第 473 行 / 4.19.113 R 树第 456 行）：

```make
-include OplusKernelEnvConfig.mk
```

**从未 include `oplus_native_features.mk`** —— 而后者才是 OPPO 官方 CI 生成的那份开关清单
（222 行，形如 `OPLUS_FEATURE_SECURE_GUARD=yes` … `TARGET_PRODUCT=lito`）。
`OplusKernelEnvConfig.mk` 只负责把宏塞进 `KBUILD_CFLAGS`，**变量本身要由这份清单提供**。

于是 `OPLUS_FEATURE_*` 全部为空 → `ifeq ($(X),yes)` 判假 → 私有驱动目录不参与编译 →
调用方编了、提供方没编 → 一堆 `undefined reference`。

### 为什么"命令行传变量"是错的

make 的命令行变量**优先级高于 Makefile 内的 `:=`/`+=` 赋值**。把
`OPLUS_CONNECTIVITY_NATIVE_FEATURE_SET=yes` 传进去，`:=` 定的名字列表就被覆盖成单词 `yes`，
`foreach` 遍历它展开成 `-Dyes`；传 `=1` 则得到 `-D1` —— 这正是 `#define 1 1` 的来源。

### 正解

1. 把官方清单提取成 `scripts/oplus_vars.mk`（本仓库已附，225 行，来源
   `oppo-source/android_kernel_oppo_sm7250@oppo/sm7250_s_12.1_reno4_5g:oplus_native_features.mk`）
2. 拷到内核树根，在 `Makefile` 的 `-include OplusKernelEnvConfig.mk` **上一行**加：
   ```make
   -include oplus_vars.mk
   ```
   顺序很重要：必须先赋变量，`OplusKernelEnvConfig.mk` 才能用 `ifeq` 判断。
3. 不要从命令行传任何 `OPLUS_*` 变量。

### 其余三个卡点的一键补丁

| 卡点 | 修法 |
|---|---|
| 8 `techpack/Kbuild` 不匹配软链 | `find ... -type d` 改成 `\( -type d -o -type l \)` |
| 6 `gcc-wrapper` 强制 | 注释 `Makefile` 里 `CC = $(PYTHON) $(srctree)/scripts/gcc-wrapper.py $(REAL_CC)` |
| 11 section mismatch | `./scripts/config --file out/.config --enable SECTION_MISMATCH_WARN_ONLY` |

### 附带结论：不要为对齐版本换 R 树

`oppo-source/kernel_msm-4.19` 的 `reno5-r-g`/`reno5-r-c` 实测为 `4.19.113`（与设备一致），
但**组织内没有 sm7250 的 R 分支驱动/设备树仓库**（`19125` 即 PCLM50 的设备树只在 S 分支）。
换过去等于把卡点 2 的 113 处 Kconfig 引用重走一遍。先把这棵已编通 2831 个 `.o` 的树收尾。
