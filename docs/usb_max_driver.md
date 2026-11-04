# MAX3421E SPI bridge notes

`max3421e_spi_bridge` accepts one register request and preloads the command plus
all payload clocks into the SPI master TX FIFO before asserting CS. This keeps
CS low across the complete command and data phase. The command byte is formed
as `{req_addr_i, 1'b0, req_write_i, 1'b0}`. Payload byte zero is the low byte
of `req_wdata_i`; read transactions transmit zero dummy bytes. The first RX
byte (the command phase) is discarded, and data bytes are returned in the same
little indexed byte order.

The reused core is `third_party/spi-fpga-core/rtl/spi_master.sv`, configured for
8-bit mode 0, MSB first, divider zero, and two internal CS outputs to keep its
selector width legal. The selected physical output is CS[0]. Requests of 1 to
64 bytes are supported. Zero and overlength requests return `rsp_error_o`
without an SPI transaction. The response and error remain asserted until
`rsp_ready_i`.

Build and run the self-checking peripheral testbench with:

```sh
verilator --binary --timing -Wno-fatal --top-module max3421e_spi_bridge_tb \
  -Mdir /tmp/max3421e_spi_bridge_obj tb/usb/max3421e_spi_bridge_tb.sv \
  rtl/usb/max3421e_spi_bridge.sv \
  third_party/spi-fpga-core/rtl/spi_master.sv \
  third_party/spi-fpga-core/rtl/spi_fifo.sv
/tmp/max3421e_spi_bridge_obj/Vmax3421e_spi_bridge_tb
```

At a 50 MHz input clock, the core's divider-zero SCK is 25 MHz, a 40 ns SCK
period. The implementation first fills the FIFO, so time to first SCK also
includes request acceptance and `len+1` FIFO writes. A 64-byte burst transfers
65 SPI bytes (command plus payload), 1,040 system clocks / 20.8 us of wire time,
plus preload and FSM overhead. The current Verilator run measured
request-to-CS/request-to-response latencies of 6/50 cycles (0.12/1.00 us) for
one byte and 69/1,436 cycles (1.38/28.72 us) for 64 bytes. Exact command output
and hashes are saved in `docs/usb_host/results/protocol/bridge_current.txt`.
The 64-byte response latency is below the 42.667 us USB full-speed 64-byte
interval, leaving about 13.95 us for controller arbitration and additional
register operations.
This is a bridge-only measurement; it excludes USB transaction scheduling and
MAX3421E FIFO-drain work. MAX3421E's stated 26 MHz ceiling is respected.
