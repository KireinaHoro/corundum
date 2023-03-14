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

async def WithTimeout(action, timeout_ns=100):
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
        self.match_width = self.dut.UMATCH_WIDTH

        print(f'Rule Width: {self.match_width}; Rule Count: {self.dut.UMATCH_ENTRIES}')

        self.all_bypass()
        
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
        match_bytes = self.match_width.value // 8
        def match_single(ru: MatchRule):
            r = pkt[ru.idx:ru.idx+match_bytes]
            # big endian
            i = reduce(lambda acc, v: acc << 8 + v, r, 0)
            im = i & ru.mask
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
        assert len(self.rules) <= self.dut.UMATCH_ENTRIES, 'too many rules supplied'
        assert self.mode > 0 and self.mode < self.dut.UMATCH_MODES, 'unrecognised modes'

        self.dut.match_valid.value = 0
        # deassert valid to clear matching rule for at least one cycle
        await RisingEdge(self.dut.clk)

        concat_idx, concat_mask, concat_start, concat_end = 0, 0, 0, 0
        for ru in self.rules:
            concat_idx = (concat_idx << self.match_width) + ru.idx
            concat_mask = (concat_mask << self.match_width) + ru.mask
            concat_start = (concat_start << self.match_width) + ru.start
            concat_end = (concat_end << self.match_width) + ru.end
        self.dut.match_idx = concat_idx
        self.dut.match_mask = concat_mask
        self.dut.match_start = concat_start
        self.dut.match_end = concat_end
        
        # disable unused rules
        for idx in range(len(self.rules), self.dut.UMATCH_ENTRIES):
            self.dut.match_mask[idx] = 0
        
        self.dut.match_mode = self.mode
        
        self.dut.match_valid.value = 1
        # hold at least one cycle after setting matching rule
        await RisingEdge(self.dut.clk)

    async def push_pkt(self, pkt):
        frame = AxiStreamFrame(pkt)
        # not setting tid, tdest

        await self.pkt_src.send(frame)
        if self.match(pkt):
            sink = self.matched_sink
        else:
            sink = self.unmatched_sink
        out: AxiStreamFrame = await WithTimeout(sink.recv())

        assert frame == out, f'mismatched frame {frame} vs received {out}'


async def run_test_simple(dut):
    tb = TB(dut)
    await tb.cycle_reset()

    pkts = map(bytes, rdpcap('sample.pcap'))

    tb.all_bypass()
    for p in pkts:
        await tb.push_pkt(p)

    tb.all_match()
    for p in pkts:
        await tb.push_pkt(p)

async def run_test_complex(dut):
    tb = TB(dut)
    await tb.cycle_reset()

    pkts = map(bytes, rdpcap('sample.pcap'))

    tb.tcp_dportnum(22)
    for p in pkts:
        await tb.push_pkt(p)

    tb.tcp_or_udp()
    for p in pkts:
        await tb.push_pkt(p)

if cocotb.SIM_NAME:
    for test in [run_test_simple, run_test_complex]:
        factory = TestFactory(test)
        factory.generate_tests()