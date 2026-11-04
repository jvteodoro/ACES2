# ESP32 classic SPI slave notes

Primary source: Espressif, *ESP-IDF Programming Guide v6.1 — SPI Slave Driver*:
<https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-reference/peripherals/spi_slave.html>

Supplemental hardware reference: Espressif, *ESP32 Technical Reference Manual
v5.2*, Chapter 7, SPI Controller:
<https://www.espressif.com/sites/default/files/documentation/esp32_technical_reference_manual_en.pdf>

Consulted for the classic ESP32 SPI3 slave in the FPGA audio link. The project
uses ESP-IDF 6.1.0. Physical characterization of the final settings is recorded
in [`../esp32_spi_audio_postmortem.md`](../esp32_spi_audio_postmortem.md).

## Relevant guidance and project configuration

- The guide describes the classic ESP32 SPI slave as designed for SCLK up to
  10 MHz. Faster clocks or a non-50% duty cycle can cause receive errors. The
  FPGA project now uses 5 MHz: `50 MHz / (2 × (4 + 1))`.
- A SPI transaction is bounded by the host's CS and clock. The returned
  `spi_slave_transaction_t::trans_len` reports the actual number of bits; the
  configured `length` only sets receive-buffer capacity.
- The guide supports transactions up to 64 bytes without DMA and recommends
  selecting DMA for transfers longer than 32 bytes. The ACES2 frame is exactly
  64 bytes, so the final configuration uses DMA. DMA RX buffers must be
  word-aligned and a multiple of four bytes; the frame buffer satisfies both.
- For classic ESP32 DMA, the guide discusses mode 1 and 3 timing. The final
  FPGA and ESP32 are both configured for mode 1 (`CPOL=0`, `CPHA=1`). The
  intermediate mixed configuration (FPGA mode 1, ESP32 mode 0) was incorrect
  and was corrected before final validation.
- The SPI ISR runs on the CPU core that initializes the SPI slave unless an
  affinity is set. This firmware assigns it to CPU1, alongside the receive
  task; Wi-Fi/UDP runs on CPU0.
- The guide notes that an ESP32 SPI slave is CPU-controlled and that the host
  should not start a transaction before the slave is ready. It recommends a
  separate handshake GPIO when needed. The FPGA/ESP32 link does not currently
  use a handshake wire; instead, a measured 100 µs CS-inactive interval between
  frames produced stable full-length transactions. This interval is empirical,
  not a datasheet minimum.
- GPIO18, GPIO19, GPIO23, and GPIO5 are the SPI3 IO_MUX signals for SCLK, MISO,
  MOSI, and CS0 respectively. The firmware selects `SPI3_HOST` and those pins.

The FPGA SCLK formula is `clk / (2 * (DIV + 1))`. The final GPIO transport uses
`DIV=4`, mode 1, 512 clock edges per frame, and `SPI_CS_GAP_CYCLES=5000` at
50 MHz. Keep SPI electrical timing and cable delay separate from this
frequency guidance; the maximum clock is not an I/O timing constraint.
