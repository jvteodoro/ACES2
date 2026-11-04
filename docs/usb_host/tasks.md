# Delegação e acompanhamento

Responsável pela arquitetura, contratos, integração, revisão e aceitação:
agente principal Codex. A implementação foi delegada efetivamente a GPT-6 Luna
por subagentes. Os agentes compartilham o worktree; o estado abaixo foi
reconciliado em 2026-11-01 com os artefatos e execuções atuais.

| ID | Responsável | Escopo | Estado |
| --- | --- | --- | --- |
| CHAR-01 | Luna characterization | Identificação e caracterização Linux/ALSA em `hardware/um2/` | Entregue e revisado; usbmon indisponível sem privilégio |
| DRV-01 | Luna max_driver | Bridge SPI/MAX, testes e notas | Entregue; testes separados aprovados |
| DRV-02 | Luna max_driver | Controller, host engine e inicialização | Entregue com correções locais; testes unitários passaram; integração final revisada pelo coordenador |
| PCM-01 | Luna pcm_datapath | Decoder PCM e buffer | Entregue; testes e síntese isolada aprovados |
| ENUM-01 | Luna characterization | Parser e enumerador | Entregue; testes com descritores observados passaram |
| CTRL-01 | Luna pcm_datapath | Transferência de controle EP0 | Entregue; TB revisado e passou com engine abstrato |
| ISO/TOP-01 | Luna pcm_datapath | Recepção isócrona, top e PCM | Entregue; ISO-02 late-SOF/jitter unit passou; backpressure atual confirmou FIFO cheia e lacunas modeladas |
| MODEL-01 | Luna characterization + coordenador | Modelo MAX3421E/UM2 sobre SPI físico e regressão integrada | Recompilado no hash atual em 2026-11-02; 1.000 frames/48.000 PCM, lacunas exatas em perda SOF, desconexão e overrun. Saída em `results/model_run_current.log`, hashes em `results/model_run.md` |
| DRV-03 / RX-PHASE-01 | Luna max_driver | Hold/arbitragem SPI, captura MISO trailing e revisão de timing | Regressões atuais e fits/STA core e placa passaram; exceções e caminhos MAX revisados. Limites externos ESP32 MOSI/CS ainda pendentes |
| REVIEW-BOARD-01 | Luna max_driver + coordenador | Revisão do wrapper e projeto/procedimentos de placa | Caminho físico USB → FPGA → ESP32 → UDP exercitado em 2026-11-03; SPI modo 1 a 5 MHz, gap CS de 100 µs; cerca de 3.530 quadros completos/s, CRC inválido=0 em regime estável. Usuário confirmou captura WAV audível. Delay elétrico no pad e revisão exata do shield continuam sem caracterização |
| UDP-DIAG-01 | Coordenador | Tornar visíveis perdas da fila de rede e falhas de envio UDP | Contadores SPI/CRC/UDP exercitados em hardware; ESP32 envia datagramas e o backend Python grava WAV. O teste físico demonstrou o funcionamento na configuração atual; veja `esp32_spi_audio_postmortem.md` |
| DOC-REVIEW-02 | Luna objective_audit + coordenador | Comparar notas históricas com o parser/decodificador atual e repetir a medição SPI | Revisão encontrou endpoint/minimum packet obsoletos e contagem de frames invertida; notas foram corrigidas. Regressão atual da bridge salvou tempos e hashes em `results/protocol/bridge_current.txt` |
| INT-01 | Coordenador | Integração independente, regressão, STA e relatório | RTL, suite USB/SPI, lint, O3, board-long, Quartus fit/STA e transporte físico executados; limites externos de MOSI/CS e qualidade de áudio calibrada continuam pendentes |
| LINT-01 | Coordenador | Alvo Verilator nos tops USB e placa | `make lint` passou nos dois tops; zero avisos padrão no RTL do projeto, dispensa de largura limitada ao core SPI de terceiros |

Os detalhes reproduzíveis e métricas estão em `architecture.md`,
`verification.md`, `completion_audit.md` e `results/`. A aceitação exige revisão
do código e evidência independente; uma declaração do implementador, sozinha,
não conclui a tarefa.

## Critérios e pontos não verificados

O perfil real capturado é PCM estéreo S16_LE a 48 kHz, identificado no Linux
como VID/PID `08bb:2902`. Não existe captura usbmon. O O3 integrado atual passou
1 segundo, 1.000 pacotes e 48.000 amostras, com injeções de perda,
desconexão/reenumeração e overrun; smoke e faults de controle também passaram.
O wrapper pelo modelo MAX/UM2 validou dois quadros GPIO/CRC no teste curto e,
no teste prolongado, 48.000 amostras no host e 47.992 palavras PCM em 3.428
quadros GPIO completos, sem descarte e com sequência/CRC/PCM contínuos. Oito
amostras ficam no grupo parcial do encoder.

O STA final dos caminhos USB/SPI MAX está aprovado: TNS=0, sem violações nos
caminhos medidos, MOSI/CS hold com exceções estreitas para clock burst-gated e
verificação por eventos no testbench. Os relatórios associam os hashes atuais.
O enlace ESP32 foi caracterizado em hardware após o ajuste de modo, DMA e gap
entre quadros. A FPGA usa 5 MHz em modo 1 e o firmware usa os pinos IO_MUX
SPI3. Os limites de atraso de SCK/MOSI/CS do receptor e interconexão ainda
precisam ser obtidos. A operação física foi confirmada, mas o roteamento e os
componentes internos exatos do shield `2045L` não foram inspecionados com
esquemático de revisão.
