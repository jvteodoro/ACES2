`timescale 1ns/1ps

module spi_tb;
  localparam int DATA_WIDTH = 32;
  localparam int NUM_WORDS = 4;

  logic clk_i;
  logic rst_ni;
  logic [DATA_WIDTH-1:0] tx_data_i;
  logic tx_valid_i, tx_ready_o, tx_stall_o;
  logic [DATA_WIDTH-1:0] rx_data_o;
  logic rx_valid_o, rx_ready_i;
  logic miso_i, mosi_o, sck_o;
  logic [0:0] cs_n_o;
  logic busy_o, xfer_done_o;

  logic [DATA_WIDTH-1:0] expected [0:NUM_WORDS-1];
  logic [DATA_WIDTH-1:0] received [0:NUM_WORDS-1];
  integer received_count;
  integer accepted_count;
  integer cs_fall_count;
  integer cs_rise_count;
  integer failures;
  integer bit_count;
  logic [DATA_WIDTH-1:0] slave_shift;
  logic test_done;
  logic [8*32-1:0] sim_status;

  spi #(
    .DATA_WIDTH        (DATA_WIDTH),
    .NUM_CS            (1),
    .SPI_FIFO_DEPTH    (8),
    .SPI_CLK_DIV_WIDTH (8),
    .SPI_CLK_DIV       (1),
    .CPOL              (1'b0),
    .CPHA              (1'b0)
  ) dut (
    .clk_i,
    .rst_ni,
    .tx_data_i,
    .tx_valid_i,
    .tx_ready_o,
    .tx_stall_o,
    .rx_data_o,
    .rx_valid_o,
    .rx_ready_i,
    .miso_i,
    .mosi_o,
    .sck_o,
    .cs_n_o,
    .busy_o,
    .xfer_done_o
  );

  always #5 clk_i = ~clk_i;

  // Mode 0 slave model: sample MOSI on rising SCK edges. MISO is held low
  // for this transport-only test, while RX is drained by rx_ready_i.
  always @(posedge sck_o) begin
    if (!cs_n_o[0]) begin
      slave_shift <= {slave_shift[DATA_WIDTH-2:0], mosi_o};
      if (bit_count == DATA_WIDTH-1) begin
        received[received_count] <= {slave_shift[DATA_WIDTH-2:0], mosi_o};
        received_count <= received_count + 1;
        bit_count <= 0;
      end else begin
        bit_count <= bit_count + 1;
      end
    end
  end

  always @(negedge cs_n_o[0])
    if (rst_ni) cs_fall_count = cs_fall_count + 1;
  always @(posedge cs_n_o[0])
    if (rst_ni) cs_rise_count = cs_rise_count + 1;

  always @(posedge clk_i) begin
    if (tx_valid_i && tx_ready_o)
      accepted_count = accepted_count + 1;
    if (tx_stall_o)
      failures = failures + 1;
    if (cs_n_o[0] && sck_o !== 1'b0)
      failures = failures + 1;
  end

  task automatic send_word(input logic [DATA_WIDTH-1:0] word);
    tx_data_i = word;
    tx_valid_i = 1'b1;
    do @(posedge clk_i); while (!tx_ready_o);
    @(negedge clk_i);
    tx_valid_i = 1'b0;
  endtask

  task automatic check_word(input integer index);
    if (received[index] !== expected[index]) begin
      failures = failures + 1;
      $display("[FAIL][SPI] palavra %0d: esperado=%h recebido=%h",
               index, expected[index], received[index]);
    end else begin
      $display("[PASS][SPI] palavra %0d: %h", index, received[index]);
    end
  endtask

  initial begin
    $dumpfile("spi_tb.vcd");
    $dumpvars(0, spi_tb);
    expected[0] = 32'h0000_0001;
    expected[1] = 32'h1234_5678;
    expected[2] = 32'hA5A5_5A5A;
    expected[3] = 32'hDEAD_BEEF;
    sim_status = "INIT";
    clk_i = 1'b0;
    rst_ni = 1'b0;
    tx_data_i = '0;
    tx_valid_i = 1'b0;
    rx_ready_i = 1'b1;
    miso_i = 1'b0;
    received_count = 0;
    accepted_count = 0;
    cs_fall_count = 0;
    cs_rise_count = 0;
    failures = 0;
    bit_count = 0;
    slave_shift = '0;
    test_done = 1'b0;

    repeat (4) @(posedge clk_i);
    sim_status = "RESET";
    rst_ni = 1'b1;
    @(negedge clk_i);
    sim_status = "SEND_WORD_0";
    send_word(expected[0]);
    sim_status = "SEND_WORD_1";
    send_word(expected[1]);
    sim_status = "SEND_WORD_2";
    send_word(expected[2]);
    sim_status = "SEND_WORD_3";
    send_word(expected[3]);

    sim_status = "WAIT_TRANSFER";
    wait (xfer_done_o);
    repeat (3) @(posedge clk_i);
    sim_status = "CHECK_BURST";
    if (accepted_count != NUM_WORDS) begin
      failures = failures + 1;
      $display("[FAIL][SPI] accepted_count=%0d", accepted_count);
    end
    if (received_count != NUM_WORDS) begin
      failures = failures + 1;
      $display("[FAIL][SPI] received_count=%0d", received_count);
    end
    if (cs_fall_count != 1 || cs_rise_count != 1) begin
      failures = failures + 1;
      $display("[FAIL][SPI] CS não contínuo: falls=%0d rises=%0d",
               cs_fall_count, cs_rise_count);
    end
    for (integer i = 0; i < NUM_WORDS; i = i + 1)
      check_word(i);

    if (failures == 0) begin
      sim_status = "PASS";
      $display("SIMULAÇÃO spi PASSOU: burst de %0d palavras sem stall", NUM_WORDS);
      test_done = 1'b1;
      $finish;
    end else begin
      sim_status = "FAIL";
      $display("SIMULAÇÃO spi FALHOU: %0d falhas", failures);
      $fatal(1);
    end
  end
endmodule
