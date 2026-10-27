# Intel Quartus

O projeto inicial está em `de10_lite/` para a Terasic DE10-Lite com MAX 10 10M50DAF484C7G. O top-level `rtl/top/aces2_top.sv` e o QSF cobrem os I/Os digitais da placa documentados no manual. O W5500 deve usar os sinais do GPIO ou Arduino que forem escolhidos; não associe dois conectores ao mesmo pino FPGA. Os resultados de compilação são ignorados pelo `.gitignore`.

Há duas revisões Quartus:

- `aces2_de10_lite.qpf`: top principal `aces2_top`;
- `aces2_spi_test.qpf`: top de bancada `spi_test_top`, para validar o enlace
  SPI com palavras conhecidas.

A pinagem FPGA–ESP32 e o procedimento de bancada estão em
[`rtl/top/spi_pinout.md`](../rtl/top/spi_pinout.md).
