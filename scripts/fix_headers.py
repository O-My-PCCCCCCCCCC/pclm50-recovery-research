#!/usr/bin/env python3
"""反复编译，自动把缺失的头文件目录从驱动仓库挂进 kernel/include/，直到不再缺头文件。
用 make -k 尽量多收集错误，减少迭代次数。
"""
import os, re, subprocess, glob, shutil

K = "/mnt/工作区/pclm50-kernel"
SRC = f"{K}/kernel"
MOD = f"{K}/modules"
PRE = "/mnt/工作区/pclm50-tw/src/prebuilts"
A64 = f"{PRE}/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin"
A32 = f"{PRE}/gcc/linux-x86/arm/arm-linux-androideabi-4.9/bin"
CLANG = f"{PRE}/clang/host/linux-x86/clang-r383902/bin"

ENV = dict(os.environ)
ENV["PATH"] = CLANG + ":" + ENV.get("PATH", "")
ENV.update({"ARCH": "arm64", "SUBARCH": "arm64", "CC": "clang",
            "CLANG_TRIPLE": "aarch64-linux-gnu-",
            "CROSS_COMPILE": f"{A64}/aarch64-linux-android-",
            "CROSS_COMPILE_ARM32": f"{A32}/arm-linux-androideabi-"})

# 建立 basename -> 所在目录 的索引（只扫 modules）
hidx = {}
for root, dirs, files in os.walk(MOD):
    for f in files:
        hidx.setdefault(f, []).append(root)

INC_ROOT = os.path.abspath(os.path.join(SRC, "include"))

def _safe(path):
    """硬护栏：词法判断路径必须在 include/ 之下（允许软链指向外部仓库）"""
    ap = os.path.abspath(path)
    return ap == INC_ROOT or ap.startswith(INC_ROOT + os.sep)

def fix_one(hdr):
    """把缺失头文件从 modules 复制到 include/ 对应位置。绝不删除任何现有目录。"""
    if hdr.startswith('/') or '..' in hdr.split('/'):
        return f"  SKIP {hdr} (不安全路径)"
    base = os.path.basename(hdr)
    rel_dir = os.path.dirname(hdr)
    if not rel_dir:
        return f"  SKIP {hdr} (无目录层级)"
    dst_dir = os.path.join(SRC, "include", rel_dir)
    if not _safe(dst_dir):
        return f"  SKIP {hdr} (越界)"
    dst_file = os.path.join(dst_dir, base)
    if os.path.lexists(dst_file):
        return None
    cands = hidx.get(base, [])
    if not cands:
        return f"  ? {hdr}  (modules 里找不到 {base})"
    src = os.path.join(cands[0], base)
    if not os.path.exists(src):
        return f"  ? {hdr}  (源文件不存在)"
    if os.path.lexists(dst_dir) and not os.path.isdir(dst_dir):
        os.remove(dst_dir)                        # 断链软链，清掉
    os.makedirs(dst_dir, exist_ok=True)          # 只创建，不删除
    if os.path.islink(dst_file):                  # 断了的老软链，替换成副本
        os.remove(dst_file)
    shutil.copy2(src, dst_file)
    return f"  + include/{hdr}  <= modules/{os.path.relpath(src, MOD)}"

for it in range(1, 31):
    r = subprocess.run(["make", "-k", "O=out", "-j4", "Image"],
                       cwd=SRC, env=ENV, capture_output=True, text=True, timeout=5400)
    out = r.stdout + r.stderr
    if os.path.exists(f"{SRC}/out/arch/arm64/boot/Image"):
        print(f"[{it}] ✅ Image 产出成功")
        break
    miss = sorted(set(re.findall(r"fatal error: '([^']+)' file not found", out)))
    if not miss:
        print(f"[{it}] 没有'缺头文件'错误，其他错误如下（最后 30 行）：")
        print("\n".join(out.splitlines()[-30:]))
        break
    print(f"[{it}] 缺 {len(miss)} 个头文件")
    n = 0
    for h in miss:
        r2 = fix_one(h)
        if r2:
            print("  " + r2)
            if not r2.startswith("?"):
                n += 1
    if n == 0:
        print("  本轮没修成任何一项，退出")
        break
