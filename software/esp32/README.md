# Receptor SPI do ESP32

Este projeto configura um ESP32 como escravo SPI para receber conjuntos de
32 bits enviados pela FPGA ACES2.

## Configuração atual

| Parâmetro | Valor |
|---|---:|
| SPI | `SPI3_HOST` / VSPI no ESP32 clássico |
| Modo | 1 (`CPOL=0`, `CPHA=1`) |
| Ordem | MSB-first |
| Palavra | 32 bits |
| Transação SPI | 16 palavras / 512 bits |
| Payload por quadro | 14 palavras |
| Frequência configurada | 5 MHz (clock FPGA 50 MHz, divisor 4; limite documentado 10 MHz) |
| CS inativo entre quadros | 100 µs (5.000 clocks FPGA) |
| Fila SPI | 64 transações |
| DMA SPI | habilitado; quadro de 64 bytes, buffer alinhado a 4 bytes |
| Afinidade da ISR SPI | CPU1, junto da tarefa de recepção |
| Buffers internos | 16 blocos de 256 palavras |
| Transporte de rede | UDP |
| Amostras por datagrama | 256 |
| Porta USB | `/dev/ttyUSB0` |

Desde a versão com provisioning BLE, SSID, senha Wi-Fi, IP, porta e MAGIC do
backend salvos pelo app têm prioridade sobre os valores de fallback de
`wifi_config.h`. Eles persistem no NVS após desligar. O procedimento está em
[`software/android_app/README.md`](../android_app/README.md).

O histórico do problema e as medições que levaram à configuração atual estão
em [`docs/usb_host/esp32_spi_audio_postmortem.md`](../../docs/usb_host/esp32_spi_audio_postmortem.md).

Pinagem padrão usada no firmware:

| ESP32 | Sinal |
|---:|---|
| GPIO18 | SCK, entrada no ESP32 |
| GPIO19 | MISO, saída do ESP32 |
| GPIO23 | MOSI, entrada no ESP32 |
| GPIO5 | CS_n, entrada no ESP32 |
| GND | referência comum com a FPGA |

Os sinais devem permanecer em 3,3 V. GPIO18/19/23/5 são os pinos IO_MUX
dedicados de SPI3 no ESP32 clássico; o firmware seleciona `SPI3_HOST` para
evitar roteá-los pela GPIO matrix. A pinagem pode ser alterada no início de
`main/main.c` caso o modelo da placa ESP32 use outra conexão.

## Instalação do ESP-IDF

O projeto usa ESP-IDF. Depois de instalar o framework, carregue o ambiente:

```bash
source "$HOME/.espressif/tools/activate_idf_v6.1.sh"
idf.py --version
```

Se outra versão do ESP-IDF estiver instalada, use o respectivo
`activate_idf_<versão>.sh`.

## Compilar e gravar

Na primeira configuração, crie o arquivo local de rede a partir do modelo. O
arquivo `main/wifi_config.h` fica fora do Git para não publicar senha ou IP
local:

```bash
cp main/wifi_config.h.example main/wifi_config.h
```

Edite `main/wifi_config.h` com SSID, senha e IP do computador antes de compilar.
Na raiz do projeto:

```bash
cd software/esp32
idf.py set-target esp32
idf.py build
idf.py -p /dev/ttyUSB0 flash
idf.py -p /dev/ttyUSB0 monitor
```

Para gravar e abrir o monitor em uma única etapa:

```bash
idf.py -p /dev/ttyUSB0 flash monitor
```

Saia do monitor com `Ctrl-]`.

## Funcionamento do receptor

O firmware mantém 64 transações SPI enfileiradas. Cada transação contém 16
palavras de 32 bits, delimitadas por um único `CS_n`: cabeçalho, 14 palavras
de payload e CRC-32. O DMA é usado porque o quadro possui 64 bytes. A
recepção SPI roda em uma tarefa dedicada no CPU1, converte cada palavra de
quatro bytes MSB-first
para `uint32_t`, preenche blocos de 256 amostras e rearma imediatamente a
transação SPI. A tarefa de rede, quando habilitada, roda separadamente no CPU0.

Os quadros PCM são agrupados em datagramas UDP com até 256 palavras. Cada pacote
contém um número de sequência, quantidade de quadros PCM e um MAGIC de 32 bits
configurado pelo app (o padrão `0x41434553`, ASCII `ACES`). Defina um MAGIC
único por dispositivo de captura. O cabeçalho é big-endian e o payload de amostras é
enviado na ordem nativa do ESP32 (little-endian). O receptor deve detectar
perda de pacotes comparando o número de sequência.

O monitor serial imprime quadros PCM, erros de CRC, descontinuidades de
sequência, amostras descartadas por falta de bloco, blocos descartados quando a
fila UDP encheu e falhas de `sendmsg`. O contador `UDP pacotes` avança apenas
quando `sendmsg` retorna sucesso. O receptor UDP em `software/udp_receiver/`
valida os datagramas, mostra valores PCM e grava WAV estéreo. A UART não
participa do caminho crítico de recepção.

## Teste inicial

1. Conecte GND entre FPGA e ESP32.
2. Configure SSID, senha e IP de destino em `main/wifi_config.h`.
3. Ligue `SCK`, `MOSI` e `CS_n` da FPGA aos GPIOs de entrada indicados.
4. Ligue o `MISO` do ESP32 ao GPIO MISO da FPGA, mesmo que o teste inicial só
   valide a recepção na direção FPGA → ESP32.
5. Grave o firmware e abra o monitor serial.
6. Use o `spi_test_top` da FPGA com `SW[1:0]=01` para enviar
   `0x12345678`.
7. Ative `SW9` para transmissão contínua e observe os contadores no monitor.

Esse procedimento descreve o teste isolado original. Confira o modo SPI dos
dois lados antes de executá-lo: o `spi_test_top` ainda está em modo 0, enquanto
o firmware integrado de áudio usa modo 1 com DMA. Para validar esse firmware,
use a imagem `aces2_usb_audio_debug`, que também configura o intervalo CS de
100 µs descrito no postmortem. Não combine FPGA em modo 0 com o ESP32 em modo 1.

Durante a caracterização da taxa máxima do SPI, mantenha
`ACES2_WIFI_ENABLE=0`. Para verificar áudio real com a FPGA USB Host, ative-o e
configure SSID/senha/IP no mesmo arquivo. O ESP32 recebe apenas o transporte de
diagnóstico e não executa nenhuma função USB.

Formato UDP:

```text
uint32 magic        (big-endian)
uint32 sequence     (big-endian)
uint16 frame_count (big-endian; quadros PCM estéreo)
uint16 flags        (big-endian)
uint32 frames[]     (little-endian, cada palavra `{right_s16,left_s16}`)
```

Quadro SPI:

```text
word 0  = 0xACED + sequência de 16 bits
word 1  = payload 0
...
word 14 = payload 13
word 15 = CRC-32/IEEE do word 0 até o word 14
```

Antes de conectar, confirme no esquemático da sua placa ESP32 que os GPIOs
selecionados estão disponíveis e não estão ligados a periféricos conflitantes.
