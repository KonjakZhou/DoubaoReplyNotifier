#!/bin/bash
# Double-clickable installer. Shows clear errors and pauses so the window does
# not vanish before the user can read what went wrong.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
echo "==============================================="
echo "  豆包回复通知 - 安装程序"
echo "==============================================="
echo ""
if /bin/bash "$ROOT/install.sh"; then
  echo ""
  echo "安装完成。可以关闭此窗口。"
else
  rc=$?
  echo "" >&2
  echo "===============================================" >&2
  echo "  安装失败（退出码 $rc）" >&2
  echo "===============================================" >&2
  echo "常见原因：" >&2
  echo "  1) 权限不足：当前用户对 /Applications 没有写权限" >&2
  echo "  2) 旧版无法停止：请在菜单栏退出旧通知器后重试" >&2
  echo "  3) 分发包损坏：请重新完整解压" >&2
  echo "  4) 缺少 Command Line Tools：执行 xcode-select --install" >&2
  echo "" >&2
  echo "请向上翻看 install.sh 的错误输出以定位具体原因。" >&2
fi
echo ""
read -n 1 -s -r -p "按任意键关闭此窗口..." || true
echo ""
