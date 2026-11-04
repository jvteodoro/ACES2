# Integração SPI com o ESP32 na DE10-Lite

## 1. Top-levels disponíveis

Existem dois top-levels para a placa:

| Top-level | Projeto Quartus | Objetivo |
|---|---|---|
| `spi_test_top` | `quartus/de10_lite/aces2_spi_test.qpf` | Teste elétrico do SPI com palavras conhecidas |
| `aces2_top` | `quartus/de10_lite/aces2_de10_lite.qpf` | Top legado ACES2 com fonte de teste |
| `aces2_usb_audio_top` | `quartus/de10_lite/aces2_usb_audio.qpf` | Host USB e stream PCM real pela UM2 |

O projeto de teste pode validar a conexão física com o osciloscópio e o ESP32.
Confira a tabela de pinagem específica antes de trocar o `.sof`: o top USB e o
top de teste não usam as mesmas posições do header para todos os quatro sinais.

## 2. Pinagem do top USB de áudio FPGA ↔ ESP32

| Sinal SPI | Direção na FPGA | bit do top | Pino MAX 10 (QSF) | Header DE10 JP1 | GPIO no ESP32 clássico | Direção no ESP32 |
|---|---|---:|---|---|---:|---|
| `SCK` | saída | `gpio[0]` | `PIN_V10` | pino 1 / `GPIO_0` | GPIO18 | entrada SPI clock |
| `MISO` | entrada | `gpio[1]` | `PIN_W10` | pino 2 / `GPIO_1` | GPIO19 | saída SPI MISO |
| `MOSI` | saída | `gpio[2]` | `PIN_V9` | pino 3 / `GPIO_2` | GPIO23 | entrada SPI MOSI |
| `CS_n` | saída | `gpio[3]` | `PIN_W9` | pino 4 / `GPIO_3` | GPIO5 | entrada chip-select |
| `GND` | referência | — | GND da placa | GND | GND do ESP32 | referência comum |

O top USB de áudio e `aces2_spi_test.qsf` usam JP1 pinos 1–4 (`GPIO_0..GPIO_3`)
para `gpio[0..3]`. O firmware usa GPIO18/19/23/5 no ESP32 clássico; não usa os
pinos ESP32 GPIO0 a GPIO3. O QSF legado `aces2_de10_lite.qsf` mantém outra
atribuição histórica dos bits do conector; não use o `.sof` legado com esta
fiação sem conferir seu próprio mapeamento.

Os quatro sinais digitais usam `3.3-V LVTTL`. O ESP32 também deve operar em
nível lógico de 3,3 V. Não conecte sinais de 5 V diretamente à FPGA ou ao
ESP32. O terra da DE10-Lite e o terra do ESP32 precisam estar conectados.

Os demais bits `gpio[35:4]` são mantidos em alta impedância pelos top-levels.

## 3. `spi_test_top`

O top de teste usa:

- `KEY0` (`key_n[0]`) como reset ativo baixo;
- `KEY1` (`key_n[1]`) para disparar uma palavra única;
- `SW[1:0]` para selecionar a palavra;
- `SW9` para habilitar transmissão contínua;
- `LEDR` para indicar handshake e atividade SPI.

Palavras selecionáveis:

| `SW[1:0]` | Palavra |
|---|---|
| `00` | `0x00000000` |
| `01` | `0x12345678` |
| `10` | `0xA5A55A5A` |
| `11` | `0xDEADBEEF` |

`SW[8:2]` normalmente deve permanecer em zero. Quando diferente de zero,
esse campo substitui os sete bits mais significativos da palavra e pode ser
usado como identificador visual do teste.

Com `SW9=0`, pressione `KEY1` para enviar uma palavra. Com `SW9=1`, a mesma
palavra é enviada continuamente, preenchendo o FIFO TX e mantendo o CS ativo
entre palavras quando possível.

### LEDs do top de teste

| LED | Sinal |
|---:|---|
| `LEDR[0]` | bit menos significativo de `accepted_count` |
| `LEDR[2:1]` | palavra selecionada (`SW[1:0]`) |
| `LEDR[3]` | `tx_ready` |
| `LEDR[4]` | `busy` |
| `LEDR[5]` | `CS_n` ativo |
| `LEDR[6]` | `tx_stall` |
| `LEDR[7]` | `rx_valid` |
| `LEDR[9]` | transmissão contínua (`SW9`) |

Para observar no osciloscópio, use `gpio[0]` como trigger de clock e monitore
`gpio[1]`, `gpio[2]` e `gpio[3]` em paralelo.

## 4. `aces2_top`

O top legado mantém a mesma conexão SPI e usa `SW9` para habilitar
temporariamente um contador de 32 bits. O projeto separado
`aces2_usb_audio_top` já liga o host USB, o encoder de quadros PCM e o master
SPI:

```text
USB PCM valid/ready -> spi_frame_encoder -> spi TX FIFO -> GPIO0..3 -> ESP32
```

Os dois blocos usam `clk_50`; se uma fonte futura usar outro domínio, deve
passar por FIFO assíncrono/CDC, sem ligar `valid` diretamente entre clocks.

## 5. Configuração SPI atual

| Parâmetro | Valor |
|---|---:|
| `DATA_WIDTH` | 32 bits |
| `CPOL` | 0 |
| `CPHA` | 0 — SPI modo 0 |
| Ordem | MSB-first |
| `SPI_CLK_DIV` | 2 |
| Clock FPGA | 50 MHz |
| SCK nominal | 8,33 MHz |
| `CS` | contínuo entre palavras enfileiradas |

O ESP-IDF para o ESP32 clássico documenta operação do SPI slave até 10 MHz.
O divisor 2 mantém o SCK abaixo desse limite. Os GPIO18/19/23/5 do firmware
usam `SPI3_HOST` (VSPI) e correspondem aos pinos IO_MUX dedicados.

O ESP32 deve ser configurado com os mesmos modo, ordem dos bits e frequência
máxima compatível. O firmware deve tratar `CS_n` contínuo como um burst de
palavras de 32 bits.

## 6. Compilação Quartus

### Top de teste

Abra `aces2_spi_test.qpf` no Quartus Prime e compile a revisão
`aces2_spi_test`.

### Top principal

Abra `aces2_de10_lite.qpf` e compile a revisão `aces2_de10_lite`.

Os dois projetos incluem `spi.sv`, `spi_uc.sv`, `spi_master.sv` e `spi_fifo.sv`.
O SDC define o clock de 50 MHz em `PIN_P11`.

## 7. Checklist de bancada

1. Confirme que FPGA e ESP32 estão em 3,3 V.
2. Conecte os terras antes dos sinais.
3. Compile primeiro `spi_test_top`.
4. Selecione `SW[1:0]=01` e pressione `KEY1`.
5. Verifique `CS_n`, `SCK` e `MOSI` no osciloscópio.
6. Ative `SW9` somente depois de confirmar modo e níveis elétricos.
7. Confirme no ESP32 a recepção de `0x12345678` e dos demais padrões.
8. Só depois substitua o gerador de teste pela fonte de áudio USB.
