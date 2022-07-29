# XDC constraints for floorplanning PsPIN on VCU1525

create_pblock pblock_cluster_0
add_cells_to_pblock [get_pblocks pblock_cluster_0] [get_cells -quiet [list {core_inst/core_inst/core_pcie_inst/core_inst/app.app_block_inst/pspin_inst/i_pspin/gen_clusters[0].gen_cluster_sync.i_cluster}]]
resize_pblock [get_pblocks pblock_cluster_0] -add {SLR1}
create_pblock pblock_cluster_1
add_cells_to_pblock [get_pblocks pblock_cluster_1] [get_cells -quiet [list {core_inst/core_inst/core_pcie_inst/core_inst/app.app_block_inst/pspin_inst/i_pspin/gen_clusters[1].gen_cluster_sync.i_cluster}]]
resize_pblock [get_pblocks pblock_cluster_1] -add {SLR2}
