#!/bin/bash
# =============================================================================
#  决定性实验：确认 lk 到底启动了哪个分区的 recovery
#    - 原厂 recovery (sde25) 内嵌 vbmeta size = 2880
#    - recoverybak   (sde48) 内嵌 vbmeta size = 2112
#  只要在 recovery 里读到 ro.boot.vbmeta.size 就知道 lk 用了哪个
#  同时回读 sde25 的 md5，判断有没有被"还原"
# =============================================================================
A=/mnt/工作区/pclm50-tw/artifacts
D=<DEVICE_SERIAL>
OUT=/home/awa/桌面/pclm50_test
LOG=$OUT/decisive.txt
CAND="${1:-C5_usb_signed}"
IMG="$A/${CAND}.bin"

log(){ echo "$(date '+%H:%M:%S') $*" | tee -a "$LOG"; }
usb(){ timeout 6 lsusb 2>/dev/null | grep -iE '22d9|05c6|18d1' | grep -oE '[0-9a-f]{4}:[0-9a-f]{4}' | head -1; }
adbok(){ timeout 6 adb devices 2>/dev/null | grep -qE "^${D}[[:space:]]+device"; }
dsu(){ timeout 40 adb -s $D shell "su -c '$1'" 2>&1 | tr -d '\r'; }

MD5=$(md5sum "$IMG" | cut -d' ' -f1)
log "===== 决定性实验: $CAND (md5 $MD5) ====="

# 0) 必须在 Android + root
adbok || { log "设备不在 adb，先人工回系统"; exit 1; }
dsu "id" | grep -q 'uid=0' || { log "无 root"; exit 1; }

# 1) 写入候选并回读
timeout 200 adb -s $D push "$IMG" /data/local/tmp/cand.img >/dev/null 2>&1
dsu "dd if=/data/local/tmp/cand.img of=/dev/block/bootdevice/by-name/recovery bs=4096 conv=fsync" >/dev/null
W=$(dsu "dd if=/dev/block/bootdevice/by-name/recovery bs=4096 2>/dev/null | md5sum" | awk '{print $1}')
[ "$W" = "$MD5" ] && log "写入+回读 ✓" || { log "回读不符 $W"; exit 1; }

# 2) 清 BCB 并进 recovery
dsu "dd if=/dev/zero of=/dev/block/bootdevice/by-name/misc bs=2048 count=1 conv=fsync" >/dev/null
timeout 20 adb -s $D reboot recovery >/dev/null 2>&1
log "已触发 reboot recovery，等待 recovery 里 adb 上线..."

# 3) 等 recovery 的 adb，一上线立刻读关键属性
GOT=0
for i in $(seq 1 22); do
  if adbok; then
    MODE=$(timeout 15 adb -s $D shell getprop ro.boot.mode 2>/dev/null | tr -d '\r')
    VBSZ=$(timeout 15 adb -s $D shell getprop ro.boot.vbmeta.size 2>/dev/null | tr -d '\r')
    VBDG=$(timeout 15 adb -s $D shell getprop ro.boot.vbmeta.digest 2>/dev/null | tr -d '\r')
    VBSM=$(timeout 15 adb -s $D shell getprop ro.boot.startupmode 2>/dev/null | tr -d '\r')
    U=$(usb)
    log "  [拿到] usb=$U  ro.boot.mode=$MODE  startupmode=$VBSM"
    log "  [拿到] vbmeta.size=$VBSZ   vbmeta.digest=$VBDG"
    case "$VBSZ" in
      2880) log "  >>> lk 用的是 sde25 原厂 recovery 的 vbmeta —— 说明分区已被还原成原厂";;
      2112) log "  >>> lk 用的是 sde48 recoverybak 的 vbmeta —— ★ lk 回退启动了 recoverybak";;
      "")   log "  >>> 读不到 vbmeta.size";;
      *)    log "  >>> 未知 size=$VBSZ";;
    esac
    GOT=1; break
  fi
  sleep 5
done
[ "$GOT" = "0" ] && log "  recovery 的 adb 一直没上线（usb=$(usb)）"

# 4) 回系统并回读 sde25，判断有没有被还原
log "  尝试回系统..."
timeout 20 adb -s $D reboot >/dev/null 2>&1
for i in $(seq 1 24); do adbok && break; sleep 5; done
if adbok; then
  NOW=$(dsu "md5sum /dev/block/bootdevice/by-name/recovery" | awk '{print $1}')
  log "  回读 sde25 md5 = $NOW"
  if [ "$NOW" = "$MD5" ]; then
    log "  >>> 候选镜像仍在分区里 —— 没有任何东西还原它（lk 是回退到了别处）"
  else
    log "  >>> 候选已不在分区里（被还原了）"
  fi
else
  log "  未能回到系统，回读跳过"
fi
log "===== 结束 ====="
