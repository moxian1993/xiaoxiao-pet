#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
UPDATES_DIR="$HOME/Library/Application Support/柯基小小/Updates"

"$ROOT_DIR/build.sh" "$UPDATES_DIR"

echo
echo "本地更新已发布："
echo "$UPDATES_DIR"
echo
echo "现在右键柯基，选择“更新”即可安装。"
read -r "?按回车键关闭窗口。"
