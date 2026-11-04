`timescale 1ns/1ps
module usb_audio_backpressure_tb;
  localparam int CLK_HZ=50_000_000;
  localparam int HALF_PERIOD_NS=10;
  localparam int ENUM_LIMIT=CLK_HZ/1000*40;
  logic clk=0, rst_n=0, connect=1;
  logic int_n,miso,sck,mosi,cs_n;
  logic [31:0] sample_data;
  logic sample_valid,sample_ready=1;
  logic connected,enumerated,streaming,fault;
  logic [31:0] frame_count,packet_count,dropped_packets,missed_frames;
  logic [31:0] protocol_errors,sample_count;
  logic [8:0] buffer_high_water;
  logic [31:0] model_frames,model_packets,model_missed,model_lost,model_overruns;
  logic [31:0] setup_count,status_count,nak_count,spi_transactions,spi_errors,usb_errors;
  logic [31:0] max_bank_latency,byte_gap_min,byte_gap_max,bank_reassert_count;
  logic [31:0] device_bytes,config_bytes;
  logic [1:0] max_bank_occupancy;
  logic device_configured,model_streaming;
  integer expected_sample=0, received_samples=0, observed_gap_samples=0;
  bit stream_seen=0;
  always #(HALF_PERIOD_NS) clk=~clk;

  max3421e_um2_model #(.CLK_HZ(CLK_HZ),.OSC_STARTUP_MS(1),.BUS_RESET_MS(2)) u_device (
    .clk_i(clk),.rst_ni(rst_n),.connect_i(connect),.sck_i(sck),.mosi_i(mosi),.cs_n_i(cs_n),
    .miso_o(miso),.int_n_o(int_n),.inject_nak_i(1'b0),.inject_stall_i(1'b0),
    .inject_crc_i(1'b0),.inject_timeout_i(1'b0),.inject_overrun_i(1'b0),
    .suppress_frame_irq_i(1'b0),.frame_count_o(model_frames),
    .iso_packet_count_o(model_packets),.missed_iso_frame_count_o(model_missed),
    .lost_sample_count_o(model_lost),.overrun_count_o(model_overruns),.setup_count_o(setup_count),
    .status_count_o(status_count),.control_nak_count_o(nak_count),
    .spi_transaction_count_o(spi_transactions),.spi_protocol_error_count_o(spi_errors),
    .usb_protocol_error_count_o(usb_errors),.max_bank_release_latency_o(max_bank_latency),
    .bank_reassert_count_o(bank_reassert_count),.max_bank_occupancy_o(max_bank_occupancy),
    .byte_gap_min_cycles_o(byte_gap_min),.byte_gap_max_cycles_o(byte_gap_max),
    .device_descriptor_bytes_o(device_bytes),.configuration_descriptor_bytes_o(config_bytes),
    .configured_o(device_configured),.streaming_o(model_streaming)
  );

  usb_audio_host_top #(.CLK_HZ(CLK_HZ),.DEBOUNCE_MS(2),.BUS_RESET_MS(2),
    .BUS_RESET_TIMEOUT_MS(4),.HOST_TIMEOUT_CYCLES(CLK_HZ/1000)) u_host (
    .clk_i(clk),.rst_ni(rst_n),.int_n_i(int_n),.miso_i(miso),.sck_o(sck),.mosi_o(mosi),.cs_n_o(cs_n),
    .sample_data_o(sample_data),.sample_valid_o(sample_valid),.sample_ready_i(sample_ready),
    .connected_o(connected),.enumerated_o(enumerated),.streaming_o(streaming),.fault_o(fault),
    .frame_count_o(frame_count),.packet_count_o(packet_count),.dropped_packets_o(dropped_packets),
    .missed_frames_o(missed_frames),.protocol_errors_o(protocol_errors),.sample_count_o(sample_count),
    .buffer_high_water_o(buffer_high_water)
  );

  // Model emits sequential stereo words: left=sample ID, right=~left.
  // Accumulate all missing IDs (including consecutive missed USB frames); the
  // settled aggregate must equal the model's exact lost-sample count.
  always @(posedge clk) begin : integrity_scoreboard
    logic [15:0] left_sample,right_sample;
    integer delta;
    if(!rst_n) begin
      expected_sample=0; received_samples=0; observed_gap_samples=0; stream_seen=0;
    end else begin
      if(streaming && !stream_seen) begin expected_sample=0; stream_seen=1; end
      if(sample_valid && sample_ready) begin
        left_sample=sample_data[15:0]; right_sample=sample_data[31:16];
        if(right_sample!==~left_sample)
          $fatal(1,"channel order/corruption: sample=%0d data=%08x",received_samples,sample_data);
        if(left_sample!==expected_sample[15:0]) begin
          delta=(int'(left_sample)-(expected_sample & 16'hffff)) & 16'hffff;
          if(delta<1 || delta>5000)
            $fatal(1,"reorder/corruption: expected=%0d got=%0d gap=%0d",expected_sample,left_sample,delta);
          observed_gap_samples=observed_gap_samples+delta;
          expected_sample=int'(left_sample);
        end
        expected_sample=expected_sample+1;
        received_samples=received_samples+1;
      end
    end
  end

  task automatic wait_for_stream;
    int n;
    begin
      n=0;
      while((!enumerated || !streaming || !model_streaming) && !fault && n<ENUM_LIMIT) begin
        @(posedge clk); n++;
      end
      if(!enumerated || !streaming || !model_streaming || fault)
        $fatal(1,"enumeration/stream timeout enum=%b top=%b model=%b fault=%b",enumerated,streaming,model_streaming,fault);
    end
  endtask

  task automatic wait_for_samples(input int target,input int limit_cycles);
    int n;
    begin
      n=0;
      while(received_samples<target && n<limit_cycles) begin @(posedge clk); n++; end
      if(received_samples<target)
        $fatal(1,"sample drain timeout received=%0d target=%0d",received_samples,target);
    end
  endtask

  initial begin : scenario
    int n,baseline_samples,baseline_frames,long_stall_lost,settle_frames;
    repeat(8) @(posedge clk);
    rst_n=1;
    wait_for_stream();
    if(!connected || !device_configured || fault || protocol_errors!=0)
      $fatal(1,"bad initial stream state connected=%b configured=%b fault=%b protocol=%0d",connected,device_configured,fault,protocol_errors);

    // One millisecond of consumer stall remains within the 256-frame FIFO.
    baseline_samples=received_samples;
    sample_ready=0;
    repeat(CLK_HZ/1000) @(posedge clk);
    if(buffer_high_water>=256 || model_lost!=0 || dropped_packets!=0)
      $fatal(1,"short stall unexpectedly lost data highwater=%0d model_lost=%0d drops=%0d",buffer_high_water,model_lost,dropped_packets);
    sample_ready=1;
    wait_for_samples(baseline_samples+48,CLK_HZ/1000*10);
    if(observed_gap_samples!=0 || model_lost!=0 || sample_count!=received_samples)
      $fatal(1,"short stall did not recover losslessly gaps=%0d model_lost=%0d accepted=%0d received=%0d",
        observed_gap_samples,model_lost,sample_count,received_samples);

    // Hold the consumer long enough to fill all 256 entries and back up the
    // packet decoder. USB SOFs continue; whole packets are dropped as needed.
    baseline_samples=received_samples;
    baseline_frames=model_frames;
    sample_ready=0;
    repeat(CLK_HZ*12/1000) @(posedge clk);
    if(buffer_high_water!=256)
      $fatal(1,"FIFO did not reach configured capacity: highwater=%0d",buffer_high_water);
    if(model_frames<baseline_frames+10 || model_lost==0 || (dropped_packets==0 && missed_frames==0))
      $fatal(1,"long stall not accounted by live source frames=%0d base=%0d lost=%0d drops=%0d missed=%0d",
        model_frames,baseline_frames,model_lost,dropped_packets,missed_frames);
    if(protocol_errors!=0 || fault || model_overruns!=0 || usb_errors!=0 || spi_errors!=0)
      $fatal(1,"unexpected transport/protocol fault proto=%0d fault=%b overrun=%0d usb/spi=%0d/%0d",
        protocol_errors,fault,model_overruns,usb_errors,spi_errors);
    long_stall_lost=model_lost;
    sample_ready=1;

    // FIFO backlog is about 5.3 ms. Wait well beyond drain plus fresh frames,
    // then compare every observed sequence gap to the model's exact lost IDs.
    settle_frames=model_frames+14;
    n=0;
    while(model_frames<settle_frames && n<CLK_HZ/1000*100) begin @(posedge clk); n++; end
    if(model_frames<settle_frames) $fatal(1,"post-stall stream did not settle within 100ms");
    wait_for_samples(received_samples+1,CLK_HZ/1000*10);
    repeat(CLK_HZ/1000*2) @(posedge clk);
    if(received_samples<=baseline_samples || sample_count!=received_samples)
      $fatal(1,"consumer did not resume sample flow accepted=%0d scoreboard=%0d",sample_count,received_samples);
    if(observed_gap_samples!=model_lost || model_lost<long_stall_lost)
      $fatal(1,"sample loss accounting mismatch observed=%0d model=%0d long-stall baseline=%0d",
        observed_gap_samples,model_lost,long_stall_lost);
    if(protocol_errors!=0 || fault || usb_errors!=0 || spi_errors!=0)
      $fatal(1,"post-stall protocol fault proto=%0d fault=%b usb/spi=%0d/%0d",protocol_errors,fault,usb_errors,spi_errors);

    $display("PASS backpressure: short-stall lossless; FIFO=%0d max, frames=%0d packets=%0d missed=%0d drops=%0d lost-samples=%0d observed-gaps=%0d received=%0d",
      buffer_high_water,model_frames,packet_count,missed_frames,dropped_packets,model_lost,observed_gap_samples,received_samples);
    $finish;
  end
endmodule
