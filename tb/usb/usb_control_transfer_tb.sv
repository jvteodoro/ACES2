`timescale 1ns/1ps
module usb_control_transfer_tb;
  logic clk=0; always #10 clk=~clk;
  logic rst_n=0, req_valid=0, req_ready, cancel=0;
  logic [63:0] setup=0; logic [15:0] in_len=0; logic [6:0] addr=0, ep0=8;
  logic [7:0] data_o; logic data_valid, data_ready=1, done, error;
  logic [3:0] error_code;
  logic hreq_valid,hreq_ready=0,hcancel,hrsp_valid=0,hrsp_ready;
  logic [7:0] htoken; logic [6:0] haddr,hout_len;
  logic [511:0] hwdata; logic htoggle_valid,hrcv_toggle,hsnd_toggle;
  logic [2047:0] hrsp_packet=0; logic [8:0] hrsp_len=0;
  logic [3:0] hrsp_error=0; logic hrcv_result=0,hsnd_result=0;
  int seen, expected_total, error_count=0; bit collect=0, expect_toggle_init=0;

  usb_control_transfer #(.CTRL_TIMEOUT_CYCLES(2000),.NAK_RETRY_LIMIT(3),.CANCEL_GRACE_CYCLES(20)) dut(
    .clk_i(clk),.rst_ni(rst_n),.ctrl_req_valid_i(req_valid),.ctrl_req_ready_o(req_ready),
    .ctrl_setup_i(setup),.ctrl_in_length_i(in_len),.ctrl_address_i(addr),.ctrl_ep0_size_i(ep0),
    .ctrl_cancel_i(cancel),.ctrl_data_o(data_o),.ctrl_data_valid_o(data_valid),
    .ctrl_data_ready_i(data_ready),.ctrl_done_o(done),.ctrl_error_o(error),.ctrl_error_code_o(error_code),
    .host_req_valid_o(hreq_valid),.host_req_ready_i(hreq_ready),.host_req_token_o(htoken),
    .host_req_addr_o(haddr),.host_req_wdata_o(hwdata),.host_req_out_len_o(hout_len),
    .host_req_toggle_valid_o(htoggle_valid),.host_req_rcv_toggle_o(hrcv_toggle),
    .host_req_snd_toggle_o(hsnd_toggle),.host_cancel_o(hcancel),.host_rsp_valid_i(hrsp_valid),
    .host_rsp_ready_o(hrsp_ready),.host_rsp_packet_i(hrsp_packet),.host_rsp_len_i(hrsp_len),
    .host_rsp_error_i(hrsp_error),.host_rsp_rcv_toggle_i(hrcv_result),.host_rsp_snd_toggle_i(hsnd_result));

  always @(posedge clk) if(collect && data_valid && data_ready) begin
    if(data_o !== 8'(seen)) $fatal(1,"stream byte %0d got %02x",seen,data_o);
    seen++;
  end
  always @(posedge clk) if(done && error) $fatal(1,"done and error same cycle");
  always @(posedge clk) if(error) error_count++;

  task automatic begin_request(input logic [63:0] s, input int n);
    @(negedge clk); setup=s; in_len=n; addr=0; ep0=8; req_valid=1; expect_toggle_init=1;
    @(posedge clk); @(negedge clk); req_valid=0;
  endtask
  task automatic expect_req(input logic [7:0] token, input logic [6:0] length);
    int timeout;
    timeout=0;
    while(!hreq_valid && timeout<100) begin @(negedge clk); timeout++; end
    if(!hreq_valid) $fatal(1,"host request timeout expected token %02x",token);
    if(htoken!==token || hout_len!==length || haddr!==addr)
      $fatal(1,"host req token=%02x len=%0d addr=%0d expected %02x/%0d",htoken,hout_len,haddr,token,length);
    if(token==8'h10 && hwdata[63:0]!==setup)
      $fatal(1,"setup packing got %016x expected %016x",hwdata[63:0],setup);
    if(token==0 && expect_toggle_init && (!htoggle_valid || !hrcv_toggle))
      $fatal(1,"first IN was not initialized to DATA1");
    if(token==0 && !expect_toggle_init && htoggle_valid)
      $fatal(1,"toggle was reset between packets");
    hreq_ready=1; @(posedge clk); @(negedge clk); hreq_ready=0;
    if(token==0) expect_toggle_init=0;
  endtask
  task automatic host_response(input logic [3:0] err, input int n, input int base);
    // Never change valid on the sampling edge: the DUT may otherwise consume
    // the response before this task starts waiting for its handshake.
    @(negedge clk);
    hrsp_packet='0;
    for(int k=0;k<n;k++) hrsp_packet[k*8 +:8]=8'(base+k);
    hrsp_len=n; hrsp_error=err; hrsp_valid=1;
    do @(posedge clk); while(!hrsp_ready);
    @(negedge clk); hrsp_valid=0; hrsp_error=0; hrsp_len=0;
  endtask
  task automatic complete_setup;
    expect_req(8'h10,8);
    host_response(0,0,0);
  endtask
  task automatic wait_done;
    int t; t=0; while(!done && t<100) begin @(posedge clk); t++; end
    if(!done) $fatal(1,"control done timeout");
  endtask

  initial begin
    #2000000; $fatal(1,"control bench watchdog");
  end
  initial begin
    repeat(4) @(posedge clk); rst_n=1;

    // 1191-byte configuration descriptor over 8-byte EP0 packets, ending in 7.
    seen=0; expected_total=1191; collect=1;
    begin_request(64'h04a7_0000_0002_06_80,1191);
    complete_setup();
    for(int p=0;p<149;p++) begin
      int n; n=(p==148)?7:8;
      expect_req(8'h00,0);
      host_response(0,n,p*8);
    end
    repeat(8) @(posedge clk);
    collect=0;
    if(seen!=expected_total) $fatal(1,"received %0d bytes expected %0d",seen,expected_total);
    if(done) $fatal(1,"done asserted before status stage");
    expect_req(8'ha0,0); host_response(0,0,0); wait_done();
    $display("PASS descriptor");

    // Short packet terminates early; stream exactly three bytes then status.
    seen=0; expected_total=3; collect=1; data_ready=0;
    begin_request(64'h0020_0000_0002_06_80,32); complete_setup(); expect_req(0,0);
    host_response(0,3,0);
    repeat(4) @(posedge clk); if(seen!=0) $fatal(1,"backpressure failed");
    data_ready=1;
    repeat(5) @(posedge clk); collect=0;
    if(seen!=3) $fatal(1,"short packet emitted %0d bytes",seen);
    expect_req(8'ha0,0); host_response(0,0,0); wait_done();
    $display("PASS short");

    // ZLP also ends the IN data stage without delivering a byte.
    seen=0; collect=1; begin_request(64'h0010_0000_0002_06_80,16);
    complete_setup(); expect_req(0,0); host_response(0,0,0);
    if(data_valid) $fatal(1,"ZLP generated data");
    expect_req(8'ha0,0); host_response(0,0,0); wait_done(); collect=0;
    $display("PASS zlp");

    // SET_ADDRESS is setup plus HS-IN status; retry NAK once without duplicate work.
    begin_request(64'h0000_0000_0001_05_00,0);
    expect_req(8'h10,8); host_response(4,0,0); expect_req(8'h10,8); host_response(0,0,0);
    expect_req(8'h80,0); host_response(0,0,0); wait_done();
    $display("PASS set address");

    // STALL on a data packet fails and does not complete.
    begin_request(64'h0010_0000_0002_06_80,16); complete_setup(); expect_req(0,0);
    begin : stall_test
      int old_errors; old_errors=error_count;
      host_response(5,0,0);
      repeat(2) @(posedge clk);
      if(error_count==old_errors || done) $fatal(1,"STALL was not terminal err=%b count=%0d old=%0d done=%b code=%x state=%0d",error,error_count,old_errors,done,error_code,dut.state_q);
    end
    $display("PASS stall");

    // Caller cancellation during an in-flight token requests lower-layer abort.
    begin_request(64'h0010_0000_0002_06_80,16); complete_setup(); expect_req(0,0);
    begin : cancel_test
      int old_errors; old_errors=error_count;
      cancel=1; @(posedge clk); @(negedge clk); if(!hcancel) $fatal(1,"cancel not forwarded");
      host_response(4'hf,0,0); cancel=0;
      repeat(2) @(posedge clk);
      if(error_count==old_errors || done) $fatal(1,"cancel did not fail transaction");
    end
    $display("PASS cancel");

    // Overall timeout is independent of a missing host response/backpressure.
    begin : timeout_quarantine_test
      int old_errors; old_errors=error_count;
      begin_request(64'h0008_0000_0002_06_80,8); expect_req(8'h10,8);
      repeat(2005) @(posedge clk);
      if(!hcancel) $fatal(1,"timeout did not abort lower transaction");
      repeat(25) @(posedge clk);
      $display("quarantine state=%0d hready=%b cancel_timer=%0d errorcount=%0d",dut.state_q,hrsp_ready,dut.cancel_timer_q,error_count);
      if(error_count==old_errors || req_ready) $fatal(1,"timeout quarantine did not block new request");
      host_response(4'hf,0,0);
      if(!req_ready) $fatal(1,"late response did not release quarantine");
    end
    $display("PASS quarantine");

    // Timeout also terminates a byte stream stalled by upper backpressure.
    begin : stream_timeout_test
      int old_errors; old_errors=error_count;
      data_ready=0; begin_request(64'h0008_0000_0002_06_80,8);
      complete_setup(); expect_req(0,0); host_response(0,8,0);
      repeat(2005) @(posedge clk);
      repeat(2) @(posedge clk);
      if(error_count==old_errors || data_valid) $fatal(1,"stream backpressure timeout failed");
      data_ready=1;
    end
    $display("PASS stream timeout");

    // A cancel concurrent with a pending request must suppress its handshake.
    begin : concurrent_cancel_test
      int old_errors; old_errors=error_count;
      begin_request(64'h0000_0000_0001_05_00,0);
      cancel=1; hreq_ready=1;
      #1; // Allow combinational cancellation gating to settle before checking.
      if(hreq_valid) $fatal(1,"cancelled request remained valid");
      @(posedge clk); @(negedge clk); cancel=0; hreq_ready=0;
      repeat(2) @(posedge clk);
      if(error_count==old_errors || !req_ready) $fatal(1,"concurrent cancel did not terminate cleanly");
    end
    $display("PASS concurrent cancel");

    // NAK retry budget includes setup and status stages and cannot reset on retry.
    begin : setup_nak_exhaustion
      int old_errors; old_errors=error_count;
      begin_request(64'h0000_0000_0001_05_00,0);
      for(int k=0;k<4;k++) begin expect_req(8'h10,8); host_response(4,0,0); end
      repeat(2) @(posedge clk);
      if(error_count==old_errors) $fatal(1,"SETUP NAK retry limit not enforced");
    end
    $display("PASS setup NAK");
    begin : status_nak_exhaustion
      int old_errors; old_errors=error_count;
      begin_request(64'h0000_0000_0001_05_00,0); expect_req(8'h10,8); host_response(0,0,0);
      for(int k=0;k<4;k++) begin expect_req(8'h80,0); host_response(4,0,0); end
      repeat(2) @(negedge clk);
      if(error_count==old_errors) $fatal(1,"status NAK retry limit not enforced");
    end
    $display("PASS status NAK");

    // OUT data request is rejected without sending SETUP.
    begin_request(64'h0001_0000_0000_01_00,1);
    if(!error || hreq_valid) $fatal(1,"unsupported OUT data request accepted");
    $display("PASS usb_control_transfer_tb"); $finish;
  end
endmodule
