#!/bin/bash
# =============================================================================
#  PCLM50 recovery 候选镜像自动测试矩阵
#  每个候选：刷入 → 回读校验 → 清 BCB → 进 recovery → 观测 → 恢复原厂 → 取内核日志
#  用法: bash test_matrix.sh [候选名...]      (不给参数=全部)
# =============================================================================
A=/mnt/工作区/pclm50-tw/artifacts
S=/mnt/工作区/pclm50-tw/stock
D=<DEVICE_SERIAL>
OUT=/home/awa/桌面/pclm50_test
mkdir -p "$OUT/logs"
LOG=$OUT/results.txt
STOCK=$S/recovery_stock.img
VBMETA=$S/vbmeta_preflash.img

log(){ echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
usb(){ timeout 6 lsusb 2>/dev/null | grep -iE '22d9|05c6|18d1' | grep -oE 'ID [0-9a-f]{4}:[0-9a-f]{4}' | awk '{print $2}' | head -1; }
adbok(){ timeout 6 adb devices 2>/dev/null | grep -qE "^${D}[[:space:]]+device"; }
fbok(){ timeout 8 fastboot devices 2>/dev/null | grep -qE "^${D}"; }
dev_su(){ timeout 40 adb -s $D shell "su -c '$1'" 2>&1 | tr -d '\r'; }

wait_adb(){ local n=${1:-24}; local i; for i in $(seq 1 $n); do adbok && return 0; sleep 5; done; return 1; }

restore_and_boot(){
  log "  恢复原厂..."
  if fbok; then
    timeout 120 fastboot flash recovery "$STOCK" >/dev/null 2>&1
    timeout 60  fastboot flash vbmeta   "$VBMETA" >/dev/null 2>&1
    timeout 30  fastboot erase misc     >/dev/null 2>&1
    timeout 30  fastboot reboot         >/dev/null 2>&1
  elif adbok; then
    dev_su "dd if=/data/local/tmp/stock.img of=/dev/block/bootdevice/by-name/recovery bs=4096 conv=fsync" >/dev/null
    dev_su "dd if=/dev/zero of=/dev/block/bootdevice/by-name/misc bs=2048 count=1 conv=fsync" >/dev/null
    timeout 20 adb -s $D reboot >/dev/null 2>&1
  else
    log "  ✗ 设备既不在 adb 也不在 fastboot —— 需要人工断电重启"
    return 1
  fi
  wait_adb 30 && { log "  ✓ 已回系统"; return 0; }
  log "  ✗ 回系统超时"
  return 1
}

run_one(){  # $1 = 候选名(不含 .bin)
  local n="$1" img="$A/${1}.bin" md5 now
  [ -f "$img" ] || { log "跳过 $n（无文件）"; return 1; }
  log "================ $n ================"
  md5=$(md5sum "$img" | cut -d' ' -f1)

  if ! wait_adb 12; then
    log "  ! 当前不在 adb，尝试先恢复"; restore_and_boot || { log "设备不可达，终止矩阵"; exit 2; }
  fi

  # --- 预置原厂镜像到设备(回滚用) ---
  timeout 120 adb -s $D push "$STOCK" /data/local/tmp/stock.img >/dev/null 2>&1

  # --- 刷入 ---
  timeout 180 adb -s $D push "$img" /data/local/tmp/cand.img >/dev/null 2>&1 || { log "  推送失败"; return 1; }
  local rmd5; rmd5=$(dev_su "md5sum /data/local/tmp/cand.img" | awk '{print $1}')
  [ "$rmd5" = "$md5" ] || { log "  推送 md5 不符: $rmd5 != $md5"; return 1; }
  dev_su "dd if=/data/local/tmp/cand.img of=/dev/block/bootdevice/by-name/recovery bs=4096 conv=fsync" >/dev/null
  now=$(dev_su "dd if=/dev/block/bootdevice/by-name/recovery bs=4096 2>/dev/null | md5sum" | awk '{print $1}')
  [ "$now" = "$md5" ] && log "  写入 + 回读校验 ✓" || { log "  ✗ 回读 md5 不符: $now"; restore_and_boot; return 1; }

  # --- 清 BCB 并进 recovery ---
  dev_su "dd if=/dev/zero of=/dev/block/bootdevice/by-name/misc bs=2048 count=1 conv=fsync" >/dev/null
  timeout 20 adb -s $D reboot recovery >/dev/null 2>&1

  # --- 观测 70 秒 ---
  local verdict="?" traj="" i u a
  for i in $(seq 1 14); do
    u=$(usb); a=""
    adbok && a="adb"
    traj="$traj ${u:-none}${a:+/$a}"
    if [ -n "$u" ]; then
      case "$u" in
        18d1:d00d) verdict="FASTBOOT(lk拒绝后落bootloader)"; break;;
        22d9:2769) verdict="RECOVERY-ADB-UP(USB已枚举)"; break;;
        22d9:2765) verdict="ANDROID-回退(未进recovery)"; break;;
        22d9:*)    verdict="OPPO-其他模式 $u"; break;;
      esac
    fi
    sleep 5
  done
  [ "$verdict" = "?" ] && verdict="NO-USB(70s内无任何枚举)"
  log "  轨迹: $traj"
  log "  >>> 判定: $verdict"

  # --- 恢复原厂并回系统 ---
  restore_and_boot || { log "设备不可达，终止矩阵"; exit 2; }

  # --- 取证：上一轮启动的内核日志 ---
  dev_su "cp -f /proc/last_kmsg /data/local/tmp/lk_$n.log" >/dev/null
  timeout 90 adb -s $D pull /data/local/tmp/lk_$n.log "$OUT/logs/${n}.last_kmsg" >/dev/null 2>&1
  local f="$OUT/logs/${n}.last_kmsg"
  if [ -s "$f" ]; then
    local has_rec has_init has_panic
    has_rec=$(grep -ac 'androidboot.mode=recovery' "$f" || true)
    has_init=$(grep -ac 'init: ' "$f" || true)
    has_panic=$(grep -acE 'Kernel panic|Unable to handle|Internal error|BUG:' "$f" || true)
    log "  内核日志: 是recovery启动=$has_rec  init行=$has_init  崩溃=$has_panic  ($(stat -c%s "$f") B)"
  else
    log "  内核日志: 未取到"
  fi
  log ""
}

LIST=("$@")
[ ${#LIST[@]} -eq 0 ] && LIST=(C1_art_only C2_art_tail C3_art_signed C4_usb_tail C5_usb_signed)
for c in "${LIST[@]}"; do run_one "$c"; done
log "===== 矩阵测试结束 ====="
