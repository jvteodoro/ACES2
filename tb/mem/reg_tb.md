# Documento técnico — Testbench do registrador

## 1. Objetivo

O testbench `mem/reg_tb.sv` verifica automaticamente o comportamento do
registrador implementado em `rtl/mem/reg.sv`. A simulação utiliza clock
síncrono, produz um relatório textual de aprovação/reprovação e gera o arquivo
de ondas `tb/mem/reg_tb.vcd`.

## 2. Unidade sob teste

O módulo RTL é `reg_module`, parametrizado por `DATA_WIDTH`. A interface é:

| Sinal | Direção | Largura | Descrição |
|---|---|---:|---|
| `clk` | entrada | 1 | Clock; operação na borda de subida |
| `rst` | entrada | 1 | Reset síncrono, com prioridade sobre `we` |
| `we` | entrada | 1 | Habilitação de escrita |
| `in` | entrada | `DATA_WIDTH` | Palavra de entrada |
| `out` | saída | `DATA_WIDTH` | Valor armazenado |

Com `rst=1`, o registrador recebe zero na próxima borda de subida. Com
`rst=0` e `we=1`, a palavra `in` é armazenada. Com `we=0`, o valor anterior é
mantido.

## 3. Configuração da simulação

| Parâmetro | Valor |
|---|---:|
| `DATA_WIDTH` | 32 bits |
| Período do clock | 20 ns |
| Meio período | 10 ns |
| `TEST_WORD_1` | `0x00000066` |
| `TEST_WORD_2` | `0xA5A55A5A` |

O clock é gerado continuamente pelo testbench. Os estímulos são aplicados em
borda de descida e as verificações ocorrem após a borda de subida seguinte,
evitando ambiguidade de amostragem.

## 4. Casos verificados

1. **Reset:** duas bordas de clock com `rst=1` devem produzir `out=0`.
2. **Escrita:** com `we=1`, `TEST_WORD_1` deve aparecer em `out`.
3. **Retenção:** com `we=0`, uma nova entrada não pode alterar `out`.
4. **Sobrescrita:** `TEST_WORD_2` deve substituir o valor anterior.
5. **Prioridade do reset:** com `rst=1` e `we=1` simultaneamente, o resultado
   deve ser zero, e não o valor de entrada.

Cada caso usa comparação `!==`, portanto valores `X` ou `Z` também causam
falha. O contador `test_num` identifica o caso e `failure_count` registra
falhas. Ao final, `sim_status` recebe `PASS` ou `FAIL`; em caso de falha, a
simulação termina com `$fatal`.

## 5. Execução

A partir da raiz do repositório:

```sh
make -C tb sim
```

Ou diretamente pelo alvo da raiz:

```sh
make sim
```

O executável intermediário do Verilator é colocado em `obj_dir/`, que é
ignorado pelo Git. O VCD é gravado em:

```text
tb/mem/reg_tb.vcd
```

## 6. Visualização das ondas

O script [reg_tb.tcl](reg_tb.tcl) organiza a visualização no GTKWave:

- `clk`, `rst` e `we` ficam no grupo **CLOCK E CONTROLE**;
- `in` e `out` ficam no grupo **CAMINHO DE DADOS** e são exibidos em
  hexadecimal;
- `sim_status` é exibido em ASCII;
- `test_num` e `failure_count` são exibidos em decimal;
- comentários separam os grupos;
- cores diferentes distinguem clock, reset, habilitação, dados e status;
- marcadores `A` a `D` identificam os principais pontos da simulação.

Para abrir o VCD com a configuração:

```sh
gtkwave -S tb/mem/reg_tb.tcl tb/mem/reg_tb.vcd
```

Também é possível usar o alvo do Makefile:

```sh
make -C tb waves
```

## 7. Critério de aprovação

A simulação é aprovada quando todos os casos exibem `[PASS]` e o terminal
apresenta:

```text
SIMULAÇÃO PASSOU: 5 casos verificados
```
