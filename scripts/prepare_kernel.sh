#!/bin/bash
# =============================================================================
#  PCLM50 内核树准备（可重复执行，幂等）
#  在原始 tarball 解出的 kernel/ 上依次施加全部必要修改
# =============================================================================
set -e
K=/mnt/工作区/pclm50-kernel
SRC=$K/kernel

echo "=== 0) 前置检查 ==="
[ -f "$SRC/Makefile" ] || { echo "✗ 内核树不完整"; exit 1; }
echo "  版本: $(awk -F' = ' '/^VERSION/{v=$2}/^PATCHLEVEL/{p=$2}/^SUBLEVEL/{s=$2}END{print v"."p"."s}' "$SRC/Makefile")"

echo
echo "=== 1) defconfig 两道门 ==="
DEF="$SRC/arch/arm64/configs/vendor/lito-perf_defconfig"
[ -f "$DEF" ] || { echo "✗ 缺 defconfig"; exit 1; }
grep -q '^CONFIG_MODULE_SIG_FORCE=n' "$DEF" || sed -i 's/^CONFIG_MODULE_SIG_FORCE=y/CONFIG_MODULE_SIG_FORCE=n/' "$DEF"
grep -q '^CONFIG_MODVERSIONS=n'      "$DEF" || sed -i 's/^CONFIG_MODVERSIONS=y/CONFIG_MODVERSIONS=n/' "$DEF"
grep -E '^CONFIG_MODULE_SIG_FORCE=|^CONFIG_MODVERSIONS=' "$DEF" | sed 's/^/  /'

echo
echo "=== 2) vermagic 门（kernel/module.c）==="
python3 - <<'PY'
p="/mnt/工作区/pclm50-kernel/kernel/kernel/module.c"
s=open(p,encoding='utf-8',errors='surrogateescape').read()
if 'PCLM50 permissive: vermagic' in s:
    print("  已打过，跳过")
else:
    old="\t} else if (!same_magic(modmagic, vermagic, info->index.vers)) {"
    new="\t/* PCLM50 permissive: vermagic check disabled */\n\t} else if (0 && !same_magic(modmagic, vermagic, info->index.vers)) {"
    assert s.count(old)==1, f"匹配数异常: {s.count(old)}"
    open(p,'w',encoding='utf-8',errors='surrogateescape').write(s.replace(old,new))
    print("  已跳过 vermagic 比较")
PY

echo
echo "=== 3) 禁用 gcc-wrapper（REAL_CC 指向不存在的 GNU gcc）==="
python3 - <<'PY'
p="/mnt/工作区/pclm50-kernel/kernel/Makefile"
s=open(p,encoding='utf-8',errors='surrogateescape').read()
old="CC\t\t= $(PYTHON) $(srctree)/scripts/gcc-wrapper.py $(REAL_CC)"
if old in s:
    new="# PCLM50: 禁用 gcc-wrapper\n# CC\t\t= $(PYTHON) $(srctree)/scripts/gcc-wrapper.py $(REAL_CC)"
    open(p,'w',encoding='utf-8',errors='surrogateescape').write(s.replace(old,new))
    print("  已禁用")
else:
    print("  已完成或已不存在")
PY

echo
echo "=== 4) gcc-wrapper.py 转 Python 3 ==="
python3 - <<'PY'
import re
p="/mnt/工作区/pclm50-kernel/kernel/scripts/gcc-wrapper.py"
s=open(p,encoding='utf-8',errors='surrogateescape').read()
s2=re.sub(r'(?m)^(\s*)print\s+(?!\()(.*)$', lambda m: f'{m.group(1)}print({m.group(2)})', s)
if s2!=s:
    open(p,'w',encoding='utf-8',errors='surrogateescape').write(s2); print("  已转换 print")
else: print("  无需转换")
PY

echo
echo "=== 5) CRLF -> LF（kconfig/make 不认 \\r）==="
python3 - <<'PY'
import os
K="/mnt/工作区/pclm50-kernel"
fixed=0
for base in (K+"/kernel", K+"/modules"):
    for r,d,fs in os.walk(base):
        if '/out' in r or '/.git' in r: continue
        for n in fs:
            if not (n.startswith("Kconfig") or n.startswith("Makefile") or
                    n.endswith((".mk",".c",".h",".rc",".sh",".dts",".dtsi",".txt"))): continue
            p=os.path.join(r,n)
            if os.path.islink(p): continue
            try:
                d2=open(p,'rb').read()
                if b'\r\n' in d2:
                    open(p,'wb').write(d2.replace(b'\r\n',b'\n')); fixed+=1
            except: pass
print(f"  转换 {fixed} 个文件")
PY

echo
echo "=== 6) 组装驱动/设备树软链 ==="
cd $K
ln -sfn "$K/modules/vendor" "$SRC/vendor"                                  && echo "  ✓ kernel/vendor"
mkdir -p "$SRC/arch/arm64/boot/dts"
ln -sfn "$K/modules/vendor/qcom/proprietary/devicetree-4.19" "$SRC/arch/arm64/boot/dts/vendor" && echo "  ✓ arch/arm64/boot/dts/vendor"
for d in camera display video; do
  [ -d "$K/modules/kernel/msm-4.19/techpack/$d" ] && ln -sfn "$K/modules/kernel/msm-4.19/techpack/$d" "$SRC/techpack/$d" && echo "  ✓ techpack/$d"
done

echo
echo "=== 7) 已知特例（healthinfo 反向嵌套 + sched_assist 头文件）==="
H=$K/modules/vendor/oplus/kernel/oplus_performance/healthinfo
ln -sfn $H/mm  "$SRC/mm/healthinfo"        && echo "  ✓ mm/healthinfo -> healthinfo/mm"
mkdir -p "$SRC/fs/proc"
ln -sfn $H/fs  "$SRC/fs/proc/healthinfo"   && echo "  ✓ fs/proc/healthinfo -> healthinfo/fs"
mkdir -p "$SRC/include/linux"
ln -sfn "$K/modules/vendor/oplus/kernel/oplus_performance/sched_assist" "$SRC/include/linux/sched_assist" && echo "  ✓ include/linux/sched_assist"

echo
echo "=== 准备完成 ==="
