import cocotb
from cocotb.clock import Clock, Timer
from cocotb.triggers import RisingEdge, Edge, First

def round_align(number, multiple=64):
    return multiple * round(number / multiple)

async def Active(dut, signal):
    while signal.value != 1:
        await RisingEdge(dut.clk)

async def WithTimeout(action, timeout_ns=10000):
    # timeout
    timer = Timer(timeout_ns, 'ns')
    task = cocotb.start_soon(action)
    result = await First(task, timer)
    if result is timer:
        assert False, 'Timeout waiting for action'
    return result
