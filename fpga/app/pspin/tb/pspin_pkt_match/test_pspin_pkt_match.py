import logging
from dataclasses import dataclass
from functools import reduce
import operator

import cocotb, cocotb_test
from cocotb.clock import Clock, Timer
from cocotb.triggers import RisingEdge, Edge, First
from cocotb.regression import TestFactory
from cocotbext.axi import AxiStreamSource, AxiStreamSink, AxiStreamBus, AxiStreamFrame

# we only use the raw parser
from scapy.utils import rdpcap

def round_align(number, multiple=64):
    return multiple * round(number / multiple)

async def Active(signal):
    if signal.value != 1:
        await RisingEdge(signal)

async def WithTimeout(action, timeout_ns=500):
    # timeout
    timer = Timer(timeout_ns, 'ns')
    task = cocotb.start_soon(action)
    result = await First(task, timer)
    if result is timer:
        assert False, 'Timeout waiting for action'
    return result

@dataclass(frozen=True)
class MatchRule:
    idx: int
    mask: int
    start: int
    end: int

MODE_AND = 0
MODE_OR = 1

class TB:
    def __init__(self, dut):
        self.dut = dut
        self.match_width = self.dut.UMATCH_WIDTH.value
        self.match_count = self.dut.UMATCH_ENTRIES.value
        self.match_modes = self.dut.UMATCH_MODES.value

        print(f'Rule Width: {self.match_width}; Rule Count: {self.match_count}')

        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(dut.clk, 2, units='ns').start())

        self.pkt_src = AxiStreamSource(AxiStreamBus.from_prefix(dut, 's_axis_nic_rx'),
                                       dut.clk, dut.rstn, reset_active_level=False)
        self.unmatched_sink = AxiStreamSink(AxiStreamBus.from_prefix(dut, 'm_axis_nic_rx'),
                                            dut.clk, dut.rstn, reset_active_level=False)
        self.matched_sink = AxiStreamSink(AxiStreamBus.from_prefix(dut, 'm_axis_pspin_rx'),
                                          dut.clk, dut.rstn, reset_active_level=False)

    # ruleset generation
    def all_match(self):
        self.rules = []
        self.mode = MODE_AND
    def all_bypass(self):
        self.rules = []
        self.mode = MODE_OR
    def tcp_dportnum(self, dport):
        assert self.match_width == 32, 'only support 32-bit match atm'
        self.rules = [
            MatchRule(5, 0xff, 0x06, 0x06), # proto == TCP
            MatchRule(9, 0xffff0000, dport << 16, dport << 16), # dport
        ]
        self.mode = MODE_AND
    def tcp_or_udp(self):
        assert self.match_width == 32, 'only support 32-bit match atm'
        self.rules = [
            MatchRule(5, 0xff, 0x06, 0x06), # proto == TCP
            MatchRule(5, 0xff, 0x11, 0x11), # proto == UDP
        ]
        self.mode = MODE_OR

    # match packet with ruleset
    def match(self, pkt: bytes):
        print(f'Current rule {self.rules}, mode {self.mode}')

        match_bytes = self.match_width // 8
        def match_single(ru: MatchRule):
            r = pkt[ru.idx*match_bytes:ru.idx*match_bytes+match_bytes]
            # big endian
            i = reduce(lambda acc, v: (acc << 8) + v, r, 0)
            im = i & ru.mask
            print(f'i={i:#x}\tim={im:#x}\tru.start={ru.start:#x}\tru.end={ru.end:#x}')
            return ru.start <= im and im <= ru.end
        results = map(match_single, self.rules)
        if self.mode == MODE_AND:
            return reduce(operator.and_, results, True)
        elif self.mode == MODE_OR:
            return reduce(operator.or_, results, False)
        else:
            raise ValueError(f'unknown matching mode {self.mode}')

    async def cycle_reset(self):
        self.dut.rstn.setimmediatevalue(1)
        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)
        self.dut.rstn.value = 0
        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)
        self.dut.rstn.value = 1
        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)

    async def set_rule(self):
        assert len(self.rules) <= self.match_count, 'too many rules supplied'
        assert self.mode >= 0 and self.mode < self.match_modes, \
            'unrecognised mode %d' % self.mode

        print(f'Setting rule {self.rules}, mode {self.mode}')

        self.dut.match_valid.value = 0
        # deassert valid to clear matching rule for at least one cycle
        await RisingEdge(self.dut.clk)

        concat_idx, concat_mask, concat_start, concat_end = 0, 0, 0, 0
        for ru in self.rules:
            concat_idx = (concat_idx << self.match_width) + ru.idx
            concat_mask = (concat_mask << self.match_width) + ru.mask
            concat_start = (concat_start << self.match_width) + ru.start
            concat_end = (concat_end << self.match_width) + ru.end
        self.dut.match_idx.value = concat_idx
        self.dut.match_mask.value = concat_mask
        self.dut.match_start.value = concat_start
        self.dut.match_end.value = concat_end
        
        # disable unused rules
        for idx in range(len(self.rules), self.match_count):
            self.dut.match_mask[idx].value = 0
        
        self.dut.match_mode.value = self.mode
        
        self.dut.match_valid.value = 1
        # hold at least one cycle after setting matching rule
        await RisingEdge(self.dut.clk)

    async def push_pkt(self, pkt):
        frame = AxiStreamFrame(pkt)
        # not setting tid, tdest

        await self.pkt_src.send(frame)
        if self.match(pkt):
            print('Packet matches')
            sink = self.matched_sink
        else:
            print('Packet does not match')
            sink = self.unmatched_sink
        out: AxiStreamFrame = await WithTimeout(sink.recv())

        assert frame == out, f'mismatched frame {frame} vs received {out}'

def load_packets(limit=None):
    if hasattr(load_packets, 'pkts'):
        return load_packets.pkts[:limit]
    else:
        load_packets.pkts = list(map(bytes, rdpcap('sample.pcap')))
        return load_packets(limit)

async def run_test_all_bypass(dut):
    tb = TB(dut)
    await tb.cycle_reset()

    pkts = load_packets(10)

    tb.all_bypass()
    await tb.set_rule()
    for p in pkts:
        await tb.push_pkt(p)

async def run_test_all_match(dut):
    tb = TB(dut)
    await tb.cycle_reset()

    pkts = load_packets(10)

    tb.all_match()
    await tb.set_rule()
    for p in pkts:
        await tb.push_pkt(p)

async def run_test_switch_rule(dut):
    tb = TB(dut)
    await tb.cycle_reset()

    pkts = load_packets(10)

    tb.all_bypass()
    await tb.set_rule()
    for p in pkts:
        await tb.push_pkt(p)

    tb.all_match()
    await tb.set_rule()
    for p in pkts:
        await tb.push_pkt(p)

async def run_test_tcp_dport(dut):
    tb = TB(dut)
    await tb.cycle_reset()

    pkts = load_packets()

    tb.tcp_dportnum(22)
    await tb.set_rule()
    for p in pkts:
        await tb.push_pkt(p)

async def run_test_tcp_and_udp(dut):
    tb = TB(dut)
    await tb.cycle_reset()

    pkts = load_packets()

    tb.tcp_or_udp()
    await tb.set_rule()
    for p in pkts:
        await tb.push_pkt(p)

if cocotb.SIM_NAME:
    for test in [run_test_all_bypass, run_test_all_match, run_test_switch_rule, run_test_tcp_dport, run_test_tcp_and_udp]:
        factory = TestFactory(test)
        factory.generate_tests()