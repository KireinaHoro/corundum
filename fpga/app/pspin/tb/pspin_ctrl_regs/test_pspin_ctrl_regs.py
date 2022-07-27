import logging
import os
import itertools
from re import A
from tkinter import W
import cocotb, cocotb_test
import pytest
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge
from cocotb.regression import TestFactory

from cocotbext.axi import AxiLiteBus, AxiLiteMaster

class TB:
    def __init__(self, dut):
        self.dut = dut
        self.log = logging.getLogger('cocotb.tb')
        self.log.setLevel(logging.DEBUG)

        cocotb.start_soon(Clock(dut.clk, 2, units='ns').start())

        self.axil_master = AxiLiteMaster(AxiLiteBus.from_prefix(dut, 's_axil'), dut.clk, dut.rst)

    def set_idle_generator(self, generator=None):
        if generator:
            self.axil_master.write_if.aw_channel.set_pause_generator(generator())
            self.axil_master.write_if.w_channel.set_pause_generator(generator())
            self.axil_master.read_if.ar_channel.set_pause_generator(generator())

    def set_backpressure_generator(self, generator=None):
        if generator:
            self.axil_master.write_if.b_channel.set_pause_generator(generator())
            self.axil_master.read_if.r_channel.set_pause_generator(generator())

    async def cycle_reset(self):
        self.dut.rst.setimmediatevalue(0)
        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)
        self.dut.rst.value = 1
        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)
        self.dut.rst.value = 0
        await RisingEdge(self.dut.clk)
        await RisingEdge(self.dut.clk)

async def run_test_regs(dut, data_in=None, idle_inserter=None, backpressure_inserter=None):
    tb = TB(dut)
    await tb.cycle_reset()
    tb.set_idle_generator(idle_inserter)
    tb.set_backpressure_generator(backpressure_inserter)

    tb.log.info('Testing cluster enable reg')
    assert tb.dut.cl_fetch_en_o.value == 0b00, 'cluster enable reset value mismatch'

    await tb.axil_master.write_dword(0x0000, 0b11)
    assert tb.dut.cl_fetch_en_o.value == 0b11, 'cluster enable mismatch'
    await RisingEdge(dut.clk)

    await tb.axil_master.write_dword(0x0000, 0b00)
    assert tb.dut.cl_fetch_en_o.value == 0b00, 'cluster enable mismatch'
    await RisingEdge(dut.clk)

    tb.log.info('Testing reset reg')
    assert tb.dut.aux_rst_o.value == 0b1, 'aux rst reset value mismatch'
    
    await tb.axil_master.write_dword(0x0004, 0b0)
    assert tb.dut.aux_rst_o.value == 0b0, 'aux rst mismatch'
    await RisingEdge(dut.clk)

    await tb.axil_master.write_dword(0x0004, 0b1)
    assert tb.dut.aux_rst_o.value == 0b1, 'aux rst mismatch'
    await RisingEdge(dut.clk)

    await tb.axil_master.write_dword(0x0004, 0b0)
    assert tb.dut.aux_rst_o.value == 0b0, 'aux rst mismatch'
    await RisingEdge(dut.clk)

    tb.log.info('Testing status reg readout')
    tb.dut.cl_eoc_i.value = 0b10
    tb.dut.cl_busy_i.value = 0b11
    tb.dut.mpq_full_i.value = 0xdeadbeef_ffffffff_ffffffff_ffffffff_ffffffff_ffffffff_ffffffff_ffffffff
    assert await tb.axil_master.read_dword(0x0100) == 0b10
    assert await tb.axil_master.read_dword(0x0104) == 0b11
    assert await tb.axil_master.read_dwords(0x0108, 8) == [0xffffffff] * 7 + [0xdeadbeef]
    
    await RisingEdge(dut.clk)
    await RisingEdge(dut.clk)

def cycle_pause():
    return itertools.cycle([1, 1, 0, 0])

if cocotb.SIM_NAME:
    for test in [run_test_regs]:
        factory = TestFactory(test)
        factory.add_option('idle_inserter', [None, cycle_pause])
        factory.add_option('backpressure_inserter', [None, cycle_pause])
        factory.generate_tests()


# cocotb-test

tests_dir = os.path.dirname(__file__)
rtl_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'rtl'))
axi_dir = os.path.abspath(os.path.join(tests_dir, '..', '..', 'lib', 'axi', 'rtl'))

@pytest.mark.parametrize('data_width', [32])
def test_pspin_ctrl_regs(request, data_width):
    dut = 'pspin_ctrl_regs'
    module = os.path.splitext(os.path.basename(__file__))[0]
    toplevel = dut

    axi_deps = ['axil_reg_if', 'axil_reg_if_rd', 'axil_reg_if_wr']

    verilog_sources = [
        os.path.join(rtl_dir, f"{dut}.v"),
    ] + [os.path.join(axi_dir, f'{x}.v') for x in axi_deps]

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