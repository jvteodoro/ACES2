`timescale 1ns/1ps

module spi_uc_tb;
  localparam int DATA_WIDTH = 32;

  logic rst_ni;
  logic [DATA_WIDTH-1:0] tx_data;
  logic tx_valid, tx_ready;
  logic tx_full, tx_empty, busy;
  logic rx_empty, rx_ready, rx_re;
  logic start, tx_we;
  logic [DATA_WIDTH-1:0] tx_wdata;
  logic cpol, cpha, lsb_first, cs_inter_byte;
  logic [0:0] cs_sel;
  logic [7:0] clk_div;
  logic [1:0] cs_setup, cs_hold;
  logic [8*32-1:0] sim_status;
  integer checks;
  integer failures;

  spi_uc #(
    .DATA_WIDTH      (DATA_WIDTH),
    .NUM_CS          (2),
    .FIFO_DEPTH      (16),
    .DIV_WIDTH       (8),
    .CS_DLY_W        (2),
    .SPI_CLK_DIV     (3),
    .CS_SEL          (1),
    .CS_SETUP_CYCLES (2),
    .CS_HOLD_CYCLES  (1)
  ) dut (
    .rst_ni,
    .tx_data_i        (tx_data),
    .tx_valid_i       (tx_valid),
    .tx_ready_o       (tx_ready),
    .tx_full_i        (tx_full),
    .tx_empty_i       (tx_empty),
    .busy_i           (busy),
    .rx_empty_i       (rx_empty),
    .rx_ready_i       (rx_ready),
    .rx_re_o          (rx_re),
    .start_o          (start),
    .tx_we_o          (tx_we),
    .tx_wdata_o       (tx_wdata),
    .cpol_o           (cpol),
    .cpha_o           (cpha),
    .lsb_first_o      (lsb_first),
    .cs_sel_o         (cs_sel),
    .clk_div_o        (clk_div),
    .cs_setup_cycles_o(cs_setup),
    .cs_hold_cycles_o (cs_hold),
    .cs_inter_byte_o  (cs_inter_byte)
  );

  task automatic check(input logic condition, input string name);
    checks = checks + 1;
    if (!condition) begin
      failures = failures + 1;
      $display("[FAIL][UC] %s", name);
    end else begin
      $display("[PASS][UC] %s", name);
    end
  endtask

  initial begin
    $dumpfile("spi_uc_tb.vcd");
    $dumpvars(0, spi_uc_tb);
    checks = 0;
    failures = 0;
    sim_status = "INIT";
    tx_data = 32'h1234_5678;
    tx_valid = 1'b1;
    tx_full = 1'b0;
    tx_empty = 1'b1;
    busy = 1'b0;
    rx_empty = 1'b1;
    rx_ready = 1'b0;
    rst_ni = 1'b0;
    sim_status = "RESET";
    #1;
    check(!tx_ready && !tx_we && !start && !rx_re, "reset bloqueia handshakes");

    rst_ni = 1'b1;
    sim_status = "CHECK_TX";
    #1;
    check(tx_ready && tx_we && (tx_wdata == tx_data), "aceita palavra TX");
    check(start == 1'b0, "não inicia com FIFO TX vazia");

    tx_full = 1'b1;
    sim_status = "CHECK_BACKPRESSURE";
    #1;
    check(!tx_ready && !tx_we, "aplica backpressure com FIFO cheia");

    tx_full = 1'b0;
    tx_valid = 1'b0;
    tx_empty = 1'b0;
    sim_status = "CHECK_START";
    #1;
    check(start == 1'b1, "inicia quando há palavra e master está ocioso");

    busy = 1'b1;
    sim_status = "CHECK_BUSY";
    #1;
    check(start == 1'b0, "não reinicia durante transferência");

    rx_empty = 1'b0;
    rx_ready = 1'b0;
    sim_status = "CHECK_RX";
    #1;
    check(!rx_re, "mantém RX quando consumidor não está pronto");
    rx_ready = 1'b1;
    #1;
    check(rx_re, "drena RX quando consumidor está pronto");

    sim_status = "CHECK_CONFIG";
    check(cpol == 1'b0 && cpha == 1'b0 && lsb_first == 1'b0,
          "configuração SPI modo 0 MSB-first");
    check(cs_sel == 1 && clk_div == 8'd3 && cs_setup == 2 && cs_hold == 1,
          "parâmetros SPI propagados");
    check(cs_inter_byte, "CS contínuo entre palavras");

    if (failures == 0) begin
      sim_status = "PASS";
      $display("SIMULAÇÃO spi_uc PASSOU: %0d verificações", checks);
      $finish;
    end else begin
      sim_status = "FAIL";
      $display("SIMULAÇÃO spi_uc FALHOU: %0d de %0d falhas", failures, checks);
      $fatal(1);
    end
  end
endmodule
