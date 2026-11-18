# ACES2

Projeto ACES2 em FPGA. O repositório mantém o objetivo de captura USB e transmissão Ethernet com W5500, e agora inclui um protótipo de USB Audio Host em RTL para a Behringer U-Phoria UM2 usando o MAX3421E.

Este repositório dá continuidade ao [ACES original](https://github.com/jvteodoro/ACES), que contém uma estrutura inicial de recepção I²S e processamento FFT. A implementação do host USB é inteiramente RTL e não usa o ESP32 para executar a stack USB. O caminho UM2 → FPGA → ESP32 → UDP foi exercitado em bancada e o áudio foi capturado em WAV; veja os registros e limites conhecidos em `docs/usb_host/`.

## Estado do projeto

O alvo de hardware é a Terasic DE10-Lite com FPGA Intel MAX 10 10M50DAF484C7G. O USB Audio Host e seu wrapper de placa estão implementados em RTL. A integração Ethernet/W5500 permanece fora do escopo desta etapa.

## Estrutura

```text
docs/                    documentação de arquitetura, decisões e desenvolvimento
docs/usb_host/           arquitetura, verificação, bring-up e documentação técnica USB
hardware/um2/            descritores, perfil de stream e evidências de caracterização UM2
rtl/                     RTL SystemVerilog do projeto
tb/                      testbenches SystemVerilog
sim/verilator/            harnesses e configurações para Verilator
sim/questa/               scripts e configurações para Questa/ModelSim
quartus/                  projeto e restrições de síntese por placa
third_party/              dependências externas como submódulos Git
scripts/                  automações de desenvolvimento
```

## Dependência SPI

O núcleo SPI está registrado como submódulo Git. Após clonar este projeto:

```sh
git submodule update --init --recursive
```

Consulte o README e a licença do repositório upstream antes de distribuir uma versão que incorpore esse núcleo. O upstream informa licenciamento GPL-3.0-or-later para projetos de código aberto e opção de licença comercial.

## Ferramentas

- Verilator 5 ou mais recente para lint e simulação rápida.
- Questa ou ModelSim para simulação com GUI e fluxos de regressão.
- Intel Quartus Prime para síntese e implementação.

O projeto DE10-Lite do USB Audio Host está em `quartus/de10_lite/`; o wrapper
top-level, pin map e constraints estão implementados. As revisões Quartus
`aces2_usb_audio` e `aces2_usb_audio_debug` geram seus `.sof` nos respectivos
diretórios `output_files_*`. O procedimento de gravação da FPGA, do ESP32 e de
execução do backend está em
[`docs/usb_host/end_to_end_commands.md`](docs/usb_host/end_to_end_commands.md).

Comandos de desenvolvimento:

```sh
make lint       # lint dos tops USB Audio Host e wrapper DE10-Lite
make sim        # regressão SPI legada com Verilator
make -C tb/usb  # suite de simulação do USB Audio Host
make -C tb/usb board_long # streaming prolongado até os quadros GPIO
make questa     # ponto de entrada reservado para Questa/ModelSim
make quartus    # compila os projetos host MAX 10 e wrapper DE10-Lite
# use QUARTUS_SH=/path/to/quartus_sh se Quartus não estiver no PATH
```

`make lint` verifica os tops do host e wrapper. `make quartus` executa os fits core e DE10-Lite (configure `QUARTUS_SH` se necessário). Os procedimentos de hardware, relatórios, resultados e limitações estão documentados em [`docs/usb_host/`](docs/usb_host/architecture.md). Não trate os resultados simulados como validação física.

## Documentação

- [Visão geral da arquitetura](docs/architecture.md)
- [Decisões e pendências](docs/decisions.md)
- [Fluxo de desenvolvimento](docs/development.md)
- [Créditos e licenças de terceiros](THIRD_PARTY.md)
- [Arquitetura USB Audio Host](docs/usb_host/architecture.md)
- [Comandos para gravar FPGA/ESP32 e iniciar captura no backend](docs/usb_host/end_to_end_commands.md)
- [Referências técnicas usadas e arquivadas](docs/usb_host/references/README.md)
- [Caracterização observada da UM2](hardware/um2/characterization_report.md)
- [Auditoria de conclusão e itens pendentes](docs/usb_host/completion_audit.md)
- [Configurador Android React Native para o ESP32](software/android_app/README.md)
