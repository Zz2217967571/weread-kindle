#!/bin/sh
# 在 Kindle 上运行：用 KOReader 自己的 koreader.sh 生成 /mnt/us/weread/run.sh。
# 启停框架、暂停系统界面、恢复屏幕这些逻辑全部沿用 KOReader 的，只把入口换成 main.lua，
# 这样 KOReader 升级后重新部署一次就能跟上。
set -e
KO=/mnt/us/koreader
APP=/mnt/us/weread

sed \
    -e "s#^export KOREADER_DIR=.*#export KOREADER_DIR=\"${KO}\"#" \
    -e "s#/var/tmp/koreader.sh#/var/tmp/weread-run.sh#g" \
    -e "s#^\\([[:space:]]*\\)\\./reader\\.lua \"\\\$@\" >>crash\\.log 2>&1#\\1WEREAD_DIR=${APP} ./luajit ${APP}/main.lua \"\$@\" >>${APP}/crash.log 2>\\&1#" \
    "${KO}/koreader.sh" >"${APP}/run.sh.new"

# 开发期：App 运行时也开着 SSH（只认密钥），方便部署和看日志
sed -i "s#^RETURN_VALUE=85\$#${APP}/dev-ssh.sh\\nRETURN_VALUE=85#" "${APP}/run.sh.new"

# 5.18 上状态栏时钟每分钟会在屏幕左上角重画一次。用系统提供的 chromebar 开关关掉时钟，
# 退出时再打开。（暂停状态栏进程会让 Kindle 的图形系统被判定异常、反复重启后整机重启，不能用。）
sed -i \
    -e "s#^\([[:space:]]*\)killall -STOP awesome\$#\1killall -STOP awesome\n\1lipc-set-prop com.lab126.chromebar configureClock 0#" \
    -e "s#^\([[:space:]]*\)killall -CONT awesome\$#\1lipc-set-prop com.lab126.chromebar configureClock 1\n\1killall -CONT awesome#" \
    "${APP}/run.sh.new"

# 开发期热重启：tools/krun 写入 /tmp/weread-reload 再结束 App，外层脚本就只重新跑 main.lua，
# 不把 Kindle 的系统服务停了又起（频繁停起会触发系统的重启保护）。
# 开发用环境变量从 /tmp/weread-dev.env 读入。
sed -i \
    -e "s#^\([[:space:]]*\)\(WEREAD_DIR=${APP} ./luajit\)#\1[ -f /tmp/weread-dev.env ] \&\& . /tmp/weread-dev.env \&\& rm -f /tmp/weread-dev.env\n\1\2#" \
    -e "s#^\([[:space:]]*\)RETURN_VALUE=\\\$?\$#\1RETURN_VALUE=\$?\n\1[ -f /tmp/weread-reload ] \&\& rm -f /tmp/weread-reload \&\& RETURN_VALUE=85#" \
    "${APP}/run.sh.new"

grep -q "${APP}/main.lua" "${APP}/run.sh.new" || { echo "patch failed: entry"; exit 1; }
grep -q "configureClock 0" "${APP}/run.sh.new" || { echo "patch failed: clock off"; exit 1; }
grep -q "configureClock 1" "${APP}/run.sh.new" || { echo "patch failed: clock on"; exit 1; }
grep -q "weread-reload" "${APP}/run.sh.new" || { echo "patch failed: reload"; exit 1; }
grep -q "weread-dev.env" "${APP}/run.sh.new" || { echo "patch failed: dev env"; exit 1; }
grep -q "/var/tmp/weread-run.sh" "${APP}/run.sh.new" || { echo "patch failed: tmp copy"; exit 1; }
grep -q "dev-ssh.sh" "${APP}/run.sh.new" || { echo "patch failed: ssh"; exit 1; }
mv "${APP}/run.sh.new" "${APP}/run.sh"
chmod +x "${APP}/run.sh"
echo "run.sh generated"
