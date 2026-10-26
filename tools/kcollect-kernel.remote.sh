# 收集编译外部内核模块需要的设备信息，放到 /mnt/us/kcollect/。只读系统，不改设备。
OUT=/mnt/us/kcollect
rm -rf "$OUT"
mkdir -p "$OUT"
cd "$OUT"
uname -r >uname-r.txt
cat /proc/version >version.txt
# 内核配置，编出来的模块结构体布局要和它一致
cp /proc/config.gz config.gz 2>/dev/null
# 符号表：带 __crc_ 的就是 modversions 要校验的 CRC，其余用来查找未导出符号的地址
cat /proc/kallsyms >kallsyms.txt
cat /proc/modules >modules.txt
KM=/lib/modules/$(uname -r)
cp "$KM"/modules.* . 2>/dev/null
find "$KM" -name '*.ko' >ko-list.txt
# 拷几个现成模块，对照 vermagic 和 __versions 段
for m in $(grep -E "mxc_epdc|falcon|configfs|libcomposite" ko-list.txt | head -4); do cp "$m" .; done
# 容器和镜像要用到的
{
    echo "== loop"; ls -l /dev/loop* 2>&1; grep -w loop /proc/devices; cat /sys/module/loop/parameters/max_loop 2>&1
    echo "== filesystems"; cat /proc/filesystems
    echo "== cgroups"; cat /proc/cgroups; mount | grep cgroup
    echo "== fb0"; cat /sys/class/graphics/fb0/name /sys/class/graphics/fb0/modes /sys/class/graphics/fb0/stride 2>&1
    echo "== input"; for e in /sys/class/input/event*; do echo "$e $(cat $e/device/name 2>/dev/null)"; done
} >misc.txt 2>&1
sync
