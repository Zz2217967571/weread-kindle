#!/bin/sh
# 开发期用：沿用 KOReader SSH 插件的方式启动 dropbear（端口 2222，只允许密钥登录）。
# 只有放了 /mnt/us/weread/dev.ssh 才启动，默认不开 SSH（tools/deploy.sh 会自动放这个标记）
[ -f /mnt/us/weread/dev.ssh ] || exit 0
[ -f /tmp/dropbear_koreader.pid ] && kill -0 "$(cat /tmp/dropbear_koreader.pid)" 2>/dev/null && exit 0
cd /mnt/us/koreader || exit 0
./dropbear -E -R -p 2222 -P /tmp/dropbear_koreader.pid -s
iptables -C INPUT -p tcp --dport 2222 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT 2>/dev/null ||
    iptables -A INPUT -p tcp --dport 2222 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
iptables -C OUTPUT -p tcp --sport 2222 -m conntrack --ctstate ESTABLISHED -j ACCEPT 2>/dev/null ||
    iptables -A OUTPUT -p tcp --sport 2222 -m conntrack --ctstate ESTABLISHED -j ACCEPT
exit 0
