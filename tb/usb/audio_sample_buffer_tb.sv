`timescale 1ns/1ps
module audio_sample_buffer_tb;
  logic clk=0; always #5 clk=~clk;
  logic rst_n=0, flush=0, iv=0, ir, ov, ory=0, overflow;
  logic [31:0] id=0, od; logic [4:0] occ, high;
  audio_sample_buffer #(.DEPTH(16)) dut(clk,rst_n,flush,id,iv,ir,od,ov,ory,occ,high,overflow);
  task automatic push(input int value);
    @(negedge clk); id=value; iv=1;
    do @(posedge clk); while(!ir);
    @(negedge clk); iv=0;
  endtask
  task automatic pop_expect(input int value);
    @(negedge clk); ory=1;
    if(!ov || od !== value) $fatal(1,"FIFO got %08x expected %08x",od,value);
    @(posedge clk); @(negedge clk); ory=0;
  endtask
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    for(int i=0;i<16;i++) push(i);
    if(occ!=16 || high!=16 || ir) $fatal(1,"full state incorrect");
    @(negedge clk); iv=1; id=99; @(posedge clk); @(negedge clk);
    if(!overflow) $fatal(1,"overflow pulse missing"); @(negedge clk); iv=0;
    for(int i=0;i<8;i++) pop_expect(i);
    for(int i=16;i<24;i++) push(i);
    for(int i=8;i<24;i++) pop_expect(i);
    if(occ!=0) $fatal(1,"FIFO not empty");
    // Empty consumer readiness is not an underflow condition.
    ory=1; repeat(3) @(posedge clk); if(overflow) $fatal(1,"spurious underflow/overflow"); ory=0;
    for(int i=0;i<8;i++) push(i);
    flush=1; @(posedge clk); @(negedge clk); flush=0;
    if(occ!=0 || ov) $fatal(1,"flush failed");
    $display("PASS audio_sample_buffer_tb"); $finish;
  end
endmodule
