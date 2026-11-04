SHELL := /bin/bash
VERILATOR ?= verilator
ROOT := ../..
BUILD := $(abspath $(ROOT)/obj_dir/usb)
SPI := $(ROOT)/third_party/spi-fpga-core/rtl/spi_master.sv $(ROOT)/third_party/spi-fpga-core/rtl/spi_fifo.sv

.PHONY: all bridge pcm buffer pcm_path descriptors parser enumerator control engine enumeration_path iso recovery board board_long board_build
all: descriptors bridge pcm buffer pcm_path parser enumerator control engine enumeration_path iso recovery board

descriptors:
	cd $(ROOT) && python3 -m unittest discover -s hardware/um2/scripts -p 'test_*.py' -v

bridge:
	mkdir -p $(BUILD)/bridge
	$(VERILATOR) --binary --timing -Wno-fatal --top-module max3421e_spi_bridge_tb \
	  --Mdir $(BUILD)/bridge $(ROOT)/rtl/usb/max3421e_spi_bridge.sv $(SPI) max3421e_spi_bridge_tb.sv
	$(BUILD)/bridge/Vmax3421e_spi_bridge_tb

pcm:
	mkdir -p $(BUILD)/pcm
	$(VERILATOR) --binary --timing -Wno-fatal --top-module usb_pcm_decoder_tb \
	  --Mdir $(BUILD)/pcm $(ROOT)/rtl/usb/usb_pcm_decoder.sv usb_pcm_decoder_tb.sv
	$(BUILD)/pcm/Vusb_pcm_decoder_tb

buffer:
	mkdir -p $(BUILD)/buffer
	$(VERILATOR) --binary --timing -Wno-fatal --top-module audio_sample_buffer_tb \
	  --Mdir $(BUILD)/buffer $(ROOT)/rtl/usb/audio_sample_buffer.sv audio_sample_buffer_tb.sv
	$(BUILD)/buffer/Vaudio_sample_buffer_tb

pcm_path:
	mkdir -p $(BUILD)/pcm_path
	$(VERILATOR) --binary --timing -Wno-fatal --top-module usb_pcm_path_tb \
	  --Mdir $(BUILD)/pcm_path $(ROOT)/rtl/usb/usb_pcm_decoder.sv \
	  $(ROOT)/rtl/usb/audio_sample_buffer.sv usb_pcm_path_tb.sv
	$(BUILD)/pcm_path/Vusb_pcm_path_tb

parser:
	mkdir -p $(BUILD)/parser
	$(VERILATOR) --binary --timing -Wno-fatal --top-module usb_descriptor_parser_tb \
	  --Mdir $(BUILD)/parser $(ROOT)/rtl/usb/usb_descriptor_parser.sv usb_descriptor_parser_tb.sv
	cd $(ROOT) && $(BUILD)/parser/Vusb_descriptor_parser_tb

enumerator:
	mkdir -p $(BUILD)/enumerator
	$(VERILATOR) --binary --timing -Wno-fatal --top-module usb_enumerator_tb \
	  --Mdir $(BUILD)/enumerator $(ROOT)/rtl/usb/usb_descriptor_parser.sv \
	  $(ROOT)/rtl/usb/usb_enumerator.sv usb_enumerator_tb.sv
	cd $(ROOT) && $(BUILD)/enumerator/Vusb_enumerator_tb

control:
	mkdir -p $(BUILD)/control
	$(VERILATOR) --binary --timing -Wno-fatal --top-module usb_control_transfer_tb \
	  --Mdir $(BUILD)/control $(ROOT)/rtl/usb/usb_control_transfer.sv usb_control_transfer_tb.sv
	cd $(ROOT) && timeout 30s $(BUILD)/control/Vusb_control_transfer_tb

engine:
	mkdir -p $(BUILD)/engine
	$(VERILATOR) --binary --timing -Wno-fatal --top-module usb_host_engine_tb \
	  --Mdir $(BUILD)/engine $(ROOT)/rtl/usb/usb_host_engine.sv \
	  $(ROOT)/rtl/usb/max3421e_controller.sv $(ROOT)/rtl/usb/max3421e_spi_bridge.sv \
	  $(SPI) usb_host_engine_tb.sv
	cd $(ROOT) && timeout 30s $(BUILD)/engine/Vusb_host_engine_tb

enumeration_path:
	mkdir -p $(BUILD)/enumeration_path
	$(VERILATOR) --binary --timing -Wno-fatal --top-module usb_enumeration_path_tb \
	  --Mdir $(BUILD)/enumeration_path $(ROOT)/rtl/usb/usb_enumerator.sv \
	  $(ROOT)/rtl/usb/usb_descriptor_parser.sv $(ROOT)/rtl/usb/usb_control_transfer.sv \
	  usb_enumeration_path_tb.sv
	cd $(ROOT) && timeout 30s $(BUILD)/enumeration_path/Vusb_enumeration_path_tb

iso:
	mkdir -p $(BUILD)/iso
	$(VERILATOR) --binary --timing -Wno-fatal --top-module usb_isochronous_receiver_tb \
	  --Mdir $(BUILD)/iso $(ROOT)/rtl/usb/usb_isochronous_receiver.sv usb_isochronous_receiver_tb.sv
	cd $(ROOT) && timeout 30s $(BUILD)/iso/Vusb_isochronous_receiver_tb

recovery:
	mkdir -p $(BUILD)/recovery
	$(VERILATOR) --binary --timing -Wno-fatal --top-module max3421e_controller_recovery_tb \
	  --Mdir $(BUILD)/recovery $(ROOT)/rtl/usb/usb_host_engine.sv \
	  $(ROOT)/rtl/usb/max3421e_controller.sv $(ROOT)/rtl/usb/max3421e_spi_bridge.sv \
	  $(SPI) max3421e_controller_recovery_tb.sv
	cd $(ROOT) && timeout 30s $(BUILD)/recovery/Vmax3421e_controller_recovery_tb

board_build:
	mkdir -p $(BUILD)/board
	$(VERILATOR) --binary --timing -Wno-fatal --top-module aces2_usb_audio_top_tb \
	  --Mdir $(BUILD)/board $(wildcard $(ROOT)/rtl/usb/*.sv) \
	  $(ROOT)/tb/usb/models/max3421e_um2_model.sv \
	  $(ROOT)/rtl/top/aces2_usb_audio_top.sv \
	  $(ROOT)/rtl/top/de10_lite_reset_release.sv \
	  $(ROOT)/rtl/top/de10_lite_status_leds.sv \
	  $(ROOT)/rtl/top/de10_lite_usb_audio_pads.sv \
	  $(ROOT)/rtl/top/usb_audio_fpga_subsystem.sv \
	  $(ROOT)/rtl/spi/spi.sv \
	  $(ROOT)/rtl/spi/spi_uc.sv $(ROOT)/rtl/spi/spi_frame_encoder.sv $(SPI) \
	  aces2_usb_audio_top_tb.sv

board: board_build
	cd $(ROOT) && timeout 30s $(BUILD)/board/Vaces2_usb_audio_top_tb

# Optional ~1 s synthetic 48 kHz stream, captured at the physical ESP GPIO pins.
board_long: board_build
	cd $(ROOT) && timeout 1800s $(BUILD)/board/Vaces2_usb_audio_top_tb +LONG_RUN
