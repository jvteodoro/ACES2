# Integração SPI com o ESP32 na DE10-Lite

## 1. Top-levels disponíveis

Existem dois top-levels para a placa:

| Top-level | Projeto Quartus | Objetivo |
|---|---|---|
| `spi_test_top` | `quartus/de10_lite/aces2_spi_test.qpf` | Teste elétrico do SPI com palavras conhecidas |
| `aces2_top` | `quartus/de10_lite/aces2_de10_lite.qpf` | Top principal do ACES2 |

O projeto de teste deve ser usado primeiro para validar a conexão física com o
osciloscópio e com o ESP32. O projeto principal usa a mesma pinagem SPI.

## 2. Pinagem FPGA ↔ ESP32

| Sinal SPI | Direção na FPGA | `gpio[]` | Pino FPGA DE10-Lite | Direção no ESP32 |
|---|---|---:|---|---|
| `SCK` | saída | `gpio[0]` | `PIN_V10` | entrada SPI clock |
| `MISO` | entrada | `gpio[1]` | `PIN_V9` | saída SPI MISO |
| `MOSI` | saída | `gpio[2]` | `PIN_V8` | entrada SPI MOSI |
| `CS_n` | saída | `gpio[3]` | `PIN_V7` | entrada chip-select |
| `GND` | referência | — | GND da placa | GND do ESP32 |

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

O top principal mantém a mesma conexão SPI e usa `SW9` para habilitar
temporariamente um contador de 32 bits. Esse contador é somente um gerador de
bring-up: ele substitui o produtor de áudio USB enquanto o host USB e a classe
USB Audio ainda não estão implementados.

Quando o stream de áudio estiver disponível, o bloco temporário deve ser
substituído por uma conexão:

```text
audio_data   -> spi.tx_data_i
audio_valid  -> spi.tx_valid_i
spi.tx_ready_o -> audio_ready
```

Se o áudio e o SPI estiverem em domínios de clock diferentes, use um FIFO
assíncrono/CDC antes do adaptador SPI. Não atravesse essa fronteira ligando
`valid` diretamente entre clocks diferentes.

## 5. Configuração SPI atual

| Parâmetro | Valor |
|---|---:|
| `DATA_WIDTH` | 32 bits |
| `CPOL` | 0 |
| `CPHA` | 0 — SPI modo 0 |
| Ordem | MSB-first |
| `SPI_CLK_DIV` | 1 |
| Clock FPGA | 50 MHz |
| SCK nominal | 12,5 MHz |
| `CS` | contínuo entre palavras enfileiradas |

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
