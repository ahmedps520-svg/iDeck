#!/bin/busybox sh
# /init of the engine test initramfs (engine/run_guest_tests.py).
# Runs the static test binaries on the serial console and powers off.
# Sections are framed with @@BEGIN / @@END lines for the host to cut out.
B=/bin/busybox
$B mkdir -p /dev /proc /sys /tmp
$B mount -t devtmpfs devtmpfs /dev
$B mount -t proc proc /proc
$B mount -t sysfs sysfs /sys
exec >/dev/console 2>&1 </dev/console

section() {
    name="$1"
    shift
    echo "@@BEGIN $name"
    "$@"
    echo "@@END $name $?"
}

echo "@@BEGIN cpuinfo"
$B grep -m1 Features /proc/cpuinfo
$B grep -c ^processor /proc/cpuinfo
echo "@@END cpuinfo 0"

# fpdump=NAME[,NAME...] on the kernel command line: dump those patterns.
dumps=$($B sed -n "s/.*fpdump=\([^ ]*\).*/\1/p" /proc/cmdline | $B tr "," " ")
for name in $dumps; do
    section "dump-$name" /ideck-fpcheck --dump "$name"
done

if ! $B grep -q "nofpcheck" /proc/cmdline; then
    section fpcheck /ideck-fpcheck
fi
if ! $B grep -q "nobench" /proc/cmdline; then
    section bench /ideck-bench --json
fi

echo "@@DONE"
$B sync
$B poweroff -f
