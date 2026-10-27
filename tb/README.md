# Testbenches

Adicione testbenches SystemVerilog e modelos de dispositivos aqui. Organize os testes por bloco e documente os comandos de execução e critérios de aprovação.

## `mem/reg_tb.sv`

Execute a simulação com:

```sh
make -C tb sim
```

O testbench verifica reset, escrita, retenção sem `we`, sobrescrita e prioridade
do reset. Em caso de sucesso, exibe `SIMULAÇÃO PASSOU` e gera
`tb/mem/reg_tb.vcd` para inspeção das formas de onda.

Consulte o [documento técnico do registrador](mem/reg_tb.md) para a descrição da interface,
casos de teste e visualização no GTKWave.

O adaptador SPI possui testes unitário e integrado documentados em
[spi/spi_tb.md](spi/spi_tb.md).
