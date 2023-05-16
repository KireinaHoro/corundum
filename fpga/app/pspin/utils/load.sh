#!/usr/bin/env bash

set -eu

die() {
    echo "$@" >&2
    exit 1
}

RISCV="/opt/riscv"
TRIPLE="riscv32-unknown-elf"
OBJDUMP="$RISCV/bin/$TRIPLE-objdump"
OBJCOPY="$RISCV/bin/$TRIPLE-objcopy"
READELF="$RISCV/bin/$TRIPLE-readelf"
NM="$RISCV/bin/$TRIPLE-nm"

hex_to_dec() {
    echo "obase=10; ibase=16; ${1^^}" | bc
}

hex_to_dec_be() {
    padded=$(printf "%08x" 0x$1)
    # https://stackoverflow.com/a/39564881/5520728
    hex_to_dec $(echo $padded | tac -rs ..)
}

L2_BASE=$(hex_to_dec 1c000000)
L2_END=$(hex_to_dec 1c100000)
PROG_BASE=$(hex_to_dec 1d000000)

DEV="/dev/pspin0"
# DEV="./test-mem"
REGS="/sys/devices/pci0000:00/0000:00:03.1/0000:1d:00.0/mqnic.app_12340100.0"
RESET="$REGS/cl_ctrl/1"
FETCH="$REGS/cl_ctrl/0"

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

get_handler() {
    addr_str=$($NM $1 | grep _$2 | cut -f 1 -d ' ')
    if [[ -z "$addr_str" ]]; then
        handler_addr=0
        handler_size=0
    else
        handler_addr=$(hex_to_dec $addr_str)
        # FIXME: this is arbitrary and will not work once we have PMP for handlers
        handler_size=4096
    fi
}

do_rule() {
    echo -n $2 > "$REGS/me_idx/$1"
    # match registers are BE
    echo -n $(hex_to_dec_be $3) > "$REGS/me_mask/$1"
    echo -n $(hex_to_dec_be $4) > "$REGS/me_start/$1"
    echo -n $(hex_to_dec_be $5) > "$REGS/me_end/$1"
}

rule_false() {
    do_rule $1 0 0 1 0
}

rule_empty() {
    do_rule $1 0 0 0 0
}

bypass_ruleset() {
    echo Setting all bypass ME rule in ruleset $1...
    base=$(($1 * 4))
    for ((idx = $base; idx < $(($base+4)); idx++)); do
        rule_false $idx
    done
    echo -n 0 > "$REGS/me_mode/$1" # MODE_AND
}

match_ruleset() {
    echo Setting all match ME rule in ruleset $1...
    base=$(($1 * 4))
    for ((idx = $base; idx < $(($base+4)); idx++)); do
        rule_empty $idx
    done
    echo -n 0 > "$REGS/me_mode/$1" # MODE_AND
}

udp_ruleset() {
    echo Setting match UDP rule in ruleset $1...
    base=$(($1 * 4))
    do_rule $base 3 ffff0000 08000000 08000000 # IPv4
    do_rule $(($base+1)) 5 ff 11 11 # UDP
    rule_empty $(($base+2))
    rule_false $(($base+3)) # never EOM
    echo -n 0 > "$REGS/me_mode/$1" # MODE_AND
}

ctx_id=$1
cmd=$2

usage="usage: $0 <ctx id> <up|down> [<elf> <hostmem addr hi> <hostmem addr lo> <hostmem size>]"

[[ $# -ge 2 ]] || die $usage

if [[ "$cmd" == "down" ]]; then
    # disable HER context
    echo Disabling HER context $ctx_id...
    echo -n 0 > "$REGS/her_valid/0"
    echo -n 0 > "$REGS/her_ctx_enabled/$ctx_id"
    echo -n 1 > "$REGS/her_valid/0"
    echo Done!
    exit 0
elif [[ "$cmd" != up ]]; then
    die "Action must be one of {up, down}"
fi

[[ $# == 6 ]] || die $usage
elf=$3
hostmem_hi=$4
hostmem_lo=$5
hostmem_sz=$6

# cycle reset (mandated by kernel module)
echo Disabling fetch...
echo -n 0 > $FETCH
echo Resetting...
echo -n 1 > $RESET
echo Bringing cluster out of reset...
echo -n 0 > $RESET

# readelf -S ; sw/pulp-sdk/linker/link.ld
write_section $elf .rodata            1c000000
write_section $elf .l2_handler_data   1c0c0000
write_section $elf .vectors           1d000000
write_section $elf .text              1d000100

echo Enabling fetch...
# enable fetching - 2 clusters
echo -n 3 > $FETCH

echo -n 0 > "$REGS/me_valid/0"
udp_ruleset $ctx_id
# match_ruleset 0
# bypass_ruleset 0
# bypass_ruleset 1
# bypass_ruleset 2
# bypass_ruleset 3
echo -n 1 > "$REGS/me_valid/0"
# TODO: set all match rule

echo Setting HER generator...
echo -n 0 > "$REGS/her_valid/0"

get_handler $elf hh
printf "HH @ %#x\t(size %d)\n" $handler_addr $handler_size
echo -n $handler_addr > "$REGS/her_hh_addr/$ctx_id"
echo -n $handler_size > "$REGS/her_hh_size/$ctx_id"
get_handler $elf ph
printf "PH @ %#x\t(size %d)\n" $handler_addr $handler_size
echo -n $handler_addr > "$REGS/her_ph_addr/$ctx_id"
echo -n $handler_size > "$REGS/her_ph_size/$ctx_id"
get_handler $elf th
printf "TH @ %#x\t(size %d)\n" $handler_addr $handler_size
echo -n $handler_addr > "$REGS/her_th_addr/$ctx_id"
echo -n $handler_size > "$REGS/her_th_size/$ctx_id"

echo -n 1 > "$REGS/her_ctx_enabled/$ctx_id"

# end of l2_handler_data is her_handler_mem_addr
l2_hnd_data_section=$($READELF -S $elf | grep l2_handler_data | tr -s ' ')
l2_hnd_data_addr=$(hex_to_dec $(cut -d ' ' -f 5 <<< "$l2_hnd_data_section"))
l2_hnd_data_size=$(hex_to_dec $(cut -d ' ' -f 7 <<< "$l2_hnd_data_section"))

her_handler_mem_addr=$(($l2_hnd_data_addr + $l2_hnd_data_size))
her_handler_mem_size=$(($L2_END - $her_handler_mem_addr))

printf "HER handler mem addr: %#x\n" $her_handler_mem_addr
printf "HER handler mem size: %#x\n" $her_handler_mem_size

echo -n $her_handler_mem_addr > "$REGS/her_handler_mem_addr/$ctx_id"
echo -n $her_handler_mem_size > "$REGS/her_handler_mem_size/$ctx_id"

# TODO: scratchpad

printf "HER host mem hi: %#x\n" $hostmem_hi
printf "HER host mem lo: %#x\n" $hostmem_lo
printf "HER host mem size: %#x\n" $hostmem_sz

echo -n $hostmem_hi > "$REGS/her_host_mem_addr_hi/$ctx_id"
echo -n $hostmem_lo > "$REGS/her_host_mem_addr_lo/$ctx_id"
echo -n $hostmem_sz > "$REGS/her_host_mem_size/$ctx_id"

echo -n 1 > "$REGS/her_valid/0"

echo All done!
