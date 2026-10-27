# Decisões e pendências

## Decisões registradas

| ID | Decisão | Estado |
| --- | --- | --- |
| D-001 | Usar SystemVerilog como linguagem RTL principal. | Adotada |
| D-002 | Suportar lint/simulação com Verilator e simulação com Questa/ModelSim. | Adotada |
| D-003 | Usar Intel Quartus para síntese e implementação. | Adotada |
| D-004 | Consumir `ayoub-ac/spi-fpga-core` como submódulo Git, sem copiar seus fontes para o RTL do projeto. | Adotada |
| D-005 | Manter documentação de arquitetura e decisões versionada no repositório. | Adotada |
| D-006 | Usar a placa Terasic DE10-Lite com MAX 10 10M50DAF484C7G como alvo inicial. | Adotada |

## Pendências que afetam a implementação

| Tema | Pergunta a resolver | Impacto |
| --- | --- | --- |
| Host USB | Qual controlador/PHY host externo e conexão física serão usados com a DE10-Lite? | É necessário hardware host compatível com a velocidade USB do dispositivo e conexão com a FPGA. |
| Classe USB | Qual versão/perfil USB Audio Class e configuração de áudio da UM2 serão suportados? | Define enumeração, endpoints, descritores, frequência e formato das amostras. |
| Rede | O áudio será transmitido por UDP ou TCP? Qual formato de pacote? | Define protocolo, latência, recuperação de perda e configuração de sockets no W5500. |
| SPI | Qual modo, frequência e sinais do shield W5500 serão utilizados? | Define parâmetros do núcleo SPI e atribuição de pinos. |
| Temporização | Quais clocks de referência, taxa de amostragem e requisitos de latência? | Define buffers, CDCs, restrições SDC e dimensionamento. |
| Licença | A distribuição será compatível com GPL-3.0-or-later ou será necessária licença comercial para o núcleo SPI? | Afeta redistribuição e publicação do projeto. |

O projeto Quartus usa MAX10_CLK1_50 (50 MHz, pino P11) e KEY0 (pino B8) como entrada de reset ativa em nível baixo. As atribuições do W5500 permanecem em aberto até confirmar a revisão do shield e os pinos usados no cabeçalho de expansão.

## Registro de decisões futuras

Acrescente uma entrada com contexto, decisão, alternativas consideradas e consequências quando uma pendência for resolvida. Evite colocar parâmetros ainda não medidos ou confirmados como constantes RTL definitivas.
