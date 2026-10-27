SHELL := /bin/sh

.PHONY: help lint sim questa quartus

help:
	@printf '%s\n' \
	  'make lint    Verilator lint (requer lista de fontes RTL)' \
	  'make sim     Simulação Verilator (requer testbench)' \
	  'make questa  Simulação Questa/ModelSim (requer arquivos de simulação)' \
	  'make quartus Fluxo Quartus (requer projeto em quartus/<placa>)'

lint:
	@echo 'RTL ainda não implementado; configure a lista de fontes em sim/verilator/.'

sim:
	@echo 'Testbench ainda não disponível; consulte docs/development.md.'

questa:
	@echo 'Projeto de simulação ainda não configurado; consulte docs/development.md.'

quartus:
	@echo 'Projeto Quartus depende da definição de placa e dispositivo FPGA.'
