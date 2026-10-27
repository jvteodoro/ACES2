# Visão geral da arquitetura

## Objetivo

Capturar áudio recebido de uma interface Behringer UM2 conectada por USB e transmitir os dados por Ethernet usando o controlador W5500 em um shield conectado à FPGA por SPI.

## Blocos previstos

```text
Behringer UM2
     │ USB (host ainda a definir)
     ▼
Host USB / USB Audio Class
     │ amostras de áudio e controle de fluxo
     ▼
Buffer de áudio
     │ fluxo de dados
     ▼
Empacotamento de rede ──► W5500 ──► Ethernet
                            ▲
                     controlador SPI
```

Os blocos são uma decomposição inicial, não uma especificação funcional. Interfaces, largura e frequência de amostragem, formato dos pacotes e comportamento em caso de buffer cheio serão definidos em decisões futuras.

## Fronteiras de projeto

- O host USB deve enumerar a interface UM2 e suportar o perfil USB Audio Class compatível com o dispositivo.
- O buffer deve absorver diferenças temporárias entre a taxa de chegada das amostras e a transmissão Ethernet.
- O W5500 fornece TCP/IP por hardware, mas exige inicialização de registradores e envio/recepção de dados através de SPI.
- O controlador SPI de terceiros será integrado como dependência isolada, com uma camada adaptadora do projeto para encapsular a interface específica do núcleo.

## Relação com o ACES original

O repositório original contém uma referência de receptor I²S e integração com FFT. Nesta nova arquitetura, a aquisição indicada é USB. A reutilização de blocos do ACES original só deve ocorrer depois de validar suas interfaces, dependências, restrições de ferramenta e compatibilidade de licença.
