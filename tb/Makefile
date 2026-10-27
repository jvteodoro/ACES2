SHELL := /bin/sh

VERILATOR ?= verilator
BUILD_DIR := ../obj_dir
RTL_DIR := ../rtl

.PHONY: help sim reg reg_waves spi_uc spi spi_waves spi_uc_waves waves clean

help:
	@printf '%s\n' \
	  'make sim   Executa todas as simulações disponíveis' \
	  'make reg   Simula o registrador e gera mem/reg_tb.vcd' \
	  'make spi   Simula o adaptador SPI e gera spi/spi_tb.vcd' \
	  'make waves Abre as ondas do teste integrado SPI no GTKWave' \
	  'make clean Remove os artefatos gerados pelo Verilator'

sim: reg spi_uc spi

reg:
	$(VERILATOR) --binary --timing --trace --top-module reg_tb \
		--Mdir $(BUILD_DIR) $(RTL_DIR)/mem/reg.sv mem/reg_tb.sv
	(cd mem && ../../obj_dir/Vreg_tb)

spi_uc:
	$(VERILATOR) --binary --timing --trace -Wno-fatal --top-module spi_uc_tb \
		--Mdir $(BUILD_DIR)/spi_uc \
		$(RTL_DIR)/spi/spi_uc.sv spi/spi_uc_tb.sv
	(cd spi && ../../obj_dir/spi_uc/Vspi_uc_tb)

spi:
	$(VERILATOR) --binary --timing --trace -Wno-fatal --top-module spi_tb \
		--Mdir $(BUILD_DIR)/spi \
		$(RTL_DIR)/spi/spi.sv $(RTL_DIR)/spi/spi_uc.sv \
		../third_party/spi-fpga-core/rtl/spi_master.sv \
		../third_party/spi-fpga-core/rtl/spi_fifo.sv spi/spi_tb.sv
	(cd spi && ../../obj_dir/spi/Vspi_tb)

spi_waves: spi
	gtkwave -S spi/spi_tb.tcl spi/spi_tb.vcd

spi_uc_waves: spi_uc
	gtkwave -S spi/spi_uc_tb.tcl spi/spi_uc_tb.vcd

reg_waves: reg
	gtkwave -S mem/reg_tb.tcl mem/reg_tb.vcd

waves: spi_waves

clean:
	rm -rf $(BUILD_DIR)
