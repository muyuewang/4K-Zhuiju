#!/bin/bash
# 用法: ui.sh <动作>
#   动作 = launch | dump | tap:<文本> | wait:<秒>
export PATH="/c/Android/Sdk/platform-tools:$PATH"
D="127.0.0.1:5555"
W="C:/Users/fengxin/WorkBuddy/vivos7/flutter_app"

ensure() {
  adb devices 2>/dev/null | grep -q "$D" || { adb connect $D >/dev/null 2>&1; sleep 2; }
}

do_dump() {
  MSYS_NO_PATHCONV=1 adb -s $D shell uiautomator dump /sdcard/u.xml >/dev/null 2>&1
  MSYS_NO_PATHCONV=1 adb -s $D pull /sdcard/u.xml "$W/u.xml" >/dev/null 2>&1
  python - "$1" <<'PY'
import re, sys
want = sys.argv[1] if len(sys.argv) > 1 else ''
d = open(r'C:/Users/fengxin/WorkBuddy/vivos7/flutter_app/u.xml', encoding='utf-8').read()
rows = []
for m in re.finditer(r'<node[^>]*?>', d):
    s = m.group(0)
    if 'clickable="true"' not in s:
        continue
    cd = re.search(r'content-desc="([^"]*)"', s)
    bd = re.search(r'bounds="([^"]*)"', s)
    if not bd:
        continue
    t = (cd.group(1) if cd else '').replace('\n', ' / ')
    n = re.findall(r'\d+', bd.group(1))
    if len(n) != 4:
        continue
    cx, cy = (int(n[0]) + int(n[2])) // 2, (int(n[1]) + int(n[3])) // 2
    rows.append((t, cx, cy))
show = [r for r in rows if want and want in r[0]] if want else rows
for t, cx, cy in show:
    print(f'  [{cx},{cy}]  {t[:44]}')
PY
}

case "$1" in
  launch)
    ensure
    adb -s $D shell am force-stop com.juzi.juzi >/dev/null 2>&1
    sleep 1
    adb -s $D shell am start -n com.juzi.juzi/.MainActivity >/dev/null 2>&1
    echo "launched"
    ;;
  dump)
    ensure; do_dump "$2"
    ;;
  tap*)
    ensure
    TXT="${1#tap:}"
    MSYS_NO_PATHCONV=1 adb -s $D shell uiautomator dump /sdcard/u.xml >/dev/null 2>&1
    MSYS_NO_PATHCONV=1 adb -s $D pull /sdcard/u.xml "$W/u.xml" >/dev/null 2>&1
    COORD=$(python - "$TXT" <<'PY'
import re, sys
want = sys.argv[1]
d = open(r'C:/Users/fengxin/WorkBuddy/vivos7/flutter_app/u.xml', encoding='utf-8').read()
best = None
for m in re.finditer(r'<node[^>]*?>', d):
    s = m.group(0)
    if 'clickable="true"' not in s:
        continue
    cd = re.search(r'content-desc="([^"]*)"', s)
    bd = re.search(r'bounds="([^"]*)"', s)
    if not bd:
        continue
    t = (cd.group(1) if cd else '').replace('\n', ' ')
    n = re.findall(r'\d+', bd.group(1))
    if len(n) != 4:
        continue
    if want in t:
        best = ((int(n[0]) + int(n[2])) // 2, (int(n[1]) + int(n[3])) // 2)
        break
print(f'{best[0]} {best[1]}' if best else '')
PY
)
    if [ -z "$COORD" ]; then echo "NOT_FOUND: $TXT"; exit 2; fi
    adb -s $D shell input tap $COORD
    echo "tapped [$COORD] -> $TXT"
    ;;
  wait:*)
    sleep "${1#wait:}"
    ;;
  shot)
    ensure
    MSYS_NO_PATHCONV=1 adb -s $D shell screencap -p /sdcard/s.png >/dev/null 2>&1
    MSYS_NO_PATHCONV=1 adb -s $D pull /sdcard/s.png "$W/s.png" >/dev/null 2>&1
    python -c "
from PIL import Image
im=Image.open(r'C:/Users/fengxin/WorkBuddy/vivos7/flutter_app/s.png')
im.thumbnail((720,1280)); im.convert('RGB').save(r'C:/Users/fengxin/WorkBuddy/vivos7/flutter_app/s.jpg','JPEG',quality=82)
print('shot ok', im.size)"
    ;;
  dl)
    ensure
    echo "--- downloads 目录 ---"
    adb -s $D shell "ls -la /storage/emulated/0/Android/data/com.juzi.juzi/files/downloads/ 2>&1" 2>&1 | head -15
    ;;
esac