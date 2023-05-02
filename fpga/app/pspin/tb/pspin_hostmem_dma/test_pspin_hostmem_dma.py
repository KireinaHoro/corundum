import logging
import pytest
import os
from dataclasses import dataclass
from functools import reduce
from itertools import product
from itertools import cycle
from math import ceil
from random import randbytes
import operator

import cocotb
from cocotb_test.simulator import run
from cocotb.clock import Clock, Timer
from cocotb.triggers import RisingEdge, Edge, First, with_timeout
from cocotb.regression import TestFactory
from cocotbext.axi import AxiStreamSource, AxiStreamBus, AxiStreamFrame
from cocotbext.axi import AxiBus, AxiMaster
from cocotbext.axi.stream import define_stream

from dma_psdp_ram import PsdpRamRead, PsdpRamWrite, PsdpRamReadBus, PsdpRamWriteBus

from common import *

tests_dir = os.path.dirname(__file__)

DescBus, DescTransaction, DescSource, DescSink, DescMonitor = \
    define_stream("Desc",
                  signals=[
                      "dma_addr", "ram_sel", "ram_addr", "len", "tag", "valid", "ready"]
                  )

DescStatusBus, DescStatusTransaction, DescStatusSource, DescStatusSink, DescStatusMonitor = \
    define_stream("DescStatus",
                  signals=[
                      "tag", "error", "valid"]
                  )

class TB:
    def __init__(self, dut):
        self.dut = dut

        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(dut.clk, 2, units='ns').start())
        
        # AXI master
        self.axi_master = AxiMaster(AxiBus.from_prefix(dut, 's_axi'), dut.clk, dut.rstn, reset_active_level=False)

        # read datapath
        self.rd_desc_sink = DescSink(DescBus.from_prefix(
            dut, 'm_axis_read_desc'), dut.clk, dut.rstn, reset_active_level=False)
        self.rd_desc_status_source = DescStatusSource(DescStatusBus.from_prefix(
            dut, 's_axis_read_desc_status'), dut.clk, dut.rstn, reset_active_level=False)
        self.ram_rd = PsdpRamRead(PsdpRamReadBus.from_prefix(dut, 'ram'), dut.clk, dut.rstn, reset_active_level=False)

        # write datapath
        self.wr_desc_sink = DescSink(DescBus.from_prefix(
            dut, 'm_axis_write_desc'), dut.clk, dut.rstn, reset_active_level=False)
        self.wr_desc_status_source = DescStatusSource(DescStatusBus.from_prefix(
            dut, 's_axis_write_desc_status'), dut.clk, dut.rstn, reset_active_level=False)
        self.ram_wr = PsdpRamWrite(PsdpRamWriteBus.from_prefix(dut, 'ram'), dut.clk, dut.rstn, reset_active_level=False)

    def set_idle_generator(self, generator=None):
        if generator:
            self.rd_desc_status_source.set_pause_generator(generator())
            self.axi_master.write_if.aw_channel.set_pause_generator(generator())
            self.axi_master.write_if.w_channel.set_pause_generator(generator())
            self.axi_master.read_if.ar_channel.set_pause_generator(generator())
            self.ram_rd.set_pause_generator(generator())
            self.ram_wr.set_pause_generator(generator())

    def set_backpressure_generator(self, generator=None):
        if generator:
            self.axi_master.read_if.r_channel.set_pause_generator(generator())
            self.axi_master.write_if.b_channel.set_pause_generator(generator())

    async def cycle_reset(self):
        self.dut.rstn.setimmediatevalue(1)
        clk_edge = RisingEdge(self.dut.clk)
        await clk_edge
        await clk_edge
        self.dut.rstn.value = 0
        await clk_edge
        await clk_edge
        self.dut.rstn.value = 1
        await clk_edge
        await clk_edge


async def run_test_dma_read(dut, idle_inserter=None, backpressure_inserter=None):
    tb = TB(dut)
    await tb.cycle_reset()

    clk_edge = RisingEdge(tb.dut.clk)
    await clk_edge
    await clk_edge

    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    # test dummy addr and long-enough length
    addr = 0xdeadbeef00
    length = 256

    read_op = tb.axi_master.init_read(addr, length)
    desc = await tb.rd_desc_sink.recv()
    assert int(desc.dma_addr) == addr
    assert int(desc.len) >= length # should always read same or more than AXI request
    tb.log.info(f'Received DMA descriptor {desc}')

    ram_base_addr = 0
    data = b'Hello, world!'
    tb.ram_rd.write(ram_base_addr, data)
    tb.log.info('Dumping DMA read RAM:')
    tb.ram_rd.hexdump(0, 64, '')

    await clk_edge
    await clk_edge

    # send finish
    resp = DescStatusTransaction(tag=desc.tag, error=0)
    tb.log.info(f'Sending DMA completion {resp}')
    await tb.rd_desc_status_source.send(resp)

    await with_timeout(read_op.wait(), 100, 'ns')
    assert read_op.data == data
    
# TODO: test narrow burst
# TODO: test unaligned
# TODO: test error handling

def cycle_pause():
    # 1 cycle ready in 4 cycles
    return cycle([1, 1, 1, 0])


if cocotb.SIM_NAME:
    for test in [run_test_dma_read]:
        factory = TestFactory(test)
        factory.add_option('idle_inserter', [None, cycle_pause])
        factory.add_option('backpressure_inserter', [None, cycle_pause])
        factory.generate_tests()

# cocotb-test
'''
@pytest.mark.parametrize(
    ['matcher_len', 'buf_frames', 'data_width'],
    list(product([66, 2048], [0, 1, 2], [64, 512]))
)
def test_match_engine(request, matcher_len, buf_frames, data_width):
    dut = 'pspin_pkt_match'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    verilog_sources = [
        os.path.join(pspin_rtl, f'{dut}.v'),
        os.path.join(axis_lib_rtl, f'axis_fifo.v'),
    ]

    parameters = {}
    parameters['AXIS_IF_DATA_WIDTH'] = data_width
    parameters['UMATCH_MATCHER_LEN'] = matcher_len
    parameters['UMATCH_BUF_FRAMES'] = buf_frames

    extra_env = {f'PARAM_{k}': str(v) for k, v in parameters.items()}

    sim_build = os.path.join(tests_dir, 'sim_build',
        request.node.name.replace('[', '-').replace(']', ''))

    run(
        python_search=[tests_dir],
        verilog_sources=verilog_sources,
        toplevel=toplevel,
        module=module,
        parameters=parameters,
        sim_build=sim_build,
        extra_env=extra_env
    )
'''
