
create_ip -name clk_wiz -vendor xilinx.com -library ip -module_name pspin_clk_wiz

set_property -dict [list \
    CONFIG.PRIM_IN_FREQ {250} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {50} \
    CONFIG.CLKIN1_JITTER_PS {40.0} \
    CONFIG.MMCM_DIVCLK_DIVIDE {5} \
    CONFIG.MMCM_CLKFBOUT_MULT_F {24.000} \
    CONFIG.MMCM_CLKIN1_PERIOD {4.000} \
    CONFIG.MMCM_CLKIN2_PERIOD {10.0} \
    CONFIG.MMCM_CLKOUT0_DIVIDE_F {24.000} \
    CONFIG.CLKOUT1_JITTER {153.164} \
    CONFIG.CLKOUT1_PHASE_ERROR {154.678}
] [get_ips pspin_clk_wiz]
