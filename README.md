# OPPO PCLM50 逆向实测记录：第三方 recovery / 自编内核加载任意 `.ko`

> **设备**：OPPO PCLM50（Reno3 元气版 / Reno3 Young 5G，项目号 `19125`）
> **平台**：Qualcomm lito / SM7250（骁龙 765G），arm64
> **系统**：ColorOS 11.1 / Android 11（`PCLM50_11_C.12`），内核 `4.19.113-perf+`
> **记录时间**：2026-11-11
> **状态**：**未达成最终目标**。恢复原厂、无变砖。本文档的价值在于把踩过的每个坑写成可复现的事实。

---

## 一句话结论

| 目标 | 结果 | 卡在哪 |
|---|---|---|
| 刷入第三方 recovery（TWRP） | ❌ 未达成 | OPPO 的 lk 校验 recovery 分区**尾部内嵌的 vbmeta**，与 `vbmeta` 分区无关；改 `vbmeta` 校验对它完全无效 |
| 自编 permissive 内核（加载任意 `.ko`） | ⚠️ 未产出 | 三道门已全部正确改好，代码编过 2831 个 `.o` 到链接阶段；**卡在逆向 OPPO 私有构建编排**，非代码问题 |
| 设备恢复原厂 | ✅ 完成 | `recovery` / `vbmeta` 回读 md5 与原厂逐字节一致 |
| 修复被误禁的系统模块 | ✅ 完成 | 见 `docs/03` |

**最重要的三条"别浪费时间"的结论：**

1. **不要试图通过修改 `vbmeta` 分区来让第三方 recovery 启动** —— 在这台设备上这条路走不通，原因见 `docs/01`。
2. **普通 `.ko` 在这台设备上永远无法 `insmod`** —— `CONFIG_MODULE_SIG_FORCE=y`，运行时无法关闭。要跑内核代码只有 **APatch KPM** 一条路，而它**本来就是通的**。
3. **折腾分区前先看 `/data/adb/boot-guard/count`** —— 连续 3 次启动失败会把**所有模块**静默禁用，症状看起来像"模块坏了"，日志里却找不到原因（见 `docs/03`）。

---

## 目录

| 文档 | 内容 |
|---|---|
| [`docs/01-lk-avb-recovery.md`](docs/01-lk-avb-recovery.md) | **核心发现**：lk 如何校验 recovery、`recoverybak` 回退分区、为什么关 AVB 无效 |
| [`docs/02-kernel-build-blockers.md`](docs/02-kernel-build-blockers.md) | 自编内核的 **12 个构建卡点**与逐个解法（最有复用价值） |
| [`docs/03-bootguard-module-disable.md`](docs/03-bootguard-module-disable.md) | 开机守卫静默禁用所有模块的机制与修复 |
| [`docs/04-device-facts.md`](docs/04-device-facts.md) | 设备实测事实清单：分区表、内核配置、OPPO 自愈机制 SHA1 |
| [`scripts/`](scripts/) | 全部自动化脚本：源码拉取、内核树准备、自动修复、测试矩阵 |
| [`logs/`](logs/) | 8 轮编译日志（已滤掉噪音） |
| [`evidence/`](evidence/) | 原厂 recovery 成功启动的 uboot 日志、内核配置、设备节点等原始证据 |

---

## 环境（本项目实测可用，无需联网下载工具链）

| 项 | 值 |
|---|---|
| 构建宿主 | Kali Linux Rolling 2026.3，4 核，15.5 GiB 内存 |
| 编译器 | AOSP `clang-r383902`（实为 clang 11.0.1）—— 可从 TWRP/AOSP 源码树 `prebuilts/clang/` 直接复用 |
| 交叉 binutils | `aarch64-linux-android-{as,ld.bfd,nm,objcopy,objdump,strip,ar,ranlib}`，**没有 GNU gcc 驱动**（`CC=clang` + binutils 即可） |
| 源码 | `android_kernel_oppo_sm7250` @ `oppo/sm7250_s_12.1_reno4_5g`（170 MB tarball）+ `android_kernel_modules_and_devicetree_oppo_sm7250`（45 MB），**tarball 方式比 git clone 快两个数量级** |

> 用 `codeload.github.com/.../tar.gz/refs/heads/<branch>` 下载比 `git clone` 划算得多：
> 树-only 约 170 MB，而带历史的 clone 是 2.1 GB。实测国内直连 45 KB/s，挂梯子后 5.9 MB/s。

---

## 我们做成了什么（可直接复用）

### 1. 完整查清 lk 拒绝第三方 recovery 的机制

不是"AVB 校验开着"这种笼统结论，而是精确到字段：

```
recovery 分区尾部 AVBf footer:
  original_image_size = 89,354,240
  vbmeta_offset       = 89,354,240
  vbmeta_size         = 2880      ← lk 在 recovery 启动时报的 androidboot.vbmeta.size=2880
```

而 Android 启动时报的是 `androidboot.vbmeta.size=18048`（那才是 `vbmeta` 分区的大小）。
**结论：lk 启动 recovery 时读的是 recovery 分区自己尾部内嵌的 vbmeta，压根不看 `vbmeta` 分区。**

### 2. 定位了 `recoverybak` 这个从未被提及的回退分区

`/dev/block/bootdevice/by-name/recoverybak` → `sde48`，100,663,296 B，
**是一份完整合法的 OPPO recovery 镜像**（自带 `AVB0` + `AVBf`），
SHA1 `2fa0c55da292cdedee7adb4539f52b6eafb1d0de`，自 2026-11-06 全盘备份以来**未被改动**。

自编 recovery 被 lk 拒绝后，设备实际启动的是**原厂 recovery**（用户现场确认），高度怀疑即此分区回退。

### 3. 把 OPPO 私有构建编排的 12 个卡点全部文档化

包括两个**最容易踩、且文档里绝对查不到**的坑：

- **`-DOPLUS_FEATURE_X` 宏 与 Makefile 里同名 make 变量是两套独立开关**，值还必须是 `yes` 而不是 `1`
- **`techpack/Kbuild` 用 `find -type d` 自动发现目录，软链目录不被匹配** → 显示驱动整个不编

详见 `docs/02`。

### 4. 一套可重跑的自动化脚本

- `scripts/fetch-sources.sh` —— 自动探测梯子/代理，tarball 拉取 + 断点续传 + 解包校验
- `scripts/prepare_kernel.sh` —— 幂等地施加三道门 + 目录组装 + CRLF 转换 + py2→py3 修复
- `scripts/fix_kernel_tree.py` —— 反复跑 defconfig，自动把 113 个缺失的 Kconfig 引用按目录结构挂接（含特例映射表）
- `scripts/fix_headers.py` —— 同类思路修头文件（**注意：本脚本曾两次误删内核树，见下方"我们踩的坑"**）
- `scripts/test_matrix.sh` / `scripts/decisive.sh` —— recovery 候选镜像自动测试与 lk 分区判定实验

### 5. 设备侧的实测事实清单

分区表与容量、内核编译配置、OPPO 自愈机制的 SHA1 比对面、显示栈真相（无 fbdev、无 VT）、APatch/KPM 运行状态 —— 见 `docs/04`。

---

## 我们没做成什么（诚实清单）

1. **没有产出可用的 `Image`**。最后一次失败是我自己的工具 bug（见下）。
2. **没有验证新内核能否开机**。版本跨度 4.19.157（ColorOS 12.1 源码）vs 4.19.113（设备），这层风险**一次都没被检验过**。
3. **没有实现"加载任意 `.ko`"**。
4. **第三方 recovery 一次都没启动成功**。5 个候选镜像（含 USB 初始化修复版、avbtool 正确签名版）全部被 lk 拒绝。

---

## 我们踩的坑（含我自己的破坏性错误，写给后人避雷）

### 自动化修复脚本两次删掉了内核树

`fix_headers.py` 早期的逻辑是"目标目录已存在但缺文件 → 删掉重建"。当缺失头文件的相对目录只有一层（例如 `linux/xxx.h`）时，`dst_dir` 就落到了真实目录 `include/linux`，于是：

- 第一次：`rmtree` 掉整个 `include/`（5303 个文件）
- 第二次：`rmtree` 掉 `include/linux/`（2604 个文件）

两次都靠原始 tarball 完整恢复。**教训：任何自动化脚本做"修复"时必须遵守三条铁律**——

1. **只创建、只复制，绝不 `rmtree` 真实目录**
2. 护栏必须按**词法路径**判断（`abspath`）而不是 `realpath`，否则合法的外链软链会被误判为越界
3. 危险操作前先 `os.path.lexists` + 显式判断是软链还是真实目录

修正后的实现见 `scripts/fix_headers.py`（已加硬护栏）。

### 另一个低级错误

批量注入 make 变量时，把**派生变量** `OPLUS_CONNECTIVITY_NATIVE_FEATURE_SET` 也一起传了。命令行变量会覆盖 Makefile 的 `:=` 赋值，于是 `$(foreach myfeature,$(OPLUS_CONNECTIVITY_NATIVE_FEATURE_SET), ... -D$(myfeature) ...)` 遍历的对象从空列表变成了 `1`，展开成 `-D1`：

```
<command line>:4:9: error: macro name must be an identifier
#define 1 1
```

**教训：注入 make 变量前必须区分"开关变量"和"派生/聚合变量"。**

---

## 下次接着干：确定的路线

### 路线 A（推荐）：换匹配版本的内核源码树

```bash
# 4.19.113 / Android 11，与设备同版本（Reno5 5G 也是 SM7250）
git clone --depth 1 -b reno5-r-g \
  https://github.com/oppo-source/kernel_msm-4.19.git
```

`docs/02` 里的 12 个卡点中，大部分是 **OPPO 构建编排缺失**导致的，与内核版本无关，可直接复用解法；
版本对齐后能消除"开机即崩"这层最大不确定性。

### 路线 B：继续用 12.1 树

按 `docs/02` 的清单逐条修完即可，全部是确定性问题、不需要再试探。建议顺序：

1. 修变量注入（只传开关、传 `yes`、排除派生变量）
2. 修 `techpack/Kbuild` 的 `find -type d` → `\( -type d -o -type l \)`
3. 取消 `drivers/gpu/drm/Makefile` 里 `msm/` 的注释（或反之，避免与 techpack 重复）
4. 打开 `CONFIG_SECTION_MISMATCH_WARN_ONLY=y`
5. 编 `Image` → 用 `mkbootimg` 按原厂 boot 头参数重打包（ramdisk/cmdline/dtb 全部沿用原厂，**只换 kernel 段**）
6. **用 APatch Manager 给新 boot.img 重新打补丁**（否则丢 root，KPM 全失效）
7. `fastboot flash boot`，起不来就 `fastboot flash boot boot_stock.img` 回滚（30 秒）

### 路线 C（如果只是要跑内核代码，强烈推荐）：别编内核

如果目标是在内核里 hook 而不是加载某个特定二进制 —— **改用 APatch KPM**。
本项目设备上 KPM 通路**一直是正常的**：

```
[rootstealth] hooks active: openat(56) faccessat(48) newfstatat(79) statx(291) readlinkat(78) inotify_add_watch(27)
KP AP KPM loading done: loaded=2 skipped=0 total=2
```

KPM 能做的事和 `.ko` 几乎一样（hook 系统调用、改内核数据结构、拦截文件访问），
而且**零编译、零刷机、零变砖风险**。

---

## ⚠️ 免责声明

本文档记录的是**在自己拥有的设备上**的实测过程。包含解锁 Bootloader、修改分区、反编译分析等内容。

- 所有分区写操作前都做了原始镜像备份并记录 md5，全程只动过 `recovery` / `vbmeta` / `misc` 三个分区
- 设备最终**完整恢复原厂状态**（回读 md5 与原厂逐字节一致）
- **照做可能导致设备变砖、数据丢失、保修失效。风险自负。**
- 文中涉及的第三方工具（APatch / KernelPatch / KPM）版权归各自作者

## 许可

文档与脚本以 MIT 许可发布。文中引用的内核源码版权归 OPPO / 高通 / Linux 内核社区所有。
