`timescale 1ns/1ps

module spi_frame_encoder_tb;
  logic clk_i, rst_ni;
  logic [31:0] payload_data_i, tx_data_o;
  logic payload_valid_i, payload_ready_o, tx_valid_o, tx_ready_i;
  logic [31:0] payload [0:13];
  logic [31:0] frame [0:15];
  logic [31:0] crc_check;
  integer input_index, output_index, failures;
  logic [8*32-1:0] sim_status;

  spi_frame_encoder dut (
    .clk_i, .rst_ni,
    .payload_data_i, .payload_valid_i, .payload_ready_o,
    .tx_data_o, .tx_valid_o, .tx_ready_i
  );

  always #5 clk_i = ~clk_i;

  function automatic [31:0] crc32_word(input [31:0] crc_i, input [31:0] data_i);
    reg [31:0] crc;
    integer b, bit_i;
    begin
      crc = crc_i;
      for (b = 3; b >= 0; b = b - 1) begin
        crc = crc ^ ((data_i >> (b * 8)) & 32'hff);
        for (bit_i = 0; bit_i < 8; bit_i = bit_i + 1)
          crc = crc[0] ? ((crc >> 1) ^ 32'hedb88320) : (crc >> 1);
      end
      crc32_word = crc;
    end
  endfunction

  initial begin
    $dumpfile("spi_frame_encoder_tb.vcd");
    $dumpvars(0, spi_frame_encoder_tb);
    payload[0] = 32'h0000_0001;
    payload[1] = 32'h1234_5678;
    for (integer i = 2; i < 14; i = i + 1)
      payload[i] = 32'h1000_0000 + i;
    clk_i = 0; rst_ni = 0; payload_valid_i = 0; payload_data_i = 0;
    tx_ready_i = 1; input_index = 0; output_index = 0; failures = 0;
    sim_status = "RESET";
    repeat (3) @(posedge clk_i);
    rst_ni = 1;
    sim_status = "COLLECT_PAYLOAD";
    while (input_index < 14) begin
      @(negedge clk_i);
      payload_data_i = payload[input_index];
      payload_valid_i = 1;
      @(posedge clk_i);
      if (payload_ready_o) input_index = input_index + 1;
    end
    @(negedge clk_i); payload_valid_i = 0;
    sim_status = "CHECK_FRAME";
    while (output_index < 16) begin
      @(posedge clk_i);
      if (tx_valid_o && tx_ready_i) begin
        frame[output_index] = tx_data_o;
        output_index = output_index + 1;
      end
    end

    if (frame[0] !== 32'hACED_0000) begin
      failures = failures + 1;
      $display("header=%h", frame[0]);
    end
    for (integer j = 0; j < 14; j = j + 1)
      if (frame[j+1] !== payload[j]) begin
        failures = failures + 1;
        $display("payload[%0d]=%h esperado=%h", j, frame[j+1], payload[j]);
      end
    crc_check = crc32_word(32'hFFFF_FFFF, frame[0]);
    for (integer k = 1; k < 15; k = k + 1)
      crc_check = crc32_word(crc_check, frame[k]);
    crc_check = crc_check ^ 32'hFFFF_FFFF;
    if (frame[15] !== crc_check) begin
      failures = failures + 1;
      $display("crc=%h esperado=%h", frame[15], crc_check);
    end

    if (failures == 0) begin
      sim_status = "PASS";
      $display("SIMULAÇÃO spi_frame_encoder PASSOU");
      $finish;
    end else begin
      sim_status = "FAIL";
      $display("SIMULAÇÃO spi_frame_encoder FALHOU: %0d falhas", failures);
      $fatal(1);
    end
  end
endmodule
