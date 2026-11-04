`timescale 1ns/1ps
module usb_host_engine_tb;
  logic clk=0,rst_n=0;
  always #10 clk=~clk;
  logic init_done=1,connected=1,full_speed=1,fault=0;
  logic req_valid,req_ready; logic [7:0] req_token; logic [6:0] req_addr,req_out_len;
  logic [511:0] req_data; logic req_tgl_valid,req_rcv_tgl,req_snd_tgl,cancel;
  logic rsp_valid,rsp_ready; logic [2047:0] rsp_packet; logic [8:0] rsp_len; logic [3:0] rsp_error;
  logic rsp_rcv_tgl,rsp_snd_tgl,reg_lock,disco,frame_tick,reinit;
  logic reg_valid,reg_ready,reg_write; logic [4:0] reg_addr; logic [6:0] reg_len; logic [511:0] reg_wdata;
  logic reg_rsp_valid,reg_rsp_ready; logic [511:0] reg_rdata; logic reg_error;
  usb_host_engine #(.TRANSACTION_TIMEOUT_CYCLES(30000)) dut(
    .clk_i(clk),.rst_ni(rst_n),.init_done_i(init_done),.connected_i(connected),.full_speed_i(full_speed),.fault_i(fault),
    .host_req_valid_i(req_valid),.host_req_ready_o(req_ready),.host_req_token_i(req_token),.host_req_addr_i(req_addr),
    .host_req_wdata_i(req_data),.host_req_out_len_i(req_out_len),.host_req_toggle_valid_i(req_tgl_valid),
    .host_req_rcv_toggle_i(req_rcv_tgl),.host_req_snd_toggle_i(req_snd_tgl),.host_cancel_i(cancel),
    .host_rsp_valid_o(rsp_valid),.host_rsp_ready_i(rsp_ready),.host_rsp_packet_o(rsp_packet),.host_rsp_len_o(rsp_len),
    .host_rsp_error_o(rsp_error),.host_rsp_rcv_toggle_o(rsp_rcv_tgl),.host_rsp_snd_toggle_o(rsp_snd_tgl),
    .reg_lock_o(reg_lock),.disconnect_detected_o(disco),.frame_tick_o(frame_tick),.reinitialize_o(reinit),
    .reg_valid_o(reg_valid),.reg_ready_i(reg_ready),.reg_write_o(reg_write),.reg_addr_o(reg_addr),.reg_len_o(reg_len),
    .reg_wdata_o(reg_wdata),.reg_rsp_valid_i(reg_rsp_valid),.reg_rsp_ready_o(reg_rsp_ready),.reg_rdata_i(reg_rdata),.reg_error_i(reg_error));
  max3421e_controller_init_tb physical_init_test(.done_o(controller_done));

  int cycles,delay_q,irq_phase,bank_idx,rx_byte_idx,script_mode,first_irq_cycle,first_bank_free_cycle;
  int bank_count,produced_packets,bank_read_idx,next_packet_cycle,timed_first_cycle,timed_free_cycle;
  bit timed_done,bank_overrun;
  logic pending; logic [4:0] saved_addr; logic [6:0] saved_len; logic saved_write; logic [511:0] saved_data;
  logic [7:0] hrsl_value; int sndfifo_writes,sndbc_value,hxfr_count;
  logic [7:0] sndfifo_bytes[64];
  logic controller_done;
  int frame_ticks=0;
  always @(posedge clk) if(rst_n && frame_tick) frame_ticks++;
  assign reg_ready=!pending&&!reg_rsp_valid;
  always @(posedge clk) begin
    if(!rst_n) begin
      cycles<=0; delay_q<=0; pending<=0; reg_rsp_valid<=0; reg_rdata<=0; reg_error<=0;
      irq_phase<=0; bank_idx<=0; rx_byte_idx<=0; script_mode<=0; first_irq_cycle<=-1; first_bank_free_cycle<=-1;
      bank_count<=0; produced_packets<=0; bank_read_idx<=0; next_packet_cycle<=0; timed_first_cycle<=-1; timed_free_cycle<=-1; timed_done<=0; bank_overrun<=0;
      hrsl_value<=0; sndfifo_writes<=0; sndbc_value<=0; hxfr_count<=0;
    end else begin
      cycles<=cycles+1;
      if(script_mode==5 && produced_packets<4 && cycles>=next_packet_cycle) begin
        if(bank_count<2) begin
          bank_count<=bank_count+1;
          produced_packets<=produced_packets+1;
          if(produced_packets==3) timed_done<=1;
          if(timed_first_cycle<0) timed_first_cycle<=cycles;
        end else begin bank_overrun<=1; hrsl_value<=8'h06; end
        next_packet_cycle<=next_packet_cycle+2133;
      end
      if(reg_rsp_valid&&reg_rsp_ready) reg_rsp_valid<=0;
      if(reg_valid&&reg_ready) begin
        if(reg_write && reg_addr==29 && req_tgl_valid && req_token==8'h44 &&
           reg_wdata[7:0]!==8'h10)
          $fatal(1,"RCV DATA0 must set HCTL bit4 only; got %02x",reg_wdata[7:0]);
        pending<=1; saved_addr<=reg_addr; saved_len<=reg_len; saved_write<=reg_write; saved_data<=reg_wdata;
        delay_q<= (reg_addr==1 && !reg_write && reg_len==64) ? 1436 : 50;
      end
      if(pending) begin
        if(delay_q>0) delay_q<=delay_q-1;
        else begin
          pending<=0; reg_rsp_valid<=1; reg_error<=0; reg_rdata<=0;
          if(saved_write) begin
            if(saved_addr==4 && saved_len!=8) $fatal(1,"SETUP FIFO length");
            if(saved_addr==2) begin
              for(int b=0;b<64;b++) if(b<saved_len) sndfifo_bytes[b]<=saved_data[b*8 +:8];
              sndfifo_writes<=saved_len;
            end
            if(saved_addr==7) sndbc_value<=saved_data[7:0];
            if(saved_addr==30) begin
              hxfr_count<=hxfr_count+1;
              if(saved_data[7:0]==8'ha0) begin script_mode<=4; irq_phase<=0; end
              else if(saved_data[7:0]==8'h40) begin script_mode<=6; irq_phase<=0; bank_idx<=0; rx_byte_idx<=0; end
              else if(hxfr_count==0) begin script_mode<=1; irq_phase<=0; bank_idx<=0; rx_byte_idx<=0; first_irq_cycle<=-1; first_bank_free_cycle<=-1; end
              else if(hxfr_count==1) begin script_mode<=5; irq_phase<=0; bank_count<=0; produced_packets<=0; bank_read_idx<=0; rx_byte_idx<=0; timed_done<=0; bank_overrun<=0; timed_first_cycle<=-1; timed_free_cycle<=-1; next_packet_cycle<=cycles+20; end
              else if(hxfr_count==2 || hxfr_count==3) begin script_mode<=2; irq_phase<=0; end
              else begin script_mode<=3; irq_phase<=0; end
            end
            if(saved_addr==25) begin
              if(saved_data[2]) begin
                if(first_bank_free_cycle<0) first_bank_free_cycle<=cycles;
                irq_phase<=irq_phase+1;
                if(script_mode==5) begin
                  bank_count<=bank_count-1;
                  bank_read_idx<=bank_read_idx+1;
                  if(timed_free_cycle<0) timed_free_cycle<=cycles;
                end
              end
              if(saved_data[7]) irq_phase<=irq_phase+1;
              if(saved_data[7]&&script_mode==5) timed_done<=0;
            end
          end else case(saved_addr)
            25: begin
              if(script_mode==1) begin
                if(first_irq_cycle<0) begin reg_rdata<=8'hc4; first_irq_cycle<=cycles; end
                else if(irq_phase<4) reg_rdata<=8'h04;
                else if(irq_phase==4) reg_rdata<=8'h80;
                else reg_rdata<=0;
              end else if(script_mode==6) begin
                if(irq_phase==0) reg_rdata<=8'h04;
                else if(irq_phase==1) reg_rdata<=8'h84;
                else if(irq_phase==2) reg_rdata<=8'h80;
                else reg_rdata<=0;
              end else if(script_mode==5) begin
                reg_rdata<=(bank_count>0?8'h04:0)|(timed_done?8'h80:0);
              end
              else if(script_mode==2||script_mode==4) reg_rdata<=(irq_phase==0)?8'h80:0;
              else if(script_mode==3) reg_rdata<=0;
              else reg_rdata<=8'h80;
            end
            6: begin
              if(script_mode==5) begin if(bank_read_idx<3) reg_rdata<=64; else reg_rdata<=4; end
              else if(script_mode==6) begin if(bank_idx==0) reg_rdata<=10; else reg_rdata<=2; end
              else if(bank_idx<3) reg_rdata<=64; else reg_rdata<=4;
              bank_idx<=bank_idx+1;
            end
            1: begin
              for(int b=0;b<64;b++) if(b<saved_len) reg_rdata[b*8 +:8]<=rx_byte_idx+b;
              rx_byte_idx<=rx_byte_idx+saved_len;
            end
            31: begin
              if(script_mode==2) reg_rdata<=8'h06; // hrTOGERR/ISO overrun case
              else reg_rdata<=8'h30;
            end
            default: reg_rdata<=0;
          endcase
        end
      end
    end
  end

  task automatic submit(input byte token,input int out_n);
    @(negedge clk); req_token=token; req_out_len=out_n; req_valid=1;
    do @(posedge clk); while(!req_ready);
    @(negedge clk); req_valid=0;
  endtask
  task automatic wait_response(input int bound);
    int n; n=0;
    while(!rsp_valid&&n<bound) begin @(posedge clk); n++; end
    if(!rsp_valid) $fatal(1,"host response timeout engine_state=%0d script=%0d irq_phase=%0d bank_idx=%0d packet_len=%0d error=%x pending=%0d saved=%0d write=%0d",
      dut.state_q,script_mode,irq_phase,bank_idx,dut.packet_len_q,dut.error_q,pending,saved_addr,saved_write);
  endtask

  initial begin
    req_valid=0; req_token=0; req_addr=7'h12; req_out_len=0; req_data=0; req_tgl_valid=0; req_rcv_tgl=0; req_snd_tgl=0;
    cancel=0; rsp_ready=0;
    repeat(5) @(posedge clk); rst_n=1;
    @(negedge clk); full_speed=0;
    @(negedge clk); if(req_ready) $fatal(1,"low-speed device accepted by full-speed engine");
    full_speed=1;
    req_tgl_valid=1; req_rcv_tgl=0; req_snd_tgl=1;
    submit(8'h44,0); wait_response(30000);
    if(rsp_error!=0||rsp_len!=196) $fatal(1,"ISO IN result error=%x len=%0d",rsp_error,rsp_len);
    for(int i=0;i<196;i++) if(rsp_packet[i*8 +:8] !== i[7:0]) $fatal(1,"bad packet byte %0d",i);
    if(first_irq_cycle<0||first_bank_free_cycle<0||(first_bank_free_cycle-first_irq_cycle)>2133)
      $fatal(1,"first RX bank release missed 42.67us budget: %0d cycles",first_bank_free_cycle-first_irq_cycle);
    if(reinit) $fatal(1,"unexpected reinit after success");
    if(frame_ticks!=1) $fatal(1,"one FRAMEIRQ generated %0d frame ticks",frame_ticks);
    $display("ISO IN: response=%0d bytes; first RCVDAV bank freed in %0d cycles",rsp_len,first_bank_free_cycle-first_irq_cycle);
    @(negedge clk); rsp_ready=1; @(posedge clk); @(negedge clk); rsp_ready=0;

    // Production-time bank model: each 64-byte packet arrives 2,133 clocks
    // after the previous one; only two receive banks exist in the model.
    req_tgl_valid=0; submit(8'h44,0); wait_response(20000);
    if(rsp_error!=0||rsp_len!=196||bank_overrun) $fatal(1,"timed ISO receive failed err=%x len=%0d overrun=%0d",rsp_error,rsp_len,bank_overrun);
    for(int i=0;i<196;i++) if(rsp_packet[i*8 +:8] !== i[7:0]) $fatal(1,"timed packet byte %0d",i);
    if(timed_free_cycle-timed_first_cycle>2133) $fatal(1,"timed first bank release late: %0d",timed_free_cycle-timed_first_cycle);
    $display("Timed ISO: 196 bytes, 2-bank occupancy, no overrun; first-bank service %0d cycles",timed_free_cycle-timed_first_cycle);
    @(negedge clk); rsp_ready=1; @(posedge clk); @(negedge clk); rsp_ready=0;

    // The MAX RCVFIFO exposes 64-byte banks. A short final chunk is valid,
    // but another bank after a partial chunk is malformed; drain it and
    // discard the packet atomically.
    submit(8'h40,0); wait_response(10000);
    if(rsp_error!=13||rsp_len!=0) $fatal(1,"partial then additional chunk error=%x len=%0d",rsp_error,rsp_len);
    @(negedge clk); rsp_ready=1; @(posedge clk); @(negedge clk); rsp_ready=0;

    // HRSLT=6 is the MAX3421E ISO over/underrun code; packet must be atomic.
    submit(8'h44,0); wait_response(5000);
    if(rsp_error!=6||rsp_len!=0) $fatal(1,"HRSLT6 handling error=%x len=%0d",rsp_error,rsp_len);
    @(negedge clk); rsp_ready=1; @(posedge clk); @(negedge clk); rsp_ready=0;

    // OUT path writes FIFO and byte count before launching the token.
    for(int i=0;i<3;i++) req_data[i*8 +:8]=8'hA0+i;
    submit(8'hA0,3); wait_response(5000);
    if(rsp_error!=0||sndfifo_writes!=3||sndbc_value!=3||sndfifo_bytes[2]!=8'hA2)
      $fatal(1,"OUT setup failed error=%x fifo=%0d count=%0d",rsp_error,sndfifo_writes,sndbc_value);
    @(negedge clk); rsp_ready=1; @(posedge clk); @(negedge clk); rsp_ready=0;

    // No HXFRDN is bounded by the engine timer and asks the controller to
    // reinitialize after the engine releases the register lock.
    script_mode=3; submit(8'h00,0);
    wait(reinit); wait_response(50);
    if(rsp_error!=14||reg_lock) $fatal(1,"timeout/lock release");
    wait(controller_done);
    $display("PASS usb_host_engine_tb; HXFR launches=%0d",hxfr_count);
    $finish;
  end
endmodule

// Physical SPI peripheral model used to exercise the controller's complete
// initialization sequence through max3421e_spi_bridge and spi_master.
module max3421e_controller_init_tb(output logic done_o);
  logic clk=0,rst_n=0,int_n=1;
  always #10 clk=~clk;
  logic reg_lock=0,disconnect=0,reinit=0,reg_valid=0,reg_ready,reg_write=0;
  logic [4:0] reg_addr=0; logic [6:0] reg_len=1; logic [511:0] reg_wdata=0,reg_rdata;
  logic reg_rsp_valid,reg_rsp_ready=1,reg_error,init_done,connected,full_speed,frame_tick,fault;
  logic sck,mosi,miso=0,cs_n;
  logic [7:0] regs[32];
  int bit_count,data_count,reg_number,clock_count;
  logic [7:0] command_q,cmd_shift,data_shift;
  bit write_cmd,frame_pending;
  max3421e_controller #(.CLK_HZ(1_000_000),.DEBOUNCE_MS(2),.BUS_RESET_MS(1),.BUS_RESET_TIMEOUT_MS(3),.OSC_TIMEOUT_MS(2)) dut(
    .clk_i(clk),.rst_ni(rst_n),.int_n_i(int_n),.reg_lock_i(reg_lock),.disconnect_i(disconnect),.engine_reinitialize_i(reinit),
    .reg_valid_i(reg_valid),.reg_ready_o(reg_ready),.reg_write_i(reg_write),.reg_addr_i(reg_addr),.reg_len_i(reg_len),.reg_wdata_i(reg_wdata),
    .reg_rsp_valid_o(reg_rsp_valid),.reg_rsp_ready_i(reg_rsp_ready),.reg_rdata_o(reg_rdata),.reg_error_o(reg_error),
    .init_done_o(init_done),.connected_o(connected),.full_speed_o(full_speed),.frame_tick_o(frame_tick),.fault_o(fault),
    .sck_o(sck),.mosi_o(mosi),.miso_i(miso),.cs_n_o(cs_n));

  function automatic logic [7:0] read_register(input int a);
    if(a==13) read_register=8'h01; // OSCOKIRQ
    else if(a==25) read_register=frame_pending?8'h40:8'h00;
    else if(a==31) read_register=regs[31];
    else if(a==29) read_register=8'h00; // BUSRST auto-clears in this model
    else read_register=regs[a];
  endfunction
  always @(negedge cs_n) begin bit_count=0; data_count=0; command_q=0; cmd_shift=0; data_shift=0; write_cmd=0; end
  always @(posedge cs_n) miso=0;
  always @(posedge sck) begin
    if(!cs_n) begin
      if(bit_count<8) begin
        cmd_shift={cmd_shift[6:0],mosi};
        if(bit_count==7) begin
          command_q=cmd_shift; reg_number=command_q[7:3]; write_cmd=command_q[1]; data_shift=0;
        end
      end else if(write_cmd) begin
        data_shift={data_shift[6:0],mosi};
        if(bit_count==15+data_count*8) begin
          regs[reg_number]=data_shift;
          if(reg_number==29 && data_shift==8'h04) regs[31]=8'h80;
          if(reg_number==27 && data_shift==8'hc9) frame_pending=1;
          if(reg_number==25 && (data_shift&8'h40)) frame_pending=0;
          data_count++; data_shift=0;
        end
      end
      bit_count++;
    end
  end
  always @(negedge sck) begin
    if(!cs_n && !write_cmd && bit_count>=8) begin
      logic [7:0] rb; int byte_no,bit_no;
      byte_no=(bit_count-8)/8; bit_no=(bit_count-8)%8;
      rb=read_register(reg_number+byte_no);
      miso=rb[7-bit_no];
    end
  end
  always @(posedge clk) clock_count++;
  initial begin
    done_o=0; clock_count=0; frame_pending=0; bit_count=0; data_count=0; reg_number=0; command_q=0; cmd_shift=0; data_shift=0; write_cmd=0;
    for(int i=0;i<32;i++) regs[i]=0;
    repeat(4) @(posedge clk); rst_n=1;
    repeat(10000) begin
      @(posedge clk);
      if(init_done) break;
      if(fault) $fatal(1,"controller init fault at %0d",clock_count);
    end
    if(!init_done||!connected||!full_speed) $fatal(1,"controller did not initialize and detect full speed");
    if(regs[17]!=8'h18||regs[15]!=0||regs[27]!=8'hc9||regs[16]!=1||regs[26]!=8'h60)
      $fatal(1,"MAX initialization writes PINCTL=%02x CHIPRES=%02x MODE=%02x CPUCTL=%02x HIEN=%02x",regs[17],regs[15],regs[27],regs[16],regs[26]);
    if(!frame_pending) begin end
    $display("Physical controller init: cycles=%0d PINCTL=%02x MODE=%02x HIEN=%02x",clock_count,regs[17],regs[27],regs[26]);
    done_o=1;
  end
endmodule
