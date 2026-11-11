# 03 · 开机守卫静默禁用所有模块：一个极难排查的"隐形故障"

> 这是一个**真实发生、且症状极具误导性**的故障。
> 用户主诉是"内核模块跑不起来了"，实际原因是某个保护脚本把所有模块静默禁用了。

## 症状

用户反馈："APatch 的 KPM / Zygisk 相关功能好像坏了"。
排查时表面现象是：

- APatch 正常（`apd` 进程在跑）
- KPM 正常加载
- 但依赖 Zygisk / Xposed 的功能全部失效

没有任何报错、没有任何日志提示"模块被禁用"。

## 根因：`/data/adb/post-fs-data.d/05-bootguard.sh`

```sh
#!/system/bin/sh
# 开机失败守卫：连续 3 次没正常启动 → 自动禁用所有模块
G=/data/adb/boot-guard
mkdir -p $G 2>/dev/null
C=$(cat $G/count 2>/dev/null || echo 0)
C=$((C + 1))
echo $C > $G/count
echo "$(date "+%F %T") 开机尝试 #$C" >> $G/log

if [ $C -ge 3 ]; then
  N=0
  for m in /data/adb/modules/*/; do
    [ -f "$m/module.prop" ] || continue
    touch "$m/disable" 2>/dev/null && N=$((N+1))
  done
  # 同时禁掉 post-fs-data.d 里的第三方启动器（保留自己和守卫）
  for f in /data/adb/post-fs-data.d/*.sh; do
    b=$(basename $f)
    case "$b" in 05-bootguard.sh) continue;; esac
    mv "$f" "$f.disabled" 2>/dev/null
  done
  echo "$(date "+%F %T" ) !!! 连续 3 次启动失败，已禁用 $N 个模块并停用开机启动器" >> $G/log
fi
exit 0
```

配套的 `/data/adb/boot-completed.d/99-bootguard-reset.sh` 在**系统正常启动完成**后把计数清零：

```sh
G=/data/adb/boot-guard
echo 0 > $G/count
echo "$(date "+%F %T") ✅ 启动成功，计数清零" >> $G/log
```

### 机制总结

| 事件 | 计数 | 后果 |
|---|---|---|
| 每次开机到 `post-fs-data` | +1 | — |
| 系统正常启动完成 | 归 0 | — |
| **连续 3 次没走到 `boot-completed`** | 达到 3 | **`touch` 所有模块的 `disable`，并把 `post-fs-data.d/*.sh` 改名成 `.disabled`** |

**设计意图是好的**（防止坏模块导致无限 bootloop），但副作用是：

1. **全量禁用**，不区分"哪个模块坏了"
2. **完全静默** —— 唯一痕迹在 `/data/adb/boot-guard/log`，而那个目录平时没人会看
3. 被禁用的模块在管理器界面上只显示"已禁用"，看起来像用户自己关的

## 本次事故的触发链

```
反复刷写第三方 recovery（40+ 次重启）
  → 大量启动未完成（落在 fastboot 或 recovery）
  → boot-guard 计数反复累积到 3
  → 3 个模块被静默禁用：
      zygisksu       (Zygisk Next 1.5.2, LSPosed Developers)
      zygisk_vector  (Vector v2.2, Jingming — Xposed 兼容 hook 框架)
      fanggeji       (防格机保护 v1.1)
  → Zygisk 层整体失效 → 所有依赖 Zygisk/Xposed 的功能失效
  → 用户感知："内核模块坏了"
```

关键佐证 —— `/data/adb/.mod-autofix.log` 里记录的服务启动时间戳（每次开机都会重启一次）：

```
2026-11-11 17:55:34 … 18:00:17 … 18:12:55 … 19:01:14 … 20:21:34 … 20:34:11
```

一个晚上 **40 次左右**的开机记录，正是反复刷 recovery 的产物。

## 排查方法

```bash
# 1) 守卫日志：直接看它有没有触发
adb shell "su -c 'tail -30 /data/adb/boot-guard/log'"
# 期望看到 "✅ 启动成功，计数清零"；若看到 "!!! 连续 3 次启动失败" 就是它干的

# 2) 模块真实状态
adb shell "su -c 'for d in /data/adb/modules/*/; do echo -n \"\$(basename \$d): \"; [ -f \$d/disable ] && echo DISABLED || echo ok; done'"

# 3) 被停用的启动器
adb shell "ls -la /data/adb/post-fs-data.d/"
# 出现 *.sh.disabled 就是被守卫改名的

# 4) 当前计数
adb shell "cat /data/adb/boot-guard/count"
```

## 修复

```bash
# 0) 先备份现场
adb shell "su -c 'mkdir -p /data/local/tmp/state_backup; for m in /data/adb/modules/*/; do [ -f \$m/disable ] && basename \$m >> /data/local/tmp/state_backup/was_disabled.txt; done'"

# 1) 计数清零（避免立刻又触发）
adb shell "su -c 'echo 0 > /data/adb/boot-guard/count'"

# 2) 恢复模块
adb shell "su -c 'rm -f /data/adb/modules/zygisksu/disable'"
adb shell "su -c 'rm -f /data/adb/modules/zygisk_vector/disable'"
adb shell "su -c 'rm -f /data/adb/modules/fanggeji/disable'"

# 3) 恢复被停用的启动器
adb shell "su -c 'for f in /data/adb/post-fs-data.d/*.disabled; do [ -e \"\$f\" ] && mv \"\$f\" \"\${f%.disabled}\"; done'"

# 4) 重启验证
adb reboot
```

## 修复后的实测验证（本项目已确认全部通过）

| 项 | 结果 |
|---|---|
| KPM 加载 | `KP AP KPM loading done: loaded=2 skipped=0 total=2` |
| rootstealth | `23 default entries loaded` + `hooks active: openat faccessat newfstatat statx readlinkat inotify_add_watch` |
| `selinux_MAF_fork` | `load_module_ex: succeed` |
| 三模块 | 全部 `启用` |
| Vector 框架 | `Framework Version: 2.2 / API Version: 102 / Enabled Modules: 4` |
| Zygisk Next | `zn-nsdaemon-zygote` + `zn-nsdaemon-zygote_secondary` 两个进程都在（说明已注入两个 zygote） |
| 守卫 | `count=0`，`✅ 启动成功，计数清零` |

## 建议

1. **折腾分区 / 刷机期间**，每次重启前先 `echo 0 > /data/adb/boot-guard/count`
2. 或者临时把 `05-bootguard.sh` 改名停用（但那就失去 bootloop 保护了，二选一）
3. 看到一个"模块莫名其妙全被禁用"，**第一件事去看 `/data/adb/boot-guard/log`**
4. 更稳的写法：守卫应该只禁用**最近变更过的**模块，而不是全量禁用

## 附带确认的另一个事实

`su` 的 SELinux 域是 `u:r:magisk:s0`，**但这台设备装的是 APatch 不是 Magisk**：

```
/data/adb/ap/           存在（apd 守护进程、kpm/、ori.img、su_path 等）
/data/adb/magisk/       不存在
pm list packages        只有 me.bmax.apatch
```

**APatch 故意复用 Magisk 的 SELinux 域名字符串**以获得更好的隐藏效果。
所以**不要用 `u:r:magisk:s0` 来判断 root 方案** —— 这是个很容易误判的地方。
（本项目最初就误判成"设备是 Magisk"，差点走错方向。）
