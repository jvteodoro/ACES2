`timescale 1ns/1ps
module max3421e_spi_bridge_tb;
  logic clk=0, rst_n=0;
  always #10 clk=~clk;
  logic req_valid, req_ready, req_write;
  logic [4:0] req_addr;
  logic [6:0] req_len;
  logic [511:0] req_wdata, rsp_data;
  logic rsp_valid, rsp_ready, rsp_error, busy, sck, mosi, miso, cs_n;
  max3421e_spi_bridge dut(.clk_i(clk),.rst_ni(rst_n),.req_valid_i(req_valid),.req_ready_o(req_ready),
    .req_write_i(req_write),.req_addr_i(req_addr),.req_len_i(req_len),.req_wdata_i(req_wdata),
    .rsp_valid_o(rsp_valid),.rsp_ready_i(rsp_ready),.rsp_rdata_o(rsp_data),.rsp_error_o(rsp_error),
    .busy_o(busy),.sck_o(sck),.mosi_o(mosi),.miso_i(miso),.cs_n_o(cs_n));

  byte unsigned read_bytes[64];
  byte unsigned captured[65];
  int cap_count, bit_count, byte_index, first_cs_cycle, cs_cycle, clocks;
  int req_cycle, cs_assert_cycle,mosi_transition_count;
  byte unsigned shift_in;
  logic mosi_at_sample;
  bit transaction_active;
  realtime cs_fall_ns,last_sck_ns,last_rise_ns,last_fall_ns,mosi_change_ns,miso_valid_ns;
  realtime last_transfer_cs_setup_ns,last_transfer_cs_hold_ns;
  realtime min_cs_setup_ns,min_cs_hold_ns,min_period_ns,min_high_ns,min_low_ns,min_mosi_setup_ns,min_miso_delay_ns;
  bit saw_sck_edge;
  always @(mosi) begin
    mosi_change_ns=$realtime;
    if(!cs_n) mosi_transition_count++;
  end
  always @(posedge sck) begin
    if (!cs_n) begin
      if(!saw_sck_edge) begin
        if(($realtime-cs_fall_ns)<30.0) $fatal(1,"CS setup to first SCK < MAX3421E tL=30ns");
        last_transfer_cs_setup_ns=$realtime-cs_fall_ns;
        if(($realtime-cs_fall_ns)<min_cs_setup_ns) min_cs_setup_ns=$realtime-cs_fall_ns;
      end
      if(saw_sck_edge) begin
        if(($realtime-last_rise_ns)<38.4) $fatal(1,"SCK period below MAX3421E tCP=38.4ns");
        if(($realtime-last_rise_ns)<min_period_ns) min_period_ns=$realtime-last_rise_ns;
      end
      if(($realtime-mosi_change_ns)<5.0) $fatal(1,"MOSI setup below MAX3421E tDS=5ns");
      if(($realtime-mosi_change_ns)<min_mosi_setup_ns) min_mosi_setup_ns=$realtime-mosi_change_ns;
      // The MAX3421E requires MOSI to remain stable for tDH=10 ns after the
      // rising sampling edge. This edge-level assertion covers the event
      // timing that periodic STA cannot infer for burst-gated SCK.
      mosi_at_sample=mosi;
      if(saw_sck_edge && ($realtime-last_fall_ns)<17.0) $fatal(1,"SCK low pulse below MAX3421E tCL=17ns");
      if(saw_sck_edge && ($realtime-last_fall_ns)<min_low_ns) min_low_ns=$realtime-last_fall_ns;
      saw_sck_edge=1; last_rise_ns=$realtime; last_sck_ns=$realtime;
      if (!transaction_active) begin transaction_active=1; cap_count=0; bit_count=0; shift_in=0; end
      if (bit_count==0) begin first_cs_cycle=clocks; cs_cycle=clocks; end
      shift_in={shift_in[6:0],mosi};
      bit_count++;
      if (bit_count==8) begin captured[cap_count]=shift_in; cap_count++; bit_count=0; shift_in=0; end
      #10.0;
      if(mosi !== mosi_at_sample) $fatal(1,"MOSI changed within MAX3421E tDH=10ns");
    end
  end
  always @(negedge sck) if(!cs_n) begin
    if(saw_sck_edge && ($realtime-last_rise_ns)<17.0) $fatal(1,"SCK high pulse below MAX3421E tCH=17ns");
    if(saw_sck_edge && ($realtime-last_rise_ns)<min_high_ns) min_high_ns=$realtime-last_rise_ns;
    // The MAX updates MISO 14.2 ns after falling SCK. The bridge's
    // optional trailing-edge receive mode samples the old bit at this
    // falling transition, before that delayed update; check the prior
    // MISO transition's age to prove setup at every receive sample.
    if(miso_valid_ns>cs_fall_ns) begin
      if(($realtime-miso_valid_ns)<14.2) $fatal(1,"MISO sample too close to prior MAX tDO transition");
      if(($realtime-miso_valid_ns)<min_miso_delay_ns) min_miso_delay_ns=$realtime-miso_valid_ns;
    end
    last_fall_ns=$realtime; last_sck_ns=$realtime;
  end
  always @(posedge cs_n) begin
    transaction_active=0;
    if(saw_sck_edge) last_transfer_cs_hold_ns=$realtime-last_sck_ns;
    if(rst_n && saw_sck_edge && ($realtime-last_sck_ns)<30.0) $fatal(1,"CS hold after final SCK below MAX3421E tT=30ns");
    if(rst_n && saw_sck_edge && ($realtime-last_sck_ns)<min_cs_hold_ns) min_cs_hold_ns=$realtime-last_sck_ns;
    saw_sck_edge=0;
  end
  always @(negedge cs_n) begin cs_assert_cycle=clocks; cs_fall_ns=$realtime; last_sck_ns=$realtime; saw_sck_edge=0; end
  // A deterministic peripheral drives each receive byte MSB first. Data is
  // advanced 14.2 ns after falling SCK, matching the MAX3421E tDO maximum.
  int slave_bit;
  always @(posedge sck or posedge cs_n) begin
    if (cs_n) slave_bit=0;
    else slave_bit++;
  end
  always @(negedge sck or negedge cs_n) begin
    if (cs_n) miso=0;
    else begin
      // Conservative model for the MAX3421E's 14.2 ns maximum tDO at
      // VL > 2.5 V. The bridge samples the outgoing bit at the falling
      // edge before this delayed update, then sees the new bit on the
      // following rising edge.
      #14.2;
      if (cs_n) miso=0;
      else if (slave_bit < 8) miso=0;
      else if (((slave_bit-8)/8)<64) miso=read_bytes[(slave_bit-8)/8][7-((slave_bit-8)%8)];
      else miso=0;
      miso_valid_ns=$realtime;
    end
  end
  always @(posedge clk) clocks++;

  task automatic send_req(input bit wr, input byte addr, input int n);
    @(negedge clk); req_write=wr; req_addr=addr[7:3]; req_len=n; req_valid=1;
    do @(posedge clk); while(!req_ready);
    @(negedge clk); req_valid=0;
  endtask
  task automatic wait_rsp(input int limit);
    int k;
    k=0; while(!rsp_valid && k<limit) begin @(posedge clk); k++; end
    if (!rsp_valid) $fatal(1,"response timeout");
  endtask
  task automatic check_capture(input int n, input byte cmd, input bit wr);
    if (cap_count != n+1) $fatal(1,"captured %0d bytes expected %0d",cap_count,n+1);
    if (captured[0] !== cmd) $fatal(1,"bad command %02x expected %02x",captured[0],cmd);
    for(int i=0;i<n;i++) if(captured[i+1] !== (wr ? req_wdata[i*8 +:8] : 8'h00))
      $fatal(1,"bad byte %0d got %02x",i,captured[i+1]);
    if(last_transfer_cs_setup_ns<30.0 || last_transfer_cs_hold_ns<30.0)
      $fatal(1,"CS timing invalid for %0d-byte transfer: tL=%0.1f tT=%0.1f",n,last_transfer_cs_setup_ns,last_transfer_cs_hold_ns);
    $display("LEN%0d measured CS tL=%0.1f ns tT=%0.1f ns",n,last_transfer_cs_setup_ns,last_transfer_cs_hold_ns);
  endtask

  initial begin
    req_valid=0; req_write=0; req_addr=0; req_len=0; req_wdata=0; rsp_ready=1; miso=0;
    clocks=0; transaction_active=0; cap_count=0; bit_count=0; slave_bit=0; cs_assert_cycle=0; mosi_transition_count=0;
    cs_fall_ns=0; last_sck_ns=0; last_rise_ns=0; last_fall_ns=0; mosi_change_ns=0; miso_valid_ns=0; saw_sck_edge=0;
    min_cs_setup_ns=1.0e9; min_cs_hold_ns=1.0e9; min_period_ns=1.0e9; min_high_ns=1.0e9; min_low_ns=1.0e9; min_mosi_setup_ns=1.0e9; min_miso_delay_ns=1.0e9;
    last_transfer_cs_setup_ns=0; last_transfer_cs_hold_ns=0;
    for(int i=0;i<64;i++) read_bytes[i]=8'h80+i;
    repeat(4) @(posedge clk); rst_n=1;
    req_cycle=clocks; send_req(1,8'h08,1); wait_rsp(1000);
    $display("LEN1 request-to-CS=%0d cycles request-to-response=%0d cycles",cs_assert_cycle-req_cycle,clocks-req_cycle);
    check_capture(1,8'h0a,1);
    @(negedge clk); rsp_ready=1;
    @(posedge clk);
    for(int i=0;i<4;i++) req_wdata[i*8 +:8]=8'h30+i;
    send_req(1,8'h28,4); wait_rsp(3000); check_capture(4,8'h2a,1);
    if(rsp_error) $fatal(1,"unexpected error");
    @(negedge clk); rsp_ready=1; @(posedge clk);
    @(negedge clk); rsp_ready=0;
    send_req(0,8'h10,4); wait_rsp(3000); check_capture(4,8'h10,0);
    if(rsp_data[31:0] !== 32'h83828180) $fatal(1,"read response wrong %08x",rsp_data[31:0]);
    repeat(5) @(posedge clk); if(!rsp_valid) $fatal(1,"response did not hold under stall");
    @(negedge clk); rsp_ready=1; @(posedge clk);
    // 64-byte register burst; verifies preloading and uninterrupted CS.
    // Alternating transitions exercise MOSI setup on every adjacent data bit.
    for(int i=0;i<64;i++) req_wdata[i*8 +:8]=(i[0] ? 8'h5a : 8'ha5);
    @(negedge clk); rsp_ready=1; @(posedge clk);
    req_cycle=clocks; send_req(1,8'h08,64); wait_rsp(40000);
    $display("LEN64 request-to-CS=%0d cycles request-to-response=%0d cycles",cs_assert_cycle-req_cycle,clocks-req_cycle);
    check_capture(64,8'h0a,1);
    // Invalid zero length is reported without starting a physical transaction.
    send_req(1,8'h00,0); wait_rsp(10); if(!rsp_error || !cs_n) $fatal(1,"invalid zero-length handling");
    @(negedge clk); rsp_ready=1; @(posedge clk);
    send_req(1,8'h00,65); wait_rsp(10); if(!rsp_error || !cs_n) $fatal(1,"invalid overlength handling");
    @(negedge clk); rsp_ready=1; @(posedge clk);
    // Reset during an active transfer must immediately return the core to
    // idle with CS high, and must not leak a stale response after reset.
    send_req(1,8'h08,64);
    wait(cs_n==0);
    repeat(20) @(posedge clk);
    @(negedge clk); rst_n=0;
    repeat(2) @(posedge clk);
    if(!cs_n) $fatal(1,"CS stayed asserted after synchronous reset");
    @(negedge clk); rst_n=1;
    repeat(4) @(posedge clk);
    if(rsp_valid || busy) $fatal(1,"stale state after reset");
    $display("SPI timings ns: CS setup=%0.1f hold=%0.1f period=%0.1f high=%0.1f low=%0.1f MOSI setup=%0.1f MISO sample offset=%0.1f MOSI transitions=%0d",
      min_cs_setup_ns,min_cs_hold_ns,min_period_ns,min_high_ns,min_low_ns,min_mosi_setup_ns,min_miso_delay_ns,mosi_transition_count);
    $display("PASS max3421e_spi_bridge_tb"); $finish;
  end
endmodule
