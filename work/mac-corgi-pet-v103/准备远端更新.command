#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h}"
OUTPUT_DIR="$ROOT_DIR/../../outputs"

"$ROOT_DIR/../windows-v103/build.sh" "$OUTPUT_DIR"
"$ROOT_DIR/build.sh" "$OUTPUT_DIR"

echo
echo "远端更新文件已准备："
echo "$OUTPUT_DIR/Corgi-Xiaoxiao-macOS.zip"
echo "$OUTPUT_DIR/Corgi-Xiaoxiao-Windows.zip"
echo "$OUTPUT_DIR/update.json"
echo
echo "请将这三个文件上传到同一个 GitHub Release，并最后发布该 Release。"
read -r "?按回车键关闭窗口。"
