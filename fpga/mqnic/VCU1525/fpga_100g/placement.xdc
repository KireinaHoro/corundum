# Placement constraints
#create_pblock pblock_slr0
#add_cells_to_pblock [get_pblocks pblock_slr0] [get_cells -quiet ""]
#resize_pblock [get_pblocks pblock_slr0] -add {SLR0}

create_pblock pblock_slr1
add_cells_to_pblock [get_pblocks pblock_slr1] [get_cells -quiet {core_inst/core_inst/core_pcie_inst/core_inst/iface[*].interface_inst/interface_rx_inst}]
add_cells_to_pblock [get_pblocks pblock_slr1] [get_cells -quiet {core_inst/core_inst/core_pcie_inst/core_inst/iface[*].interface_inst/interface_tx_inst}]
add_cells_to_pblock [get_pblocks pblock_slr1] [get_cells -quiet {core_inst/core_inst/core_pcie_inst/core_inst/iface[*].interface_inst/tx_fifo_inst}]
add_cells_to_pblock [get_pblocks pblock_slr1] [get_cells -quiet {core_inst/core_inst/core_pcie_inst/core_inst/iface[*].interface_inst/rx_fifo_inst}]
add_cells_to_pblock [get_pblocks pblock_slr1] [get_cells {core_inst/core_inst/core_pcie_inst/core_inst/dma_if_mux.dma_if_mux_ctrl_inst core_inst/core_inst/core_pcie_inst/core_inst/dma_if_mux.dma_if_mux_data_inst core_inst/core_inst/core_pcie_inst/core_inst/dma_if_mux_inst}]
resize_pblock [get_pblocks pblock_slr1] -add {SLR1}

#create_pblock pblock_slr2
#add_cells_to_pblock [get_pblocks pblock_slr2] [get_cells -quiet ""]
#resize_pblock [get_pblocks pblock_slr2] -add {SLR2}

set_property PARENT pblock_slr1 [get_pblocks pblock_pcie]
create_pblock pblock_pcie
add_cells_to_pblock [get_pblocks pblock_pcie] [get_cells -quiet [list core_inst/core_inst/core_pcie_inst/dma_if_pcie_inst core_inst/core_inst/core_pcie_inst/pcie_axil_master_inst core_inst/core_inst/pcie_if_inst pcie4_uscale_plus_inst]]
resize_pblock [get_pblocks pblock_pcie] -add {CLOCKREGION_X4Y5:CLOCKREGION_X5Y8}

create_pblock pblock_eth
add_cells_to_pblock [get_pblocks pblock_eth] [get_cells -quiet {core_inst/core_inst/core_pcie_inst/core_inst/iface[*].interface_inst/port[*].port_inst/port_tx_inst/tx_async_fifo_inst}]
add_cells_to_pblock [get_pblocks pblock_eth] [get_cells -quiet {core_inst/core_inst/core_pcie_inst/core_inst/iface[*].interface_inst/port[*].port_inst/port_rx_inst/rx_async_fifo_inst}]
add_cells_to_pblock [get_pblocks pblock_eth] [get_cells -quiet {core_inst/core_inst/core_pcie_inst/core_inst/iface[*].interface_inst/port[*].port_inst/port_tx_inst/tx_cpl_fifo_inst}]
add_cells_to_pblock [get_pblocks pblock_eth] [get_cells {qsfp0_cmac_pad_inst qsfp1_cmac_pad_inst}]
resize_pblock [get_pblocks pblock_eth] -add {CLOCKREGION_X0Y10:CLOCKREGION_X0Y14}


