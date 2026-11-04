SHELL := /bin/sh

VERILATOR ?= verilator
QUARTUS_SH ?= quartus_sh
USB_AUDIO_RTL := \
	rtl/top/aces2_usb_audio_top.sv \
	rtl/top/de10_lite_reset_release.sv \
	rtl/top/de10_lite_status_leds.sv \
	rtl/top/de10_lite_usb_audio_pads.sv \
	rtl/top/usb_audio_fpga_subsystem.sv \
	rtl/usb/usb_audio_host_top.sv \
	rtl/usb/usb_isochronous_receiver.sv \
	rtl/usb/usb_control_transfer.sv \
	rtl/usb/usb_enumerator.sv \
	rtl/usb/usb_descriptor_parser.sv \
	rtl/usb/usb_host_engine.sv \
	rtl/usb/max3421e_controller.sv \
	rtl/usb/max3421e_spi_bridge.sv \
	rtl/usb/usb_pcm_decoder.sv \
	rtl/usb/audio_sample_buffer.sv \
	rtl/spi/spi_frame_encoder.sv \
	rtl/spi/spi.sv \
	rtl/spi/spi_uc.sv \
	third_party/spi-fpga-core/rtl/spi_master.sv \
	third_party/spi-fpga-core/rtl/spi_fifo.sv

.PHONY: help lint sim questa quartus quartus-core quartus-board

help:
	@printf '%s\n' \
	  'make lint    Verilator lint do top USB host e wrapper DE10-Lite' \
	  'make sim     Simulação Verilator (requer testbench)' \
	  'make questa  Simulação Questa/ModelSim (requer arquivos de simulação)' \
	  'make quartus-core  Compila o host USB standalone MAX 10' \
	  'make quartus-board Compila o wrapper USB Audio DE10-Lite' \
	  'make quartus       Compila core e wrapper (QUARTUS_SH=quartus_sh)'

lint:
	$(VERILATOR) --lint-only --timing docs/usb_host/verilator_lint.vlt --top-module usb_audio_host_top $(USB_AUDIO_RTL)
	$(VERILATOR) --lint-only --timing docs/usb_host/verilator_lint.vlt --top-module aces2_usb_audio_top $(USB_AUDIO_RTL)

sim:
	$(MAKE) -C tb sim

questa:
	@echo 'Projeto de simulação ainda não configurado; consulte docs/development.md.'

quartus-core:
	cd quartus/usb_host && $(QUARTUS_SH) --flow compile usb_host -c usb_host

quartus-board:
	cd quartus/de10_lite && $(QUARTUS_SH) --flow compile aces2_usb_audio -c aces2_usb_audio

quartus: quartus-core quartus-board
