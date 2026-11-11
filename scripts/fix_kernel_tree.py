#!/usr/bin/env python3
"""反复跑 defconfig，自动把缺失的内核源码引用从驱动仓库挂接进来，直到通过。
匹配策略（按优先级）：
  1) modules 里存在同名目录且含所需文件（Kconfig/Makefile）→ 挂它
  2) modules 里存在路径以 <父目录名>/<本目录名> 结尾的"反向嵌套"（healthinfo 这类）→ 挂它
  3) modules 里存在同名目录（任意内容）→ 挂它
  从浅到深处理，挂上上层目录后下层自动解决。
"""
import os, re, subprocess, sys, glob

K = "/mnt/工作区/pclm50-kernel"
SRC = f"{K}/kernel"
MOD = f"{K}/modules"
PRE = "/mnt/工作区/pclm50-tw/src/prebuilts"
A64 = f"{PRE}/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin"
CLANG = f"{PRE}/clang/host/linux-x86/clang-r383902/bin"

ENV = dict(os.environ)
ENV.update({
    "PATH": CLANG + ":" + ENV.get("PATH", ""),
    "ARCH": "arm64", "SUBARCH": "arm64", "CC": "clang",
    "CLANG_TRIPLE": "aarch64-linux-gnu-",
    "CROSS_COMPILE": f"{A64}/aarch64-linux-android-",
})

# 预扫 modules 目录及文件索引
mod_dirs = {}
for root, dirs, files in os.walk(MOD):
    mod_dirs.setdefault(os.path.basename(root), []).append((root, set(files)))

def rel(p, base=MOD):
    return os.path.relpath(p, base)

def candidates(name):
    return mod_dirs.get(name, [])

# 同名匹配失效时的特例映射（目标路径 -> modules 内相对路径）
MANUAL = {
    "net/oplus_modules":                    "vendor/oplus/kernel/network",
    "drivers/power/oplus":                  "vendor/oplus/kernel/charger",
    "drivers/misc/colorctrl":               "vendor/oplus/kernel/colorctrl/colorctrl",
    "drivers/misc/colorctrl_v2":            "vendor/oplus/kernel/colorctrl/colorctrl_v2",
    "fs/oext4":                             "vendor/oplus/kernel_4.19/ext4",
    "fs/erofs":                             "vendor/oplus/kernel_4.19/erofs",
    "fs/exfat":                             "vendor/oplus/kernel_4.19/exfat",
    "drivers/scsi/oufs":                    "vendor/oplus/kernel_4.19/ufs",
    "drivers/block/zram/zwb_handle":        "vendor/oplus/kernel/oplus_performance/zwb_handle",
    "drivers/input/oplus_fp_drivers":       "vendor/oplus/secure/biometrics/fingerprints/bsp/drivers",
    "drivers/input/oplus_secure_drivers":   "vendor/oplus/secure/common/bsp/drivers",
    "drivers/soc/oplus/healthinfo":         "vendor/oplus/kernel/oplus_performance/healthinfo/main",
    "drivers/soc/oplus/owakelock":          "vendor/oplus/kernel/wakelock_profiler",
}

def pick(target_dir, need_file):
    """为目标目录挑一个最合适的 modules 候选"""
    if target_dir in MANUAL:
        cand = os.path.join(MOD, MANUAL[target_dir])
        if os.path.isdir(cand):
            return cand, "特例映射"
    name = os.path.basename(target_dir)
    parent = os.path.basename(os.path.dirname(target_dir))
    cands = candidates(name)
    if not cands:
        # 反向嵌套：目标 .../<parent>/<name>，modules 里可能是 .../<name>/<parent>
        rev = []
        for root in glob.glob(f"{MOD}/**/{name}/{parent}", recursive=True):
            if os.path.isdir(root):
                rev.append((root, set(os.listdir(root))))
        if rev:
            return rev[0][0], "反向嵌套"
        return None, "无同名目录"
    base = need_file.split(".")[0]
    # 1) 含所需文件
    for root, fs in cands:
        if any(f == need_file or f.startswith(base) for f in fs):
            return root, "含所需文件"
    # 3) 任意
    return cands[0][0], "同名目录"

def run_defconfig():
    r = subprocess.run(
        ["make", "O=out", "ARCH=arm64", f"CC=clang",
         "CLANG_TRIPLE=aarch64-linux-gnu-",
         f"CROSS_COMPILE={A64}/aarch64-linux-android-",
         "vendor/lito-perf_defconfig"],
        cwd=SRC, env=ENV, capture_output=True, text=True, timeout=600)
    return r.returncode, r.stdout + r.stderr

for it in range(1, 40):
    rc, out = run_defconfig()
    if rc == 0 and os.path.exists(f"{SRC}/out/.config"):
        print(f"[{it}] ✅ defconfig 通过")
        break
    miss = sorted(set(re.findall(r'can\'t open file "([^"]+)"', out)))
    if not miss:
        print(f"[{it}] ✗ 没有'缺文件'错误但失败，最后 20 行输出：")
        print("\n".join(out.splitlines()[-20:]))
        break
    miss.sort(key=lambda p: p.count("/"))
    print(f"[{it}] 缺 {len(miss)} 个引用")
    fixed = 0
    for m in miss:
        d = os.path.dirname(m)
        dst = os.path.join(SRC, d)
        # 目录在但所需文件缺 → 重新挑候选并改指向
        if os.path.exists(dst):
            need = os.path.basename(m)
            if os.path.exists(os.path.join(dst, need)):
                continue
            src, why = pick(d, need)
            if src and os.path.exists(os.path.join(src, need)):
                if os.path.islink(dst):
                    os.remove(dst)
                else:
                    import shutil; shutil.rmtree(dst, ignore_errors=True)
                os.symlink(src, dst)
                print(f"   ↻ kernel/{d} -> modules/{rel(src)}   (重指向/{why})")
                fixed += 1
            else:
                print(f"   ✗ {m}  —— 找不到含该文件的候选（候选={src or '无'}），需人工确认")
            continue
        src, why = pick(d, os.path.basename(m))
        if not src:
            print(f"   ? {m}  —— {why}")
            continue
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.islink(dst) or os.path.exists(dst):
            os.remove(dst)
        os.symlink(src, dst)
        print(f"   ✓ kernel/{d} -> modules/{rel(src)}   ({why})")
        fixed += 1
    if fixed == 0:
        print("   ⚠ 本轮没能修任何一项，退出避免死循环")
        break
else:
    print("超过迭代上限")

print("\n=== 关键配置 ===")
cfg = f"{SRC}/out/.config"
if os.path.exists(cfg):
    for k in ("CONFIG_MODULE_SIG_FORCE", "CONFIG_MODVERSIONS", "CONFIG_MODULE_SIG"):
        hit = [l.strip() for l in open(cfg) if l.strip().startswith(k) or l.strip() == f"# {k} is not set"]
        print(f"  {k}: {hit or '(未设置)'}")
