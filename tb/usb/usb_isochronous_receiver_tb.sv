`timescale 1ns/1ps
module usb_isochronous_receiver_tb;
  logic clk=0; always #10 clk=~clk;
  logic rst_n=0,enable=0,cancel=0,flush=0,tick=0;
  logic [6:0] address=1; logic [3:0] endpoint=4; logic [10:0] max_packet=196;
  logic req_valid,req_ready=0,host_cancel,rsp_valid=0,rsp_ready;
  logic [7:0] token; logic [6:0] req_addr,req_len; logic [511:0] req_data;
  logic toggle_valid,rcv_toggle,snd_toggle;
  logic [2047:0] rsp_packet=0,packet_data; logic [8:0] rsp_len=0,packet_len;
  logic [3:0] rsp_error=0; logic packet_valid,packet_ready=0;
  logic [31:0] frame_count,packet_count,dropped,missed,protocol_errors;

  usb_isochronous_receiver #(.CLK_HZ(1000),.DEADLINE_CYCLES(5),
    .FRAME_LATE_THRESHOLD_CYCLES(150),.FRAME_GAP_TIMEOUT_CYCLES(210)) dut(
    .clk_i(clk),.rst_ni(rst_n),.enable_i(enable),.cancel_i(cancel),.flush_i(flush),.frame_tick_i(tick),
    .address_i(address),.endpoint_i(endpoint),.max_packet_size_i(max_packet),
    .host_req_valid_o(req_valid),.host_req_ready_i(req_ready),.host_req_token_o(token),
    .host_req_addr_o(req_addr),.host_req_wdata_o(req_data),.host_req_out_len_o(req_len),
    .host_req_toggle_valid_o(toggle_valid),.host_req_rcv_toggle_o(rcv_toggle),
    .host_req_snd_toggle_o(snd_toggle),.host_cancel_o(host_cancel),
    .host_rsp_valid_i(rsp_valid),.host_rsp_ready_o(rsp_ready),.host_rsp_packet_i(rsp_packet),
    .host_rsp_len_i(rsp_len),.host_rsp_error_i(rsp_error),.packet_data_o(packet_data),
    .packet_len_o(packet_len),.packet_valid_o(packet_valid),.packet_ready_i(packet_ready),
    .frame_count_o(frame_count),.packet_count_o(packet_count),.dropped_packets_o(dropped),
    .missed_frames_o(missed),.protocol_errors_o(protocol_errors));

  task automatic frame;
    @(negedge clk); tick=1; @(posedge clk); @(negedge clk); tick=0;
  endtask
  task automatic take_req;
    int k; k=0;
    while(!req_valid && k<20) begin @(negedge clk); k++; end
    if(!req_valid) $fatal(1,"ISO request missing");
    if(token!==8'h44 || req_addr!==1 || req_len!==0 || toggle_valid)
      $fatal(1,"bad ISO token/address/length/toggle");
    req_ready=1; @(posedge clk); @(negedge clk); req_ready=0;
  endtask
  task automatic respond(input logic [3:0] err,input int n,input int base);
    @(negedge clk); rsp_packet='0;
    for(int i=0;i<n;i++) rsp_packet[i*8 +:8]=8'(base+i);
    rsp_error=err; rsp_len=n; rsp_valid=1;
    @(posedge clk); @(negedge clk); rsp_valid=0; rsp_len=0; rsp_error=0;
  endtask
  task automatic frame_and_respond(input int n,input int base);
    @(negedge clk); tick=1; rsp_packet='0;
    for(int i=0;i<n;i++) rsp_packet[i*8 +:8]=8'(base+i);
    rsp_error=0; rsp_len=n; rsp_valid=1;
    @(posedge clk); @(negedge clk); tick=0; rsp_valid=0; rsp_len=0;
  endtask

  initial begin
    repeat(3) @(posedge clk); rst_n=1; enable=1;
    // Backpressured pre-accept request expires and is never launched late.
    frame(); if(!req_valid) $fatal(1,"scheduled request absent");
    repeat(7) @(posedge clk);
    if(req_valid || missed!=1) $fatal(1,"deadline expiry failed req=%b missed=%0d",req_valid,missed);

    // Successful request and packet; output holds the complete packet.
    frame(); take_req();
    frame_and_respond(192,8'h30);
    if(frame_count!=3 || missed!=2) $fatal(1,"simultaneous frame/response handling wrong");
    if(!packet_valid || packet_len!=192 || packet_data[7:0]!=8'h30 || packet_data[15:8]!=8'h31)
      $fatal(1,"packet not staged intact");
    frame(); if(missed!=3) $fatal(1,"staged-packet frame miss not counted");
    repeat(3) @(posedge clk); if(!packet_valid) $fatal(1,"packet did not hold under backpressure");
    packet_ready=1; @(posedge clk); @(negedge clk); packet_ready=0;
    if(packet_valid) $fatal(1,"packet handshake did not clear stage");
    begin : jitter_test
      logic [31:0] missed_before; missed_before=missed;
      frame(); take_req(); repeat(102) @(posedge clk);
      if(missed!=missed_before) $fatal(1,"normal SOF polling jitter counted as a frame gap");
      respond(4,0,0);
    end

    // Host error and descriptor-oversize response are dropped whole.
    frame(); take_req(); respond(4,0,0);
    if(dropped!=2 || protocol_errors!=2) $fatal(1,"host error counters wrong");
    frame(); take_req(); respond(0,197,0);
    if(dropped!=3 || protocol_errors!=3 || packet_valid) $fatal(1,"oversize packet not dropped");

    // A stalled queued request is withdrawn at the frame deadline.
    frame(); if(!req_valid) $fatal(1,"deadline test request missing");
    repeat(7) @(posedge clk); if(req_valid) $fatal(1,"expired ISO request stayed valid");

    // Disconnect flushes held data, cancels in-flight work, and drains its late response.
    frame(); take_req();
    enable=0; flush=1; #1; if(!host_cancel) $fatal(1,"active cancel not forwarded");
    @(posedge clk); @(negedge clk); flush=0;
    if(packet_valid) $fatal(1,"flush retained packet");
    respond(4'hf,0,0);
    if(dut.transaction_active_q) $fatal(1,"late response left stale ownership");

    // A late SOF after one omitted interval is counted once. The watchdog age
    // resets at that tick, so it cannot count the same interval a second time.
    enable=1;
    begin : late_tick_test
      logic [31:0] missed_before;
      missed_before=missed;
      frame(); take_req(); respond(0,0,0);
      packet_ready=1; @(posedge clk); @(negedge clk); packet_ready=0;
      repeat(200) @(posedge clk);
      if(dut.frame_age_q<150) $fatal(1,"test interval ended too early: age=%0d",dut.frame_age_q);
      frame();
      if(missed!=missed_before+1)
        $fatal(1,"2ms SOF interval should estimate one missed frame: %0d -> %0d age=%0d late=%b seen=%b",
          missed_before,missed,dut.frame_age_q,dut.frame_late,dut.gap_seen_since_tick_q);
      take_req(); respond(0,0,0);
      packet_ready=1; @(posedge clk); @(negedge clk); packet_ready=0;
      repeat(20) @(posedge clk);
      if(missed!=missed_before+1) $fatal(1,"late tick counted twice by watchdog");
    end

    // With no subsequent SOF at all, the 2.1ms local watchdog still fires.
    begin : gap_watchdog_test
      logic [31:0] missed_before;
      missed_before=missed;
      repeat(220) @(posedge clk);
      if(missed!=missed_before+1) $fatal(1,"SOF gap watchdog did not count one event");
      frame();
      if(missed!=missed_before+1)
        $fatal(1,"late arrival double-counted a gap already reported by watchdog");
    end
    if(packet_count!=4) $fatal(1,"successful host packet count wrong: %0d",packet_count);
    $display("PASS usb_isochronous_receiver_tb"); $finish;
  end
endmodule
