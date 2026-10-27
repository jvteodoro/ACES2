# Documento técnico — Testbenches do adaptador SPI

## 1. Escopo

Os testbenches deste diretório verificam a unidade de controle `spi_uc` e o
adaptador `spi` que integra essa UC ao `spi_master` do
`third_party/spi-fpga-core`. O caso de uso inicial é transmitir palavras de
áudio da FPGA para um ESP32 configurado como escravo SPI.

O caminho de áudio ainda precisa entregar as amostras neste mesmo domínio de
clock ou através de um CDC/FIFO próprio. O adaptador SPI não tenta esconder
essa fronteira: ele fornece `tx_ready_o` para que a origem só avance quando a
amostra tiver sido aceita.

## 2. Arquitetura verificada

```text
fonte de amostras
      │ tx_valid_i / tx_ready_o
      ▼
   spi_uc ──► TX FIFO do spi_master ──► MOSI / SCK / CS_n ──► ESP32
      ▲                                             │
      └──────── rx_valid_o / rx_ready_i ◄───────────┘
```

O `spi_master` externo continua responsável por serializar bits, gerar o
clock, controlar o chip-select e armazenar TX/RX. A `spi_uc` apenas traduz o
stream local para os sinais de controle do núcleo.

## 3. Interface do adaptador `spi`

| Sinal | Direção | Descrição |
|---|---|---|
| `clk_i` | entrada | Clock do domínio FPGA |
| `rst_ni` | entrada | Reset síncrono ativo baixo |
| `tx_data_i` | entrada | Palavra a transmitir |
| `tx_valid_i` | entrada | A origem apresenta uma palavra válida |
| `tx_ready_o` | saída | A palavra pode ser aceita neste ciclo |
| `tx_stall_o` | saída | `tx_valid_i` está ativo enquanto o TX FIFO está cheio |
| `rx_data_o` | saída | Palavra recebida do ESP32 |
| `rx_valid_o` | saída | Há uma palavra disponível no RX FIFO |
| `rx_ready_i` | entrada | Consumidor aceita a palavra RX |
| `miso_i` | entrada | Dados seriais do ESP32 |
| `mosi_o` | saída | Dados seriais para o ESP32 |
| `sck_o` | saída | Clock SPI gerado pela FPGA |
| `cs_n_o` | saída | Chip-select ativo em nível baixo |
| `busy_o` | saída | Transferência SPI em andamento |
| `xfer_done_o` | saída | Pulso de conclusão de uma transferência |

Uma amostra é aceita somente quando `tx_valid_i && tx_ready_o`. Se o FIFO
estiver cheio, a origem deve manter `tx_valid_i` e `tx_data_i` estáveis até
`tx_ready_o` voltar a 1. Assim, o backpressure evita descarte silencioso.

## 4. Política da unidade de controle

- SPI modo 0: `CPOL=0`, `CPHA=0`.
- MSB-first por padrão.
- `SPI_CLK_DIV=1` por padrão: com `clk_i=50 MHz`, o SCK nominal é 12,5 MHz.
- `cs_inter_byte_o=1`: CS permanece baixo entre palavras que já estejam no
  TX FIFO, permitindo um burst contínuo.
- `CS_SEL=0`, com um CS físico exposto por padrão.
- `SPI_FIFO_DEPTH=16` no adaptador; o teste de integração usa profundidade 8.
- O canal RX é exposto. Quando respostas do ESP32 não forem necessárias,
  `rx_ready_i` deve permanecer em 1 para impedir que o RX FIFO acumule dados.

Para compatibilidade com a declaração de seleção de CS do núcleo upstream,
quando `NUM_CS=1` o núcleo é instanciado internamente com duas posições e
somente `cs_n_o[0]` é exposto pelo adaptador.

Para uma taxa de áudio de 48 ksample/s, mesmo uma palavra de 32 bits requer
1,536 Mbit/s antes de incluir margem de protocolo. O padrão de 12,5 MHz deixa
margem ampla, mas a taxa real deve ser validada com o ESP32, o cabeamento e o
formato final dos frames.

## 5. Teste unitário da UC

Arquivo: `spi_uc_tb.sv`.

Verifica 11 condições:

- reset bloqueia TX, RX e `start`;
- aceite ready/valid de uma palavra;
- backpressure quando TX FIFO está cheio;
- início somente com FIFO não vazia e master ocioso;
- ausência de reinício durante uma transferência;
- retenção e drenagem do RX conforme `rx_ready_i`;
- modo SPI, ordem dos bits, divisor e atrasos;
- CS contínuo entre palavras.

Saída esperada:

```text
SIMULAÇÃO spi_uc PASSOU: 11 verificações
```

## 6. Teste de integração

Arquivo: `spi_tb.sv`.

O teste instancia `spi`, mantém `miso_i` em zero e implementa um modelo de
escravo que amostra `mosi_o` na borda de subida de `sck_o`. Quatro palavras são
enviadas sem pausas relevantes:

```text
0x00000001
0x12345678
0xA5A55A5A
0xDEADBEEF
```

O sinal `sim_status[79:0]` acompanha a fase atual em ASCII, usando estados
como `RESET`, `SEND_WORD_0`, `WAIT_TRANSFER`, `CHECK_BURST`, `PASS` e `FAIL`.
Ele aparece no topo da configuração do GTKWave para orientar a leitura dos
demais sinais.

São verificados:

- quatro palavras aceitas pelo handshake;
- quatro palavras reconstruídas corretamente no escravo;
- nenhum `tx_stall_o` durante o burst;
- SCK em nível baixo quando CS está inativo;
- apenas uma queda e uma subida de CS para o burst completo;
- conclusão da transferência.

Saída esperada:

```text
SIMULAÇÃO spi PASSOU: burst de 4 palavras sem stall
```

## 7. Execução

Na raiz do repositório:

```sh
make -C tb spi_uc
make -C tb spi
```

Para executar todos os testbenches atuais:

```sh
make -C tb sim
```

Os VCDs são gravados em:

```text
tb/spi/spi_uc_tb.vcd
tb/spi/spi_tb.vcd
```

## 8. Visualização no GTKWave

Scripts disponíveis:

- [spi_uc_tb.tcl](spi_uc_tb.tcl): sinais da UC, handshakes e configuração;
- [spi_tb.tcl](spi_tb.tcl): stream, barramento SPI, contadores e modelo de
  escravo.

Nos dois testbenches, `sim_status` é exibido em ASCII e em amarelo. A ordem dos
sinais no painel foi mantida compacta para facilitar a leitura das ondas.

Os scripts também criam marcadores nomeados (`A`–`H` no teste integrado e
`A`–`G` no teste da UC) para reset, envio das palavras, espera, checagens e
resultado final. Como o VCD usa ps como unidade, os marcadores são definidos
nessa mesma unidade.

Uso:

```sh
gtkwave -S tb/spi/spi_uc_tb.tcl tb/spi/spi_uc_tb.vcd
gtkwave -S tb/spi/spi_tb.tcl tb/spi/spi_tb.vcd
```

O alvo `make -C tb spi_waves` abre as ondas do teste integrado; o alvo
`spi_uc_waves` abre as ondas da UC.

## 9. Limitações e próximos passos

- O protocolo de framing para o ESP32 ainda não foi definido. CS contínuo é
  adequado para streaming, mas o firmware precisa conhecer a fronteira das
  palavras e a estratégia de recuperação.
- Não há CDC entre USB/áudio e SPI neste bloco. Essa integração deve usar um
  FIFO assíncrono ou garantir um clock comum.
- A confiabilidade física depende de nível lógico, aterramento, comprimento
  do cabo e configuração do periférico SPI do ESP32.
- O próximo teste deve modelar respostas do ESP32 em `MISO` e verificar o
  protocolo de confirmação/flow-control, além de testar o comportamento quando
  a origem produz amostras mais rápido que a taxa SPI.
