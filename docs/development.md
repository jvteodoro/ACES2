# Fluxo de desenvolvimento

## Layout RTL

- `rtl/top/`: integração no nível superior e interfaces com a placa.
- `rtl/usb/`: recepção USB e tratamento da classe de áudio.
- `rtl/audio/`: fluxo, empacotamento e buffers de áudio.
- `rtl/ethernet/`: inicialização e controle de sockets do W5500.
- `rtl/spi/`: adaptador local para o núcleo SPI de terceiros.
- `rtl/common/`: funções e componentes compartilhados.
- `tb/`: testbenches, modelos de dispositivos e testes de integração.

Mantenha dependências de fornecedor e arquivos gerados fora de `rtl/`. Cada módulo deve documentar clock, reset, handshake, largura dos dados e parâmetros relevantes.

## Simulação

O fluxo previsto tem duas camadas:

1. Verilator para lint e simulação rápida automatizável.
2. Questa/ModelSim para simulação interativa e regressões de compatibilidade.

Adicione testbenches pequenos por bloco e um testbench de integração para o caminho de áudio até o modelo SPI do W5500. Os comandos serão preenchidos quando os primeiros módulos e testbenches estiverem disponíveis.

## Síntese

O projeto inicial para a DE10-Lite está em `quartus/de10_lite/`. O top-level `rtl/top/aces2_top.sv` expõe os clocks, botões, switches, dez LEDs, seis displays, GPIO, conector Arduino, VGA, SDRAM e acelerômetro; o QSF mapeia todos esses sinais para o pin planner. Os seis canais analógicos Arduino são acessados pelo ADC IP do MAX 10, e não como I/O digitais. O USB-Blaster usa pinos dedicados de configuração/JTAG. As atribuições do shield W5500 e da interface USB host externa serão feitas quando a conexão física for definida. Versione arquivos de projeto, atribuições de pinos e restrições de timing; não versione bancos de compilação nem resultados gerados.

## Dependências

Inicialize submódulos com `git submodule update --init --recursive`. Registre em `THIRD_PARTY.md` o repositório de origem, revisão, licença e alterações locais (idealmente nenhuma).
