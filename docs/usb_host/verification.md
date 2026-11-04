# Evidências de verificação

Atualizado em 2026-11-03. Esta página separa resultados de simulação, síntese e
hardware. Resultados simulados não são apresentados como validação física.

## Modelo MAX3421E/UM2 e host integrado

O testbench `usb_audio_host_tb` usa o modelo SPI/MAX3421E/UM2, temporização USB
full-speed, enumeração e PCM determinístico derivado do perfil capturado. O
replay O3 corrente em 2026-11-02 usa os hashes atuais do parser, enumerator e
top. Passou 1.000 SOFs/pacotes e 48.000 amostras, sem perdas no fluxo normal;
perda de SOF, desconexão no byte 80/196 e overrun foram injetados e produziram
lacunas exatas de 47 e 49 amostras, com nova enumeração/recuperação. Saída bruta
está em `results/model_run_current.log`; comando e hashes em
`results/model_run.md`.

O replay anterior, após o width cleanup de 2026-11-01, também executou smoke,
STALL, CRC, timeout, NAK exhaustion, temporização default e teste negativo de
SPI a 5 MHz. Esses resultados e os hashes daquele snapshot permanecem
identificados separadamente em `results/model_run.md` e
`results/model_run.log`; não são apresentados como execução do parser atual.

O testbench do wrapper percorre o modelo MAX/UM2, host, decoder, encoder e
`spi.sv`, e valida transações GPIO completas: cabeçalho, sequência, 28 palavras
PCM estéreo e CRC-32. A execução após reduzir o SCK do ESP32 para 8,33 MHz
passou com uma moldura pré-consumidor descartada e duas molduras verificadas;
ela também exige intervalo mínimo de 120 ns entre bordas de subida. Comando e
hashes atuais estão em `results/board_gpio_frame.md`. O debounce de 100 ms é
acelerado por força hierárquica de um ciclo; a enumeração, tráfego USB, byte
timing, decoder, encoder e SPI permanecem ativos.

O alvo `make -C tb/usb board_long` também passou: o modelo produziu 1.000
pacotes, o host aceitou 48.000 amostras e o monitor GPIO verificou 3.428
quadros completos (47.992 palavras), sequência 0..3427, PCM, CRC e espaçamento
SCK, sem quadros descartados. As oito amostras finais não completam o grupo de
14 palavras do encoder. O replay anterior levou 556,061 s; o replay corrente
após os parâmetros de perfil e LED sticky levou 531,571 s. Os hashes correntes
e a saída integral estão em `results/board_gpio_frame.md`. Isso prova o fluxo
RTL até os pinos no modelo de simulação, não a recepção pelo ESP32 real.

O top DE10-Lite mantém LEDR4 aceso depois da primeira amostra PCM aceita. O
testbench de placa verifica os indicadores de conectado, enumerado, streaming
e amostra vista. O receptor UDP também tem testes unitários para desempacotar
`{right_s16,left_s16}` como PCM estéreo L/R, preservar sinal, rejeitar payload
parcial e analisar WAVs de captura/teste; cinco testes passaram em 2026-11-02.
LEDs e testes UDP tornam o
bring-up observável, mas não substituem captura física.

O testbench `usb_audio_backpressure_tb` também passou no worktree atual. Com
stall de 1 ms, recuperou sem lacunas; com stall de 12 ms, encheu a FIFO de 256
frames e, após retomada, contou 287 IDs perdidos, exatamente o contador de
perda do modelo. O host registrou seis eventos missed-frame, sem drops de
pacote ou erros de protocolo; nesse cenário as perdas ocorreram por quadros
sem requisição ISO, não por respostas recebidas e descartadas. O detalhe e o
comando estão em `backpressure_test.md`.

## Outros resultados RTL

| Verificação | Resultado | Limite |
| --- | --- | --- |
| `make lint` | Passou nos tops `usb_audio_host_top` e `aces2_usb_audio_top` com Verilator 5.052; zero avisos padrão nos dois tops | `WIDTHEXPAND` dispensado somente em `spi_fifo.sv` e `spi_master.sv` de terceiros; não é análise formal |
| `make -C tb sim` | Passou no worktree atual após alteração dos defaults do SPI | Não cobre USB |
| `make -C tb/usb board` | Passou no snapshot de 8,33 MHz; valida duas molduras PCM/CRC e o intervalo mínimo de 120 ns | Resultado histórico de simulação; a configuração física atual é 5 MHz, modo 1 |
| `make -C tb/usb board_long` | Passou: 1.000 pacotes, 48.000 amostras host, 3.428 quadros GPIO/47.992 palavras, sem descartes, 8 de cauda parcial | Simulação de um segundo até GPIO; não envolve ESP32 físico |
| [`idf.py build`](results/esp32_firmware_build.md) (ESP-IDF 6.1.0) | Build histórico passou; firmware posterior foi gravado e exercitado fisicamente | Captura física atual resumida abaixo e detalhada em `esp32_spi_audio_postmortem.md` |
| `usb_control_transfer_tb` | Passou: descritores de 1.191 bytes, short packet, ZLP, status, STALL, cancelamento, timeout e NAK | Engine abstrato |
| `usb_enumeration_path_tb` | Passou: 7 SETUPs, 170 transações, retry NAK e seleção interface 2/alt 1/EP 0x84 | Periférico abstrato; sem engine/SPI físico |
| `usb_host_engine_tb` | Passou com dois bancos, 196 bytes, IRQ simultânea, timeout e descarte HRSL | Temporizadores USB acelerados; execução anterior às últimas mudanças SPI |
| `usb_isochronous_receiver_tb` | Passou, incluindo erros, cancelamento, busy frames e jitter de SOF | Unidade RTL |
| Bridge SPI/MAX3421E | `make -C tb/usb bridge` passou 1/4/64 bytes, stall/reset, MISO com tDO de 14,2 ns, MOSI setup=20 ns e hold tDH=10 ns amostrado em cada borda; CS tL/tT=40/60 ns | Teste focal do MAX; wrapper longo comprova fluxo até GPIO no modelo, não recepção física pelo ESP32 |
| SPI legado | `make -C tb sim` passou após registrar MOSI; parâmetro RX trailing segue opcional e desligado nas outras instâncias | Não cobre todos os periféricos do repositório |

Os resultados integrados de maior escopo não são equivalentes entre si: o teste
com backend abstrato verifica enumeração isoladamente; o teste de 1.000 frames
mede vazão e recuperação até a interface sample valid/ready do host; o teste
de um segundo estende a verificação até transações nos pinos GPIO. Nenhum deles
prova recepção no ESP32 real ou aquisição física da UM2 pela FPGA.

Os logs atuais `results/protocol/control.txt` e `results/protocol/engine.txt`
foram gerados separadamente com `make -C tb/usb control` e `make -C tb/usb
engine`; ambos passaram. O arquivo combinado anterior foi preservado como
`results/protocol/control_engine_combined_historical.txt` para não confundir a
falha antiga de inicialização com a saída atual aprovada do teste do engine.

## Síntese e timing

Quartus Prime Standard 25.1 compilou os projetos core `usb_host` e wrapper
`aces2_usb_audio` com o source set de 2026-11-02. Fit e STA pós-fit passaram;
resumos e relatórios reproduzíveis estão em
`results/core_timing/core_compile_summary.md` e `results/board_timing/`.

O core atualizado usou 18.144 logic cells, 12.605 registradores e 10.240 bits
de memória. A STA pós-fit reconheceu as constraints SPI; no canto slow 85 C,
WNS setup/hold +2,473/+0,239 ns, TNS zero, e MISO→captura +16,972 ns.

No wrapper DE10-Lite, o fit de 2026-11-02 usou 19.729 logic elements, 13.679
registradores e 10.240 bits de memória. A STA pós-fit reconheceu os clocks MAX
de 25 MHz e ESP32 de 8,33 MHz. No canto slow 85 C, WNS setup/hold é
+2,607/+0,253 ns e TNS é zero; MISO→captura é +17,924 ns, MAX MOSI setup
+14,773 ns e MAX CS setup +29,619 ns. Restam 2 saídas/4 caminhos sem delay:
GPIO2 MOSI e GPIO3 CS. Faltam limites do receptor/interconexão para sign-off.

As exceções de hold são limitadas aos registradores de saída MOSI e CS. SCK é
burst-gated, então a STA periódica cria bordas idle que não existem após o
último SCK. O teste focal mede CS no barramento e checa tDH MOSI de 10 ns em
cada borda real de amostragem. Isso valida a lógica RTL em simulação, não
substitui medição de atrasos do shield, jumpers e cabo.

Os artefatos antigos em `results/core_synthesis/` e `results/pcm_synthesis/`
continuam históricos e não são usados como evidência para os fits atuais.

## Caracterização e validação física

Identificação USB `08bb:2902`, descritores observados, perfil ALSA nativo
stereo S16_LE/48 kHz e artefatos estão em `hardware/um2/`. usbmon não pôde ser
usado sem privilégio; não há trace URB observado. A captura ALSA confirma o
formato nativo, mas não prova transferências USB individuais nem captura pela
FPGA.

A pinagem e os limites de níveis lógicos estão descritos em
`aces2_integration.md`. Em 2026-11-03, o usuário confirmou o caminho físico
UM2 → MAX3421E → DE10-Lite → ESP32 → UDP e captura WAV audível. O ESP32 reportou
aproximadamente 3.530 transações de 512 bits/s, com CRC inválido zero em regime
estável. O transporte SPI e suas correções estão detalhados em
[`esp32_spi_audio_postmortem.md`](esp32_spi_audio_postmortem.md).

Ainda não há trace usbmon/URB nem medida elétrica de SCK/MOSI diretamente no
pad do ESP32. A revisão do shield `2045L` não foi identificada por esquema, e
resposta em frequência, nível e distorção com tom calibrado não foram medidos.
Esses limites não invalidam a captura WAV que o usuário confirmou.

Os resultados de `board`/`board_long` acima pertencem ao snapshot de simulação
que usava 8,33 MHz; eles continuam sendo evidência histórica da RTL, enquanto
a configuração física posterior usa 5 MHz, modo 1 e CS inativo por 100 µs.
