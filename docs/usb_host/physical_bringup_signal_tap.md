# DE10-Lite + MAX3421E physical bring-up

O estado consolidado, a explicação dos módulos RTL e a interpretação das
capturas estão no [guia técnico](technical_guide.md). Este arquivo preserva o
registro cronológico das sessões SignalTap.

O diagnóstico posterior do link SPI com o ESP32 está no
[postmortem do transporte](esp32_spi_audio_postmortem.md). A captura
[`esp32_spi_before_100us_gap_20261103.csv`](captures/esp32_spi_before_100us_gap_20261103.csv)
foi disparada na descida de CS da FPGA e mostrou dois quadros completos de 512
clocks, seguidos por um terceiro quadro truncado pelo final da janela de
aquisição. Entre os quadros completos, CS ficou inativo por cerca de 0,68 µs;
esse registro serviu de comparação antes do ajuste final de 100 µs.

Na última sessão documentada (2 nov. 2026), o SignalTap mostrou um pacote
isócrono de 60 bytes e o LEDR4 acendeu. O usuário também relatou o LED POWER da
UM2 aceso. Os bytes capturados eram zero; há evidência de amostra aceita na
FPGA, mas ainda falta capturar uma forma de onda não nula. Veja o guia para o
estado consolidado e os limites dessa evidência.

## Board and capture setup

- FPGA: DE10-Lite, 10M50DAF484C7G.
- Host interface: Arduino-style USB Host Shield marked `2045L`; the marking alone does not establish a manufacturer or schematic revision.
- Shield signals used by the FPGA top: D10/IO10 = CS, D11/IO11 = MOSI, D12/IO12 = MISO, D13/IO13 = SCK, D9/IO9 = active-low INT, Arduino RESET = MAX3421E RES#.
- The MAX3421E owns the USB D+/D− signaling. The FPGA observes its register transactions over SPI; this SignalTap setup does not sample USB D+/D− directly.
- SignalTap samples at `clk_50` and records the shield SPI pins, INT, FPGA reset, KEY0, LEDs, and selected host status signals. The reusable acquisition script is [capture_usb_debug.tcl](../../quartus/de10_lite/capture_usb_debug.tcl).

Build `aces2_usb_audio_debug` with SignalTap enabled, program `output_files_usb_audio_debug/aces2_usb_audio_debug.sof`, then run `quartus_stp -t capture_usb_debug.tcl` from `quartus/de10_lite`. The capture file is written to `/tmp/aces2_usb_debug_capture.csv`. The `.stp` file must use the JTAG cable name reported by `quartus_pgm -l` (currently `USB-Blaster [1-1]`).

## First UM2 capture

The capture was made before the `CONNIRQ` handling fix described below. Raw data is retained at [first_um2_signaltap.csv](captures/first_um2_signaltap.csv).

Observed in the 8,192-sample window:

- CS, SCK, MOSI, MISO, and INT all changed. The FPGA was issuing SPI register transactions and receiving nonconstant MISO data from the shield. This rules out a completely inactive SPI link; it does not prove USB audio data was received.
- MOSI sent `22 80 06 00 01 00 00 08 00`: a write to MAX3421E SUDFIFO containing an 8-byte USB `GET_DESCRIPTOR(Device)` setup packet (`80 06 00 01 00 00 08 00`). It then sent `F2 10` to launch a SETUP transaction through HXFR. This proves the FPGA reached USB enumeration and the MAX3421E received an enumeration command.
- HIRQ reads returned `0x39` and `0x79`. In host mode, HIRQ bit 5 is CONNIRQ. The following `CA 20` transaction clears that flag.
- Immediately after this connection-change handling, the trace shows a new PINCTL write (`8A 18`) and a MAX3421E chip reset (`7A 20`, then `7A 00`). The host was restarting just after the connection event, interrupting enumeration.
- The later `68 00` transactions repeatedly read USBIRQ while waiting for OSCOKIRQ. The captured window is short (about 164 µs), so those reads alone do not establish an oscillator timeout.

The first trace did not show an audio sample reaching the ESP32. LEDR4 remained low and no streaming status was observed. Internal state/data probes in this capture were not reliable enough to interpret: Quartus reported 22 missing connections out of 101 SignalTap inputs. The external SPI/INT/LED probes were present and their waveforms decode consistently. Treat the CSV above as the pre-fix physical baseline.

## Capture after the CONNIRQ correction

[after_connirq_fix_signaltap.csv](captures/after_connirq_fix_signaltap.csv) was captured after the host stopped treating every CONNIRQ as a disconnect. It shows the same `GET_DESCRIPTOR(Device)` setup request followed by HIRQ `HXFRDN` and HRSL `0x80` (`HRSLT=0`, no host transaction error). The former immediate PINCTL/CHIPRES reset is absent. This is positive evidence that the UM2 responds to a USB control transaction, beyond merely seeing the shield's SPI pins toggle.

That short capture ends immediately after the SETUP result. LEDR1 (enumerated), LEDR2 (streaming), and LEDR4 (sample accepted by the FPGA audio path) were all low in the window. Therefore it does not yet prove that descriptor bytes were read or that audio samples arrived.

The host engine also classified `TOKEN_SETUP` (`8'h10`) as IN because it derived direction from OUTNIN bit 5 alone. In HXFR, SETUP is bit 4 and SETUP transfers are host-to-device. The RTL now marks SETUP as an OUT completion path. The next capture below validates the change: SETUP completes, but the descriptor data-IN request still does not appear.

## Capture after the SETUP direction correction

[after_setup_direction_signaltap.csv](captures/after_setup_direction_signaltap.csv) is a 16,384-sample capture (about 328 µs at 50 MHz), triggered by LEDR0 rising. It records:

- The FPGA sends `80 06 00 01 00 00 08 00` in SUDFIFO and launches HXFR SETUP with `F2 10`.
- HIRQ reports HXFRDN; the host clears it and reads HRSL. HRSL is `0x80`: JSTATUS is set and HRSLT is zero, so the MAX3421E reports the SETUP transaction completed without a USB transaction error.
- The trace contains no subsequent IN token, no RCVBC/RCVFIFO read, and no device-descriptor bytes. LEDR1, LEDR2, LEDR3, and LEDR9 remain low. This capture therefore confirms successful USB control-transaction completion with the attached device, while showing that descriptor retrieval and audio streaming are not yet working.

The next useful debug point is the control-transfer/enumerator handshake immediately after the host returns the successful SETUP result. The missing descriptor read is now on the FPGA control path; extending the capture alone is unlikely to help because the SPI trace becomes idle after the HRSL reads.

## Capture after connection debounce correction

[after_debounce_fix_descriptor_signaltap.csv](captures/after_debounce_fix_descriptor_signaltap.csv) was captured with all 101 SignalTap inputs connected. It confirms the post-SETUP data path and the subsequent address request:

- The host sends the descriptor data `IN` token, reads `RCVBC=8`, and receives `12 01 10 01 00 00 00 08` from RCVFIFO.
- It then fetches the full 18-byte device descriptor in 8-, 8-, and 2-byte packets. The bytes identify VID `08BB`, PID `2902`, USB 1.10, and EP0 max packet size 8, matching the Behringer UM2.
- The host completes `SET_ADDRESS` at address zero; the control transfer reports done with no control or enumerator error. The enumerator then enters its specified 2 ms settle period before requesting the configuration descriptor, beyond this 16,384-sample (328 µs) window.

The prior trace accepted the descriptor data request in the control path but then went silent on SPI. The controller was servicing `CONDETIRQ` by starting another 100 ms debounce even though it had already established a connection. The host's register transaction timeout is also 100 ms, so this path could starve the descriptor request. `max3421e_controller` now returns directly to `C_READY` when HRSL confirms the same connected speed. This fixed build reached RCVFIFO and read the UM2's device descriptor; configuration enumeration and PCM reception remain to be captured.

LEDR9 is a sticky aggregate: `rx_protocol + local_protocol_count + enum_error_count`. The last counter includes enumeration failures; `local_protocol_count` includes malformed decoder packets and stray host responses. An LEDR9 event by itself does not identify which condition occurred. Earlier SignalTap captures probed LEDR9; the current acquisition replaces that probe with LEDR4 to correlate the first accepted PCM sample with the USB packet.

## RTL correction from the trace

HIRQ.CONNIRQ means that the USB port state changed; it can be raised by either attachment or removal. The prior host engine labeled every CONNIRQ as a disconnect. The top level then canceled EP0 control transfers on that event, and the controller restarted the MAX3421E before enumeration could complete.

The host engine now reports a port-change event to the controller. The controller checks HRSL J/K state, and the top level cancels an in-flight control transfer only when `connected_o` actually falls. Relevant RTL is in `rtl/usb/usb_host_engine.sv`, `rtl/usb/max3421e_controller.sv`, and `rtl/usb/usb_audio_host_top.sv`.

LEDR4 indicates that a sample was accepted by the FPGA audio path. LEDR0 indicates only attached/full-speed status, and LEDR1/LEDR2 indicate enumeration and streaming state respectively.

## Captura após enumeração completa

[after_enum_iso_start_signaltap.csv](captures/after_enum_iso_start_signaltap.csv)
foi capturada com gatilho LEDR1 rising. LEDR1 e LEDR2 ficaram altos, LEDR3 e
`enum_error` ficaram baixos, e a janela mostrou o pedido `SET_INTERFACE`
(`bmRequestType=0x01`, interface 2, alternate 1). A janela de 328 µs terminou
antes do próximo agendamento isócrono de 1 ms.

## Primeiro pacote isócrono e LEDR4

[after_first_pcm_sample_signaltap.csv](captures/after_first_pcm_sample_signaltap.csv)
foi capturada com gatilho LEDR4 rising; a captura ocorreu automaticamente
depois da reprogramação, sem KEY0. LEDR0, LEDR1, LEDR2 e LEDR4 ficaram altos;
LEDR3 e `enum_error` ficaram baixos. A leitura de RCVBC retornou `0x3C` (60
bytes), HRSL retornou `0x80` (transação sem erro USB), e a leitura de RCVFIFO
retornou 60 bytes `00`. Como LEDR4 é acionado por `usb_sample_valid &&
usb_sample_ready`, isso comprova que ao menos uma amostra atravessou o caminho
PCM da FPGA. O payload zero não demonstra uma forma de onda de áudio não nula;
para isso, é necessário aplicar um sinal conhecido à entrada analógica da UM2.

A tentativa anterior de usar `owner_iso_q rising` como gatilho não ocorreu em
60 s. O gatilho foi alterado para LEDR4 rising, que produziu a captura acima.
Na configuração atual, LEDR4 substitui LEDR9 entre os probes e é também o
gatilho.

## Reference

MAX3421E register/status and SPI behavior: [Analog Devices MAX3421E data sheet](https://www.analog.com/media/en/technical-documentation/data-sheets/max3421e.pdf). In full-duplex mode, MISO returns host interrupt status during the command byte, and the MAX3421E samples MOSI on rising SCK edges.
