# ESP32 receiver firmware build

Build verified on 2026-11-02 with ESP-IDF 6.1.0 for the classic ESP32:

```sh
source /home/enoch/.espressif/tools/activate_idf_v6.1.sh
idf.py build
```

The build completed after adding visible counters for UDP queue drops and
`sendmsg` failures, and after making the UDP packet counter advance only for
successful sends. It produced `software/esp32/build/aces2_esp32.bin`.
The firmware selects `SPI3_HOST` for GPIO18/19/23/5, which ESP-IDF documents
as the dedicated SPI3 pins on the classic ESP32. The FPGA sends in mode 0 at
8.33 MHz after the divider change. The receiver image was compiled only; it
was not flashed or exercised on a physical ESP32.

| Source | SHA-256 |
|---|---|
| `software/esp32/main/main.c` | `89d411c085da6e4cf8904d58a71cd7bad48ffbef6af30139e595f9cd80b796df` |
| `software/esp32/README.md` | `7cba35bc9748bc6b60e72181d828149eca7fb8a067bbda3ee69c084fde5fa517` |

## Later physical bring-up (2026-11-03)

The build above is a historical snapshot and does not describe the final
firmware. Subsequent firmware was compiled, flashed, and exercised on an
ESP32-D0WD-V3. The final receiver uses SPI mode 1, DMA, 64-byte aligned frame
buffers, SPI ISR affinity to CPU1, and the UDP destination configured locally
for the computer. Physical results and the FPGA inter-frame CS change are
recorded in [`../esp32_spi_audio_postmortem.md`](../esp32_spi_audio_postmortem.md).
