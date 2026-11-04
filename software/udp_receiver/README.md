# Receptor UDP do ACES2

Backend mínimo para verificar o envio de blocos de áudio do ESP32 para o
computador pela rede local. Ele usa somente a biblioteca padrão do Python.

## Executar

A partir da raiz do projeto:

```bash
python3 software/udp_receiver/aces2_udp_receiver.py
```

Ou escolhendo a porta:

```bash
python3 software/udp_receiver/aces2_udp_receiver.py --port 5000
```

Para gravar o fluxo em WAV estéreo, 16 bits e 48 kHz:

```bash
python3 software/udp_receiver/aces2_udp_receiver.py \
  --wav captura.wav --sample-rate 48000 --channels 2 --sample-bits 16
```

Cada palavra de 32 bits da FPGA contém `{right_s16,left_s16}`. O receptor
desempacota os canais em ordem L/R no WAV estéreo. `--channels 1` grava somente
o canal esquerdo. Com `--fill-loss`, o servidor insere silêncio para lacunas de
sequência UDP.

O servidor imprime os endereços IP detectados. Configure no ESP32 o endereço
da interface que está na mesma rede:

```c
#define ACES2_WIFI_ENABLE    1
#define ACES2_UDP_DEST_IP    "192.168.1.123"
#define ACES2_UDP_DEST_PORT  5000
```

Se o firewall do computador estiver ativo, permita tráfego UDP de entrada na
porta escolhida.

Para reproduzir o áudio recebido diretamente no computador via ALSA, adicione
`--play` ao comando. O dispositivo padrão deve estar configurado no sistema.
Use `--channels 2` para ouvir estéreo:

```bash
python3 software/udp_receiver/aces2_udp_receiver.py \
  --play --channels 2 --wav captura.wav --sample-rate 48000
```

Se a reprodução ao vivo apresentar pausas, grave primeiro e reproduza o WAV
depois. O modo WAV continua ativo até Ctrl-C, que fecha e finaliza o arquivo.

## Formato aceito

O cabeçalho tem 12 bytes em big-endian:

```text
uint32 magic        = 0x41434553 ("ACES")
uint32 sequence
uint16 frame_count (quadros estéreo)
uint16 flags
```

Depois do cabeçalho vêm `frame_count` palavras de 32 bits em little-endian. O
servidor valida tamanho, magic e sequência, mostra valores PCM L/R assinados,
grava ambos os canais e imprime a taxa de quadros e lacunas. Para PCM estéreo
S16_LE a 48 kHz, espere aproximadamente 48.000 quadros por segundo.

## Arquitetura e estado da validação

O caminho implementado para o protótipo é UM2 → MAX3421E → FPGA → SPI → ESP32
→ Wi-Fi/UDP → este receptor. A stack USB e a aquisição PCM ficam integralmente
na FPGA; o ESP32 recebe quadros SPI, valida magic, CRC-32 e sequência, e os
encaminha pela rede. O receptor UDP valida datagramas e pode salvar WAV estéreo.

A captura física de 2026-11-03 confirmou quadros SPI completos de 512 bits no
ESP32, CRC válido e encaminhamento de datagramas UDP. O histórico das falhas e
a configuração aprovada estão em
[`docs/usb_host/esp32_spi_audio_postmortem.md`](../../docs/usb_host/esp32_spi_audio_postmortem.md).
Para validar conteúdo com um tom calibrado, use uma fonte de áudio conhecida
ligada às entradas LINE IN e siga o procedimento abaixo e o guia em
[`docs/usb_host/board_bringup.md`](../../docs/usb_host/board_bringup.md).

## Teste físico com sinal conhecido

1. Gere um WAV estéreo de 3 s, com tons distintos e nível baixo:

   ```bash
   python3 software/udp_receiver/make_test_tone.py /tmp/um2_test_tone.wav
   ```

2. Conecte a UM2 ao shield MAX3421E e à DE10-Lite, não ao USB do computador.
   Programe o `.sof` e confira LEDR0–4 conforme
   `docs/usb_host/board_bringup.md`.
3. Grave o ESP32 como receptor/ponte de diagnóstico e configure seu destino UDP
   para o computador. Inicie o receptor antes de tocar o sinal:

   ```bash
   python3 software/udp_receiver/aces2_udp_receiver.py \
     --channels 2 --sample-rate 48000 --wav /tmp/um2_capture.wav
   ```

4. Reproduza o WAV por uma saída analógica separada ligada às entradas LINE IN
   da UM2. Comece com volume baixo; encerre o receptor com Ctrl-C após alguns
   segundos.
5. Analise ambos os canais:

   ```bash
   python3 software/udp_receiver/analyze_capture.py /tmp/um2_capture.wav
   ```

O analisador espera 48 kHz PCM16 estéreo, tom esquerdo de 997 Hz e direito de
1597 Hz (tolerância padrão ±15 Hz), nível presente e sem clipping. O monitor
serial do ESP32 deve manter CRC/seq/descartes em zero; o receptor UDP deve
reportar cerca de 48.000 quadros/s sem lacunas ou datagramas inválidos. A
sequência de LEDs, contadores e frequências ajuda a localizar falhas na
conexão/reset MAX, enumeração, endpoint ISO, decoder PCM ou transporte.

## Gerar o mock na FPGA

Para transformar um WAV PCM de 16 bits em memória ROM da FPGA:

```bash
make -C software wav_to_fpga WAV=/caminho/para/mock.wav
```

Por padrão, é usado no máximo um segundo de áudio a 48 kHz. O comando gera
`rtl/top/audio_mock.mem` e atualiza
`rtl/top/audio_mock_config.svh`. Depois, recompile o projeto Quartus
`aces2_de10_lite`. Com `SW9` ligado, o `aces2_top` reproduz a ROM em loop e a
envia pelo SPI.

O mock mono ocupa uma palavra por amostra. O USB Host envia cada quadro estéreo
como uma palavra `{right_s16,left_s16}`; para essa captura, use `--channels 2`.
