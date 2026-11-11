# 01 · 为什么第三方 recovery 起不来：lk 的 recovery 校验机制

> 本文是本项目最核心的发现。它推翻了"改 `vbmeta` 关闭 AVB 校验就能启动自制 recovery"这个在中文刷机圈广为流传的假设 —— **至少在这台 OPPO 设备上不成立。**

## 现象

刷入自制 recovery 后，进入 recovery 时屏幕显示 OPPO 引导层（lk）的兜底页：

```
系统文件被破坏，无法开机。请安装正确的系统软件或联系售后处理。
The current image(boot/recovery) have been destroyed and can not boot.
```

同时**系统可以正常启动**（只有 recovery 分区非原厂）。

注意：这页**不是** Android recovery 报的，也**不是变砖**。`boot` / `super` / `vbmeta` 逻辑上都完好。

## 分步验证

### 第 1 步：排除 OPPO 的恢复机制 `install-recovery.sh`

`/vendor/bin/install-recovery.sh`（780 字节，随系统出厂）内容：

```sh
#!/vendor/bin/sh
if ! applypatch --check EMMC:/dev/block/bootdevice/by-name/recovery:100663296:10356e302b5b3c4e8a343e16eb46459effd5b391; then
  applypatch \
    --patch /vendor/recovery-from-boot.p \
    --source EMMC:/dev/block/bootdevice/by-name/boot:100663296:1a32dd59f628d3fc6774cf652c1e8a8f3767bf56 \
    --target EMMC:/dev/block/bootdevice/by-name/recovery:100663296:10356e302b5b3c4e8a343e16eb46459effd5b391 && ...
```

实测比对：

| 分区 | 脚本期望 SHA1 | 设备实际 SHA1 | 结论 |
|---|---|---|---|
| `boot` | `1a32dd59…` | `eea404d0…` | ❌ 不匹配 → `applypatch` 无法还原 recovery |
| `recovery` | `10356e30…` | `10356e30…` | ✅ 匹配 → 检查通过，不动作 |

因为 `boot` 被 root 方案（APatch）修改过，这个自愈机制**永久失效**。
**所以它不是"recovery 被偷偷换回原厂"的元凶** —— 这一条可以彻底排除。

### 第 2 步：发现 recovery 分区尾部有内嵌 vbmeta

`recovery_stock.img`（100,663,296 B）最后 64 字节是标准 AVB footer，按大端解析：

```
magic               = "AVBf"
version             = 1.0
original_image_size = 89,354,240   (0x05537000)
vbmeta_offset       = 89,354,240
vbmeta_size         = 2,880
```

在偏移 `89,354,240` 处确实是一段合法的 `AVB0` vbmeta（`algo=2` = SHA256_RSA4096，`auth_block=576`，`aux_block=2048`）。

内部结构：

```
[0        .. 89,354,240)  真实的 recovery 镜像（header + kernel + ramdisk + recovery_dtbo + dtb，page 对齐）
[89,354,240..89,357,120)  2,880 字节的内嵌 vbmeta (AVB0)
              ...填充...
[100,663,232..100,663,296) AVBf footer，指向上面的 vbmeta
```

### 第 3 步（决定性）：lk 到底读哪个 vbmeta

从 pstore 的 `device-info-ramoops-0` 里取到 **recovery 启动时** lk 传给内核的 cmdline：

```
androidboot.mode=recovery
androidboot.verifiedbootstate=orange
androidboot.vbmeta.device_state=unlocked
androidboot.vbmeta.size=2880              ← 注意
androidboot.vbmeta.digest=077d3889...832b??7b
```

而 **Android 正常启动时**同一字段是：

```
androidboot.vbmeta.size=18048             ← vbmeta 分区的实际大小
androidboot.vbmeta.digest=196f4ccf...d66d
```

**`2880` 正是 recovery 分区尾部内嵌 vbmeta 的大小，`18048` 才是 `vbmeta` 分区的。**
且该 digest 与内嵌 vbmeta 的 SHA256 前 60 位完全吻合（ramoops 那段文本本身有字符损坏，如 `vbmeda`/`sixe`，故末几位有差异）。

> **结论：lk 启动 recovery 时，用的是 recovery 分区自己尾部内嵌的 vbmeta；`vbmeta` 分区只用于 Android 启动链。**

这解释了一个长期困惑：**为什么把 `vbmeta` 分区 flags 改成 0x03（关闭 verity + verification）对 recovery 启动毫无作用。**

### 第 4 步：解释"历史上自制 recovery 曾经能启动"的矛盾

项目早期有一个实验镜像（`expA`，原厂 ramdisk + 把 `/system/bin/recovery` 换成脚本）**成功启动过**，`/cache/pclm50-expA.txt` 是证据：

```
脚本被 init 成功拉起   mode=recovery   hardware=qcom   bootdevice=1d84000.ufshc
/dev/dri/card0 存在   /dev/graphics/ 不存在
```

原因现在清楚了 —— **尺寸**：

| 镜像 | 大小 | 是否越过 89,354,240 | 结果 |
|---|---|---|---|
| `expA` | 88,346,624 | ❌ 未越过 | ✅ 启动成功 |
| `expA2`（同样思路） | 88,346,624 | ❌ | 曾成功 |
| `expE3` | 92,524,544 | ✅ **越过** | ❌ 被拒 |
| `expE4` | 92,532,736 | ✅ **越过** | ❌ 被拒 |

`expA` 用 `dd` 只写了前 88 MB，**根本没碰到 89,354,240 处的内嵌 vbmeta**，所以 lk 能正常解析结构；
hash 虽然不匹配，但 `device_state=unlocked`，lk 容忍并以 `verifiedbootstate=orange` 启动。

后来的 E3/E4 尺寸越过了 89,354,240，**把那 2,880 字节的 vbmeta 覆盖成了普通数据**。实测佐证：

```
偏移 89,354,240 处的内容：原厂 = "AVB0"   →   被覆盖后 = "/soc/qcom,gdsc@..."
```

footer 仍然指向那里（因为它不懂我们改了什么），于是 lk 读到的是一段非法 vbmeta → 判"镜像已损坏"。
**从此任何镜像（哪怕再写回小的）都过不去**，因为那块已经被写坏且无人修复。

## 关键结论汇总

1. **lk 读 recovery 分区尾部内嵌的 vbmeta，不看 `vbmeta` 分区** → 改 `vbmeta` flags 无效
2. 自制 recovery 要么**自带合法的 AVB footer + 内嵌 vbmeta**（`avbtool add_hash_footer`），要么**必须小于 89,354,240 B 且保证该处内容有效**
3. **`dd` 只写镜像长度是危险操作** —— 分区尾部残留的旧 AVB 元数据可能指向已被覆盖的区域。写之前先想清楚分区尾部布局
4. 写满整分区（`truncate -s 100663296` 补零）会把内嵌 vbmeta 清零，**同样导致被拒**

## 未解之谜：`recoverybak`

发现了一个从未被提及的分区：

```
/dev/block/bootdevice/by-name/recoverybak -> /dev/block/sde48    100,663,296 B
```

它是一份**完整合法的 OPPO recovery 镜像**（`ANDROID!` 头、自带 `AVB0` + `AVBf`，
kernel 36,091,916 B / ramdisk 27,178,377 / recovery_dtbo 5,221,914，与 `recovery` 分区内容完全不同）。
SHA1 `2fa0c55da292cdedee7adb4539f52b6eafb1d0de`，与 2026-11-06 全盘备份**逐字节一致，从未被改动**。

**用户现场确认：5 个自制候选镜像全部被 lk 拒绝后，设备实际启动的是原厂 recovery。**
高度怀疑 lk 在 `recovery` 校验失败时**回退启动了 `recoverybak`**。

这一点没有直接证据闭环（`fastboot` 里读不到 `recoverybak` 的使用痕迹），
**留给后来者验证**。验证思路：

1. 只在 `recoverybak` 里放一个带唯一标记的镜像，`recovery` 保持原厂 → 看启动的是哪个
2. 或者在 `recovery` 放非法镜像的同时把 `recoverybak` 也清零 → 看是否变成兜底页

若此假设成立，则"把 TWRP 刷进 `recoverybak`"可能是一条完全不同的可行路径 —— 值得一试。

## 附：五个候选镜像的测试结果

自动测试矩阵（`scripts/test_matrix.sh`）对 5 个候选逐个刷入、进 recovery、观测 70 秒 USB/adb 轨迹：

| 候选 | 做法 | 结果 |
|---|---|---|
| `C1` | 17:26 TWRP 产物，只写镜像区，留分区原有原厂尾部（≈ expA 条件） | 25s → fastboot |
| `C2` | 产物 + 零填充 + 原厂 AVB 尾块 | 24s → fastboot |
| `C3` | 产物 + `avbtool add_hash_footer`（testkey RSA4096） | 27s → fastboot |
| `C4` | **USB 初始化修复版** + 原厂 AVB 尾块 | 27s → fastboot |
| `C5` | USB 初始化修复版 + `avbtool` 签名 | 27s → fastboot |

**5 个结果完全一致**，且原厂镜像每次都能正常恢复。这说明 lk 的拒绝与本项目写入的内容无关
（C1/C2 具备完整的原厂 AVB 元数据仍被拒），指向 `recoverybak` 回退假设。

> 另注：C4/C5 修复了产物里被删掉的 `on property:sys.usb.ffs.ready=1` 段
> （那是本机 configfs 绑定 UDC、拉起 adb 的唯一动作）。原厂 recovery 启动时 `lsusb` 出现 `22d9:2769`，
> 自定义镜像启动后设备从 `lsusb` 整机消失 —— **"设备不枚举"不能当作"没启动成功"的证据**。
