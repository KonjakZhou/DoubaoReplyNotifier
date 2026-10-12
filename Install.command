#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
/bin/bash "$ROOT/install.sh"
printf '\n安装完成。可以关闭此窗口。\n'
