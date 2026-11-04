# Procedimento fim a fim: FPGA, ESP32 e backend

Este guia reúne os comandos para preparar a rede, compilar e gravar o firmware
no ESP32, programar a FPGA DE10-Lite e receber o áudio no computador. Ele
descreve a configuração que foi usada na captura funcional: FPGA USB Audio
debug → SPI → ESP32 → Wi-Fi/UDP → receptor Python. O ESP32 encaminha dados; a
enumeração USB e a aquisição PCM ocorrem na FPGA.

Execute os comandos a partir da raiz do repositório, salvo quando indicado.

## 1. Preparar o destino UDP

O ESP32 precisa enviar para o endereço IP do computador na mesma rede Wi-Fi.
Inicie o backend primeiro para ele imprimir os endereços locais que detectou:

```bash
python3 software/udp_receiver/aces2_udp_receiver.py \
  --bind 0.0.0.0 --port 5000 \
  --channels 2 --sample-rate 48000 \
  --wav /tmp/aces2_um2.wav
```

Deixe este processo aberto em um terminal. Nos passos seguintes, use outro
terminal para os comandos de configuração e gravação. Na saída, localize o IP
da interface conectada à rede Wi-Fi que o ESP32 usará. Se houver vários
endereços, escolha o da mesma sub-rede do ESP32. A porta padrão do firmware e
do backend é UDP `5000`.
Permita a entrada UDP nessa porta no firewall do computador.

Se preferir apenas ouvir em tempo real, sem gravar WAV, use `--play` no lugar
de `--wav ...`:

```bash
python3 software/udp_receiver/aces2_udp_receiver.py \
  --bind 0.0.0.0 --port 5000 --channels 2 --sample-rate 48000 --play
```

Para priorizar a captura e ouvir depois, mantenha a gravação WAV. Ao terminar,
pressione `Ctrl-C`; o receptor fecha o arquivo corretamente. Reproduza-o com
um reprodutor de áudio ou, em Linux com ALSA, por exemplo:

```bash
aplay -f S16_LE -r 48000 -c 2 /tmp/aces2_um2.wav
```

## 2. Configurar, compilar e gravar o ESP32

Edite `software/esp32/main/wifi_config.h` antes de compilar. Configure o SSID,
a senha local da rede, o IP do computador obtido no passo anterior e a porta
UDP `5000`. Não publique a senha em documentação, logs ou commits. O firmware
atual usa ESP-IDF 6.1 e a porta serial observada nesta bancada foi
`/dev/ttyUSB0`; confirme ambas no seu ambiente.

Ative o ambiente ESP-IDF e compile/grave:

```bash
source /home/enoch/.espressif/tools/activate_idf_v6.1.sh
cd software/esp32
idf.py --version
idf.py build
idf.py -p /dev/ttyUSB0 flash
```

Se o ESP32 aparecer em outra porta, substitua `/dev/ttyUSB0` (confira, por
exemplo, com `ls /dev/ttyUSB* /dev/ttyACM*`). Para acompanhar a inicialização
e os contadores SPI/UDP:

```bash
idf.py -p /dev/ttyUSB0 monitor
```

Saia do monitor com `Ctrl-]`. O monitor e o backend são processos separados;
deixe o backend ativo durante a captura. Se o monitor estiver aberto, feche-o
antes de executar outra gravação na mesma porta serial.

## 3. Compilar e gravar a FPGA

A imagem de captura fim a fim é a revisão Quartus `aces2_usb_audio_debug`,
com top-level USB Audio Host e transporte SPI ajustado para o ESP32. O arquivo
`.sof` é volátil: ele precisa ser gravado novamente depois de desligar a
DE10-Lite. Para recompilar usando a instalação Quartus Prime Standard 25.1std
registrada nesta máquina:

```bash
cd quartus/de10_lite
/home/enoch/altera_lite/25.1std/quartus/bin/quartus_sh \
  --flow compile aces2_usb_audio_debug -c aces2_usb_audio_debug
```

Conecte a DE10-Lite por USB-Blaster e descubra o nome atual do cabo JTAG:

```bash
/home/enoch/altera_lite/25.1std/quartus/bin/jtagconfig
```

Use exatamente o nome listado (pode mudar entre conexões) no comando abaixo.
O exemplo usa `USB-Blaster [1-2]`; troque-o se `jtagconfig` mostrar outro:

```bash
/home/enoch/altera_lite/25.1std/quartus/bin/quartus_pgm \
  -c 'USB-Blaster [1-2]' -m JTAG \
  -o 'p;output_files_usb_audio_debug/aces2_usb_audio_debug.sof'
```

Os comandos de compilação e programação devem ser executados no diretório
`quartus/de10_lite`. Se não for necessário recompilar, programe o `.sof`
existente diretamente com o segundo comando. Confira no Quartus a mensagem de
programação concluída e observe os LEDs de estado descritos em
[`board_bringup.md`](board_bringup.md).

## 4. Ordem recomendada para uma captura

1. Conecte a interface UM2 ao shield MAX3421E ligado à DE10-Lite e conecte o
   ESP32 à FPGA com GND comum e sinais SPI conforme
   [`board_bringup.md`](board_bringup.md).
2. Inicie o receptor UDP do passo 1 e confirme qual IP deve ser configurado.
3. Atualize SSID/senha/IP em `wifi_config.h`, compile e grave o ESP32; abra o
   monitor serial se quiser acompanhar os contadores.
4. Grave `aces2_usb_audio_debug.sof` na DE10-Lite.
5. Confirme no monitor ESP32 quadros SPI completos e sem erros de CRC; no
   backend, confirme que os contadores de pacotes e quadros avançam, sem
   pacotes inválidos ou lacunas de sequência persistentes.
6. Faça a captura por alguns segundos e encerre o backend com `Ctrl-C` para
   finalizar o WAV.

O receptor imprime os endereços IP que encontrou e estatísticas periódicas.
Se não chegarem pacotes, confirme primeiro IP de destino, SSID, conectividade
Wi-Fi e firewall; se UDP chegar mas a captura não avançar, confira o monitor
serial do ESP32. O histórico das falhas de transporte e a configuração que
resolveu a recepção SPI estão em
[`esp32_spi_audio_postmortem.md`](esp32_spi_audio_postmortem.md).

## Referências de comandos por componente

- [Firmware e protocolo SPI do ESP32](../../software/esp32/README.md)
- [Receptor UDP, gravação WAV e reprodução](../../software/udp_receiver/README.md)
- [Conexões e bring-up da DE10-Lite](board_bringup.md)
