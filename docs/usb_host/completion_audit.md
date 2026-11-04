# Auditoria de conclusão — atualização física de 2026-11-03

O diagnóstico físico do transporte FPGA → ESP32 → UDP foi concluído; consulte
[`esp32_spi_audio_postmortem.md`](esp32_spi_audio_postmortem.md) para a linha
do tempo, medições e parâmetros finais. O monitor ESP32 mostrou cerca de 3.530
quadros completos de 512 bits/s, sem CRC inválido em regime estável. O usuário
confirmou que o caminho completo funcionou e que a gravação WAV pôde ser ouvida.
Os resultados de simulação e de caracterização são preservados como evidência
separada. Os limites ainda abertos aparecem nas linhas abaixo.

| Requisito | Evidência atual | Estado / trabalho restante |
| --- | --- | --- |
| Caracterização real da UM2 | VID/PID `08bb:2902`, descritores completos, formatos ALSA, WAV nativo S16_LE estéreo/48 kHz, HID | Caracterizada no Linux. usbmon foi negado por permissão; não há URB ou tamanho/cadência de pacote medidos |
| Referências técnicas | Datasheets MAX3421E/PCM2902, guia MAX, USB 2.0/UAC, manual DE10, notas TimeQuest e guia ESP-IDF SPI slave | PDFs e notas estão em `docs/usb_host/references/`; `sha256sum -c SHA256SUMS` e JSON manifest passaram |
| Perfil USB | Interface 2/alt 1, endpoint IN `0x84`, estéreo S16_LE/48 kHz, `wMaxPacketSize=196` | Dados vêm dos descritores; 196 B é máximo anunciado, não payload medido |
| Extensão de perfil | VID/PID, taxa, endpoint, e limites de pacote têm parâmetros no top; endpoint zero seleciona endpoint IN automaticamente | Padrão continua UM2. O decoder continua estéreo S16/1 ms, e datapath limita pacote a 256 B; não alegar suporte UAC universal |
| Arquitetura RTL | Controller/bridge MAX, engine USB, EP0, enumeração/parser, ISO RX, decoder/buffer e top | Implementada em RTL e coberta pelas regressões documentadas |
| Lint RTL | `make lint`, Verilator 5.052, tops `usb_audio_host_top` e `aces2_usb_audio_top` | Passou nos dois; sem avisos padrão no RTL do projeto. `WIDTHEXPAND` está dispensado apenas nos dois arquivos SPI importados |
| Enumeração/configuração | 7 SETUPs, 170 transações, 1 retry NAK; descriptors capturados; seleção interface 2/alt 1/endpoint `0x84` | Passou com endpoint abstrato e no modelo MAX/UM2 através do SPI |
| Streaming PCM longo | Replay O3 corrente em 2026-11-02: 1.000 frames/pacotes, 48.000 amostras, hashes atuais de parser/enumerator/top, injeções de SOF, desconexão e overrun | Passou; lacunas de 47/49 amostras e reconexão verificadas em `results/model_run_current.log`. Smoke/faults de controle/5 MHz SPI passaram no replay do snapshot 2026-11-01, separado em `results/model_run.md` |
| Serviço dos bancos MAX | Regressão integrada atual: liberação 1.690 ciclos = 33,8 µs desde o byte 64 até W1C; 64 bytes sem stuffing chegam em 42,667 µs a 12 Mbit/s | Margem digital do modelo 8,867 µs usando a comparação conservadora de 64 intervalos (o byte 129 reutilizaria o banco); não limita todas as fases nem substitui medição MAX/shield |
| Falhas/backpressure | STALL, CRC/timeout/NAK exhaustion, perda SOF, desconexão e overrun; FIFO stall de 12 ms perde 287 IDs exatos | Passou em simulação; injeção CRC de controle não testa CRC ISO do endpoint |
| Wrapper GPIO PCM | [`board_gpio_frame.md`](results/board_gpio_frame.md): modelo MAX/UM2, 1.000 pacotes, 48.000 amostras host, 3.428 quadros GPIO completos, 47.992 palavras verificadas, cauda de 8, sequência 0..3427 | Replay 2026-11-02 no hash atual passou em 531,571 s wall; zero quadros descartados; sequência, PCM, CRC, LEDR4 e espaçamento SCK verificados. Não substitui aquisição física |
| Observabilidade TopLevel | LEDR0–4 mostram conexão, enumeração, streaming, falha agregada e primeira amostra (sticky); firmware expõe erros CRC/seq, blocos descartados e falhas de sendmsg; receptor UDP grava PCM estéreo WAV | Usuário confirmou a captura física e WAV audível. LEDR3 permanece a falha agregada `controller_fault || enum_error`, não um diagnóstico específico |
| Regressões | `make -C tb sim`, `make -C tb/usb`, `make -C tb/usb board_long`, `idf.py build` | `make -C tb sim`, suite USB e board-long passaram após sizing; build ESP-IDF em `results/esp32_firmware_build.md` |
| Caracterização física/URBs | Captura ALSA de 1 segundo, formatos nativos e descriptors observados | Não houve usbmon; tráfego USB real por pacote não foi observado |
| Fitting e síntese MAX 10 | Quartus Prime Standard 25.1; core `usb_host` e wrapper `aces2_usb_audio` | Ambos os flows atuais concluíram fit/STA sem erros. Métricas e hashes atuais em `results/core_timing/core_compile_summary.md` e `results/board_timing/board_compile_summary.md` |
| Timing SPI MAX | Quartus fit/STA do core e do wrapper concluídos em 2026-11-02; SCK 25 MHz, MISO `tDO=14,2 ns` | TNS zero; core MISO→captura +16,972 ns; wrapper +17,924 ns. Ver resumos em `results/core_timing/` e `results/board_timing/`. Isso cobre STA FPGA com constraints usadas, não valida o chip/shield físico |
| Timing de interfaces externas | ESP32 SPI usa DIV=4 (5 MHz), modo 1 e intervalo CS de 100 µs; clock propagado a GPIO0 e `SPI3_HOST` nos GPIO18/19/23/5 | Transporte físico funcionou; GPIO2 MOSI e GPIO3 CS ainda não têm delays externos do receptor/interconexão caracterizados para sign-off |
| Pinagem/níveis | QSF do top USB agora usa JP1 1–4 / GPIO_0..GPIO_3 para ESP32 SCK/MISO/MOSI/CS; D10–D13 SPI, D9 INT, Arduino RESET em F16 para RES#, D8/GPX tri-state | USB-Blaster e MAX 10 detectados e SOF programado; modelo/revisão do shield, jumper de VBUS, 5 V em VBUS, VL, pull-ups e níveis do módulo ainda não verificados |
| Preparação física | `.sof` e firmware foram gravados e usados em 2026-11-03; VBUS medido em 4,8 V com e sem UM2 | Hardware operou no setup conectado; esquema/revisão exata do shield `2045L` ainda não localizada |
| Aquisição FPGA | SignalTap mostrou enumeração, seleção de perfil e pacote ISO; LEDR4 indicou amostra aceita; quadros SPI completos foram validados no ESP32 e o usuário confirmou WAV | Caminho funcional confirmado; resta caracterizar conteúdo com tom analógico conhecido e medir timing no pad do ESP32 |

Rechecagem do PC usada na caracterização em 2026-11-02: `/sys/bus/usb/devices/1-2` contém VID/PID
`08bb:2902`; `/proc/asound/card1/usbid` confirma a mesma identidade e
`/proc/asound/card1/stream0` lista interface de captura 2, alt 1, estéreo
S16_LE, 48 kHz, endpoint `0x84` IN. A captura estava parada e o playback
rodando. Naquela tentativa, `lsusb` falhou ao inicializar libusb (`-99`),
`arecord` não conseguiu abrir a placa apesar da entrada CODEC em `/proc`,
`/dev/usbmon*` não existe e `/sys/kernel/debug/usb/usbmon` é negado. A UM2
estava conectada ao PC para caracterização. Essa observação histórica precede
a sessão de validação física com a FPGA.

Implementação, simulação, fitting e validação física são estados distintos.
O caminho físico da UM2 até WAV foi posteriormente confirmado pelo usuário e o
transporte SPI foi medido no ESP32; veja o postmortem referido acima. Ainda
permanecem sem evidência: trace USB por pacote/URB, medição de timing no pad do
ESP32, identificação esquemática da revisão do shield e caracterização acústica
com sinal calibrado.
