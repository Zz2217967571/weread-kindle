#!/bin/sh
# 把 kindle/ 部署到 Kindle 的 /mnt/us/weread，并在书库里放启动入口。
set -e
cd "$(dirname "$0")/.."
KSSH=tools/kssh

# 书库入口：在脚本头部加上封面（Kindle 的 scriptlet 支持用 "# Icon:" 行指定封面）
python3 -I tools/make-cover.py >/dev/null
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
{
    sed -n '1,2p' kindle/launcher/weread.sh
    printf '# Icon: data:image/png;base64,%s\n' "$(base64 < kindle/launcher/cover.png | tr -d '\n')"
    sed -n '3,$p' kindle/launcher/weread.sh
} >"$STAGE/weread.sh"
$KSSH 'cat > /mnt/us/weread/weread.sh.entry' <"$STAGE/weread.sh"

# 字体文件大（每个十几 MB），只在 Kindle 上没有或大小不同时才传
for f in kindle/fonts/*; do
    name=$(basename "$f")
    local_size=$(stat -f %z "$f")
    remote_size=$($KSSH "stat -c %s /mnt/us/weread/fonts/$name 2>/dev/null" || true)
    if [ "$local_size" != "$remote_size" ]; then
        echo "uploading font $name"
        $KSSH "mkdir -p /mnt/us/weread/fonts && cat > /mnt/us/weread/fonts/$name.tmp && mv /mnt/us/weread/fonts/$name.tmp /mnt/us/weread/fonts/$name" <"$f"
    fi
done

COPYFILE_DISABLE=1 tar -C kindle -cf - --exclude '.DS_Store' main.lua weread launcher |
    $KSSH 'mkdir -p /mnt/us/weread && tar -C /mnt/us/weread -xf - &&
        touch /mnt/us/weread/dev.ssh &&
        mv -f /mnt/us/weread/launcher/dev-ssh.sh /mnt/us/weread/dev-ssh.sh &&
        chmod +x /mnt/us/weread/dev-ssh.sh /mnt/us/weread/launcher/make-run.sh &&
        sh /mnt/us/weread/launcher/make-run.sh &&
        if ! cmp -s /mnt/us/weread/weread.sh.entry /mnt/us/documents/weread.sh; then
            rm -rf /mnt/us/documents/weread.sdr
            cp -f /mnt/us/weread/weread.sh.entry /mnt/us/documents/weread.sh
            echo "library entry updated"
        fi'
# 注意：这里不再自动创建 /mnt/us/weread/dev.flag。那个标记会让 App 运行期间一直禁用 Kindle 休眠（见 weread/app.lua keepAwakeForDev），
# 只该在开发时手动开：tools/kdev on，用完 tools/kdev off。
echo "deployed"
