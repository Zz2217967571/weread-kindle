section() { printf '\n== %s\n' "$1"; }

section "固件 / 内核"
cat /etc/prettyversion.txt 2>/dev/null
uname -a
cat /proc/version

section "CPU"
grep -E "model name|Processor|Hardware|Features|CPU architecture" /proc/cpuinfo | sort -u
grep -c ^processor /proc/cpuinfo

section "内存"
free
grep -E "MemTotal|MemFree|MemAvailable|Cached|SwapTotal|CmaTotal" /proc/meminfo
echo "-- 占内存最多的进程 (RSS KB)"
for p in /proc/[0-9]*; do
    rss=$(awk '/VmRSS/{print $2}' "$p/status" 2>/dev/null)
    [ -n "$rss" ] && echo "$rss $(tr '\0' ' ' < "$p/cmdline" 2>/dev/null | cut -c1-70)"
done | sort -rn | head -12

section "存储"
df -h / /mnt/us /var/local /tmp 2>/dev/null
mount | grep -E " / | /mnt/us | /var/local "

section "binder / ashmem"
ls -l /dev/binder* /dev/hwbinder /dev/vndbinder /dev/ashmem 2>&1
grep -iE "binder|ashmem" /proc/filesystems /proc/misc /proc/devices 2>/dev/null || echo "(proc 中没有 binder/ashmem)"

section "内核配置"
if [ -r /proc/config.gz ]; then
    zcat /proc/config.gz | grep -E "CONFIG_MODULES=|CONFIG_MODULE_SIG|CONFIG_ANDROID|CONFIG_ASHMEM|CONFIG_ION|CONFIG_STAGING=|CONFIG_NAMESPACES|CONFIG_(PID|NET|IPC|UTS|USER)_NS|CONFIG_CGROUPS=|CONFIG_SECCOMP|CONFIG_FHANDLE|CONFIG_SQUASHFS=|CONFIG_OVERLAY_FS|CONFIG_FUSE_FS|CONFIG_DEVTMPFS=|CONFIG_SW_SYNC|CONFIG_SYNC_FILE|CONFIG_MEMCG=|CONFIG_SWAP="
else
    echo "没有 /proc/config.gz"
fi

section "内核模块"
echo "-- 已加载"
lsmod 2>/dev/null || cat /proc/modules
echo "-- modules 目录"
ls /lib/modules/ 2>&1
ls /lib/modules/$(uname -r) 2>&1 | head -30
echo "-- 加载限制"
cat /proc/sys/kernel/modules_disabled 2>&1
cat /proc/sys/kernel/kptr_restrict 2>&1
grep -E " (init_module|finit_module|sys_init_module)$" /proc/kallsyms 2>/dev/null | head -3
echo "-- vermagic（自己编译的模块要匹配这个）"
for m in $(find /lib/modules -name '*.ko' 2>/dev/null | head -3); do
    modinfo "$m" 2>/dev/null | grep -E "vermagic|signer|sig_key" || strings "$m" | grep -m1 vermagic
done

section "其他"
which chroot unshare nsenter lxc-start busybox 2>/dev/null
ls /dev/fb* /dev/input/ 2>&1
cat /sys/class/graphics/fb0/virtual_size /sys/class/graphics/fb0/bits_per_pixel 2>/dev/null
