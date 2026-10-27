# ACES2

Projeto de FPGA para captura de áudio via USB e transmissão por Ethernet usando um shield W5500. O W5500 será controlado pela interface SPI por meio do núcleo [`spi-fpga-core`](https://github.com/ayoub-ac/spi-fpga-core).

Este repositório dá continuidade ao [ACES original](https://github.com/jvteodoro/ACES), que contém uma estrutura inicial de recepção I²S e processamento FFT. A arquitetura e o hardware desta nova etapa ainda estão em definição; os documentos em `docs/` registram o escopo e as decisões pendentes.

## Estado do projeto

Esta é a estrutura inicial do projeto. O alvo de hardware é a Terasic DE10-Lite com FPGA Intel MAX 10 10M50DAF484C7G. Ainda não há implementação RTL do host USB, do protocolo de rede nem integração do W5500.

## Estrutura

```text
docs/                    documentação de arquitetura, decisões e desenvolvimento
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

O projeto da DE10-Lite está em `quartus/de10_lite/` e aguarda o módulo top-level e o mapeamento dos periféricos.

Comandos de desenvolvimento planejados:

```sh
make lint       # lint de RTL (quando os módulos estiverem implementados)
make sim        # simulação com Verilator
make questa     # compilar e executar a simulação em Questa/ModelSim
make quartus    # fluxo de síntese Quartus, requer projeto de placa configurado
```

Os comandos de simulação e síntese são pontos de entrada da estrutura; ainda não há testbench. O projeto Quartus seleciona a DE10-Lite e registra o clock e reset da placa, mas ainda depende do módulo top-level para compilar.

## Documentação

- [Visão geral da arquitetura](docs/architecture.md)
- [Decisões e pendências](docs/decisions.md)
- [Fluxo de desenvolvimento](docs/development.md)
- [Créditos e licenças de terceiros](THIRD_PARTY.md)
