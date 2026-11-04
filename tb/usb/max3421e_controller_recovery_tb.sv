`timescale 1ns/1ps
module max3421e_controller_recovery_tb;
  logic clk=0,rst_n=0,int_n=1,disconnect=0,engine_reinit=0;
  always #10 clk=~clk;
  logic reg_lock=0,reg_valid=0,reg_ready,reg_write=0;
  logic [4:0] reg_addr=20; logic [6:0] reg_len=1; logic [511:0] reg_wdata=0,reg_rdata;
  logic reg_rsp_valid,reg_rsp_ready=1,reg_error,init_done,connected,full_speed,frame_tick,fault;
  logic sck,mosi,miso=0,cs_n;
  logic [7:0] regs[32];
  int bit_count,data_count,reg_number,clock_count,hirq_reads,hrsl_reads;
  logic [7:0] command_q,cmd_shift,data_shift;
  bit write_cmd,frame_pending,hxfr_pending;
  logic eng_req_valid,eng_req_ready,eng_rsp_valid,eng_lock,eng_reg_valid,eng_reg_write;
  logic eng_reg_rsp_ready,eng_host_rsp_ready=0,eng_reinit,eng_disconnect,eng_frame;
  logic [2047:0] eng_packet;
  logic [8:0] eng_packet_len;
  logic [3:0] eng_error;
  logic [4:0] eng_reg_addr;
  logic [6:0] eng_reg_len;
  logic [511:0] eng_reg_wdata;
  max3421e_controller #(.CLK_HZ(1000),.DEBOUNCE_MS(2),.BUS_RESET_MS(1),.BUS_RESET_TIMEOUT_MS(1000),.OSC_TIMEOUT_MS(1000)) dut(
    .clk_i(clk),.rst_ni(rst_n),.int_n_i(int_n),.reg_lock_i(reg_lock|eng_lock),.disconnect_i(disconnect|eng_disconnect),.engine_reinitialize_i(engine_reinit|eng_reinit),
    .reg_valid_i(reg_valid|eng_reg_valid),.reg_ready_o(reg_ready),.reg_write_i(eng_reg_valid?eng_reg_write:reg_write),.reg_addr_i(eng_reg_valid?eng_reg_addr:reg_addr),.reg_len_i(eng_reg_valid?eng_reg_len:reg_len),.reg_wdata_i(eng_reg_valid?eng_reg_wdata:reg_wdata),
    .reg_rsp_valid_o(reg_rsp_valid),.reg_rsp_ready_i(reg_rsp_ready&eng_reg_rsp_ready),.reg_rdata_o(reg_rdata),.reg_error_o(reg_error),
    .init_done_o(init_done),.connected_o(connected),.full_speed_o(full_speed),.frame_tick_o(frame_tick),.fault_o(fault),
    .sck_o(sck),.mosi_o(mosi),.miso_i(miso),.cs_n_o(cs_n));
  usb_host_engine #(.TRANSACTION_TIMEOUT_CYCLES(10000)) engine(
    .clk_i(clk),.rst_ni(rst_n),.init_done_i(init_done),.connected_i(connected),.full_speed_i(full_speed),.fault_i(fault),
    .host_req_valid_i(eng_req_valid),.host_req_ready_o(eng_req_ready),.host_req_token_i(8'h00),.host_req_addr_i(7'h01),
    .host_req_wdata_i(512'b0),.host_req_out_len_i(7'b0),.host_req_toggle_valid_i(1'b0),.host_req_rcv_toggle_i(1'b0),.host_req_snd_toggle_i(1'b0),
    .host_cancel_i(1'b0),.host_rsp_valid_o(eng_rsp_valid),.host_rsp_ready_i(eng_host_rsp_ready),.host_rsp_packet_o(eng_packet),
    .host_rsp_len_o(eng_packet_len),.host_rsp_error_o(eng_error),.host_rsp_rcv_toggle_o(),.host_rsp_snd_toggle_o(),
    .reg_lock_o(eng_lock),.disconnect_detected_o(eng_disconnect),.frame_tick_o(eng_frame),.reinitialize_o(eng_reinit),
    .reg_valid_o(eng_reg_valid),.reg_ready_i(reg_ready),.reg_write_o(eng_reg_write),.reg_addr_o(eng_reg_addr),.reg_len_o(eng_reg_len),.reg_wdata_o(eng_reg_wdata),
    .reg_rsp_valid_i(reg_rsp_valid),.reg_rsp_ready_o(eng_reg_rsp_ready),.reg_rdata_i(reg_rdata),.reg_error_i(reg_error));
  function automatic logic [7:0] read_reg(input int a);
    if(a==13) read_reg=8'h01;
    else if(a==25) read_reg=(frame_pending?8'h40:8'h00)|(hxfr_pending?8'h80:8'h00);
    else if(a==31) read_reg=regs[31];
    else if(a==29) read_reg=0;
    else if(a==20) read_reg=8'ha5;
    else read_reg=regs[a];
  endfunction
  always @(negedge cs_n) begin bit_count=0; data_count=0; command_q=0; cmd_shift=0; data_shift=0; write_cmd=0; end
  always @(posedge cs_n) miso=0;
  always @(posedge sck) if(!cs_n) begin
    if(bit_count<8) begin
      cmd_shift={cmd_shift[6:0],mosi};
      if(bit_count==7) begin command_q=cmd_shift; reg_number=command_q[7:3]; write_cmd=command_q[1]; data_shift=0; end
    end else if(write_cmd) begin
      data_shift={data_shift[6:0],mosi};
      if(bit_count==15+data_count*8) begin
        regs[reg_number]=data_shift;
        if(reg_number==29&&data_shift==8'h04) regs[31]=8'h80;
        if(reg_number==27&&data_shift==8'hc9) frame_pending=1;
        if(reg_number==25&&(data_shift&8'h40)) frame_pending=0;
        if(reg_number==30) hxfr_pending=1;
        if(reg_number==25&&(data_shift&8'h80)) hxfr_pending=0;
        data_count++; data_shift=0;
      end
    end
    bit_count++;
  end
  always @(negedge sck) if(!cs_n&&!write_cmd&&bit_count>=8) begin
    logic [7:0] rb; int byte_no,bit_no;
    byte_no=(bit_count-8)/8; bit_no=(bit_count-8)%8; rb=read_reg(reg_number+byte_no); miso=rb[7-bit_no];
    if(bit_count==8&&reg_number==25) hirq_reads++;
    if(bit_count==8&&reg_number==31) hrsl_reads++;
  end
  always @(posedge clk) clock_count++;

  task automatic wait_init(input int max_cycles);
    int n; n=0;
    while(!init_done&&n<max_cycles) begin @(posedge clk); n++; end
    if(!init_done||!connected||!full_speed||fault) $fatal(1,"init/recovery timeout or state invalid init=%0d connected=%0d speed=%0d fault=%0d",init_done,connected,full_speed,fault);
  endtask
  initial begin
    clock_count=0; bit_count=0; data_count=0; reg_number=0; hirq_reads=0; hrsl_reads=0; frame_pending=0; hxfr_pending=0; command_q=0; cmd_shift=0; data_shift=0; write_cmd=0; eng_req_valid=0;
    for(int i=0;i<32;i++) regs[i]=0;
    repeat(4) @(posedge clk); rst_n=1;
    wait_init(10000);

    // Hold an accepted read while reinit and INT arrive together. Its response
    // must complete before CHIPRES begins the new initialization sequence.
    @(negedge clk); reg_lock=1; reg_valid=1; reg_write=0;
    do @(posedge clk); while(!reg_ready);
    @(negedge clk); reg_valid=0; engine_reinit=1; int_n=0;
    @(posedge clk);
    @(negedge clk); engine_reinit=0;
    if(init_done) $fatal(1,"init_done did not drop for reinit");
    wait(reg_rsp_valid);
    if(reg_error||reg_rdata[7:0]!=8'ha5) $fatal(1,"accepted client response corrupted during reinit");
    @(posedge clk); @(negedge clk); reg_lock=0;
    wait_init(10000);
    if(hirq_reads<2) $fatal(1,"controller did not service deferred INT/HIRQ");
    repeat(5200) @(posedge clk);
    if(!init_done) $fatal(1,"init_done dropped during ordinary idle IRQ polling");

    // A bus-change notification and a client valid arriving together must
    // block the new op until the HRSL/debounce/bus-reset recovery finishes.
    @(negedge clk); reg_valid=1; disconnect=1;
    #1 if(reg_ready||init_done) $fatal(1,"new client op accepted during disconnect recovery");
    @(posedge clk); @(negedge clk); disconnect=0;
    repeat(4) begin
      @(posedge clk);
      if(reg_ready) $fatal(1,"client ready escaped recovery quarantine");
    end
    wait_init(10000);
    while(!reg_ready) @(posedge clk);
    @(posedge clk); @(negedge clk); reg_valid=0;
    wait(reg_rsp_valid);
    if(reg_error||reg_rdata[7:0]!=8'ha5) $fatal(1,"deferred read response invalid");
    @(posedge clk); @(negedge clk); reg_lock=0;

    // Align the request handshake with the controller's idle poll deadline
    // while INT is asserted. The engine must advertise its lock on that same
    // edge, so the controller stays in C_READY and cannot steal the bridge.
    do begin
      wait(dut.state_q==6'd20 && dut.int_sync_q==0);
      @(negedge clk);
    end while(dut.state_q!=6'd20);
    eng_req_valid=1;
    #1 if(!eng_req_ready||!eng_lock) $fatal(1,"engine failed to reserve controller on its accept edge");
    @(posedge clk);
    if(dut.state_q!=6'd20) $fatal(1,"controller launched an idle IRQ operation on engine accept edge state=%0d lock=%0d valid=%0d ready=%0d",dut.state_q,eng_lock,eng_reg_valid,reg_ready);
    @(negedge clk); eng_req_valid=0; int_n=1;
    wait(eng_rsp_valid);
    if(eng_error!=0||eng_packet_len!=0||eng_reinit) $fatal(1,"engine transaction lost during simultaneous idle INT/request err=%x",eng_error);
    @(negedge clk); eng_host_rsp_ready=1;
    @(posedge clk); @(negedge clk); eng_host_rsp_ready=0;
    $display("PASS max3421e_controller_recovery_tb cycles=%0d HIRQ reads=%0d HRSL reads=%0d",clock_count,hirq_reads,hrsl_reads);
    $finish;
  end
endmodule
