`timescale 1ns/1ps

module reg_tb();
   localparam DATA_WIDTH=32,
              CLK_T = 20,
              TEST_WORD_1=32'd102,
              TEST_WORD_2=32'hA5A5_5A5A;

   logic clk, rst, we;
   logic [DATA_WIDTH-1:0] in;
   logic [DATA_WIDTH-1:0] out;
   logic [10*8-1:0]       sim_status;

   integer test_num;
   integer failure_count;

   reg_module
       #(.DATA_WIDTH(DATA_WIDTH)) UUT
   (
    .clk(clk),
    .rst(rst),
    .we(we),
    .in(in),
    .out(out)
    );

   task automatic check_output(
      input logic [DATA_WIDTH-1:0] expected,
      input logic [8*32-1:0]       test_name
   );
      test_num = test_num + 1;
      if (out !== expected) begin
         failure_count = failure_count + 1;
         sim_status = "FAIL";
         $display("[FAIL][caso %0d] %s: esperado=%h obtido=%h",
                  test_num, test_name, expected, out);
      end
      else begin
         $display("[PASS][caso %0d] %s: valor=%h", test_num, test_name, out);
      end
   endtask

   task automatic apply_reset();
      sim_status = "RESET";
      rst = 1'b1;
      we  = 1'b0;
      in  = '0;
      repeat (2) @(posedge clk);
      @(negedge clk);
      check_output('0, "reset");
      rst = 1'b0;
   endtask

   task automatic write_word(input logic [DATA_WIDTH-1:0] word);
      sim_status = "WRITE";
      @(negedge clk);
      in = word;
      we = 1'b1;
      @(posedge clk);
      @(negedge clk);
      we = 1'b0;
      check_output(word, "escrita");
   endtask

   always #(CLK_T / 2) clk = ~clk;

   initial begin
      $dumpfile("reg_tb.vcd");
      $dumpvars(0, reg_tb);

      test_num = 0;
      failure_count = 0;
      sim_status = "INIT";
      clk = 1'b0;
      rst = 1'b0;
      we  = 1'b0;
      in  = '0;

      apply_reset();
      write_word(TEST_WORD_1);

      sim_status = "HOLD";
      in = TEST_WORD_2;
      @(posedge clk);
      @(negedge clk);
      check_output(TEST_WORD_1, "retenção sem we");

      write_word(TEST_WORD_2);

      sim_status = "RESET";
      rst = 1'b1;
      we  = 1'b1;
      in  = TEST_WORD_1;
      @(posedge clk);
      @(negedge clk);
      check_output('0, "reset prioritário");
      rst = 1'b0;
      we  = 1'b0;

      if (failure_count == 0) begin
         sim_status = "PASS";
         $display("SIMULAÇÃO PASSOU: %0d casos verificados", test_num);
      end
      else begin
         sim_status = "FAIL";
         $display("SIMULAÇÃO FALHOU: %0d de %0d casos falharam",
                  failure_count, test_num);
         $fatal(1);
      end

      $finish;
   end
endmodule
