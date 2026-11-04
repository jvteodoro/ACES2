`timescale 1ns/1ps
module aces2_usb_audio_top_tb;
  localparam int CLK_HZ=50_000_000;
  logic clk_50=0; always #10 clk_50=~clk_50;
  logic [1:0] key_n=2'b10;
  logic [9:0] ledr;
  tri [35:0] gpio;
  tri [15:0] arduino_io;
  logic manual_int_n=1, manual_usb_miso=0, model_active=0;
  logic esp_miso_drive=0;
  wire arduino_reset_n;
  logic model_miso,model_int_n;
  logic [31:0] model_frames,model_packets,model_missed,model_lost,model_overruns;
  logic [31:0] model_setup,model_status,model_naks,model_spi_errors,model_usb_errors;
  logic [31:0] model_spi_transactions,model_bank_latency,model_bank_reassert;
  logic [31:0] model_byte_gap_min,model_byte_gap_max,model_device_bytes,model_config_bytes;
  logic [1:0] model_bank_occupancy;
  logic model_configured,model_streaming;
  logic consumer_active=0;
  logic [511:0] serial_frame=0;
  integer serial_bit_count=0;
  bit capture_this_frame=0;
  integer discarded_frames=0, verified_frames=0, invalid_frames=0;
  integer expected_sequence=0, prior_sample=-1, observed_samples=0;
  integer n;
  bit long_run;
  integer target_frames;
  realtime last_esp_sck_rise=0.0;

  assign arduino_io[9]=model_active ? model_int_n : manual_int_n;
  assign arduino_io[12]=model_active ? model_miso : manual_usb_miso;
  assign gpio[1]=esp_miso_drive;

  aces2_usb_audio_top dut(
    .clk_50(clk_50),.key_n(key_n),.ledr(ledr),.gpio(gpio),
    .arduino_io(arduino_io),.arduino_reset_n(arduino_reset_n));

  max3421e_um2_model #(.CLK_HZ(CLK_HZ),.OSC_STARTUP_MS(1),.BUS_RESET_MS(2)) u_device (
    .clk_i(clk_50),.rst_ni(dut.system_rst_n),.connect_i(model_active),
    .sck_i(arduino_io[13]),.mosi_i(arduino_io[11]),.cs_n_i(arduino_io[10]),
    .miso_o(model_miso),.int_n_o(model_int_n),
    .inject_nak_i(1'b0),.inject_stall_i(1'b0),.inject_crc_i(1'b0),
    .inject_timeout_i(1'b0),.inject_overrun_i(1'b0),.suppress_frame_irq_i(1'b0),
    .frame_count_o(model_frames),.iso_packet_count_o(model_packets),
    .missed_iso_frame_count_o(model_missed),.lost_sample_count_o(model_lost),
    .overrun_count_o(model_overruns),.setup_count_o(model_setup),.status_count_o(model_status),
    .control_nak_count_o(model_naks),.spi_transaction_count_o(model_spi_transactions),
    .spi_protocol_error_count_o(model_spi_errors),.usb_protocol_error_count_o(model_usb_errors),
    .max_bank_release_latency_o(model_bank_latency),.bank_reassert_count_o(model_bank_reassert),
    .max_bank_occupancy_o(model_bank_occupancy),.byte_gap_min_cycles_o(model_byte_gap_min),
    .byte_gap_max_cycles_o(model_byte_gap_max),.device_descriptor_bytes_o(model_device_bytes),
    .configuration_descriptor_bytes_o(model_config_bytes),.configured_o(model_configured),
    .streaming_o(model_streaming));

  function automatic logic [31:0] crc32_word(input logic [31:0] crc_i,input logic [31:0] data_i);
    logic [31:0] crc;
    logic [7:0] byte_value;
    integer byte_index,bit_index;
    begin
      crc=crc_i;
      for(byte_index=3;byte_index>=0;byte_index=byte_index-1) begin
        byte_value=data_i[byte_index*8 +: 8];
        crc=crc^byte_value;
        for(bit_index=0;bit_index<8;bit_index=bit_index+1)
          if(crc[0]) crc=(crc>>1)^32'hEDB8_8320;
          else crc=crc>>1;
      end
      crc32_word=crc;
    end
  endfunction

  task automatic check_spi_frame(input logic [511:0] raw_frame,input bit capture_it);
    logic [31:0] words[0:15];
    logic [31:0] crc;
    logic [15:0] left_sample,right_sample;
    integer i;
    begin
      if(!capture_it) begin
        discarded_frames=discarded_frames+1;
      end else begin
        for(i=0;i<16;i=i+1) words[i]=raw_frame[511-i*32 -: 32];
        if(words[0][31:16]!==16'hACED)
          $fatal(1,"wire frame header magic mismatch: %08x",words[0]);
        if(words[0][15:0]!==16'(expected_sequence))
          $fatal(1,"wire frame sequence mismatch expected=%0d got=%0d",expected_sequence,words[0][15:0]);
        crc=32'hFFFF_FFFF;
        for(i=0;i<15;i=i+1) crc=crc32_word(crc,words[i]);
        crc=crc^32'hFFFF_FFFF;
        if(words[15]!==crc)
          $fatal(1,"wire CRC mismatch sequence=%0d expected=%08x got=%08x",words[0][15:0],crc,words[15]);
        for(i=1;i<=14;i=i+1) begin
          left_sample=words[i][15:0]; right_sample=words[i][31:16];
          if(right_sample!==~left_sample)
            $fatal(1,"wire PCM channel order/corruption word=%0d data=%08x",i,words[i]);
          if(prior_sample>=0 && left_sample!==16'(prior_sample+1))
            $fatal(1,"wire PCM ordering error previous=%0d current=%0d",prior_sample,left_sample);
          prior_sample=int'(left_sample);
          observed_samples=observed_samples+1;
        end
        expected_sequence=expected_sequence+1;
        verified_frames=verified_frames+1;
      end
    end
  endtask

  // Observe the existing SPI master at the actual GPIO pins. CPOL/CPHA=0,
  // MSB-first: sample MOSI on rising SCK edges while CS_n is low.
  always @(negedge gpio[3]) begin
    serial_bit_count=0;
    serial_frame='0;
    capture_this_frame=consumer_active;
  end
  always @(posedge gpio[0]) begin
    if(gpio[3]===1'b0) begin
      if(last_esp_sck_rise!=0.0 && ($realtime-last_esp_sck_rise)<120.0)
        $fatal(1,"ESP32 SCK exceeded 8.33 MHz: rising-edge interval=%0.3f ns",
               $realtime-last_esp_sck_rise);
      last_esp_sck_rise=$realtime;
      serial_frame={serial_frame[510:0],gpio[2]};
      serial_bit_count=serial_bit_count+1;
    end
  end
  always @(posedge gpio[3]) last_esp_sck_rise=0.0;
  always @(posedge gpio[3]) begin
    if(serial_bit_count!=0) begin
      if(serial_bit_count!=512) begin
        invalid_frames=invalid_frames+1;
        if(capture_this_frame)
          $fatal(1,"captured GPIO SPI transaction had %0d bits, expected 512",serial_bit_count);
      end else check_spi_frame(serial_frame,capture_this_frame);
    end
  end

  initial begin
    long_run = $test$plusargs("LONG_RUN");
    // Preserve board reset timing and selected physical pad checks.
    #3;
    if(arduino_reset_n!==1'b0) $fatal(1,"KEY0 reset did not assert Arduino RST#/MAX RES# asynchronously");
    #4 key_n[0]=1;
    repeat(11) begin
      @(posedge clk_50); #1;
      if(arduino_reset_n!==1'b0) $fatal(1,"MAX RES# released before twelve synchronizer clocks");
    end
    @(posedge clk_50); #1;
    if(arduino_reset_n!==1'b1) $fatal(1,"MAX RES# did not release after guarded interval");
    if(arduino_io[8]!==1'bz) $fatal(1,"D8/GPX must remain undriven");
    if(dut.usb_int_n!==1'b1 || dut.usb_miso!==1'b0)
      $fatal(1,"jumper-selected USB input pads are not read correctly");
    manual_int_n=0; manual_usb_miso=1; #1;
    if(dut.usb_int_n!==1'b0 || dut.usb_miso!==1'b1)
      $fatal(1,"USB input pad polarity/selection wrong");
    if(gpio[0]!==dut.esp_sck || gpio[1]!==esp_miso_drive || dut.esp_miso!==esp_miso_drive ||
       gpio[2]!==dut.esp_mosi || gpio[3]!==dut.esp_cs_n)
      $fatal(1,"legacy ESP32 GPIO SPI mapping changed");
    if(arduino_io[10]!==dut.usb_cs_n || arduino_io[11]!==dut.usb_mosi ||
       arduino_io[13]!==dut.usb_sck)
      $fatal(1,"MAX3421E SPI Arduino pin mapping changed");

    // Reassert reset as before, then release for the model-backed board flow.
    #1 key_n[0]=0; #1;
    if(arduino_reset_n!==1'b0) $fatal(1,"KEY0 did not reassert external MAX reset");
    if(arduino_io[8]!==1'bz) $fatal(1,"D8/GPX was driven during reset");
    #7 key_n[0]=1;
    repeat(12) @(posedge clk_50);
    @(negedge clk_50);
    manual_int_n=1; manual_usb_miso=0;
    model_active=1;

    // Compress only the board top's configured 100ms attach debounce. The
    // MAX model, real host stack, USB cadence, PCM decoder and pins stay live.
    n=0;
    while(dut.u_audio_system.u_usb_audio_host.u_controller.state_q!=dut.u_audio_system.u_usb_audio_host.u_controller.C_DB && n<CLK_HZ/1000*10) begin
      @(posedge clk_50); n=n+1;
    end
    if(dut.u_audio_system.u_usb_audio_host.u_controller.state_q!=dut.u_audio_system.u_usb_audio_host.u_controller.C_DB)
      $fatal(1,"controller did not reach attach debounce; state=%0d",dut.u_audio_system.u_usb_audio_host.u_controller.state_q);
    @(negedge clk_50);
    force dut.u_audio_system.u_usb_audio_host.u_controller.timer_q = dut.u_audio_system.u_usb_audio_host.u_controller.DB_CYCLES-1;
    @(posedge clk_50); #1;
    release dut.u_audio_system.u_usb_audio_host.u_controller.timer_q;

    n=0;
    while((!dut.enumerated || !dut.streaming || !model_streaming) && !dut.host_fault && n<CLK_HZ/1000*100) begin
      @(posedge clk_50); n=n+1;
    end
    if(!dut.enumerated || !dut.streaming || !model_streaming || dut.host_fault)
      $fatal(1,"board host/model failed to stream enum=%b top=%b model=%b fault=%b after %0d cycles",
        dut.enumerated,dut.streaming,model_streaming,dut.host_fault,n);
    if(model_usb_errors!=0 || model_spi_errors!=0)
      $fatal(1,"USB/MAX model errors during board integration usb=%0d spi=%0d",model_usb_errors,model_spi_errors);

    if(long_run) begin
      // Capture from sequence zero for the complete synthetic one-second
      // 48 kHz stream. Fourteen payload words fit in each 16-word wire frame.
      consumer_active=1;
      target_frames=48000/14;
      n=0;
      while((dut.u_audio_system.u_usb_audio_host.sample_count_o<48000 || verified_frames<target_frames) &&
            n<CLK_HZ/1000*1100) begin @(posedge clk_50); n=n+1; end
      if(dut.u_audio_system.u_usb_audio_host.sample_count_o<48000 || verified_frames<target_frames ||
         observed_samples<target_frames*14 || invalid_frames!=0)
        $fatal(1,"long GPIO regression short: host samples=%0d frames=%0d payload=%0d target frames/payload=%0d/%0d invalid=%0d",
          dut.u_audio_system.u_usb_audio_host.sample_count_o,verified_frames,observed_samples,target_frames,target_frames*14,invalid_frames);
      if(expected_sequence!=verified_frames)
        $fatal(1,"long GPIO sequence discontinuity: verified=%0d next sequence=%0d",verified_frames,expected_sequence);
      if(discarded_frames!=0 || model_packets<1000 || model_usb_errors!=0 || model_spi_errors!=0 ||
         dut.protocol_errors!=0 || dut.host_fault || model_lost!=0 || model_missed!=0)
        $fatal(1,"long host/model fault/discard packets=%0d discarded=%0d protocol=%0d fault=%b model errors/lost/missed=%0d/%0d/%0d",
          model_packets,discarded_frames,dut.protocol_errors,dut.host_fault,model_usb_errors,model_spi_errors,model_lost,model_missed);
    end else begin
      // Preserve the quick default check: ignore the first complete ESP frame
      // until the downstream consumer is declared ready.
      n=0;
      while(discarded_frames==0 && n<CLK_HZ/1000*10) begin @(posedge clk_50); n=n+1; end
      if(discarded_frames==0) $fatal(1,"no initial ESP GPIO frame was discarded");
      expected_sequence=discarded_frames;
      consumer_active=1;
      n=0;
      while(verified_frames<2 && n<CLK_HZ/1000*10) begin @(posedge clk_50); n=n+1; end
      if(verified_frames<2 || invalid_frames!=0)
        $fatal(1,"integrated GPIO transport did not produce two complete frames verified=%0d invalid=%0d",
          verified_frames,invalid_frames);
    end
    if(dut.protocol_errors!=0 || dut.host_fault || model_lost!=0 || model_missed!=0)
      $fatal(1,"unexpected host/model fault protocol=%0d fault=%b model lost/missed=%0d/%0d",
        dut.protocol_errors,dut.host_fault,model_lost,model_missed);
    if(dut.u_audio_system.u_usb_audio_host.sample_count_o==0 || observed_samples<28 || model_packets==0 || model_bank_latency==0)
      $fatal(1,"insufficient PCM/model evidence samples=%0d observed=%0d packets=%0d bank latency=%0d",
      dut.u_audio_system.u_usb_audio_host.sample_count_o,observed_samples,model_packets,model_bank_latency);
    if(!ledr[0] || !ledr[1] || !ledr[2] || !ledr[4])
      $fatal(1,"board status LEDs did not show connected/enumerated/streaming/sample-seen: %b",ledr);

    if(long_run)
      $display("PASS aces2_usb_audio_top_tb LONG_RUN: model packets=%0d host samples=%0d discarded=%0d verified GPIO frames=%0d payload=%0d expected complete=%0d tail=%0d seq=0..%0d",
        model_packets,dut.u_audio_system.u_usb_audio_host.sample_count_o,discarded_frames,verified_frames,observed_samples,
        target_frames,48000-target_frames*14,expected_sequence-1);
    else
      $display("PASS aces2_usb_audio_top_tb: model packets=%0d host samples=%0d discarded frames=%0d verified GPIO frames=%0d seq=%0d..%0d CRC/PCM words=%0d",
        model_packets,dut.u_audio_system.u_usb_audio_host.sample_count_o,discarded_frames,verified_frames,expected_sequence-verified_frames,
        expected_sequence-1,observed_samples);
    $finish;
  end
endmodule
