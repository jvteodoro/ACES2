# Diagnóstico e validação do transporte de áudio SPI no ESP32

Registro do diagnóstico físico FPGA → ESP32 → Wi-Fi/UDP, concluído em
2026-11-03. Este documento complementa o [guia de bring-up da DE10-Lite](board_bringup.md),
o [guia técnico do host USB](technical_guide.md) e as [notas oficiais de SPI do
ESP32](references/esp32_spi_slave_notes.md).

## Resultado final observado

Com a configuração descrita aqui, a captura serial do ESP32 reportou cerca de
3.530 transações por segundo, quase todas com exatamente 512 bits. Os quadros
recentes eram todos de 512 bits; `quadros_invalidos=0` e `crc=0`. O contador de
datagramas UDP avançou. Houve uma ou duas transações incompletas no início da
inicialização, sem repetição no fluxo estável. O usuário confirmou que o
sistema completo passou a funcionar e que a gravação WAV pôde ser ouvida.

Esse resultado valida o transporte em execução, mas não substitui uma medição
elétrica dos sinais no pino do ESP32 nem a análise de um tom calibrado para
medir resposta em frequência, nível ou distorção.

## Caminho e formato dos dados

```text
Behringer UM2
  → USB Full-Speed
  → shield MAX3421E
  → host USB e decodificador PCM na FPGA MAX 10
  → FIFO e encoder de quadros
  → SPI master FPGA / SPI slave ESP32
  → blocos PCM no ESP32
  → Wi-Fi / UDP
  → receptor Python / WAV ou reprodução ALSA
```

O ESP32 não executa a stack USB. O MAX3421E faz a interface elétrica USB e a
FPGA conduz as transações com o MAX3421E, enumera a UM2 e converte os pacotes
de áudio para amostras PCM.

Cada transação SPI contém 16 palavras de 32 bits (64 bytes) com um único CS:

| Palavra | Conteúdo |
| ---: | --- |
| 0 | marcador `0xACED` e sequência de 16 bits |
| 1–14 | 14 palavras PCM estéreo, cada uma `{right_s16,left_s16}` |
| 15 | CRC-32/IEEE das palavras 0–14 |

O ESP32 valida tamanho, marcador, CRC e sequência antes de publicar as 14
amostras PCM. Agrupa até 256 amostras em datagramas UDP. O cabeçalho UDP
(magic `ACES`, sequência, quantidade e flags) é big-endian; as palavras PCM
são transmitidas em little-endian. O receptor Python reordena os canais para
PCM estéreo S16_LE no WAV.

## Sintomas que iniciaram a depuração

O `spi_test_top` isolado funcionava com o mesmo ESP32 e a mesma fiação: o
contador mostrava quadros recentes de 512 bits sem erros. Ao usar o top de
áudio integrado, o ESP32 reportava muitas transações curtas, com comprimentos
recorrentes de 15 e 411 bits, e apenas raros quadros de 512 bits. O CS estava
conectado ao GPIO5 e as bordas de subida contadas nesse pino acompanhavam o
número de resultados da API SPI. Portanto, não era apenas um erro de impressão
do contador `trans_len`: o ESP32 observava eventos reais de CS.

O ESP-IDF define `trans_len` como a quantidade efetivamente transferida,
determinada pelo clock e pelo CS controlados pelo host. A fila SPI de 64
descritores impede que a tarefa de áudio tenha de criar um descritor a cada
quadro, mas não é um handshake de prontidão com o host. A documentação oficial
recomenda que o host só inicie quando o escravo estiver pronto; um GPIO de
handshake é uma opção quando não há margem entre transações. Nesta placa, a
solução medida foi manter um intervalo inativo de CS entre quadros.

## O que o ESP32 suporta neste uso

O ESP32 clássico usa uma SPI escrava controlada por CPU. O ESP-IDF documenta
até 10 MHz de SCLK para essa periferia e transferências de até 64 bytes sem
DMA; recomenda selecionar DMA acima de 32 bytes. Isso não significa que toda
combinação de frequência, tamanho, carga Wi-Fi e intervalo CS vá funcionar sem
ajustes. Este projeto envia exatamente 64 bytes por quadro, portanto a
configuração validada usa DMA, modo 1, buffer alinhado e SCK de 5 MHz.

Na captura estável, aproximadamente 3.530 quadros/s × 14 palavras PCM por
quadro correspondem a cerca de 49 mil palavras estéreo por segundo. A taxa de
áudio anunciada pela UM2 é 48 kHz; a conta medida tem margem pequena para
variações em rajadas e perdas de inicialização, por isso permanecem necessários
o intervalo CS, os contadores de sequência/descarte e a gravação WAV. Esses
números caracterizam esta execução e não são um limite universal de throughput
do ESP32.

## Como o SignalTap foi usado

O SignalTap foi usado para separar uma falha no gerador da FPGA de uma falha de
recepção no ESP32. A aquisição foi feita no clock `clk_50` da FPGA, com 16.384
amostras (aproximadamente 327,7 µs). O gatilho passou a ser a descida de
`gpio[3]` (CS ativo), em vez do LED de conexão, para correlacionar a captura
com o começo de uma transação SPI.

Sinais de barramento escolhidos:

| Sinal | Por que foi observado |
| --- | --- |
| `gpio[0]` | SCK que sai da FPGA; contar suas bordas verifica o comprimento do quadro |
| `gpio[2]` | MOSI; contém cabeçalho, sequência, áudio e CRC |
| `gpio[3]` | CS ativo-baixo; delimita a transação vista pelo escravo |
| `tx_count_o[4]` | indica se a FIFO do SPI já contém os 16 words exigidos para iniciar |
| `spi_master.start_i` | condição efetiva de início depois do gate de quadro completo |
| `spi_uc.start_o` | pedido de início produzido pelo controlador SPI |
| `tx_valid_o` / `tx_ready_i` do encoder | mostra se o quadro é produzido e aceito pelo SPI |
| `spi_master.busy_o` | confirma o período de atividade do master |
| sinais de host USB e LEDs | correlaciona a atividade SPI com enumeração e áudio |

Na captura pré-correção do intervalo entre quadros, duas janelas completas de
CS baixo duraram 5.168 amostras cada (103,36 µs) e continham exatamente 512
bordas de subida de SCK. O terceiro quadro chegou ao fim do buffer de captura
com 389 bordas; ele foi truncado pela janela do SignalTap, não é evidência de
um quadro curto transmitido pela FPGA. CS ficou alto por apenas 34 amostras
(cerca de 0,68 µs) entre os dois primeiros quadros. A captura preservada é
[esp32_spi_before_100us_gap_20261103.csv](captures/esp32_spi_before_100us_gap_20261103.csv).

Houve duas correções no setup de SignalTap. O gatilho pelo LEDR0 apenas
identificava conexão e não necessariamente capturava o início de cada quadro;
foi trocado por CS. Na primeira compilação com probes internos, alguns nomes
locais não correspondiam aos nós pós-síntese e Quartus apontou probes sem
conexão; a compilação foi interrompida. Os probes foram então ligados aos
caminhos hierárquicos dos ports de saída dos módulos. Quartus confirmou a
conexão de todas as 101 entradas de aquisição/gatilho antes da compilação
válida.

Limite da medição: o SignalTap observa os nets de saída da FPGA. Ele confirma
o que o RTL entrega à fronteira de I/O, mas não mede a forma de onda depois do
cabo diretamente no pad GPIO do ESP32. A contagem de bordas CS no GPIO5 do
ESP32 foi a verificação independente desse pino; SCK e MOSI no pad ESP32 não
foram medidos por um analisador externo.

## Causas e correções

### A FPGA podia começar um quadro antes de todos os words estarem prontos

O produtor de áudio USB é intermitente: recebe dados em pacotes periódicos,
enquanto o SPI envia quadros inteiros. Começar a transferência assim que o
primeiro word chega pode esvaziar a FIFO durante o quadro e deixar CS baixo
enquanto faltam dados. O adaptador em `rtl/spi/spi.sv` agora só passa
`start_i` ao master quando `tx_count` alcança os 16 words do quadro. A FIFO
tem profundidade 16; o gate impede iniciar com um quadro parcial. A captura
SignalTap confirmou a FIFO cheia no início e 512 clocks por transação.

### O intervalo CS anterior era curto para a sequência em rajada

O top integrado usava `SPI_CS_GAP_CYCLES=32`, aproximadamente 0,64 µs a
50 MHz (34 amostras / 0,68 µs medidos incluindo os ciclos de estado). Os
quadros USB chegam em grupos, e o ESP32 precisa concluir a transação anterior
e preparar a seguinte. A fila de descritores não garante por si só que a
periferia esteja pronta quando CS volta a cair.

A configuração integrada agora usa `SPI_CS_GAP_CYCLES=5000`, ou 100 µs com
clock de 50 MHz. CS fica alto durante essa janela. A imagem compilada e
programada em 2026-11-03 teve checksum Quartus `0x00EBDBE5`. A configuração
resultou no fluxo estável de quadros completos observado no ESP32. O intervalo
foi escolhido empiricamente; não representa um mínimo teórico do ESP32.

### Modo e DMA precisam concordar nos dois lados

A configuração inicial era SPI modo 0, sem DMA, com quadro de 64 bytes — o
limite do FIFO da periferia no caminho sem DMA. O ESP-IDF documenta que quadros
de até 64 bytes podem ser usados sem DMA, mas recomenda DMA para transferências
acima de 32 bytes. O limite de clock publicado para o SPI escravo ESP32 clássico
é 10 MHz; a frequência do projeto foi mantida em 5 MHz, abaixo desse valor.

Ao habilitar DMA para o buffer de 64 bytes, a documentação do ESP-IDF exige
modo 1 ou 3 para o caso geral de timing do ESP32 clássico. A FPGA foi alterada
para modo 1 (`CPOL=0`, `CPHA=1`) e o ESP32 também foi configurado em modo 1. O
buffer de recepção é alinhado a 4 bytes, tem tamanho múltiplo de 4 e fica em
RAM estática interna. Uma tentativa intermediária mudou a FPGA para modo 1,
mas deixou o firmware do ESP32 em modo 0; essa incompatibilidade foi erro de
integração introduzido durante a depuração e foi corrigida. Com modo 1 alinhado
nos dois lados e gap ainda curto, os quadros continuaram incompletos; portanto,
modo/DMA eram requisitos de configuração, mas não foram a correção suficiente
por si só.

### O ESP-IDF instalava a interrupção SPI no core de chamada

`spi_slave_initialize` registra a ISR do SPI no core que o inicializa. A
inicialização ocorre em `app_main` no core 0, também usado pelo Wi-Fi; a tarefa
de recepção já roda no core 1. O firmware agora define
`isr_cpu_id=ESP_INTR_CPU_AFFINITY_1`, alinhando a ISR com a tarefa de recepção
e evitando compartilhar a ISR SPI com a carga do Wi-Fi no core 0. Essa é uma
medida de robustez aplicada à configuração final, não uma causa isolada
demonstrada: com essa afinidade e gap ainda curto os quadros continuaram
curtos.

## Configuração física e de firmware validada

| Função | Configuração final |
| --- | --- |
| FPGA | DE10-Lite, MAX 10 10M50DAF484 |
| ESP32 | ESP32 clássico, `ESP32-D0WD-V3` observado no esptool |
| Clock SPI | 50 MHz na FPGA; divisor 4; SCK 5 MHz |
| Modo SPI | modo 1: CPOL=0, CPHA=1; MSB-first |
| Quadro | 16 × 32 bits = 512 bits / 64 bytes |
| FIFO TX FPGA | 16 words; só inicia com quadro completo |
| CS inativo entre quadros | 5.000 clocks FPGA = 100 µs |
| DMA ESP32 | habilitado (`SPI_DMA_CH_AUTO`); buffer alinhado a 4 bytes |
| Fila de transações ESP32 | 64 descritores pré-enfileirados |
| Core | ISR SPI e tarefa de recepção no core 1; Wi-Fi/UDP no core 0 |
| SPI3 ESP32 | GPIO18=SCK, GPIO19=MISO, GPIO23=MOSI, GPIO5=CS_n |
| Fiação FPGA | `gpio[0]`=SCK, `gpio[1]`=MISO, `gpio[2]`=MOSI, `gpio[3]`=CS_n |
| Rede desta sessão | ESP32 ligado ao Wi-Fi solicitado; destino UDP foi configurado para o IP do computador e porta 5000 |

Use GND comum e sinais em 3,3 V. Os GPIO18/19/23/5 são os pinos IO_MUX do
SPI3 no ESP32 clássico. SSID, senha e IP são dados locais de configuração em
`software/esp32/main/wifi_config.h`; a senha não deve ser copiada para este
documento ou para capturas/logs. O IP do computador é dinâmico: confirme-o na
interface Wi-Fi antes de configurar `ACES2_UDP_DEST_IP`.

## Observabilidade e interpretação dos contadores

- `SPI len bits`: `exatos512` deve acompanhar `total` depois da inicialização;
  os bins mostram transações curtas e `recent_bits_oldest_first` revela a
  janela recente.
- `CS GPIO5 positive edges/s`: contagem independente das subidas físicas de
  CS no ESP32. Deve acompanhar transações finalizadas.
- `SPI_incompletas`: cresce quando `trans_len != 512`; uma ocorrência na
  inicialização pode ser transitória, crescimento contínuo não é aceitável.
- `quadros_invalidos` e `crc`: devem permanecer em zero em regime estável.
- `seq`: contabiliza lacunas de sequência nos quadros SPI, não é o número de
  sequência atual.
- `quadros_PCM`: quantidade acumulada de palavras/amostras PCM aceitas pelo
  receptor SPI.
- `UDP pacotes`: cresce quando `sendmsg` retorna sucesso. Isso confirma que o
  ESP32 entregou o datagrama à pilha local, não que o processo receptor o
  gravou ou reproduziu.
- No backend Python, `pacotes`, `quadros_pcm`, `perdas_seq` e `invalidos`
  verificam o outro lado da rede. Para ouvir sem dependência de playback em
  tempo real, grave WAV e toque depois.

## Gravação e reprodução no computador

O receptor está em `software/udp_receiver/aces2_udp_receiver.py`. Para gravar
estéreo PCM16 a 48 kHz, com o firmware apontado para o IP atual do computador e
porta 5000, execute na raiz do repositório:

```sh
python3 software/udp_receiver/aces2_udp_receiver.py \
  --channels 2 --sample-rate 48000 --wav /tmp/aces2_um2.wav
```

Deixe o receptor rodando durante a captura e use Ctrl-C para fechar/finalizar
o WAV. Ouça-o depois com o reprodutor do sistema, por exemplo:

```sh
aplay -f S16_LE -r 48000 -c 2 /tmp/aces2_um2.wav
```

O backend também oferece `--play`, mas reprodução ao vivo pode sofrer pausas
independentes da captura SPI e da recepção UDP. `--wav` permite separar a
integridade da captura da temporização de reprodução.

## Reproduzir e gravar a configuração

1. Confirme no computador o IP da interface Wi-Fi que está na mesma rede do
   ESP32; atualize `ACES2_UDP_DEST_IP` e `ACES2_UDP_DEST_PORT` em
   `software/esp32/main/wifi_config.h`.
2. Confirme SSID/senha localmente nesse arquivo sem os publicar em logs ou
   documentos.
3. Compile e grave o ESP32: `idf.py build` e `idf.py -p /dev/ttyUSB0 flash`.
   Use `idf.py -p /dev/ttyUSB0 monitor` para os contadores.
4. Compile o projeto Quartus `aces2_usb_audio_debug` e programe o `.sof` na
   FPGA. O `.sof` é volátil; após desligar a placa, reprograme-o ou gere um
   arquivo de configuração não volátil seguindo o fluxo de hardware.
5. Inicie o receptor Python antes de avaliar UDP; confira a porta do firmware
   e permita tráfego UDP no firewall.
6. Aguarde alguns segundos de estabilização. Confirme 512 bits, CRC zero e
   taxa UDP no backend antes de julgar a forma de onda.

## O que foi e não foi provado

Foi demonstrado fisicamente que quadros SPI completos e com CRC válido chegam
ao ESP32, que a taxa observada é suficiente para o fluxo PCM da UM2, que o
firmware envia datagramas UDP e que o usuário conseguiu usar o fluxo e ouvir a
gravação WAV. O estado físico da UM2/MAX3421E e o caminho USB/PCM são descritos
nas capturas do [SignalTap do host](physical_bringup_signal_tap.md).

O diagnóstico não mediu jitter/timing diretamente no pad do ESP32, não
caracterizou qualidade de áudio com gerador calibrado e não estabelece que a
reprodução ALSA ao vivo seja livre de underruns em todos os computadores. A
recepção WAV separa a validação dos dados da latência do player.
