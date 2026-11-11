#!/bin/bash
# =============================================================================
#  拉取 PCLM50 内核源码（支持走梯子：TUN 直通 / 或自动探测本地代理端口）
#  用 codeload tarball 而不是 git clone —— 只取树不含历史，体量小得多
# =============================================================================
set -o pipefail
K=/mnt/工作区/pclm50-kernel
BR=oppo/sm7250_s_12.1_reno4_5g
LOG=$K/download.log
cd "$K" || exit 1
log(){ echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG"; }

log "===== 下载开始 ====="

# ---------- 探测网络出口 ----------
TUN=0; ip link show iKuuuVPN >/dev/null 2>&1 && TUN=1
ip addr 2>/dev/null | grep -q '198\.18\.' && TUN=1
log "TUN 模式: $([ $TUN = 1 ] && echo 是 || echo 否)"

PROXY=""
for p in 7890 7891 7897 1080 10809 10808 2080 8889; do
  if timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/$p" 2>/dev/null; then PROXY="http://127.0.0.1:$p"; break; fi
done
[ -n "$PROXY" ] && log "探测到本地代理: $PROXY" || log "未发现本地代理端口（若为 TUN 模式则无需代理）"

CURLOPT=(-L --fail --retry 5 --retry-delay 3 -C -)
[ -n "$PROXY" ] && CURLOPT+=(--proxy "$PROXY")

fetch(){  # $1=repo  $2=输出文件
  local url="https://codeload.github.com/oppo-source/$1/tar.gz/refs/heads/$BR"
  log "下载 $1 ..."
  timeout 5400 curl "${CURLOPT[@]}" -o "$2" "$url" 2>&1 | tail -2
  local sz=$(stat -c%s "$2" 2>/dev/null || echo 0)
  log "  -> $2  $sz B"
  [ "$sz" -gt 10000000 ] || { log "  ✗ 体积异常，可能没走通"; return 1; }
  return 0
}

fetch android_kernel_oppo_sm7250 kernel.tar.gz || exit 1
fetch android_kernel_modules_and_devicetree_oppo_sm7250 modules.tar.gz || exit 1

# ---------- 解包 ----------
log "=== 解包 ==="
rm -rf kernel modules
tar xzf kernel.tar.gz  && mv android_kernel_oppo_sm7250-* kernel  || { log "✗ kernel 解包失败"; exit 1; }
tar xzf modules.tar.gz && mv android_kernel_modules_and_devicetree_oppo_sm7250-* modules || { log "✗ modules 解包失败"; exit 1; }

log "=== 校验 ==="
KV=$(awk -F' = ' '/^VERSION/{v=$2} /^PATCHLEVEL/{p=$2} /^SUBLEVEL/{s=$2} END{print v"."p"."s}' kernel/Makefile 2>/dev/null)
log "  内核版本: $KV"
for f in kernel/Makefile kernel/kernel/module.c kernel/arch/arm64/configs/vendor/lito-perf_defconfig; do
  [ -f "$f" ] && log "  ✓ $f" || log "  ✗ 缺 $f"
done
[ -d "modules/vendor/qcom/proprietary/devicetree-4.19/19125" ] && \
  log "  ✓ 19125 专属设备树存在" || log "  ! 未见 19125 设备树，检查 modules 结构"
log "  体积: kernel=$(du -sh kernel 2>/dev/null|cut -f1)  modules=$(du -sh modules 2>/dev/null|cut -f1)"
log "===== 下载结束 ====="
