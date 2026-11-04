// Requests standard device/configuration descriptors over the EP0 interface,
// validates the target VID/PID, assigns an address, selects a supported audio
// interface/alternate and waits for control status before publishing enumerated.
// USB tokens and MAX3421E SPI details belong to lower-level modules.
module usb_enumerator #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter int unsigned CTRL_TIMEOUT_CYCLES = CLK_HZ,
  parameter logic [15:0] EXPECTED_VID = 16'h08bb,
  parameter logic [15:0] EXPECTED_PID = 16'h2902,
  parameter logic [15:0] MAX_CONFIG_BYTES = 16'd2048,
  parameter logic [15:0] TARGET_RATE_HZ = 16'd48000,
  parameter logic [7:0] TARGET_ENDPOINT = 8'h00,
  parameter logic [15:0] MIN_PACKET_BYTES = 16'd4,
  parameter logic [15:0] MAX_PACKET_BYTES = 16'd256
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        connected_i,

  output logic        ctrl_req_valid_o,
  input  logic        ctrl_req_ready_i,
  output logic [63:0] ctrl_setup_o,
  output logic [15:0] ctrl_in_length_o,
  output logic [6:0]  ctrl_address_o,
  output logic [6:0]  ctrl_ep0_size_o,
  output logic        ctrl_cancel_o,
  input  logic [7:0]  ctrl_data_i,
  input  logic        ctrl_data_valid_i,
  output logic        ctrl_data_ready_o,
  input  logic        ctrl_done_i,
  input  logic        ctrl_error_i,

  output logic        enumerated_o,
  output logic        enum_error_o,
  output logic [3:0]  enum_error_code_o,
  output logic [7:0]  configuration_o,
  output logic [7:0]  interface_o,
  output logic [7:0]  alternate_setting_o,
  output logic [7:0]  endpoint_o,
  output logic [10:0] max_packet_size_o,
  output logic [7:0]  interval_o,
  output logic [7:0]  channels_o,
  output logic [7:0]  sample_bits_o,
  output logic [15:0] sample_rate_o
);
  localparam logic [7:0] REQ_GET_DESCRIPTOR = 8'h06;
  localparam logic [7:0] REQ_SET_ADDRESS = 8'h05;
  localparam logic [7:0] REQ_SET_CONFIGURATION = 8'h09;
  localparam logic [7:0] REQ_SET_INTERFACE = 8'h0b;
  localparam int unsigned SETTLE_CYCLES_RAW = (CLK_HZ * 2) / 1000;
  localparam int unsigned SETTLE_CYCLES = SETTLE_CYCLES_RAW < 1 ? 1 : SETTLE_CYCLES_RAW;
  localparam int unsigned TIMER_WIDTH = $clog2((CTRL_TIMEOUT_CYCLES < SETTLE_CYCLES ? SETTLE_CYCLES : CTRL_TIMEOUT_CYCLES) + 1);

  typedef enum logic [4:0] {
    ST_IDLE,
    ST_GET_DEV8_REQ, ST_GET_DEV8_WAIT,
    ST_GET_DEV18_REQ, ST_GET_DEV18_WAIT,
    ST_SET_ADDR_REQ, ST_SET_ADDR_WAIT, ST_SETTLE,
    ST_GET_CFG9_REQ, ST_GET_CFG9_WAIT,
    ST_GET_CFG_REQ, ST_GET_CFG_WAIT, ST_PARSE_WAIT,
    ST_SET_CFG_REQ, ST_SET_CFG_WAIT,
    ST_SET_IF_REQ, ST_SET_IF_WAIT,
    ST_DONE, ST_ERROR
  } state_t;
  state_t state_q;

  logic [7:0] device_buf_q [0:17];
  logic [7:0] config_header_q [0:8];
  logic [7:0] ep0_candidate_q, config_value_q, config_total_low_q;
  logic [15:0] config_total_q;
  logic [11:0] rx_count_q;
  logic [TIMER_WIDTH-1:0] timer_q;
  logic [31:0] settle_q;
  logic [6:0] address_q, ep0_size_q;
  logic parser_start;
  logic parser_complete_q;
  logic parser_ready, parser_done, parser_valid, parser_error;
  logic [7:0] parser_interface, parser_alt, parser_endpoint, parser_interval;
  logic [10:0] parser_packet;
  logic [7:0] parser_channels, parser_bits;
  logic [15:0] parser_rate;
  logic [15:0] request_length;
  logic [7:0] set_request, setup_type;
  logic [15:0] setup_value, setup_index;
  logic [63:0] setup_word;
  logic req_state, wait_state;
  logic data_accept;

  function automatic logic [63:0] make_setup(
      input logic [7:0] bm,
      input logic [7:0] req,
      input logic [15:0] value,
      input logic [15:0] index,
      input logic [15:0] length);
    make_setup = {length, index, value, req, bm};
  endfunction

  always_comb begin
    req_state = state_q == ST_GET_DEV8_REQ || state_q == ST_GET_DEV18_REQ ||
                state_q == ST_SET_ADDR_REQ || state_q == ST_GET_CFG9_REQ ||
                state_q == ST_GET_CFG_REQ || state_q == ST_SET_CFG_REQ || state_q == ST_SET_IF_REQ;
    wait_state = state_q == ST_GET_DEV8_WAIT || state_q == ST_GET_DEV18_WAIT ||
                 state_q == ST_SET_ADDR_WAIT || state_q == ST_GET_CFG9_WAIT ||
                 state_q == ST_GET_CFG_WAIT || state_q == ST_SET_CFG_WAIT || state_q == ST_SET_IF_WAIT;
    request_length = 0;
    set_request = 0;
    setup_type = 0;
    setup_value = 0;
    setup_index = 0;
    case (state_q)
      ST_GET_DEV8_REQ: begin request_length=16'd8; set_request=REQ_GET_DESCRIPTOR; setup_type=8'h80; setup_value=16'h0100; end
      ST_GET_DEV8_WAIT: request_length=16'd8;
      ST_GET_DEV18_REQ: begin request_length=16'd18; set_request=REQ_GET_DESCRIPTOR; setup_type=8'h80; setup_value=16'h0100; end
      ST_GET_DEV18_WAIT: request_length=16'd18;
      ST_SET_ADDR_REQ: begin set_request=REQ_SET_ADDRESS; setup_type=8'h00; setup_value=16'd1; end
      ST_GET_CFG9_REQ: begin request_length=16'd9; set_request=REQ_GET_DESCRIPTOR; setup_type=8'h80; setup_value=16'h0200; end
      ST_GET_CFG9_WAIT: request_length=16'd9;
      ST_GET_CFG_REQ: begin request_length=config_total_q; set_request=REQ_GET_DESCRIPTOR; setup_type=8'h80; setup_value=16'h0200; end
      ST_GET_CFG_WAIT: request_length=config_total_q;
      ST_SET_CFG_REQ: begin set_request=REQ_SET_CONFIGURATION; setup_type=8'h00; setup_value={8'h00,config_value_q}; end
      ST_SET_IF_REQ: begin set_request=REQ_SET_INTERFACE; setup_type=8'h01; setup_value={8'h00,parser_alt}; setup_index={8'h00,parser_interface}; end
      default: begin end
    endcase
    setup_word = make_setup(setup_type,set_request,setup_value,setup_index,request_length);
    ctrl_req_valid_o = req_state;
    ctrl_setup_o = setup_word;
    ctrl_in_length_o = request_length;
    ctrl_address_o = address_q;
    ctrl_ep0_size_o = ep0_size_q;
    ctrl_cancel_o = !rst_ni || !connected_i || state_q == ST_ERROR;
    ctrl_data_ready_o = 1'b0;
    if (state_q == ST_GET_DEV8_WAIT || state_q == ST_GET_DEV18_WAIT || state_q == ST_GET_CFG9_WAIT)
      ctrl_data_ready_o = 1'b1;
    else if (state_q == ST_GET_CFG_WAIT)
      ctrl_data_ready_o = parser_ready || parser_done || parser_error || {4'b0,rx_count_q} >= config_total_q;
    data_accept = ctrl_data_valid_i && ctrl_data_ready_o;
  end

  usb_descriptor_parser #(
    .TARGET_RATE_HZ(TARGET_RATE_HZ),.TARGET_ENDPOINT(TARGET_ENDPOINT),
    .MIN_PACKET_BYTES(MIN_PACKET_BYTES),.MAX_PACKET_BYTES(MAX_PACKET_BYTES)
  ) u_descriptor_parser (
    .clk_i, .rst_ni, .start_i(parser_start), .total_length_i(config_total_q),
    .byte_data_i(ctrl_data_i), .byte_valid_i(state_q == ST_GET_CFG_WAIT && ctrl_data_valid_i),
    .byte_ready_o(parser_ready), .done_o(parser_done), .valid_o(parser_valid), .error_o(parser_error),
    .interface_o(parser_interface), .alternate_setting_o(parser_alt), .endpoint_o(parser_endpoint),
    .max_packet_size_o(parser_packet), .interval_o(parser_interval), .channels_o(parser_channels),
    .sample_bits_o(parser_bits), .sample_rate_o(parser_rate)
  );

  always_ff @(posedge clk_i) begin : enum_fsm
    logic [12:0] next_rx_count;
    if (!rst_ni || !connected_i) begin
      state_q <= ST_IDLE;
      address_q <= 0;
      ep0_size_q <= 8;
      ep0_candidate_q <= 0;
      config_value_q <= 0;
      config_total_low_q <= 0;
      config_total_q <= 0;
      rx_count_q <= 0;
      timer_q <= 0;
      settle_q <= 0;
      parser_start <= 0;
      parser_complete_q <= 0;
      enumerated_o <= 0;
      enum_error_o <= 0;
      enum_error_code_o <= 0;
      configuration_o <= 0;
      interface_o <= 0;
      alternate_setting_o <= 0;
      endpoint_o <= 0;
      max_packet_size_o <= 0;
      interval_o <= 0;
      channels_o <= 0;
      sample_bits_o <= 0;
      sample_rate_o <= 0;
    end else begin
      parser_start <= 0;
      if (parser_done) parser_complete_q <= 1'b1;
      if ((wait_state && !ctrl_done_i && !ctrl_error_i) || (req_state && !ctrl_req_ready_i)) timer_q <= timer_q + 1'b1;
      else timer_q <= 0;
      next_rx_count = {1'b0,rx_count_q} + (data_accept ? 13'd1 : 13'd0);

      if (wait_state && ctrl_error_i) begin
        state_q <= ST_ERROR;
        enum_error_o <= 1;
        enum_error_code_o <= 4'd1;
      end else if (((wait_state && !ctrl_done_i) || (req_state && !ctrl_req_ready_i)) &&
                   CTRL_TIMEOUT_CYCLES != 0 && integer'(timer_q) >= CTRL_TIMEOUT_CYCLES-1) begin
        state_q <= ST_ERROR;
        enum_error_o <= 1;
        enum_error_code_o <= 4'd2;
      end else if (state_q == ST_GET_CFG_WAIT && parser_error) begin
        state_q <= ST_ERROR;
        enum_error_o <= 1;
        enum_error_code_o <= 4'd7;
      end else begin
        if (data_accept && {4'b0,rx_count_q} >= request_length) begin
          state_q <= ST_ERROR; enum_error_o <= 1; enum_error_code_o <= 4'd3;
        end else begin
          if (data_accept) begin
            if (state_q == ST_GET_DEV8_WAIT && rx_count_q == 7) ep0_candidate_q <= ctrl_data_i;
            if (state_q == ST_GET_DEV8_WAIT) device_buf_q[rx_count_q[4:0]] <= ctrl_data_i;
            if (state_q == ST_GET_DEV18_WAIT) device_buf_q[rx_count_q[4:0]] <= ctrl_data_i;
            if (state_q == ST_GET_CFG9_WAIT) begin
              config_header_q[rx_count_q[3:0]] <= ctrl_data_i;
              if (rx_count_q == 2) config_total_low_q <= ctrl_data_i;
              if (rx_count_q == 3) config_total_q <= {ctrl_data_i,config_total_low_q};
              if (rx_count_q == 5) config_value_q <= ctrl_data_i;
            end
            rx_count_q <= next_rx_count[11:0];
          end

          case (state_q)
            ST_IDLE: begin
              rx_count_q <= 0;
              enum_error_o <= 0;
              enum_error_code_o <= 0;
              if (connected_i) state_q <= ST_GET_DEV8_REQ;
            end
            ST_GET_DEV8_REQ: if (ctrl_req_ready_i) begin rx_count_q<=0; state_q<=ST_GET_DEV8_WAIT; end
            ST_GET_DEV8_WAIT: if (ctrl_done_i) begin
              if (next_rx_count != 8 || device_buf_q[0] != 18 || device_buf_q[1] != 1 ||
                  !((data_accept && rx_count_q == 7 ? ctrl_data_i : ep0_candidate_q) == 8 ||
                    (data_accept && rx_count_q == 7 ? ctrl_data_i : ep0_candidate_q) == 16 ||
                    (data_accept && rx_count_q == 7 ? ctrl_data_i : ep0_candidate_q) == 32 ||
                    (data_accept && rx_count_q == 7 ? ctrl_data_i : ep0_candidate_q) == 64)) begin
                state_q<=ST_ERROR; enum_error_o<=1; enum_error_code_o<=4'd3;
              end else begin
                ep0_size_q<=data_accept && rx_count_q == 7 ? ctrl_data_i[6:0] : ep0_candidate_q[6:0];
                rx_count_q<=0; state_q<=ST_GET_DEV18_REQ;
              end
            end
            ST_GET_DEV18_REQ: if (ctrl_req_ready_i) begin rx_count_q<=0; state_q<=ST_GET_DEV18_WAIT; end
            ST_GET_DEV18_WAIT: if (ctrl_done_i) begin
              if (next_rx_count != 18 || device_buf_q[0] != 18 || device_buf_q[1] != 1 ||
                  {device_buf_q[9],device_buf_q[8]} != EXPECTED_VID ||
                  {device_buf_q[11],device_buf_q[10]} != EXPECTED_PID ||
                  !(device_buf_q[7] == 8 || device_buf_q[7] == 16 || device_buf_q[7] == 32 || device_buf_q[7] == 64) ||
                  (data_accept && rx_count_q == 17 ? ctrl_data_i : device_buf_q[17]) == 0) begin state_q<=ST_ERROR; enum_error_o<=1; enum_error_code_o<=4'd4; end
              else begin ep0_size_q<=device_buf_q[7][6:0]; state_q<=ST_SET_ADDR_REQ; end
            end
            ST_SET_ADDR_REQ: if (ctrl_req_ready_i) state_q<=ST_SET_ADDR_WAIT;
            ST_SET_ADDR_WAIT: if (ctrl_done_i) begin address_q<=7'd1; settle_q<=0; state_q<=ST_SETTLE; end
            ST_SETTLE: if (settle_q >= SETTLE_CYCLES-1) begin settle_q<=0; state_q<=ST_GET_CFG9_REQ; end else settle_q<=settle_q+1'b1;
            ST_GET_CFG9_REQ: if (ctrl_req_ready_i) begin rx_count_q<=0; config_total_q<=0; state_q<=ST_GET_CFG9_WAIT; end
            ST_GET_CFG9_WAIT: if (ctrl_done_i) begin
              if (next_rx_count != 9 || config_header_q[0] < 9 || config_header_q[1] != 2 ||
                  (data_accept && rx_count_q == 3 ? {ctrl_data_i,config_total_low_q} : config_total_q) < 9 ||
                  (data_accept && rx_count_q == 3 ? {ctrl_data_i,config_total_low_q} : config_total_q) > MAX_CONFIG_BYTES ||
                  config_header_q[5] == 0) begin
                state_q<=ST_ERROR; enum_error_o<=1; enum_error_code_o<=4'd5;
              end else state_q<=ST_GET_CFG_REQ;
            end
            ST_GET_CFG_REQ: if (ctrl_req_ready_i) begin rx_count_q<=0; parser_complete_q<=0; parser_start<=1; state_q<=ST_GET_CFG_WAIT; end
            ST_GET_CFG_WAIT: if (ctrl_done_i) begin
              if ({3'b0,next_rx_count} != config_total_q) begin state_q<=ST_ERROR; enum_error_o<=1; enum_error_code_o<=4'd6; end
              else state_q<=ST_PARSE_WAIT;
            end
            ST_PARSE_WAIT: if (parser_error || ((parser_done || parser_complete_q) && !parser_valid)) begin state_q<=ST_ERROR; enum_error_o<=1; enum_error_code_o<=4'd7; end
                         else if ((parser_done || parser_complete_q) && parser_valid) begin
                           interface_o<=parser_interface; alternate_setting_o<=parser_alt;
                           endpoint_o<=parser_endpoint; max_packet_size_o<=parser_packet;
                           interval_o<=parser_interval; channels_o<=parser_channels;
                           sample_bits_o<=parser_bits; sample_rate_o<=parser_rate;
                           configuration_o<=config_value_q; state_q<=ST_SET_CFG_REQ;
                         end
            ST_SET_CFG_REQ: if (ctrl_req_ready_i) state_q<=ST_SET_CFG_WAIT;
            ST_SET_CFG_WAIT: if (ctrl_done_i) state_q<=ST_SET_IF_REQ;
            ST_SET_IF_REQ: if (ctrl_req_ready_i) state_q<=ST_SET_IF_WAIT;
            ST_SET_IF_WAIT: if (ctrl_done_i) begin state_q<=ST_DONE; enumerated_o<=1; end
            ST_DONE: begin end
            ST_ERROR: begin end
            default: begin state_q<=ST_ERROR; enum_error_o<=1; enum_error_code_o<=4'd15; end
          endcase
        end
      end
    end
  end
endmodule
