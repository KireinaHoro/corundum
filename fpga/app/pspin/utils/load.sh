#!/usr/bin/env bash

set -eu

RISCV="/opt/riscv"
TRIPLE="riscv32-unknown-elf"
OBJDUMP="$RISCV/bin/$TRIPLE-objdump"
OBJCOPY="$RISCV/bin/$TRIPLE-objcopy"
READELF="$RISCV/bin/$TRIPLE-readelf"

hex_to_dec() {
    echo "obase=10; ibase=16; ${1^^}" | bc
}

L2_BASE=$(hex_to_dec 1c000000)
PROG_BASE=$(hex_to_dec 1d000000)

DEV="/dev/pspin0"
# DEV="./test-mem"
REGS="/sys/devices/pci0000:00/0000:00:03.1/0000:1d:00.0/mqnic.app_12340100.0"
RESET="$REGS/cl_rst"
FETCH="$REGS/cl_fetch_en"

# $1: addr
addr_to_seek() {
    addr=$(hex_to_dec $1)
    if (( $addr >= $PROG_BASE )); then
        offset=$(($addr - $PROG_BASE + $(hex_to_dec 400000)))
    else
        offset=$(($addr - $L2_BASE))
    fi
    # bs=4
    echo $(($offset / 4))
}

padding="                    "
# $1: file name
# $2: section name
# $3: addr to load into
write_section() {
    tmpfile=$(mktemp /tmp/pspin-load.XXXXXX)
    seek=$(addr_to_seek $3)

    printf "Loading section %s%s to 0x$3 (pspin0 offset: %#x)...\n" "$2" "${padding:${#2}}" "$((seek*4))"
    $OBJCOPY -O binary --only-section="$2" "$1" "$tmpfile"
    dd if=$tmpfile of=$DEV bs=4 seek=$seek status=none
    sync; sync

    rm "$tmpfile"
}

if [[ $# != 1 ]]; then
    echo "usage: $0 <elf>"
    exit 1
fi

# cycle reset (mandated by kernel module)
echo Disabling fetch...
echo -n 0 > $FETCH
echo Resetting...
echo -n 1 > $RESET
echo Bringing cluster out of reset...
echo -n 0 > $RESET

# readelf -S ; sw/pulp-sdk/linker/link.ld
write_section $1 .rodata            1c000000
write_section $1 .l2_handler_data   1c0c0000
write_section $1 .vectors           1d000000
write_section $1 .text              1d000100

echo Enabling fetch...
# enable fetching - 2 clusters
echo -n 3 > $FETCH

echo All done!
