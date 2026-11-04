// USB audio host receive subsystem, clocked entirely from clk_i. This module
// composes MAX3421E initialization/SPI, transaction and EP0 engines,
// enumeration/descriptor parsing, SOF-paced ISO-IN reception, PCM decoding,
// and the sample FIFO. It exports PCM with a ready/valid handshake and status
// counters; it does not route board pins or implement the ESP32 framing link.
module usb_audio_host_top #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter int unsigned DEBOUNCE_MS = 100,
  parameter int unsigned BUS_RESET_MS = 50,
  parameter int unsigned BUS_RESET_TIMEOUT_MS = 100,
  parameter int unsigned CTRL_TIMEOUT_CYCLES = 5*CLK_HZ,
  parameter int unsigned HOST_TIMEOUT_CYCLES = CLK_HZ/10,
  parameter int unsigned ISO_DEADLINE_CYCLES = CLK_HZ/4000,
  parameter int unsigned SOF_GAP_TIMEOUT_CYCLES = CLK_HZ*21/10000,
  parameter int unsigned FIFO_DEPTH = 256,
  parameter logic [15:0] EXPECTED_VID = 16'h08bb,
  parameter logic [15:0] EXPECTED_PID = 16'h2902,
  parameter logic [15:0] TARGET_RATE_HZ = 16'd48000,
  // Zero automatically selects a matching isochronous IN endpoint.
  parameter logic [7:0] TARGET_ENDPOINT = 8'h00,
  parameter logic [15:0] MIN_PACKET_BYTES = 16'd4,
  parameter logic [15:0] MAX_PACKET_BYTES = 16'd256
) (
  input logic clk_i, rst_ni, int_n_i, miso_i,
  output logic sck_o, mosi_o, cs_n_o,
  output logic [31:0] sample_data_o,
  output logic sample_valid_o, input logic sample_ready_i,
  output logic connected_o, enumerated_o, streaming_o, fault_o,
  output logic [31:0] frame_count_o, packet_count_o, dropped_packets_o,
  output logic [31:0] missed_frames_o, protocol_errors_o, sample_count_o,
  output logic [8:0] buffer_high_water_o
);
  logic init_done, full_speed, controller_frame_tick, controller_fault;
  logic engine_port_change, engine_reinitialize, engine_frame_tick, reg_lock;
  logic reg_valid, reg_ready, reg_write, reg_rsp_valid, reg_rsp_ready, reg_error;
  logic [4:0] reg_addr; logic [6:0] reg_len; logic [511:0] reg_wdata,reg_rdata;

  logic ctrl_req_valid;
  logic ctrl_done,ctrl_error;

  logic enum_req_valid,enum_req_ready,enum_cancel,enum_data_valid,enum_data_ready;
  logic [63:0] enum_setup; logic [15:0] enum_length;
  logic [6:0] enum_address,enum_ep0;
  logic [7:0] enum_data;
  logic enum_error;
  logic [7:0] enum_endpoint;
  logic [10:0] enum_max_packet;
  logic [7:0] enum_interval,enum_channels,enum_sample_bits;
  logic [15:0] enum_sample_rate;

  logic iso_enable, profile_ok, enum_connected, connected_prev_q, enum_error_prev_q;
  logic disconnect_pulse, flush_data;
  logic iso_req_valid,iso_req_ready,iso_rsp_valid,iso_rsp_ready;
  logic [7:0] iso_req_token; logic [6:0] iso_req_addr,iso_req_len;
  logic [511:0] iso_req_wdata;
  logic iso_req_toggle_valid,iso_req_rcv_toggle,iso_req_snd_toggle;
  logic [2047:0] iso_packet_data; logic [8:0] iso_packet_len;
  logic iso_packet_valid;
  logic [31:0] rx_frame_count,rx_packet_count,rx_dropped,rx_missed,rx_protocol;

  logic engine_req_valid,engine_req_ready,engine_cancel;
  logic [7:0] engine_req_token; logic [6:0] engine_req_addr,engine_req_len;
  logic [511:0] engine_req_wdata;
  logic engine_req_toggle_valid,engine_req_rcv_toggle,engine_req_snd_toggle;
  logic engine_rsp_valid,engine_rsp_ready;
  logic [2047:0] engine_rsp_packet; logic [8:0] engine_rsp_len;
  logic [3:0] engine_rsp_error;
  logic engine_rsp_rcv_toggle,engine_rsp_snd_toggle;
  logic owner_valid_q,owner_iso_q;
  logic ctrl_host_req_ready,ctrl_host_rsp_valid,ctrl_host_rsp_ready,ctrl_host_cancel;
  logic [7:0] ctrl_host_req_token; logic [6:0] ctrl_host_req_addr,ctrl_host_req_len;
  logic [511:0] ctrl_host_req_wdata;
  logic ctrl_host_req_toggle_valid,ctrl_host_req_rcv_toggle,ctrl_host_req_snd_toggle;
  logic iso_host_cancel;

  logic decoder_packet_ready,decoder_sample_valid,decoder_malformed;
  logic [31:0] decoder_sample_data;
  logic buffer_sample_ready,buffer_sample_valid;
  logic [31:0] buffer_sample_data;
  localparam int FIFO_COUNT_WIDTH=$clog2(FIFO_DEPTH+1);
  logic [FIFO_COUNT_WIDTH-1:0] buffer_high_water_internal;
  logic [8:0] buffer_high_water_9;
  logic [8:0] high_water_seen_q;
  logic [31:0] local_drop_count_q,local_protocol_count_q,enum_error_count_q;
  logic [1:0] local_drop_increment;
  logic [1:0] local_protocol_increment;
  logic enum_error_rise, stray_response;
  logic [31:0] internal_dropped,internal_protocol;
  localparam logic [15:0] DATAPATH_MAX_PACKET_BYTES =
    MAX_PACKET_BYTES > 16'd256 ? 16'd256 : MAX_PACKET_BYTES;

  max3421e_controller #(
    .CLK_HZ(CLK_HZ), .DEBOUNCE_MS(DEBOUNCE_MS), .BUS_RESET_MS(BUS_RESET_MS),
    .BUS_RESET_TIMEOUT_MS(BUS_RESET_TIMEOUT_MS)
  ) u_controller (
    .clk_i,.rst_ni,.int_n_i,.reg_lock_i(reg_lock),.port_change_i(engine_port_change),
    .engine_reinitialize_i(engine_reinitialize),.reg_valid_i(reg_valid),.reg_ready_o(reg_ready),
    .reg_write_i(reg_write),.reg_addr_i(reg_addr),.reg_len_i(reg_len),.reg_wdata_i(reg_wdata),
    .reg_rsp_valid_o(reg_rsp_valid),.reg_rsp_ready_i(reg_rsp_ready),.reg_rdata_o(reg_rdata),
    .reg_error_o(reg_error),.init_done_o(init_done),.connected_o,.full_speed_o(full_speed),
    .frame_tick_o(controller_frame_tick),.fault_o(controller_fault),.sck_o,.mosi_o,.miso_i,.cs_n_o
  );

  usb_host_engine #(.TRANSACTION_TIMEOUT_CYCLES(HOST_TIMEOUT_CYCLES)) u_host_engine (
    .clk_i,.rst_ni,.init_done_i(init_done),.connected_i(connected_o),.full_speed_i(full_speed),
    .fault_i(controller_fault),.host_req_valid_i(engine_req_valid),.host_req_ready_o(engine_req_ready),
    .host_req_token_i(engine_req_token),.host_req_addr_i(engine_req_addr),
    .host_req_wdata_i(engine_req_wdata),.host_req_out_len_i(engine_req_len),
    .host_req_toggle_valid_i(engine_req_toggle_valid),.host_req_rcv_toggle_i(engine_req_rcv_toggle),
    .host_req_snd_toggle_i(engine_req_snd_toggle),.host_cancel_i(engine_cancel),
    .host_rsp_valid_o(engine_rsp_valid),.host_rsp_ready_i(engine_rsp_ready),
    .host_rsp_packet_o(engine_rsp_packet),.host_rsp_len_o(engine_rsp_len),
    .host_rsp_error_o(engine_rsp_error),.host_rsp_rcv_toggle_o(engine_rsp_rcv_toggle),
    .host_rsp_snd_toggle_o(engine_rsp_snd_toggle),.reg_lock_o(reg_lock),
    .port_change_o(engine_port_change),.frame_tick_o(engine_frame_tick),
    .reinitialize_o(engine_reinitialize),.reg_valid_o(reg_valid),.reg_ready_i(reg_ready),
    .reg_write_o(reg_write),.reg_addr_o(reg_addr),.reg_len_o(reg_len),.reg_wdata_o(reg_wdata),
    .reg_rsp_valid_i(reg_rsp_valid),.reg_rsp_ready_o(reg_rsp_ready),
    .reg_rdata_i(reg_rdata),.reg_error_i(reg_error)
  );

  usb_control_transfer #(.CTRL_TIMEOUT_CYCLES(CTRL_TIMEOUT_CYCLES)) u_control (
    .clk_i,.rst_ni,.ctrl_req_valid_i(enum_req_valid),.ctrl_req_ready_o(enum_req_ready),
    .ctrl_setup_i(enum_setup),.ctrl_in_length_i(enum_length),.ctrl_address_i(enum_address),
    .ctrl_ep0_size_i(enum_ep0),.ctrl_cancel_i(enum_cancel || disconnect_pulse || engine_reinitialize),
    .ctrl_data_o(enum_data),.ctrl_data_valid_o(enum_data_valid),.ctrl_data_ready_i(enum_data_ready),
    .ctrl_done_o(ctrl_done),.ctrl_error_o(ctrl_error),.ctrl_error_code_o(), // top exports aggregate fault/counter only
    .host_req_valid_o(ctrl_req_valid),.host_req_ready_i(ctrl_host_req_ready),
    .host_req_token_o(ctrl_host_req_token),.host_req_addr_o(ctrl_host_req_addr),
    .host_req_wdata_o(ctrl_host_req_wdata),.host_req_out_len_o(ctrl_host_req_len),
    .host_req_toggle_valid_o(ctrl_host_req_toggle_valid),
    .host_req_rcv_toggle_o(ctrl_host_req_rcv_toggle),.host_req_snd_toggle_o(ctrl_host_req_snd_toggle),
    .host_cancel_o(ctrl_host_cancel),.host_rsp_valid_i(ctrl_host_rsp_valid),
    .host_rsp_ready_o(ctrl_host_rsp_ready),.host_rsp_packet_i(engine_rsp_packet),
    .host_rsp_len_i(engine_rsp_len),.host_rsp_error_i(engine_rsp_error),
    .host_rsp_rcv_toggle_i(engine_rsp_rcv_toggle),.host_rsp_snd_toggle_i(engine_rsp_snd_toggle)
  );

  assign enum_connected=connected_o && init_done && full_speed && !controller_fault &&
                        !engine_reinitialize && !disconnect_pulse;
  usb_enumerator #(
    .CLK_HZ(CLK_HZ),.CTRL_TIMEOUT_CYCLES(CTRL_TIMEOUT_CYCLES),
    .EXPECTED_VID(EXPECTED_VID),.EXPECTED_PID(EXPECTED_PID),
    .TARGET_RATE_HZ(TARGET_RATE_HZ),.TARGET_ENDPOINT(TARGET_ENDPOINT),
    .MIN_PACKET_BYTES(MIN_PACKET_BYTES),.MAX_PACKET_BYTES(DATAPATH_MAX_PACKET_BYTES)
  ) u_enumerator (
    .clk_i,.rst_ni,.connected_i(enum_connected),.ctrl_req_valid_o(enum_req_valid),
    .ctrl_req_ready_i(enum_req_ready),.ctrl_setup_o(enum_setup),.ctrl_in_length_o(enum_length),
    .ctrl_address_o(enum_address),.ctrl_ep0_size_o(enum_ep0),.ctrl_cancel_o(enum_cancel),
    .ctrl_data_i(enum_data),.ctrl_data_valid_i(enum_data_valid),.ctrl_data_ready_o(enum_data_ready),
    .ctrl_done_i(ctrl_done),.ctrl_error_i(ctrl_error),.enumerated_o(enumerated_o),
    .enum_error_o(enum_error),.enum_error_code_o(), // error detail is not part of the public top interface
    .configuration_o(),.interface_o(),.alternate_setting_o(),.endpoint_o(enum_endpoint),
    .max_packet_size_o(enum_max_packet),.interval_o(enum_interval),
    .channels_o(enum_channels),.sample_bits_o(enum_sample_bits),.sample_rate_o(enum_sample_rate)
  );

  assign profile_ok = enum_channels==2 && enum_sample_bits==16 && enum_sample_rate==TARGET_RATE_HZ &&
                      enum_interval==1 && enum_endpoint[7] && enum_endpoint[6:4]==0 &&
                      16'(enum_max_packet)>=MIN_PACKET_BYTES &&
                      16'(enum_max_packet)<=DATAPATH_MAX_PACKET_BYTES;
  assign iso_enable = init_done && connected_o && full_speed && enumerated_o &&
                      profile_ok && !enum_error && !controller_fault &&
                      !engine_reinitialize && !disconnect_pulse;
  assign streaming_o = iso_enable;
  assign fault_o = controller_fault || enum_error;
  // HIRQ.CONNIRQ reports either attach or detach. The host engine forwards
  // that event to the controller so it can inspect HRSL J/K state; only the
  // controller's confirmed connected_o falling edge means a real disconnect
  // and should cancel an in-flight enumeration/control transfer.
  assign disconnect_pulse = connected_prev_q && !connected_o;
  assign flush_data = disconnect_pulse || engine_reinitialize ||
                      (enum_error && !enum_error_prev_q);

  usb_isochronous_receiver #(
    .CLK_HZ(CLK_HZ),.DEADLINE_CYCLES(ISO_DEADLINE_CYCLES),
    .FRAME_GAP_TIMEOUT_CYCLES(SOF_GAP_TIMEOUT_CYCLES)
  ) u_iso_receiver (
    .clk_i,.rst_ni,.enable_i(iso_enable),.cancel_i(!iso_enable || disconnect_pulse),
    .flush_i(flush_data),.frame_tick_i(controller_frame_tick || engine_frame_tick),
    .address_i(7'd1),.endpoint_i(enum_endpoint[3:0]),.max_packet_size_i(enum_max_packet),
    .host_req_valid_o(iso_req_valid),.host_req_ready_i(iso_req_ready),
    .host_req_token_o(iso_req_token),.host_req_addr_o(iso_req_addr),
    .host_req_wdata_o(iso_req_wdata),.host_req_out_len_o(iso_req_len),
    .host_req_toggle_valid_o(iso_req_toggle_valid),.host_req_rcv_toggle_o(iso_req_rcv_toggle),
    .host_req_snd_toggle_o(iso_req_snd_toggle),.host_cancel_o(iso_host_cancel),
    .host_rsp_valid_i(iso_rsp_valid),.host_rsp_ready_o(iso_rsp_ready),
    .host_rsp_packet_i(engine_rsp_packet),.host_rsp_len_i(engine_rsp_len),
    .host_rsp_error_i(engine_rsp_error),.packet_data_o(iso_packet_data),
    .packet_len_o(iso_packet_len),.packet_valid_o(iso_packet_valid),
    .packet_ready_i(decoder_packet_ready),.frame_count_o(rx_frame_count),
    .packet_count_o(rx_packet_count),.dropped_packets_o(rx_dropped),
    .missed_frames_o(rx_missed),.protocol_errors_o(rx_protocol)
  );

  // Latch response ownership at the accepted request; enum state may change
  // or cancel while the lower engine is still draining its final response.
  always_comb begin
    engine_req_valid = !owner_valid_q && (ctrl_req_valid || iso_req_valid);
    if (ctrl_req_valid) begin
      engine_req_token=ctrl_host_req_token; engine_req_addr=ctrl_host_req_addr;
      engine_req_wdata=ctrl_host_req_wdata; engine_req_len=ctrl_host_req_len;
      engine_req_toggle_valid=ctrl_host_req_toggle_valid;
      engine_req_rcv_toggle=ctrl_host_req_rcv_toggle; engine_req_snd_toggle=ctrl_host_req_snd_toggle;
    end else begin
      engine_req_token=iso_req_token; engine_req_addr=iso_req_addr;
      engine_req_wdata=iso_req_wdata; engine_req_len=iso_req_len;
      engine_req_toggle_valid=iso_req_toggle_valid;
      engine_req_rcv_toggle=iso_req_rcv_toggle; engine_req_snd_toggle=iso_req_snd_toggle;
    end
    ctrl_host_req_ready=engine_req_ready && !owner_valid_q;
    iso_req_ready=engine_req_ready && !owner_valid_q && !ctrl_req_valid;
    ctrl_host_rsp_valid=engine_rsp_valid && owner_valid_q && !owner_iso_q;
    iso_rsp_valid=engine_rsp_valid && owner_valid_q && owner_iso_q;
    engine_rsp_ready=!owner_valid_q ? 1'b1 : owner_iso_q ? iso_rsp_ready : ctrl_host_rsp_ready;
    engine_cancel=owner_valid_q ? (owner_iso_q ? iso_host_cancel : ctrl_host_cancel) :
                  (ctrl_req_valid ? ctrl_host_cancel : iso_host_cancel);
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin owner_valid_q<=0; owner_iso_q<=0; end
    else begin
      if (engine_req_valid && engine_req_ready) begin
        owner_valid_q<=1; owner_iso_q<=!ctrl_req_valid;
      end
      if (engine_rsp_valid && engine_rsp_ready && owner_valid_q) owner_valid_q<=0;
    end
  end

  usb_pcm_decoder u_pcm_decoder (
    .clk_i,.rst_ni,.flush_i(flush_data),.packet_valid_i(iso_packet_valid),
    .packet_ready_o(decoder_packet_ready),.packet_data_i(iso_packet_data),
    .packet_len_i(iso_packet_len),.packet_error_i(1'b0),
    .sample_data_o(decoder_sample_data),.sample_valid_o(decoder_sample_valid),
    .sample_ready_i(buffer_sample_ready),.malformed_o(decoder_malformed)
  );
  audio_sample_buffer #(.DEPTH(FIFO_DEPTH)) u_audio_buffer (
    .clk_i,.rst_ni,.flush_i(flush_data),.sample_data_i(decoder_sample_data),
    .sample_valid_i(decoder_sample_valid),.sample_ready_o(buffer_sample_ready),
    .sample_data_o(buffer_sample_data),.sample_valid_o(buffer_sample_valid),
    .sample_ready_i(sample_ready_i),.occupancy_o(), // only high-water mark is exported
    .high_water_o(buffer_high_water_internal),.overflow_o() // valid&&!ready is retained backpressure, not loss
  );

  assign sample_data_o=buffer_sample_data;
  assign sample_valid_o=buffer_sample_valid && !flush_data;
  assign frame_count_o=rx_frame_count;
  assign packet_count_o=rx_packet_count;
  assign missed_frames_o=rx_missed;
  assign internal_dropped=rx_dropped+local_drop_count_q;
  assign dropped_packets_o=internal_dropped;
  assign internal_protocol=rx_protocol+local_protocol_count_q+enum_error_count_q;
  assign protocol_errors_o=internal_protocol;
  assign buffer_high_water_9=9'(buffer_high_water_internal);
  assign buffer_high_water_o=(buffer_high_water_9>high_water_seen_q)?buffer_high_water_9:high_water_seen_q;
  assign enum_error_rise=enum_error && !enum_error_prev_q;
  assign stray_response=engine_rsp_valid && !owner_valid_q;
  assign local_drop_increment={1'b0,decoder_malformed};
  assign local_protocol_increment={1'b0,decoder_malformed}+{1'b0,stray_response};

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      connected_prev_q<=0; enum_error_prev_q<=0; high_water_seen_q<=0;
      local_drop_count_q<=0; local_protocol_count_q<=0; enum_error_count_q<=0;
      sample_count_o<=0;
    end else begin
      connected_prev_q<=connected_o;
      enum_error_prev_q<=enum_error;
      if(buffer_high_water_internal>high_water_seen_q) high_water_seen_q<=buffer_high_water_internal;
      if(local_drop_increment!=0) local_drop_count_q<=local_drop_count_q+{30'b0,local_drop_increment};
      if(local_protocol_increment!=0) local_protocol_count_q<=local_protocol_count_q+{30'b0,local_protocol_increment};
      if(enum_error_rise) enum_error_count_q<=enum_error_count_q+1'b1;
      if(sample_valid_o && sample_ready_i && !flush_data) sample_count_o<=sample_count_o+1'b1;
    end
  end
endmodule
