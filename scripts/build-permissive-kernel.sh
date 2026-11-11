#!/bin/bash
# =============================================================================
#  PCLM50 自编内核（让任意 .ko 能 insmod）
#  按《PCLM50-自编内核-让ko能加载-手册.md》拆三道门：
#    ① CONFIG_MODULE_SIG_FORCE  y -> n
#    ② CONFIG_MODVERSIONS       y -> n
#    ③ kernel/module.c check_modinfo() 的 vermagic 比较 -> 跳过
#  工具链全部复用 TWRP 源码树里自带的 AOSP prebuilt，无需联网下载
# =============================================================================
set -o pipefail
K=/mnt/工作区/pclm50-kernel
SRC=$K/kernel
PRE=/mnt/工作区/pclm50-tw/src/prebuilts
CLANG=$PRE/clang/host/linux-x86/clang-r383902/bin
A64=$PRE/gcc/linux-x86/aarch64/aarch64-linux-android-4.9/bin
A32=$PRE/gcc/linux-x86/arm/arm-linux-androideabi-4.9/bin
LOG=$K/build.log

log(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

log "===== 开始 ====="
[ -f "$SRC/Makefile" ] || { log "✗ 源码未就绪"; exit 1; }

KV=$(awk -F' = ' '/^VERSION/{v=$2} /^PATCHLEVEL/{p=$2} /^SUBLEVEL/{s=$2} END{print v"."p"."s}' "$SRC/Makefile")
log "源码版本: $KV"

# ---------- ① ② defconfig 两道门 ----------
DEF="$SRC/arch/arm64/configs/vendor/lito-perf_defconfig"
if [ -f "$DEF" ]; then
  cp -n "$DEF" "$DEF.orig"
  sed -i 's/^CONFIG_MODULE_SIG_FORCE=y/CONFIG_MODULE_SIG_FORCE=n/' "$DEF"
  sed -i 's/^CONFIG_MODVERSIONS=y/CONFIG_MODVERSIONS=n/'      "$DEF"
  log "① SIG_FORCE : $(grep -E '^CONFIG_MODULE_SIG_FORCE' "$DEF" || echo '(已无该行)')"
  log "② MODVERSIONS: $(grep -E '^CONFIG_MODVERSIONS' "$DEF" || echo '(已无该行)')"
else
  log "✗ 找不到 defconfig: $DEF"; exit 1
fi

# ---------- ③ vermagic 门 ----------
MODC="$SRC/kernel/module.c"
cp -n "$MODC" "$MODC.orig"
if grep -q 'PCLM50 permissive: vermagic check disabled' "$MODC"; then
  log "③ vermagic 已改过，跳过"
else
  python3 - "$MODC" <<'PY'
import re,sys
p=sys.argv[1]; s=open(p,encoding='utf-8',errors='surrogateescape').read()
# 定位 check_modinfo 内的 vermagic 比较
m=re.search(r'(\tif \(!get_modinfo\(info, "vermagic"\) \|\|.*?return -ENOEXEC;\n\t\}\n)', s, re.S)
if not m:
    m=re.search(r'(\tif \(!get_modinfo\(info, "vermagic"\) \|\|.*?return -ENOEXEC;\n\s*\}\n)', s, re.S)
if not m:
    print("VERMAGIC_PATTERN_NOT_FOUND"); sys.exit(2)
blk=m.group(1)
new='\t/* PCLM50 permissive: vermagic check disabled */\n\tif (0) {\n' + blk.replace('\tif (','\t\tif (',1).replace('\t}','\t}',1) + '\t}\n'
s=s[:m.start()]+new+s[m.end():]
open(p,'w',encoding='utf-8',errors='surrogateescape').write(s)
print("VERMAGIC_PATCHED")
PY
  if [ $? -ne 0 ]; then
    log "③ ✗ 自动打补丁失败，需人工改 check_modinfo()"
  else
    log "③ vermagic 检查已跳过"
  fi
fi

# ---------- 组装驱动树（按官方 README 的相对路径） ----------
if [ ! -e "$SRC/vendor/qcom" ] && [ -d "$K/modules/vendor" ]; then
  log "挂载驱动/设备树..."; ls "$K/modules" | head
fi

# ---------- 编译 ----------
export PATH="$CLANG:$PATH"
export ARCH=arm64 SUBARCH=arm64
export CC=clang
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE="$A64/aarch64-linux-android-"
export CROSS_COMPILE_ARM32="$A32/arm-linux-androideabi-"

cd "$SRC" || exit 1
mkdir -p out
log "=== defconfig ==="
make O=out ARCH=arm64 vendor/lito-perf_defconfig 2>&1 | tail -5 | tee -a "$LOG" || \
make O=out ARCH=arm64 lito-perf_defconfig 2>&1 | tail -5 | tee -a "$LOG"

log "=== 校验三道门是否进配置 ==="
for k in MODULE_SIG_FORCE MODVERSIONS; do
  v=$(grep -E "^CONFIG_$k=|^# CONFIG_$k is not set" out/.config 2>/dev/null || echo '(未出现)')
  log "  $k -> $v"
done

log "=== 编译开始（$(nproc) 线程）==="
make O=out ARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- \
     CROSS_COMPILE="$A64/aarch64-linux-android-" \
     CROSS_COMPILE_ARM32="$A32/arm-linux-androideabi-" \
     -j$(nproc) Image dtbs 2>&1 | tail -60 | tee -a "$LOG"
RC=$?
log "编译退出码: $RC"
IMG=$SRC/out/arch/arm64/boot/Image
if [ -f "$IMG" ]; then
  log "✅ 产物: $IMG  $(stat -c%s "$IMG") B"
  md5sum "$IMG" | tee -a "$LOG"
  ls -la $SRC/out/arch/arm64/boot/dts/vendor/qcom/*.dtb 2>/dev/null | head -3 | tee -a "$LOG"
else
  log "✗ 没有产出 Image，看 $LOG 里的错误"
fi
log "===== 结束 ====="
