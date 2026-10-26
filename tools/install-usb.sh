#!/bin/sh
# 用 USB 把应用装到 Kindle（不需要 SSH）。Kindle 用数据线连上 Mac 后，卷名一般是 /Volumes/Kindle。
# 用法：tools/install-usb.sh [Kindle 卷的路径]
set -e
cd "$(dirname "$0")/.."
K=${1:-/Volumes/Kindle}
[ -d "$K/documents" ] || { echo "找不到 $K/documents，Kindle 没挂载？"; exit 1; }
[ -d "$K/koreader" ] || { echo "Kindle 上没有 koreader 目录，请先装 KOReader（见 README 的前置条件）"; exit 1; }

mkdir -p "$K/weread"
COPYFILE_DISABLE=1 tar -C kindle -cf - --exclude '.DS_Store' main.lua weread launcher fonts | tar -C "$K/weread" -xf -
mv -f "$K/weread/launcher/dev-ssh.sh" "$K/weread/dev-ssh.sh"

# 书库入口：脚本头加上封面
{
    sed -n '1,2p' kindle/launcher/weread.sh
    printf '# Icon: data:image/png;base64,%s\n' "$(base64 < kindle/launcher/cover.png | tr -d '\n')"
    sed -n '3,$p' kindle/launcher/weread.sh
} >"$K/documents/weread.sh"
rm -rf "$K/documents/weread.sdr"
echo "已复制。在 Mac 上推出 Kindle，书库里会出现“微信读书”，点开即可（第一次启动会自动生成 run.sh）。"
