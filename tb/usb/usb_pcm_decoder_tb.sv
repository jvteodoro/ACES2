`timescale 1ns/1ps
module usb_pcm_decoder_tb;
  logic clk=0; always #5 clk=~clk;
  logic rst_n=0, flush=0, pv=0, pr, pe=0, sv, sr=0, malformed;
  logic [2047:0] pd=0; logic [8:0] plen=0; logic [31:0] sd;
  usb_pcm_decoder dut(clk,rst_n,flush,pv,pr,pd,plen,pe,sd,sv,sr,malformed);

  task automatic send(input int n, input bit err);
    @(negedge clk); plen=n; pe=err; pv=1;
    @(posedge clk);
    @(negedge clk); pv=0; pe=0;
  endtask
  task automatic check_sample(input logic [31:0] value);
    @(negedge clk); sr=1;
    do @(posedge clk); while (!sv);
    if(sd !== value) $fatal(1,"sample %08x expected %08x",sd,value);
    @(negedge clk); sr=0;
  endtask
  initial begin
    #100000; $fatal(1,"decoder bench timeout");
  end
  initial begin
    repeat(3) @(posedge clk); rst_n=1;
    pd[0 +:16]=16'h8000; pd[16 +:16]=16'h7fff;
    pd[32 +:16]=16'hffff; pd[48 +:16]=16'h0001;
    send(8,0); check_sample(32'h7fff8000); check_sample(32'h0001ffff);
    for(int i=0;i<48;i++) begin
      pd[i*32 +:16]=i; pd[i*32+16 +:16]=16'h8000+i;
    end
    send(192,0);
    // Packet was latched by send; each frame must remain ordered under stalls.
    for(int i=0;i<48;i++) check_sample({16'(16'h8000+i),16'(i)});
    for(int i=0;i<49;i++) begin
      pd[i*32 +:16]=i; pd[i*32+16 +:16]=i+1;
    end
    send(196,0); for(int i=0;i<49;i++) check_sample({16'(i+1),16'(i)});
    send(2,0); if(!malformed) @(posedge clk); if(!malformed) $fatal(1,"bad length not flagged");
    send(4,1); if(!malformed) @(posedge clk); if(!malformed) $fatal(1,"error packet not flagged");
    send(0,0); repeat(2) @(posedge clk); if(sv) $fatal(1,"zero packet emitted samples");
    // Abort an in-flight packet and verify no old sample escapes.
    pd=0; send(192,0); flush=1; @(posedge clk); @(negedge clk); flush=0;
    repeat(2) @(posedge clk); if(sv) $fatal(1,"flush retained samples");
    $display("PASS usb_pcm_decoder_tb"); $finish;
  end
endmodule
