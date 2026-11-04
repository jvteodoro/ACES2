`timescale 1ns/1ps
// Independent integration scoreboard: known stereo sequence, variable USB
// packet sizes and sink stalls spanning multiple packet arrival attempts.
module usb_pcm_path_tb;
  logic clk=0;
  always #10 clk=~clk;
  logic rst_n=0, flush=0;
  logic pv=0, pr, pe=0, dv, dr, malformed;
  logic [2047:0] pd='0;
  logic [8:0] plen=0;
  logic [31:0] dd, od;
  logic ov, sink_ready=0, blocked;
  logic [4:0] occ, high_water;
  int received=0, submitted=0, packets=0, stall_cycles=0;
  logic [31:0] rng=32'h32cafe01;
  logic held=0;
  logic [31:0] held_data;
  usb_pcm_decoder dec (
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),
    .packet_valid_i(pv),.packet_ready_o(pr),.packet_data_i(pd),
    .packet_len_i(plen),.packet_error_i(pe),.sample_data_o(dd),
    .sample_valid_o(dv),.sample_ready_i(dr),.malformed_o(malformed)
  );
  audio_sample_buffer #(.DEPTH(16)) fifo (
    .clk_i(clk),.rst_ni(rst_n),.flush_i(flush),
    .sample_data_i(dd),.sample_valid_i(dv),.sample_ready_o(dr),
    .sample_data_o(od),.sample_valid_o(ov),.sample_ready_i(sink_ready),
    .occupancy_o(occ),.high_water_o(high_water),.overflow_o(blocked)
  );
  // Drive away from sampling edges. Long stalls deliberately fill the FIFO.
  always @(negedge clk) begin
    rng = {rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
    sink_ready = rst_n && rng[3:0] < 5;
  end
  always @(posedge clk) if (rst_n) begin
    if (malformed) $fatal(1,"valid packet marked malformed");
    if (held && (!ov || od !== held_data))
      $fatal(1,"output changed under backpressure");
    held <= ov && !sink_ready;
    held_data <= od;
    if (ov && sink_ready) begin
      if (od !== {~16'(received),16'(received)})
        $fatal(1,"frame %0d: got %08x",received,od);
      received = received + 1;
    end
    if (dv && !dr) stall_cycles = stall_cycles + 1;
  end
  initial begin
    #10000000;
    $fatal(1,"PCM path watchdog: submitted=%0d received=%0d",submitted,received);
  end
  initial begin
    int n;
    repeat(4) @(negedge clk);
    rst_n=1;
    while(submitted < 10000) begin
      n=1+((packets*17)%49);
      if(n>10000-submitted) n=10000-submitted;
      @(negedge clk);
      pd='0;
      for(int i=0;i<n;i++) pd[i*32 +:32]={~16'(submitted+i),16'(submitted+i)};
      plen=9'(n*4);
      pv=1;
      do @(posedge clk); while(!pr);
      @(negedge clk);
      pv=0;
      submitted=submitted+n;
      packets=packets+1;
    end
    wait(received==10000);
    repeat(4) @(negedge clk);
    if(ov || dv || occ!=0) $fatal(1,"residual samples");
    if(high_water!=16 || stall_cycles==0) $fatal(1,"test failed to fill FIFO");
    $display("PASS PCM path: packets=%0d frames=%0d high_water=%0d stalls=%0d",
             packets,received,high_water,stall_cycles);
    $finish;
  end
endmodule
