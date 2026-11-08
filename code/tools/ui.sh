#!/bin/bash
# ADB 测试辅助：按 content-desc / text 精确点击，坐标每次实时抓取
# 用法:
#   ./ui.sh desc                 列出所有非空 content-desc
#   ./ui.sh texts                列出所有非空 text
#   ./ui.sh tap "描述"           按 content-desc 精确点击
#   ./ui.sh tapx "描述"          按 content-desc 包含匹配点击
#   ./ui.sh tapt "文本"          按 text 包含匹配点击
#   ./ui.sh tapxy x y            直接点坐标
#   ./ui.sh shot out.png         截图
#   ./ui.sh swipe x1 y1 x2 y2 ms
#   ./ui.sh back                 返回键
#   ./ui.sh selected             当前选中的 Tab
#
# 注意：Windows 下 adb daemon 会在命令结束后被回收，因此每条命令
# 都必须自带 start-server + connect，否则第二条就 device offline。
export MSYS_NO_PATHCONV=1
DEV="${DEV:-emulator-5554}"

ensured() {
  adb start-server >/dev/null 2>&1
  # 沙箱会在命令之间回收 adb server，因此每条命令都要重新 connect。
  # connect 之后设备并非立刻可用，需要轮询 get-state，否则紧接着的
  # dump 会报 device offline，脚本就会读到上一次残留的 _ui.xml，
  # 造成「界面没变化」的假象（这个坑实际踩到过）。
  local i
  for i in 1 2 3 4 5 6 7 8; do
    if [ "$(adb -s "$DEV" get-state 2>/dev/null)" = "device" ]; then return 0; fi
    adb connect 127.0.0.1:5555 >/dev/null 2>&1
    sleep 1
  done
  echo "DEVICE_NOT_READY: $DEV" >&2
  return 1
}

dump() {
  ensured || return 1
  # 先删掉旧文件：dump 失败时 cat 会读到上一次的残留，
  # 让人误以为界面没变化。
  adb -s "$DEV" shell rm -f /sdcard/_ui.xml >/dev/null 2>&1
  local out
  out=$(adb -s "$DEV" shell uiautomator dump /sdcard/_ui.xml 2>&1)
  case "$out" in
    *"dumped to"*) : ;;
    *) echo "DUMP_FAILED: $out" >&2; return 1 ;;
  esac
  adb -s "$DEV" shell cat /sdcard/_ui.xml 2>/dev/null
}

# 把一个 XML 拉平成「一行一个节点」
nodes() { tr '<' '\n<' < /dev/stdin; }

# 从节点行里取 bounds 并点击
tap_line() {
  local line="$1"
  local b coords cx cy
  b=$(echo "$line" | grep -o 'bounds="\[[0-9]*,[0-9]*\]\[[0-9]*,[0-9]*\]"')
  if [ -z "$b" ]; then echo "NO_BOUNDS"; return 2; fi
  coords=$(echo "$b" | sed -E 's/bounds="\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]"/\1 \2 \3 \4/')
  set -- $coords
  cx=$(( ($1+$3)/2 )); cy=$(( ($2+$4)/2 ))
  echo "tap ($cx,$cy)"
  adb -s "$DEV" shell input tap $cx $cy
}

cmd="$1"; shift

case "$cmd" in
  desc)
    dump | grep -o 'content-desc="[^"]*"' | grep -v 'content-desc=""' | sed 's/content-desc="//; s/"$//'
    ;;
  texts)
    dump | nodes | grep -o ' text="[^"]*"' | grep -v ' text=""' | sed 's/ text="//; s/"$//'
    ;;
  tap)
    pat="$1"
    dump > /tmp/_d.xml
    line=$(nodes < /tmp/_d.xml | grep -F "content-desc=\"$pat\"" | head -1)
    if [ -z "$line" ]; then echo "NOT_FOUND: $pat"; exit 2; fi
    tap_line "$line"
    ;;
  tapx)
    pat="$1"
    dump > /tmp/_d.xml
    line=$(nodes < /tmp/_d.xml | grep -F "content-desc=\"" | grep -F "$pat" | head -1)
    if [ -z "$line" ]; then echo "NOT_FOUND: $pat"; exit 2; fi
    tap_line "$line"
    ;;
  tapt)
    pat="$1"
    dump > /tmp/_d.xml
    line=$(nodes < /tmp/_d.xml | grep -F " text=\"" | grep -F "$pat" | head -1)
    if [ -z "$line" ]; then echo "NOT_FOUND: $pat"; exit 2; fi
    tap_line "$line"
    ;;
  tapxy)
    ensured
    adb -s "$DEV" shell input tap "$1" "$2"
    echo "tap ($1,$2)"
    ;;
  shot)
    ensured
    adb -s "$DEV" exec-out screencap -p > "${1:-/tmp/shot.png}"
    echo "saved ${1:-/tmp/shot.png} ($(stat -c %s "${1:-/tmp/shot.png}" 2>/dev/null) bytes)"
    ;;
  swipe)
    ensured
    adb -s "$DEV" shell input swipe "$1" "$2" "$3" "$4" "${5:-300}"
    ;;
  back)
    ensured
    adb -s "$DEV" shell input keyevent 4
    ;;
  text)
    ensured
    adb -s "$DEV" shell input text "$1"
    ;;
  enter)
    ensured
    adb -s "$DEV" shell input keyevent 66
    ;;
  selected)
    dump | nodes | grep -E 'Tab [0-9]' | grep 'selected="true"' | grep -o 'content-desc="[^"]*"'
    ;;
  *)
    echo "usage: ui.sh {desc|texts|tap <desc>|tapx <sub>|tapt <text>|tapxy x y|shot f|swipe x1 y1 x2 y2 ms|back|text s|enter|selected}"
    ;;
esac