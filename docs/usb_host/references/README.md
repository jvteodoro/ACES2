# Referências técnicas do USB Audio Host

Os documentos usados no desenvolvimento ficam neste diretório. Consulte
[manifest.json](manifest.json) para títulos, revisões, URLs oficiais, endereço
efetivamente usado no download, tamanho, finalidade e SHA-256 de cada arquivo.
O manual da placa já existente continua em
[DE10-Lite_User_Manual.pdf](../../DE10-Lite_User_Manual.pdf).

| Documento local | Uso no projeto |
| --- | --- |
| [MAX3421E.pdf](MAX3421E.pdf) | Datasheet Rev. 4: SPI, limites elétricos e registradores |
| [max3421e-programming-guide.pdf](max3421e-programming-guide.pdf) | Inicialização, controle, interrupções e ISO com dois FIFOs de 64 bytes |
| [pcm2902.pdf](pcm2902.pdf) | Datasheet TI SLES035E: formatos, taxas e comportamento do codec |
| [audio10.pdf](audio10.pdf) | USB Audio Class 1.0: descritores e controles |
| [usb_20.pdf](usb_20.pdf) | USB 2.0: protocolo, enumeração e transferências |
| [usb_20_20250603.zip](usb_20_20250603.zip) | Pacote oficial completo, incluindo errata e ECNs |
| [hut1_3_0.pdf](hut1_3_0.pdf) | HID Usage Tables 1.3: interpretação dos controles HID observados na UM2 |
| [quartus_timequest_notes.md](quartus_timequest_notes.md) | Referências Intel e comandos SDC/STA verificados no Quartus Prime 25.1 Standard |
| [esp32_spi_slave_notes.md](esp32_spi_slave_notes.md) | Guia oficial ESP-IDF 6.1 e TRM ESP32 5.2: limite SPI, pinos IO_MUX e limites de timing MOSI/CS |
| [usb_host_shield_pinout.md](usb_host_shield_pinout.md) | Manual de hardware do USB Host Shield 2.0: Arduino D9-D13, RESET, GPX, alimentação e variantes |

Os PDFs Maxim foram obtidos como cópias dos documentos originais hospedadas
pela SparkFun: o servidor da Analog Devices recusou os downloads por HTTP/2
e não respondeu à tentativa HTTP/1.1. As versões oficiais foram consultadas
pela ferramenta de pesquisa; os PDFs locais identificam o mesmo título,
revisão e número de páginas. Isso não constitui comparação binária com um
download direto da Analog Devices. Os documentos TI e USB-IF vieram dos
servidores oficiais. O ZIP USB foi validado por CRC e o PDF base extraído dele.

Verificação das cópias locais, a partir deste diretório:

```sh
sha256sum -c SHA256SUMS
```

Os direitos autorais e avisos de cada documento permanecem com seus titulares;
os documentos de terceiros não recebem a licença do RTL do projeto.

Os dados efetivamente observados na UM2 estão em
[hardware/um2](../../../hardware/um2/). O datasheet do PCM2902 complementa
essa caracterização; não substitui os descritores do dispositivo conectado.
Documentos arquivados não significam revisão técnica ou implementação concluída.
