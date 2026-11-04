`timescale 1ns/1ps
module usb_enumerator_tb;
  localparam int CONFIG_BYTES=1191;
  logic clk=0, rst_n=0, connected=0;
  logic req_valid, req_ready=1, cancel;
  logic [63:0] setup;
  logic [15:0] in_length;
  logic [6:0] address, ep0;
  logic [7:0] data;
  logic data_valid=0, data_ready, done=0, ctrl_error=0;
  logic enumerated, enum_error;
  logic [3:0] error_code;
  logic [7:0] config_value, intf, alt, endpoint, interval, channels, bits;
  logic [10:0] packet;
  logic [15:0] rate;
  logic [7:0] config_mem[0:CONFIG_BYTES-1];
  logic [7:0] dev_desc[0:17];
  int req_count;
  always #5 clk=~clk;

  usb_enumerator #(.CLK_HZ(1000),.CTRL_TIMEOUT_CYCLES(5000)) dut(
    .clk_i(clk),.rst_ni(rst_n),.connected_i(connected),
    .ctrl_req_valid_o(req_valid),.ctrl_req_ready_i(req_ready),.ctrl_setup_o(setup),
    .ctrl_in_length_o(in_length),.ctrl_address_o(address),.ctrl_ep0_size_o(ep0),.ctrl_cancel_o(cancel),
    .ctrl_data_i(data),.ctrl_data_valid_i(data_valid),.ctrl_data_ready_o(data_ready),
    .ctrl_done_i(done),.ctrl_error_i(ctrl_error),.enumerated_o(enumerated),.enum_error_o(enum_error),
    .enum_error_code_o(error_code),.configuration_o(config_value),.interface_o(intf),
    .alternate_setting_o(alt),.endpoint_o(endpoint),.max_packet_size_o(packet),.interval_o(interval),
    .channels_o(channels),.sample_bits_o(bits),.sample_rate_o(rate));

  task automatic request(input logic [7:0] expected_req, input logic [15:0] expected_value,
                        input logic [15:0] expected_index, input logic [15:0] expected_len,
                        input logic [6:0] expected_addr);
    int guard;
    guard=0;
    while(!req_valid && guard<3000) begin @(negedge clk); guard++; end
    if(!req_valid) $fatal(1,"control request timeout expected req=%02x enum_error=%b code=%0d state=%0d parser_done=%b parser_valid=%b parser_error=%b",expected_req,enum_error,error_code,dut.state_q,dut.parser_done,dut.parser_valid,dut.parser_error);
    if(setup[7:0] != (expected_req==6 ? 8'h80 : (expected_req==11 ? 8'h01 : 8'h00)) ||
       setup[15:8] != expected_req || setup[31:16] != expected_value || setup[47:32] != expected_index ||
       setup[63:48] != expected_len || in_length != expected_len || address != expected_addr)
      $fatal(1,"bad setup req=%02x setup=%016x len=%0d addr=%0d",expected_req,setup,in_length,address);
    @(posedge clk); req_count++;
    @(negedge clk);
  endtask

  task automatic finish_data;
    @(negedge clk); data_valid=0;
    @(negedge clk); done=1;
    @(negedge clk); done=0;
  endtask

  task automatic send_device(input int length);
    for(int i=0;i<length;i++) begin
      @(negedge clk); data=dev_desc[i]; data_valid=1;
      while(!data_ready) @(negedge clk);
      @(posedge clk);
    end
    finish_data();
  endtask

  task automatic send_config(input int offset,input int length);
    for(int i=0;i<length;i++) begin
      @(negedge clk); data=config_mem[offset+i]; data_valid=1;
      while(!data_ready) @(negedge clk);
      @(posedge clk);
    end
    finish_data();
  endtask

  initial begin
    $readmemh("tb/usb/pcm2902_config.mem",config_mem);
    dev_desc[0]=18; dev_desc[1]=1;
    dev_desc[2]=8'h10; dev_desc[3]=8'h01; dev_desc[4]=0; dev_desc[5]=0; dev_desc[6]=0; dev_desc[7]=8;
    dev_desc[8]=8'hbb; dev_desc[9]=8'h08; dev_desc[10]=8'h02; dev_desc[11]=8'h29;
    dev_desc[12]=0; dev_desc[13]=1; dev_desc[14]=1; dev_desc[15]=2; dev_desc[16]=0; dev_desc[17]=1;
    req_count=0; data=0;
    repeat(3) @(posedge clk); rst_n=1; connected=1;

    request(6,16'h0100,0,8,0); send_device(8);
    if(ep0!=8) $fatal(1,"initial EP0 size");
    request(6,16'h0100,0,18,0); send_device(18);
    request(5,1,0,0,0);
    @(negedge clk); done=1; @(negedge clk); done=0;
    wait(address==1);
    request(6,16'h0200,0,9,1); send_config(0,9);
    request(6,16'h0200,0,CONFIG_BYTES,1); send_config(0,CONFIG_BYTES);
    request(9,1,0,0,1); @(negedge clk); done=1; @(negedge clk); done=0;
    request(11,1,2,0,1); @(negedge clk); done=1; @(negedge clk); done=0;
    wait(enumerated || enum_error);
    if(enum_error) $fatal(1,"enumeration failed error=%0d",error_code);
    if(!enumerated || req_count!=7 || config_value!=1 || intf!=2 || alt!=1 || endpoint!=8'h84 ||
       packet!=196 || interval!=1 || channels!=2 || bits!=16 || rate!=48000)
      $fatal(1,"bad enumerated output reqs=%0d cfg=%0d if=%0d alt=%0d ep=%02x max=%0d",req_count,config_value,intf,alt,endpoint,packet);

    // A disconnect aborts the address/configuration and permits a fresh run.
    @(negedge clk); connected=0;
    @(negedge clk);
    if(enumerated || address!=0 || !cancel) $fatal(1,"disconnect did not clear enumeration");

    // Reconnect, then hold a control request open to exercise local timeout.
    connected=1;
    request(6,16'h0100,0,8,0);
    repeat(5003) @(posedge clk);
    if(!enum_error || error_code!=2) $fatal(1,"control timeout not reported");
    if(!cancel) $fatal(1,"timeout did not request control-transfer cancellation");

    @(negedge clk); connected=0; @(negedge clk); req_ready=0; connected=1;
    repeat(5003) @(posedge clk);
    if(!enum_error || error_code!=2 || !cancel) $fatal(1,"stalled request timeout not reported err=%b code=%0d cancel=%b state=%0d timer=%0d ready=%b",enum_error,error_code,cancel,dut.state_q,dut.timer_q,req_valid);
    $display("PASS usb_enumerator_tb"); $finish;
  end
endmodule
