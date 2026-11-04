`timescale 1ns/1ps
module usb_audio_host_tb #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter bit FAST_INIT = 1'b1
);
  localparam int unsigned TEST_DEBOUNCE_MS=FAST_INIT?2:100;
  localparam int unsigned TEST_BUS_RESET_MS=FAST_INIT?2:50;
  localparam int unsigned TEST_BUS_RESET_TIMEOUT_MS=FAST_INIT?4:100;
  localparam int unsigned TEST_HOST_TIMEOUT_CYCLES=FAST_INIT?(CLK_HZ/1000):(CLK_HZ/10);
  localparam int unsigned ENUM_WAIT_CYCLES=CLK_HZ/1000*(FAST_INIT?30:250);
  localparam int HALF_PERIOD_NS = 500_000_000 / CLK_HZ;
  logic clk=0, rst_n=0, connect=1;
  logic int_n, miso, sck, mosi, cs_n;
  logic [31:0] sample_data;
  logic sample_valid, sample_ready=1;
  logic connected, enumerated, streaming, fault;
  logic [31:0] frame_count, packet_count, dropped_packets, missed_frames;
  logic [31:0] protocol_errors, sample_count;
  logic [8:0] buffer_high_water;

  logic inject_nak=0, inject_stall=0, inject_crc=0, inject_timeout=0, inject_overrun=0;
  logic suppress_frame_irq=0;
  logic [31:0] model_frames, model_packets, model_missed, model_lost, model_overruns;
  logic [31:0] setup_count, status_count, nak_count, spi_transactions, spi_errors, usb_errors;
  logic [31:0] max_bank_latency, byte_gap_min, byte_gap_max, bank_reassert_count;
  logic [31:0] device_bytes, config_bytes;
  logic [1:0] max_bank_occupancy;
  logic device_configured, model_streaming;
  integer score_expected=0, score_received=0, score_gaps=0, score_gap_samples=0;
  logic [31:0] source_cycle[0:65535];
  logic source_seen[0:65535];
  bit scoreboard_allow_gap=0, latency_measure_enable=0;
  integer latency_count=0, latency_min=32'h7fffffff, latency_max=0;
  longint unsigned latency_sum=0;
  bit prev_enumerated=0;
  integer new_epoch_samples=0;
  always #(HALF_PERIOD_NS) clk=~clk;

  initial begin
    for (int k=0;k<65536;k++) begin source_cycle[k]=0; source_seen[k]=0; end
  end

  always @(u_device.frame_count_q) begin : source_timestamp
    integer sample_idx;
    integer frame_samples;
    if (rst_n && model_streaming) begin
      frame_samples=int'(u_device.current_packet_length_q)/4;
      for (int k=0;k<49;k++) begin
        if (k<frame_samples) begin
          sample_idx=int'(u_device.packet_sample_base_q)+k;
          if (sample_idx<65536) begin
            source_cycle[sample_idx]=u_device.cycles_q;
            source_seen[sample_idx]=1'b1;
          end
        end
      end
    end
  end

  max3421e_um2_model #(.CLK_HZ(CLK_HZ),.OSC_STARTUP_MS(FAST_INIT?1:5),
    .BUS_RESET_MS(TEST_BUS_RESET_MS)) u_device (
    .clk_i(clk),.rst_ni(rst_n),.connect_i(connect),.sck_i(sck),.mosi_i(mosi),.cs_n_i(cs_n),
    .miso_o(miso),.int_n_o(int_n),.inject_nak_i(inject_nak),.inject_stall_i(inject_stall),
    .inject_crc_i(inject_crc),.inject_timeout_i(inject_timeout),.inject_overrun_i(inject_overrun),
    .suppress_frame_irq_i(suppress_frame_irq),.frame_count_o(model_frames),
    .iso_packet_count_o(model_packets),.missed_iso_frame_count_o(model_missed),
    .lost_sample_count_o(model_lost),.overrun_count_o(model_overruns),.setup_count_o(setup_count),
    .status_count_o(status_count),.control_nak_count_o(nak_count),
    .spi_transaction_count_o(spi_transactions),.spi_protocol_error_count_o(spi_errors),
    .usb_protocol_error_count_o(usb_errors),.max_bank_release_latency_o(max_bank_latency),
    .bank_reassert_count_o(bank_reassert_count),
    .max_bank_occupancy_o(max_bank_occupancy),.byte_gap_min_cycles_o(byte_gap_min),
    .byte_gap_max_cycles_o(byte_gap_max),.device_descriptor_bytes_o(device_bytes),
    .configuration_descriptor_bytes_o(config_bytes),.configured_o(device_configured),
    .streaming_o(model_streaming)
  );

  usb_audio_host_top #(.CLK_HZ(CLK_HZ),.DEBOUNCE_MS(TEST_DEBOUNCE_MS),
    .BUS_RESET_MS(TEST_BUS_RESET_MS),.BUS_RESET_TIMEOUT_MS(TEST_BUS_RESET_TIMEOUT_MS),
    .HOST_TIMEOUT_CYCLES(TEST_HOST_TIMEOUT_CYCLES)) u_host (
    .clk_i(clk),.rst_ni(rst_n),.int_n_i(int_n),.miso_i(miso),.sck_o(sck),.mosi_o(mosi),.cs_n_o(cs_n),
    .sample_data_o(sample_data),.sample_valid_o(sample_valid),.sample_ready_i(sample_ready),
    .connected_o(connected),.enumerated_o(enumerated),.streaming_o(streaming),.fault_o(fault),
    .frame_count_o(frame_count),.packet_count_o(packet_count),.dropped_packets_o(dropped_packets),
    .missed_frames_o(missed_frames),.protocol_errors_o(protocol_errors),.sample_count_o(sample_count),
    .buffer_high_water_o(buffer_high_water)
  );

  always @(posedge clk) begin : sample_scoreboard
    logic [15:0] sample_left, sample_right;
    integer delta;
    integer pcm_latency;
    if (!rst_n) begin
      score_expected=0; score_received=0; score_gaps=0; score_gap_samples=0;
      prev_enumerated=0; new_epoch_samples=0;
      latency_count=0; latency_min=32'h7fffffff; latency_max=0; latency_sum=0;
    end else begin
      if (enumerated && !prev_enumerated) begin
        score_expected=0;
        new_epoch_samples=0;
      end
      if (sample_valid && sample_ready) begin
        sample_left=sample_data[15:0];
        sample_right=sample_data[31:16];
        if (sample_right !== ~sample_left) $fatal(1,"channel data mismatch sample=%0d data=%08x",score_received,sample_data);
        if (sample_left !== score_expected[15:0]) begin
          delta = (int'(sample_left) - (score_expected & 16'hffff)) & 16'hffff;
          if (!scoreboard_allow_gap || (delta < 47) || (delta > 49))
            $fatal(1,"sample sequence mismatch expected=%0d got=%0d gap=%0d",score_expected,sample_left,delta);
          score_gaps=score_gaps+1;
          score_gap_samples=score_gap_samples+delta;
          score_expected=int'(sample_left);
        end
        if (latency_measure_enable) begin
          if (!source_seen[sample_left])
            $fatal(1,"PCM sample %0d has no source SOF timestamp",sample_left);
          pcm_latency=int'(u_device.cycles_q-source_cycle[sample_left]);
          if (pcm_latency<0) $fatal(1,"negative model PCM latency %0d",pcm_latency);
          if (pcm_latency<latency_min) latency_min=pcm_latency;
          if (pcm_latency>latency_max) latency_max=pcm_latency;
          latency_sum=latency_sum+pcm_latency;
          latency_count=latency_count+1;
        end
        score_expected=score_expected+1;
        score_received=score_received+1;
        new_epoch_samples=new_epoch_samples+1;
      end
      prev_enumerated=enumerated;
    end
  end

  // The default retry case injects exactly one NAK, then lets the request
  // succeed on the host's retry.
  always @(posedge clk) begin
    if (rst_n && inject_nak && nak_count != 0 && !$test$plusargs("FAULT_NAK_EXHAUST"))
      inject_nak <= 1'b0;
  end


  task automatic wait_enum(input int unsigned limit_cycles);
    int unsigned n;
    begin
      n=0;
      while(!enumerated && !fault && n<limit_cycles) begin @(posedge clk); n++; end
      if(!enumerated) begin
        $display("DEBUG connected=%b init=%b enum_error=%b enum_connected=%b enum_state=%0d ctrl_state=%0d owner=%b engine_req=%b/%b engine_state=%0d reg=%b/%b controller_state=%0d bridge_pending=%b setup/status=%0d/%0d desc=%0d/%0d spi_tx/errors=%0d/%0d usb=%0d HIRQ=%02x HRSL=%02x",
          connected,u_host.init_done,u_host.enum_error,u_host.enum_connected,u_host.u_enumerator.state_q,
          u_host.u_control.state_q,u_host.owner_valid_q,
          u_host.engine_req_valid,u_host.engine_req_ready,u_host.u_host_engine.state_q,u_host.reg_valid,u_host.reg_ready,
          u_host.u_controller.state_q,u_host.u_controller.bridge_pending_q,setup_count,status_count,device_bytes,config_bytes,
          spi_transactions,spi_errors,usb_errors,u_device.hirq_q,u_device.regs[31]);
        $fatal(1,"enumeration timeout/fault=%b after %0d cycles",fault,n);
      end
    end
  endtask

  task automatic wait_model_frames(input int unsigned target, input int unsigned limit_cycles);
    int unsigned n;
    begin
      n=0;
      while(model_frames<target && !fault && n<limit_cycles) begin @(posedge clk); n++; end
      if(model_frames<target) $fatal(1,"stream timeout frame=%0d target=%0d fault=%b",model_frames,target,fault);
    end
  endtask

  initial begin : top_level_scenarios
    int unsigned n;
    int unsigned frame_base, packet_base, sample_base;
    int unsigned missed_frames_base, missed_samples_base, gap_samples_base, gap_events_base;
    int unsigned drop_base, model_packet_base, top_packet_base, lost_base, overrun_base;
    int unsigned disconnect_byte_index;
    bit expected_control_fault;
    expected_control_fault = $test$plusargs("FAULT_STALL") || $test$plusargs("FAULT_CRC") ||
                             $test$plusargs("FAULT_TIMEOUT") || $test$plusargs("FAULT_NAK_EXHAUST");
    rst_n=0;
    // One NAK on the first control transaction exercises actual retry and
    // proves that failed SETUP did not consume descriptor bytes.
    inject_nak=!expected_control_fault || $test$plusargs("FAULT_NAK_EXHAUST");
    repeat(8) @(posedge clk);
    rst_n=1;
    if ($test$plusargs("FAULT_STALL")) inject_stall=1;
    if ($test$plusargs("FAULT_CRC")) inject_crc=1;
    if ($test$plusargs("FAULT_TIMEOUT")) inject_timeout=1;
    if (expected_control_fault) begin
      n=0;
      while(!fault && !enumerated && n<CLK_HZ/10) begin @(posedge clk); n++; end
      if(!fault || enumerated) $fatal(1,"control fault was not surfaced fault=%b enum=%b cycles=%0d",fault,enumerated,n);
      $display("PASS injected control fault: stall=%b crc=%b timeout=%b nak-exhaust=%b setup=%0d nak=%0d",
        inject_stall,inject_crc,inject_timeout,$test$plusargs("FAULT_NAK_EXHAUST"),setup_count,nak_count);
      $finish;
      disable top_level_scenarios;
    end
    wait_enum(ENUM_WAIT_CYCLES);

    if (CLK_HZ < 50_000_000) begin
      // At 10 MHz system clock the same divider yields 5 MHz SPI while the
      // model keeps the USB full-speed byte rate at 1.5 MB/s.
      wait_model_frames(12,(CLK_HZ/1000)*20);
      if (model_overruns==0 || max_bank_occupancy!=2 || dropped_packets==0 || packet_count!=0)
        $fatal(1,"slow SPI overrun/discard mismatch: overrun=%0d highwater=%0d packets=%0d drops=%0d",model_overruns,max_bank_occupancy,packet_count,dropped_packets);
      if (max_bank_latency <= CLK_HZ/1_000_000*40)
        $fatal(1,"slow SPI test unexpectedly met the bank service deadline (%0d cycles)",max_bank_latency);
      $display("PASS slow-SPI negative: clk=%0d Hz SPI=%0d Hz max-bank-latency=%0d cycles overrun=%0d",
               CLK_HZ,CLK_HZ/2,max_bank_latency,model_overruns);
      $finish;
      disable top_level_scenarios;
    end

    if (!connected || !device_configured || !streaming || fault)
      $fatal(1,"top not streaming after enumeration connected=%b configured=%b streaming=%b fault=%b",connected,device_configured,streaming,fault);
    if (setup_count!=7 || status_count!=7 || device_bytes!=26 || config_bytes!=1200)
      $fatal(1,"control enumeration mismatch setup=%0d status=%0d device=%0d config=%0d",setup_count,status_count,device_bytes,config_bytes);
    if (nak_count!=1 || usb_errors!=0 || spi_errors!=0)
      $fatal(1,"control/SPI model errors nak=%0d usb=%0d spi=%0d",nak_count,usb_errors,spi_errors);
    latency_measure_enable=1;

    if ($test$plusargs("SMOKE") || $test$plusargs("RECOVERY")) begin
      wait_model_frames(12,(CLK_HZ/1000)*20);
      n=0;
      while(packet_count<10 && n<(CLK_HZ/1000)*4) begin @(posedge clk); n++; end
      if(packet_count<10 || dropped_packets!=0 || protocol_errors!=0 || score_received<450 ||
         latency_count!=score_received || latency_max>=CLK_HZ/1000 || bank_reassert_count==0)
        $fatal(1,"smoke stream mismatch model_frames/packets=%0d/%0d top_packets=%0d samples=%0d drops=%0d missed=%0d protocol=%0d model_err=%0d/%0d bank=%0d latency=%0d",
          model_frames,model_packets,packet_count,score_received,dropped_packets,missed_frames,protocol_errors,spi_errors,usb_errors,max_bank_occupancy,max_bank_latency);
      $display("PASS full-path smoke: setup/status=%0d/%0d config=%0d packets=%0d samples=%0d bank=%0d/%0d cyc PCM-latency=%0d..%0d cyc",
        setup_count,status_count,config_bytes,packet_count,score_received,max_bank_occupancy,max_bank_latency,latency_min,latency_max);
      if ($test$plusargs("SMOKE")) begin
        $finish;
        disable top_level_scenarios;
      end
    end

    if (!$test$plusargs("RECOVERY")) begin
      wait_model_frames(1000,(CLK_HZ/1000)*1100);
      n=0;
      while(sample_count<48_000 && n<(CLK_HZ/1000)*2) begin @(posedge clk); n++; end
      if(sample_count!=48_000 || score_received!=48_000 || score_gaps!=0)
        $fatal(1,"1000-frame PCM scoreboard count=%0d accepted=%0d gaps=%0d",sample_count,score_received,score_gaps);
      if(latency_count!=48_000 || latency_max>=CLK_HZ/1000)
        $fatal(1,"1000-frame digital PCM latency count=%0d min=%0d max=%0d cycles",latency_count,latency_min,latency_max);
      if(model_packets!=1000 || packet_count!=1000 || dropped_packets!=0 || missed_frames!=0 ||
         protocol_errors!=0 || model_missed!=0 || model_lost!=0 || model_overruns!=0)
        $fatal(1,"normal stream counters model_frames=%0d model_packets=%0d packets=%0d drops=%0d missed=%0d proto=%0d",
               model_frames,model_packets,packet_count,dropped_packets,missed_frames,protocol_errors);
      if(max_bank_occupancy>2 || max_bank_latency>CLK_HZ/1_000_000*42 ||
         byte_gap_min<33 || byte_gap_max>34 || buffer_high_water>256)
        $fatal(1,"timing/buffer limits banks=%0d latency=%0d byte-gap=%0d..%0d highwater=%0d",
               max_bank_occupancy,max_bank_latency,byte_gap_min,byte_gap_max,buffer_high_water);
      $display("PASS normal stream: frames=%0d packets=%0d PCM=%0d bytes=%0d bank=%0d/%0d cyc byte-gap=%0d..%0d PCM-latency=%0d..%0d cyc avg=%0d",
               model_frames,model_packets,score_received,config_bytes,max_bank_occupancy,max_bank_latency,byte_gap_min,byte_gap_max,
               latency_min,latency_max,latency_sum/latency_count);
      latency_measure_enable=0;
    end

    // Omit one SOF interrupt. The device sample clock still advances, so the
    // next received payload must reveal one 47-sample frame gap.
    scoreboard_allow_gap=1;
    frame_base=model_frames;
    missed_frames_base=model_missed;
    missed_samples_base=model_lost;
    gap_samples_base=score_gap_samples;
    gap_events_base=score_gaps;
    suppress_frame_irq=1;
    wait_model_frames(frame_base+1,(CLK_HZ/1000)*2);
    suppress_frame_irq=0;
    wait_model_frames(frame_base+3,(CLK_HZ/1000)*3);
    n=0;
    while(score_gaps==0 && n<(CLK_HZ/1000)*2) begin @(posedge clk); n++; end
    if(model_missed!=missed_frames_base+1 || missed_frames==0 ||
       score_gaps!=gap_events_base+1 || score_gap_samples-gap_samples_base!=47 ||
       model_lost-missed_samples_base!=47)
      $fatal(1,"missed frame did not create an observable sample gap model=%0d top=%0d score=%0d",model_missed,missed_frames,score_gaps);
    $display("Missed-frame injection: model/top missed=%0d/%0d lost=%0d scoreboard gap=%0d samples",
      model_missed-missed_frames_base,missed_frames,model_lost-missed_samples_base,score_gap_samples-gap_samples_base);

    // Unplug after the device has begun a payload so any partial FIFO bank and
    // in-flight host transaction must be discarded by disconnect recovery.
    n=0;
    while((!u_device.iso_active_q || u_device.iso_byte_index_q<80 ||
           u_device.iso_byte_index_q>=u_device.current_packet_length_q) && n<(CLK_HZ/1000)*4) begin
      @(posedge clk); n++;
    end
    if(!u_device.iso_active_q || u_device.iso_byte_index_q<80 ||
       u_device.iso_byte_index_q>=u_device.current_packet_length_q)
      $fatal(1,"could not reach an active partial ISO packet for disconnect");
    disconnect_byte_index=u_device.iso_byte_index_q;
    connect=0;
    n=0;
    while((connected || enumerated || streaming) && n<(CLK_HZ/1000)*5) begin @(posedge clk); n++; end
    if(connected || enumerated || streaming || sample_valid)
      $fatal(1,"disconnect did not clear host data path");
    $display("Disconnect injected mid-packet at source byte %0d/%0d",disconnect_byte_index,u_device.current_packet_length_q);
    packet_base=model_packets;
    connect=1;
    wait_enum(ENUM_WAIT_CYCLES);
    n=0;
    while(model_packets<packet_base+10 && n<(CLK_HZ/1000)*20) begin @(posedge clk); n++; end
    if(model_packets<packet_base+10 || !streaming || fault || new_epoch_samples<100)
      $fatal(1,"reconnect failed to resume capture packets=%0d baseline=%0d samples=%0d",model_packets,packet_base,new_epoch_samples);
    $display("Reconnect recovery: fresh enum complete, packets resumed to %0d",model_packets-packet_base);

    // Force one ISO overrun, observe the receiver's actual packet discard, and
    // wait for a following valid packet and samples before declaring recovery.
    overrun_base=model_overruns;
    lost_base=model_lost;
    drop_base=dropped_packets;
    model_packet_base=model_packets;
    top_packet_base=packet_count;
    sample_base=score_received;
    gap_samples_base=score_gap_samples;
    gap_events_base=score_gaps;
    scoreboard_allow_gap=1;
    inject_overrun=1;
    n=0;
    while(model_overruns==overrun_base && n<(CLK_HZ/1000)*3) begin @(posedge clk); n++; end
    inject_overrun=0;
    n=0;
    while((dropped_packets==drop_base || model_lost==lost_base) && n<(CLK_HZ/1000)*5) begin @(posedge clk); n++; end
    if(model_overruns!=overrun_base+1 || dropped_packets<=drop_base || model_lost==lost_base)
      $fatal(1,"overrun result was not discarded: model overrun=%0d drop=%0d lost=%0d",model_overruns-overrun_base,dropped_packets-drop_base,model_lost-lost_base);
    n=0;
    while((model_packets<=model_packet_base || packet_count<=top_packet_base || score_received<=sample_base ||
           score_gaps<=gap_events_base) && n<(CLK_HZ/1000)*8) begin
      @(posedge clk); n++;
    end
    if(model_packets<=model_packet_base || packet_count<=top_packet_base || score_received<=sample_base ||
       score_gaps<=gap_events_base || score_gap_samples-gap_samples_base!=model_lost-lost_base || max_bank_occupancy>2)
      $fatal(1,"post-overrun resume mismatch model_pkts=%0d top_pkts=%0d samples=%0d gap=%0d lost=%0d drops=%0d",
        model_packets-model_packet_base,packet_count-top_packet_base,score_received-sample_base,
        score_gap_samples-gap_samples_base,model_lost-lost_base,dropped_packets-drop_base);
    $display("PASS injected ISO overrun/recovery: overrun=%0d drop=%0d lost/gap samples=%0d/%0d resumed packets=%0d",
      model_overruns-overrun_base,dropped_packets-drop_base,model_lost-lost_base,
      score_gap_samples-gap_samples_base,model_packets-model_packet_base);
    $display("PASS usb_audio_host_tb; SPI transactions=%0d setup/status=%0d/%0d USB errors=%0d",
             spi_transactions,setup_count,status_count,usb_errors);
    $finish;
  end

endmodule
