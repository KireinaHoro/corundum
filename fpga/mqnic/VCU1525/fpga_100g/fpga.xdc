# XDC constraints for the Xilinx VCU1525 board
# part: xcvu9p-fsgd2104-2L-e

# General configuration
set_property CFGBVS GND [current_design]
set_property CONFIG_VOLTAGE 1.8 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS true [current_design]
set_property BITSTREAM.CONFIG.CONFIGFALLBACK ENABLE [current_design]
set_property BITSTREAM.CONFIG.EXTMASTERCCLK_EN DISABLE [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 85.0 [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR YES [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES [current_design]
set_property BITSTREAM.CONFIG.UNUSEDPIN PULLUP [current_design]

# System clocks
# 300 MHz (DDR 0)
#set_property -dict {LOC AY37 IOSTANDARD LVDS} [get_ports clk_300mhz_0_p]
#set_property -dict {LOC AY38 IOSTANDARD LVDS} [get_ports clk_300mhz_0_n]
#create_clock -period 3.333 -name clk_300mhz_0 [get_ports clk_300mhz_0_p]

# 300 MHz (DDR 1)
#set_property -dict {LOC AW20 IOSTANDARD LVDS} [get_ports clk_300mhz_1_p]
#set_property -dict {LOC AW19 IOSTANDARD LVDS} [get_ports clk_300mhz_1_n]
#create_clock -period 3.333 -name clk_300mhz_1 [get_ports clk_300mhz_1_p]

# 300 MHz (DDR 2)
#set_property -dict {LOC F32  IOSTANDARD LVDS} [get_ports clk_300mhz_2_p]
#set_property -dict {LOC E32  IOSTANDARD LVDS} [get_ports clk_300mhz_2_n]
#create_clock -period 3.333 -name clk_300mhz_2 [get_ports clk_300mhz_2_p]

# 300 MHz (DDR 3)
#set_property -dict {LOC J16  IOSTANDARD LVDS} [get_ports clk_300mhz_3_p]
#set_property -dict {LOC H16  IOSTANDARD LVDS} [get_ports clk_300mhz_3_n]
#create_clock -period 3.333 -name clk_300mhz_3 [get_ports clk_300mhz_3_p]

# SI570 user clock
#set_property -dict {LOC AU19 IOSTANDARD LVDS} [get_ports clk_user_p]
#set_property -dict {LOC AV19 IOSTANDARD LVDS} [get_ports clk_user_n]
#create_clock -period 6.400 -name clk_user [get_ports clk_user_p]

# LEDs
set_property -dict {LOC BC21 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports {led[0]}]
set_property -dict {LOC BB21 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports {led[1]}]
set_property -dict {LOC BA20 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports {led[2]}]

set_false_path -to [get_ports {led[*]}]
set_output_delay 0.000 [get_ports {led[*]}]

# Reset button
#set_property -dict {LOC AL20 IOSTANDARD LVCMOS12} [get_ports reset]

#set_false_path -from [get_ports {reset}]
#set_input_delay 0 [get_ports {reset}]

# DIP switches
set_property -dict {LOC AN22 IOSTANDARD LVCMOS12} [get_ports {sw[0]}]
set_property -dict {LOC AM19 IOSTANDARD LVCMOS12} [get_ports {sw[1]}]
set_property -dict {LOC AL19 IOSTANDARD LVCMOS12} [get_ports {sw[2]}]
set_property -dict {LOC AP20 IOSTANDARD LVCMOS12} [get_ports {sw[3]}]

set_false_path -from [get_ports {sw[*]}]
set_input_delay 0.000 [get_ports {sw[*]}]

# UART
#set_property -dict {LOC BF18 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports uart_txd]
#set_property -dict {LOC BB20 IOSTANDARD LVCMOS12} [get_ports uart_rxd]

#set_false_path -to [get_ports {uart_txd}]
#set_output_delay 0 [get_ports {uart_txd}]
#set_false_path -from [get_ports {uart_rxd}]
#set_input_delay 0 [get_ports {uart_rxd}]

# QSFP28 Interfaces
set_property -dict {LOC N4} [get_ports qsfp0_rx1_p]
set_property -dict {LOC N3} [get_ports qsfp0_rx1_n]
set_property -dict {LOC N9} [get_ports qsfp0_tx1_p]
set_property -dict {LOC N8} [get_ports qsfp0_tx1_n]
set_property -dict {LOC M2} [get_ports qsfp0_rx2_p]
set_property -dict {LOC M1} [get_ports qsfp0_rx2_n]
set_property -dict {LOC M7} [get_ports qsfp0_tx2_p]
set_property -dict {LOC M6} [get_ports qsfp0_tx2_n]
set_property -dict {LOC L4} [get_ports qsfp0_rx3_p]
set_property -dict {LOC L3} [get_ports qsfp0_rx3_n]
set_property -dict {LOC L9} [get_ports qsfp0_tx3_p]
set_property -dict {LOC L8} [get_ports qsfp0_tx3_n]
set_property -dict {LOC K2} [get_ports qsfp0_rx4_p]
set_property -dict {LOC K1} [get_ports qsfp0_rx4_n]
set_property -dict {LOC K7} [get_ports qsfp0_tx4_p]
set_property -dict {LOC K6} [get_ports qsfp0_tx4_n]
#set_property -dict {LOC M11 } [get_ports qsfp0_mgt_refclk_0_p] ;# MGTREFCLK0P_231 from U14.4 via U43.13
#set_property -dict {LOC M10 } [get_ports qsfp0_mgt_refclk_0_n] ;# MGTREFCLK0N_231 from U14.5 via U43.14
set_property -dict {LOC K11} [get_ports qsfp0_mgt_refclk_1_p]
set_property -dict {LOC K10} [get_ports qsfp0_mgt_refclk_1_n]
set_property -dict {LOC BE16 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports qsfp0_modsell]
set_property -dict {LOC BE17 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports qsfp0_resetl]
set_property PACKAGE_PIN BE20 [get_ports qsfp0_modprsl]
set_property IOSTANDARD LVCMOS12 [get_ports qsfp0_modprsl]
set_property PULLUP true [get_ports qsfp0_modprsl]
set_property PACKAGE_PIN BE21 [get_ports qsfp0_intl]
set_property IOSTANDARD LVCMOS12 [get_ports qsfp0_intl]
set_property PULLUP true [get_ports qsfp0_intl]
set_property -dict {LOC BD18 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports qsfp0_lpmode]
set_property -dict {LOC AT22 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports qsfp0_refclk_reset]
set_property -dict {LOC AT20 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports {qsfp0_fs[0]}]
set_property -dict {LOC AU22 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports {qsfp0_fs[1]}]

# 156.25 MHz MGT reference clock (from SI570)
#create_clock -period 6.400 -name qsfp0_mgt_refclk_0 [get_ports qsfp0_mgt_refclk_0_p]

# 156.25 MHz MGT reference clock (from SI5335, FS = 0b01)
#create_clock -period 6.400 -name qsfp0_mgt_refclk_1 [get_ports qsfp0_mgt_refclk_1_p]

# 161.1328125 MHz MGT reference clock (from SI5335, FS = 0b10)
#create_clock -period 6.206 -name qsfp0_mgt_refclk_1 [get_ports qsfp0_mgt_refclk_1_p]

set_false_path -to [get_ports {qsfp0_modsell qsfp0_resetl qsfp0_lpmode qsfp0_refclk_reset {qsfp0_fs[*]}}]
set_output_delay 0.000 [get_ports {qsfp0_modsell qsfp0_resetl qsfp0_lpmode qsfp0_refclk_reset {qsfp0_fs[*]}}]
set_false_path -from [get_ports {qsfp0_modprsl qsfp0_intl}]
set_input_delay 0.000 [get_ports {qsfp0_modprsl qsfp0_intl}]

set_property -dict {LOC U4} [get_ports qsfp1_rx1_p]
set_property -dict {LOC U3} [get_ports qsfp1_rx1_n]
set_property -dict {LOC U9} [get_ports qsfp1_tx1_p]
set_property -dict {LOC U8} [get_ports qsfp1_tx1_n]
set_property -dict {LOC T2} [get_ports qsfp1_rx2_p]
set_property -dict {LOC T1} [get_ports qsfp1_rx2_n]
set_property -dict {LOC T7} [get_ports qsfp1_tx2_p]
set_property -dict {LOC T6} [get_ports qsfp1_tx2_n]
set_property -dict {LOC R4} [get_ports qsfp1_rx3_p]
set_property -dict {LOC R3} [get_ports qsfp1_rx3_n]
set_property -dict {LOC R9} [get_ports qsfp1_tx3_p]
set_property -dict {LOC R8} [get_ports qsfp1_tx3_n]
set_property -dict {LOC P2} [get_ports qsfp1_rx4_p]
set_property -dict {LOC P1} [get_ports qsfp1_rx4_n]
set_property -dict {LOC P7} [get_ports qsfp1_tx4_p]
set_property -dict {LOC P6} [get_ports qsfp1_tx4_n]
#set_property -dict {LOC T11 } [get_ports qsfp1_mgt_refclk_0_p] ;# MGTREFCLK0P_230 from U14.4 via U43.15
#set_property -dict {LOC T10 } [get_ports qsfp1_mgt_refclk_0_n] ;# MGTREFCLK0N_230 from U14.5 via U43.16
set_property -dict {LOC P11} [get_ports qsfp1_mgt_refclk_1_p]
set_property -dict {LOC P10} [get_ports qsfp1_mgt_refclk_1_n]
set_property -dict {LOC AY20 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports qsfp1_modsell]
set_property -dict {LOC BC18 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports qsfp1_resetl]
set_property PACKAGE_PIN BC19 [get_ports qsfp1_modprsl]
set_property IOSTANDARD LVCMOS12 [get_ports qsfp1_modprsl]
set_property PULLUP true [get_ports qsfp1_modprsl]
set_property PACKAGE_PIN AV21 [get_ports qsfp1_intl]
set_property IOSTANDARD LVCMOS12 [get_ports qsfp1_intl]
set_property PULLUP true [get_ports qsfp1_intl]
set_property -dict {LOC AV22 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports qsfp1_lpmode]
set_property -dict {LOC AR21 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports qsfp1_refclk_reset]
set_property -dict {LOC AR22 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports {qsfp1_fs[0]}]
set_property -dict {LOC AU20 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports {qsfp1_fs[1]}]

# 156.25 MHz MGT reference clock (from SI570)
#create_clock -period 6.400 -name qsfp1_mgt_refclk_0 [get_ports qsfp1_mgt_refclk_0_p]

# 156.25 MHz MGT reference clock (from SI5335, FS = 0b01)
#create_clock -period 6.400 -name qsfp1_mgt_refclk_1 [get_ports qsfp1_mgt_refclk_1_p]

# 161.1328125 MHz MGT reference clock (from SI5335, FS = 0b10)
#create_clock -period 6.206 -name qsfp1_mgt_refclk_1 [get_ports qsfp1_mgt_refclk_1_p]

set_false_path -to [get_ports {qsfp1_modsell qsfp1_resetl qsfp1_lpmode qsfp1_refclk_reset {qsfp1_fs[*]}}]
set_output_delay 0.000 [get_ports {qsfp1_modsell qsfp1_resetl qsfp1_lpmode qsfp1_refclk_reset {qsfp1_fs[*]}}]
set_false_path -from [get_ports {qsfp1_modprsl qsfp1_intl}]
set_input_delay 0.000 [get_ports {qsfp1_modprsl qsfp1_intl}]

# I2C interface
#set_property -dict {LOC BF19 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports i2c_mux_reset]
set_property -dict {LOC BF20 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports i2c_scl]
set_property -dict {LOC BF17 IOSTANDARD LVCMOS12 SLEW SLOW DRIVE 8} [get_ports i2c_sda]

set_false_path -to [get_ports {i2c_sda i2c_scl}]
set_output_delay 0.000 [get_ports {i2c_sda i2c_scl}]
set_false_path -from [get_ports {i2c_sda i2c_scl}]
set_input_delay 0.000 [get_ports {i2c_sda i2c_scl}]

# PCIe Interface
set_property -dict {LOC AF2} [get_ports {pcie_rx_p[0]}]
set_property -dict {LOC AF1} [get_ports {pcie_rx_n[0]}]
set_property -dict {LOC AF7} [get_ports {pcie_tx_p[0]}]
set_property -dict {LOC AF6} [get_ports {pcie_tx_n[0]}]
set_property -dict {LOC AG4} [get_ports {pcie_rx_p[1]}]
set_property -dict {LOC AG3} [get_ports {pcie_rx_n[1]}]
set_property -dict {LOC AG9} [get_ports {pcie_tx_p[1]}]
set_property -dict {LOC AG8} [get_ports {pcie_tx_n[1]}]
set_property -dict {LOC AH2} [get_ports {pcie_rx_p[2]}]
set_property -dict {LOC AH1} [get_ports {pcie_rx_n[2]}]
set_property -dict {LOC AH7} [get_ports {pcie_tx_p[2]}]
set_property -dict {LOC AH6} [get_ports {pcie_tx_n[2]}]
set_property -dict {LOC AJ4} [get_ports {pcie_rx_p[3]}]
set_property -dict {LOC AJ3} [get_ports {pcie_rx_n[3]}]
set_property -dict {LOC AJ9} [get_ports {pcie_tx_p[3]}]
set_property -dict {LOC AJ8} [get_ports {pcie_tx_n[3]}]
set_property -dict {LOC AK2} [get_ports {pcie_rx_p[4]}]
set_property -dict {LOC AK1} [get_ports {pcie_rx_n[4]}]
set_property -dict {LOC AK7} [get_ports {pcie_tx_p[4]}]
set_property -dict {LOC AK6} [get_ports {pcie_tx_n[4]}]
set_property -dict {LOC AL4} [get_ports {pcie_rx_p[5]}]
set_property -dict {LOC AL3} [get_ports {pcie_rx_n[5]}]
set_property -dict {LOC AL9} [get_ports {pcie_tx_p[5]}]
set_property -dict {LOC AL8} [get_ports {pcie_tx_n[5]}]
set_property -dict {LOC AM2} [get_ports {pcie_rx_p[6]}]
set_property -dict {LOC AM1} [get_ports {pcie_rx_n[6]}]
set_property -dict {LOC AM7} [get_ports {pcie_tx_p[6]}]
set_property -dict {LOC AM6} [get_ports {pcie_tx_n[6]}]
set_property -dict {LOC AN4} [get_ports {pcie_rx_p[7]}]
set_property -dict {LOC AN3} [get_ports {pcie_rx_n[7]}]
set_property -dict {LOC AN9} [get_ports {pcie_tx_p[7]}]
set_property -dict {LOC AN8} [get_ports {pcie_tx_n[7]}]
set_property -dict {LOC AP2} [get_ports {pcie_rx_p[8]}]
set_property -dict {LOC AP1} [get_ports {pcie_rx_n[8]}]
set_property -dict {LOC AP7} [get_ports {pcie_tx_p[8]}]
set_property -dict {LOC AP6} [get_ports {pcie_tx_n[8]}]
set_property -dict {LOC AR4} [get_ports {pcie_rx_p[9]}]
set_property -dict {LOC AR3} [get_ports {pcie_rx_n[9]}]
set_property -dict {LOC AR9} [get_ports {pcie_tx_p[9]}]
set_property -dict {LOC AR8} [get_ports {pcie_tx_n[9]}]
set_property -dict {LOC AT2} [get_ports {pcie_rx_p[10]}]
set_property -dict {LOC AT1} [get_ports {pcie_rx_n[10]}]
set_property -dict {LOC AT7} [get_ports {pcie_tx_p[10]}]
set_property -dict {LOC AT6} [get_ports {pcie_tx_n[10]}]
set_property -dict {LOC AU4} [get_ports {pcie_rx_p[11]}]
set_property -dict {LOC AU3} [get_ports {pcie_rx_n[11]}]
set_property -dict {LOC AU9} [get_ports {pcie_tx_p[11]}]
set_property -dict {LOC AU8} [get_ports {pcie_tx_n[11]}]
set_property -dict {LOC AV2} [get_ports {pcie_rx_p[12]}]
set_property -dict {LOC AV1} [get_ports {pcie_rx_n[12]}]
set_property -dict {LOC AV7} [get_ports {pcie_tx_p[12]}]
set_property -dict {LOC AV6} [get_ports {pcie_tx_n[12]}]
set_property -dict {LOC AW4} [get_ports {pcie_rx_p[13]}]
set_property -dict {LOC AW3} [get_ports {pcie_rx_n[13]}]
set_property -dict {LOC BB5} [get_ports {pcie_tx_p[13]}]
set_property -dict {LOC BB4} [get_ports {pcie_tx_n[13]}]
set_property -dict {LOC BA2} [get_ports {pcie_rx_p[14]}]
set_property -dict {LOC BA1} [get_ports {pcie_rx_n[14]}]
set_property -dict {LOC BD5} [get_ports {pcie_tx_p[14]}]
set_property -dict {LOC BD4} [get_ports {pcie_tx_n[14]}]
set_property -dict {LOC BC2} [get_ports {pcie_rx_p[15]}]
set_property -dict {LOC BC1} [get_ports {pcie_rx_n[15]}]
set_property -dict {LOC BF5} [get_ports {pcie_tx_p[15]}]
set_property -dict {LOC BF4} [get_ports {pcie_tx_n[15]}]
set_property -dict {LOC AM11} [get_ports pcie_refclk_p]
set_property -dict {LOC AM10} [get_ports pcie_refclk_n]
set_property PACKAGE_PIN BD21 [get_ports pcie_reset_n]
set_property IOSTANDARD LVCMOS12 [get_ports pcie_reset_n]
set_property PULLUP true [get_ports pcie_reset_n]

# 100 MHz MGT reference clock
create_clock -period 10.000 -name pcie_mgt_refclk_1 [get_ports pcie_refclk_p]

set_false_path -from [get_ports pcie_reset_n]
set_input_delay 0.000 [get_ports pcie_reset_n]

# reset from PCIe host for PsPIN
set_false_path -to [get_pins core_inst/core_inst/core_pcie_inst/core_inst/app.app_block_inst/i_pspin_rst/U0/EXT_LPF/ACTIVE_HIGH_AUX.ACT_HI_AUX/GENERATE_LEVEL_P_S_CDC.SINGLE_BIT.CROSS_PLEVEL_IN2SCNDRY_IN_cdc_to/D]

# timer hold
set_false_path -from [get_pins core_inst/core_inst/core_pcie_inst/core_inst/app.app_block_inst/i_pspin_clk_wiz/inst/mmcme4_adv_inst/CLKOUT0] -to [get_pins {core_inst/core_inst/core_pcie_inst/core_inst/app.app_block_inst/pspin_inst/i_pspin/gen_clusters[*].gen_cluster_sync.i_cluster/i_ooc/i_bound/cluster_peripherals_i/cluster_timer_wrap_i/timer_unit_i/s_ref_clk0_reg/D}]

