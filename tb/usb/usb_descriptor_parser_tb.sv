`timescale 1ns/1ps
module usb_descriptor_parser_tb;
  localparam int CONFIG_BYTES=1191;
  logic clk=0, rst_n=0, start=0, valid=0, ready, done, selected, error;
  logic [15:0] total_len=CONFIG_BYTES;
  logic [7:0] data;
  logic [7:0] intf, alt, ep, interval, channels, bits;
  logic [10:0] packet;
  logic [15:0] rate;
  logic [7:0] config_mem[0:CONFIG_BYTES-1];
  logic [7:0] short_ep_cfg[0:42];
  int n;
  always #5 clk=~clk;

  usb_descriptor_parser dut(
    .clk_i(clk),.rst_ni(rst_n),.start_i(start),.total_length_i(total_len),
    .byte_data_i(data),.byte_valid_i(valid),.byte_ready_o(ready),
    .done_o(done),.valid_o(selected),.error_o(error),.interface_o(intf),
    .alternate_setting_o(alt),.endpoint_o(ep),.max_packet_size_o(packet),
    .interval_o(interval),.channels_o(channels),.sample_bits_o(bits),.sample_rate_o(rate));

  task automatic send_config(input bit corrupt_len, input bit corrupt_total, input bit malformed_final,
                             input bit malformed_freq_count, input bit malformed_ep_count);
    @(negedge clk); start=1; total_len=CONFIG_BYTES;
    @(negedge clk); start=0;
    for(int i=0;i<CONFIG_BYTES;i++) begin
      @(negedge clk);
      while(!ready) @(negedge clk);
      valid=1; data=config_mem[i];
      if(corrupt_len && i==0) data=8'hff;
      if(corrupt_total && i==2) data=8'h00;
      if(malformed_final && i==CONFIG_BYTES-6) data=8'h04;
      if(malformed_freq_count && i==415) data=8'h02;
      if(malformed_ep_count && i==396) data=8'h02;
      @(posedge clk);
      @(negedge clk); valid=0;
      if(done) return;
    end
    n=0;
    while(!done && n<10) begin @(posedge clk); n++; end
  endtask

  task automatic send_short_endpoint_config;
    @(negedge clk); start=1; total_len=43;
    @(negedge clk); start=0;
    for(int i=0;i<43;i++) begin
      @(negedge clk); while(!ready) @(negedge clk);
      valid=1; data=short_ep_cfg[i]; @(posedge clk); @(negedge clk); valid=0;
      if(done) return;
    end
  endtask

  initial begin
    $readmemh("tb/usb/pcm2902_config.mem",config_mem);
    data=0;
    // Minimal valid tree with a seven-byte isochronous endpoint descriptor;
    // bInterval is the final byte and exercises the streaming last-byte path.
    short_ep_cfg[0]=9; short_ep_cfg[1]=2; short_ep_cfg[2]=43; short_ep_cfg[3]=0;
    short_ep_cfg[4]=1; short_ep_cfg[5]=1; short_ep_cfg[6]=0; short_ep_cfg[7]=8'h80; short_ep_cfg[8]=50;
    short_ep_cfg[9]=9; short_ep_cfg[10]=4; short_ep_cfg[11]=2; short_ep_cfg[12]=1;
    short_ep_cfg[13]=1; short_ep_cfg[14]=1; short_ep_cfg[15]=2; short_ep_cfg[16]=0; short_ep_cfg[17]=0;
    short_ep_cfg[18]=7; short_ep_cfg[19]=8'h24; short_ep_cfg[20]=1; short_ep_cfg[21]=1;
    short_ep_cfg[22]=0; short_ep_cfg[23]=1; short_ep_cfg[24]=0;
    short_ep_cfg[25]=11; short_ep_cfg[26]=8'h24; short_ep_cfg[27]=2; short_ep_cfg[28]=1;
    short_ep_cfg[29]=2; short_ep_cfg[30]=2; short_ep_cfg[31]=16; short_ep_cfg[32]=1;
    short_ep_cfg[33]=8'h80; short_ep_cfg[34]=8'hbb; short_ep_cfg[35]=0;
    short_ep_cfg[36]=7; short_ep_cfg[37]=5; short_ep_cfg[38]=8'h86; short_ep_cfg[39]=5;
    short_ep_cfg[40]=8'hc4; short_ep_cfg[41]=0; short_ep_cfg[42]=1;
    repeat(3) @(posedge clk); rst_n=1;
    send_config(0,0,0,0,0);
    if(!done || error || !selected) $fatal(1,"valid real configuration rejected done=%b err=%b sel=%b seen=%b ifcount=%0d declared=%0d cand=%b consumed=%0d",done,error,selected,dut.config_seen_q,dut.unique_interfaces_q,dut.declared_interfaces_q,dut.candidate_found_q,dut.consumed_q);
    if(intf!=2 || alt!=1 || ep!=8'h84 || packet!=196 || interval!=1 ||
       channels!=2 || bits!=16 || rate!=48000)
      $fatal(1,"wrong selection intf=%0d alt=%0d ep=%02x packet=%0d ch=%0d bits=%0d rate=%0d",intf,alt,ep,packet,channels,bits,rate);

    @(negedge clk); rst_n=0; repeat(2) @(posedge clk); @(negedge clk); rst_n=1;
    send_config(1,0,0,0,0);
    if(!done || !error || selected) $fatal(1,"cross-bound descriptor length not rejected");

    @(negedge clk); rst_n=0; repeat(2) @(posedge clk); @(negedge clk); rst_n=1;
    send_config(0,1,0,0,0);
    if(!done || !error || selected) $fatal(1,"bad wTotalLength not rejected");

    @(negedge clk); rst_n=0; repeat(2) @(posedge clk); @(negedge clk); rst_n=1;
    send_config(0,0,1,0,0);
    if(!done || !error || selected) $fatal(1,"malformed final descriptor overrode earlier match");

    @(negedge clk); rst_n=0; repeat(2) @(posedge clk); @(negedge clk); rst_n=1;
    send_config(0,0,0,1,0);
    if(!done || !error || selected) $fatal(1,"truncated discrete frequency list not rejected");

    @(negedge clk); rst_n=0; repeat(2) @(posedge clk); @(negedge clk); rst_n=1;
    send_config(0,0,0,0,1);
    if(!done || !error || selected) $fatal(1,"interface endpoint count mismatch not rejected");

    @(negedge clk); rst_n=0; repeat(2) @(posedge clk); @(negedge clk); rst_n=1;
    send_short_endpoint_config();
    if(!done || error || !selected || intf!=2 || alt!=1 || ep!=8'h86 || packet!=196 || interval!=1)
      $fatal(1,"wildcard endpoint selection failed or bInterval wrong");

    @(negedge clk); rst_n=0; repeat(2) @(posedge clk); @(negedge clk); rst_n=1;
    short_ep_cfg[40]=8'h2c; short_ep_cfg[41]=8'h01; // 300 bytes exceeds 256-byte datapath.
    send_short_endpoint_config();
    if(!done || !error || selected) $fatal(1,"endpoint larger than datapath limit was accepted");
    $display("PASS usb_descriptor_parser_tb"); $finish;
  end
endmodule
