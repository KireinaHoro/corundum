from ast import Assert
import logging
import os
import itertools
from re import A
from tkinter import W
import cocotb, cocotb_test
import pytest
from cocotb.clock import Clock, Timer
from cocotb.triggers import RisingEdge, Edge, First
from cocotb.regression import TestFactory

from cocotbext.axi import AxiLiteBus, AxiLiteMaster

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

class TB:
    def __init__(self, dut):
        self.dut = dut

        print(f'Buffer BUF_START {hex(int(self.dut.BUF_START))} BUF_SIZE {hex(int(self.dut.BUF_SIZE))}')
        
        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(dut.clk, 2, units='ns').start())

    async def cycle_reset(self):
        self.dut.write_ready_i.value = 1

        self.dut.rstn.setimmediatevalue(1)
        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)
        self.dut.rstn.value = 0
        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)
        self.dut.rstn.value = 1
        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)

    async def enqueue_pkt(self, size, timeout=1000):
        self.dut.pkt_len_i.value = size
        self.dut.pkt_valid_i.value = 1
        # make sure the beat had ready && valid and held for one cycle
        await RisingEdge(self.dut.clk)
        while self.dut.pkt_ready_o == 0 and timeout:
            await RisingEdge(self.dut.clk)
            timeout -= 1
        assert timeout > 0 or self.dut.pkt_ready_o.value == 1
        self.dut.pkt_valid_i.value = 0
        # do not advance clock such that we can allow lat=1 enqueue
    
    async def dequeue_addr(self, timeout=1000):
        await WithTimeout(Active(self.dut.write_ready_i), timeout_ns=timeout)
        # either packet is successfully allocated, or dropped
        allocated = cocotb.start_soon(WithTimeout(Active(self.dut.write_valid_o), timeout_ns=timeout))
        dropped = Edge(self.dut.dropped_pkts_o)
        result = await First(allocated, dropped)
        if result is dropped:
            allocated.kill()
            return -1, 0
        res = self.dut.write_addr_o.value, self.dut.write_len_o.value
        return res

    async def do_alloc(self, size, timeout=1000):
        await self.enqueue_pkt(size, timeout)
        addr, len = await self.dequeue_addr()
        assert int(len) >= size or not int(len)
        assert int(addr) + int(len) <= int(self.dut.BUF_START) + int(self.dut.BUF_SIZE)
        return addr, len

    async def do_free(self, addr, size, timeout=100):
        self.dut.feedback_her_size_i.value = size
        self.dut.feedback_her_addr_i.value = addr
        self.dut.feedback_valid_i.value = 1
        await RisingEdge(self.dut.clk)
        while self.dut.feedback_ready_o == 0 and timeout:
            await RisingEdge(self.dut.clk)
            timeout -= 1
        assert timeout > 0 or self.dut.feedback_ready_o.value == 1
        self.dut.feedback_valid_i.value = 0

    async def stall_dma(self, cycles):
        self.dut.write_ready_i.value = 0
        for _ in range(cycles):
            await RisingEdge(self.dut.clk)
        self.dut.write_ready_i.value = 1


async def run_test_alloc(dut, data_in=None, idle_inserter=None, backpressure_inserter=None, max_size=1518):
    tb = TB(dut)
    await tb.cycle_reset()

    for i in range(256):
        if i % 8 == 0:
            cocotb.start_soon(tb.stall_dma(4))
        req_len = 64 * (i+1) # over-sized packets
        addr, length = await tb.do_alloc(req_len)
        if req_len > round_align(max_size) and length:
            assert False, f'should have dropped oversized packet {req_len}, got addr={int(addr):#x} len={int(length)}'

async def run_test_overflow(dut, data_in=None, idle_inserter=None, backpressure_inserter=None, max_size=1518):
    tb = TB(dut)
    await tb.cycle_reset()
    
    # we have 128K space
    allocated = 0
    for i in range(128):
        try:
            addr, length = await tb.do_alloc(max_size, timeout=10)
        except AssertionError:
            # print('Allocation timed out')
            pass
        else:
            if allocated + max_size > tb.dut.BUF_SIZE.value:
                assert False, f'allocated {allocated} but BUF_SIZE {tb.dut.BUF_SIZE.value}; should fail'
            allocated += length

async def run_test_free(dut, data_in=None, idle_inserter=None, backpressure_inserter=None, max_size=1518):
    tb = TB(dut)
    await tb.cycle_reset()

    async def run_size(s):
        allocated = []
        # repeated alloc & free
        for _ in range(10):
            for i in range(32):
                allocated.append(await tb.do_alloc(s))
            for addr, size in allocated:
                await tb.do_free(addr, size)
            allocated = []

    await run_size(max_size)
    await run_size(120)

if cocotb.SIM_NAME:
    for test in [run_test_alloc, run_test_overflow, run_test_free]:
        factory = TestFactory(test)
        factory.generate_tests()


# cocotb-test

'''
tests_dir = os.path.dirname(__file__)
rtl_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'rtl'))
axi_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'lib', 'axi', 'rtl'))

@pytest.mark.parametrize('data_width', [32])
def test_pspin_pkt_alloc(request, data_width):
    dut = 'pspin_pkt_alloc'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(rtl_dir, f"{dut}.v"),
    ]

    parameters = {}

    parameters['DATA_WIDTH'] = data_width
    parameters['KEEP_WIDTH'] = parameters['DATA_WIDTH'] // 8

    extra_env = {f'PARAM_{k}': str(v) for k, v in parameters.items()}

    sim_build = os.path.join(tests_dir, "sim_build",
        request.node.name.replace('[', '-').replace(']', ''))

    cocotb_test.simulator.run(
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        toplevel=toplevel,
        module=module,
        parameters=parameters,
        sim_build=sim_build,
        extra_env=extra_env,
    )
'''