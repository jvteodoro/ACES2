// Schedules at most one isochronous IN request per SOF/frame tick. Stages the
// returned packet independently of the PCM consumer so MAX3421E receive banks
// can be drained promptly; tracks packet/frame deadlines and drop/error counts.
// An unaccepted request is cancelled at its frame deadline by design.
module usb_isochronous_receiver #(
  parameter int unsigned CLK_HZ = 50_000_000,
  parameter int unsigned DEADLINE_CYCLES = CLK_HZ/4000,
  parameter int unsigned FRAME_LATE_THRESHOLD_CYCLES = CLK_HZ*15/10000,
  parameter int unsigned FRAME_GAP_TIMEOUT_CYCLES = CLK_HZ*21/10000
) (
  input logic clk_i, rst_ni,
  input logic enable_i, cancel_i, flush_i, frame_tick_i,
  input logic [6:0] address_i, input logic [3:0] endpoint_i,
  input logic [10:0] max_packet_size_i,
  output logic host_req_valid_o, input logic host_req_ready_i,
  output logic [7:0] host_req_token_o, output logic [6:0] host_req_addr_o,
  output logic [511:0] host_req_wdata_o, output logic [6:0] host_req_out_len_o,
  output logic host_req_toggle_valid_o, host_req_rcv_toggle_o, host_req_snd_toggle_o,
  output logic host_cancel_o,
  input logic host_rsp_valid_i, output logic host_rsp_ready_o,
  input logic [2047:0] host_rsp_packet_i, input logic [8:0] host_rsp_len_i,
  input logic [3:0] host_rsp_error_i,
  output logic [2047:0] packet_data_o, output logic [8:0] packet_len_o,
  output logic packet_valid_o, input logic packet_ready_i,
  output logic [31:0] frame_count_o, packet_count_o, dropped_packets_o,
  output logic [31:0] missed_frames_o, protocol_errors_o
);
  logic request_pending_q, transaction_active_q, packet_pending_q;
  logic gap_seen_since_tick_q;
  logic [31:0] deadline_q, frame_age_q;
  logic [2047:0] packet_q;
  logic [8:0] packet_len_q;
  logic response_success, response_drop, response_protocol;
  logic deadline_expired, frame_missed, frame_late, frame_gap;
  logic [2:0] missed_increment;
  logic [1:0] protocol_increment;

  assign host_req_valid_o = request_pending_q && enable_i &&
                            deadline_q < DEADLINE_CYCLES && !cancel_i;
  assign host_req_token_o = {2'b01,1'b0,1'b0,endpoint_i}; // ISO-IN token
  assign host_req_addr_o = address_i;
  assign host_req_wdata_o = '0;
  assign host_req_out_len_o = 0;
  assign host_req_toggle_valid_o = 0;
  assign host_req_rcv_toggle_o = 0;
  assign host_req_snd_toggle_o = 0;
  assign host_cancel_o = transaction_active_q && (cancel_i || !enable_i);
  assign host_rsp_ready_o = 1'b1; // never hold MAX3421E packet banks for PCM backpressure
  assign packet_data_o = packet_q;
  assign packet_len_o = packet_len_q;
  assign packet_valid_o = packet_pending_q && !flush_i && enable_i;

  assign response_success = host_rsp_valid_i && host_rsp_error_i==0;
  assign response_drop = host_rsp_valid_i &&
    (!transaction_active_q || host_rsp_error_i!=0 || {2'b0,host_rsp_len_i}>max_packet_size_i || !enable_i || flush_i ||
     (packet_pending_q && !packet_ready_i && !flush_i));
  assign response_protocol = host_rsp_valid_i &&
    (!transaction_active_q || host_rsp_error_i!=0 || {2'b0,host_rsp_len_i}>max_packet_size_i);
  assign deadline_expired = request_pending_q && deadline_q>=DEADLINE_CYCLES;
  assign frame_gap = enable_i && !frame_tick_i && frame_age_q>=FRAME_GAP_TIMEOUT_CYCLES-1;
  // A late observed SOF estimates at least one omitted interval. Resetting the
  // age on every tick prevents the watchdog from counting this same gap again.
  assign frame_late = enable_i && frame_tick_i &&
                      !gap_seen_since_tick_q &&
                      frame_age_q>=FRAME_LATE_THRESHOLD_CYCLES;
  assign frame_missed = frame_tick_i && enable_i &&
    (request_pending_q || transaction_active_q || packet_pending_q);
  assign missed_increment = {2'b0,deadline_expired} + {2'b0,frame_missed} +
                            {2'b0,frame_late} + {2'b0,frame_gap};
  assign protocol_increment = {1'b0,response_protocol} + {1'b0,1'b0};

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      request_pending_q<=0; transaction_active_q<=0; packet_pending_q<=0;
      deadline_q<=0; packet_q<=0; packet_len_q<=0;
      frame_age_q<=0; gap_seen_since_tick_q<=0;
      frame_count_o<=0; packet_count_o<=0; dropped_packets_o<=0;
      missed_frames_o<=0; protocol_errors_o<=0;
    end else begin
      if (enable_i && frame_tick_i) frame_count_o<=frame_count_o+1'b1;
      if (missed_increment!=0) missed_frames_o<=missed_frames_o+{29'b0,missed_increment};
      if (response_drop) dropped_packets_o<=dropped_packets_o+1'b1;
      if (protocol_increment!=0) protocol_errors_o<=protocol_errors_o+{30'b0,protocol_increment};
      if (response_success && transaction_active_q) packet_count_o<=packet_count_o+1'b1;

      if (!enable_i || frame_tick_i) frame_age_q<=0;
      else if (frame_gap) frame_age_q<=0;
      else frame_age_q<=frame_age_q+1'b1;
      if (!enable_i || frame_tick_i) gap_seen_since_tick_q<=0;
      else if (frame_gap) gap_seen_since_tick_q<=1;

      if (flush_i || !enable_i) begin
        request_pending_q<=0;
        deadline_q<=0;
        packet_pending_q<=0;
        packet_q<=0;
        packet_len_q<=0;
        if (host_rsp_valid_i) transaction_active_q<=0;
      end else begin
        if (packet_pending_q && packet_ready_i) packet_pending_q<=0;
        if (frame_tick_i) begin
          if (!request_pending_q && !transaction_active_q && !packet_pending_q)
            begin request_pending_q<=1; deadline_q<=0; end
        end
        if (request_pending_q) begin
          if (host_req_ready_i && host_req_valid_o) begin
            request_pending_q<=0; transaction_active_q<=1; deadline_q<=0;
          end else if (deadline_expired) begin
            request_pending_q<=0; deadline_q<=0;
          end else deadline_q<=deadline_q+1'b1;
        end
        if (host_rsp_valid_i) begin
          transaction_active_q<=0;
          if (response_success && transaction_active_q && {2'b0,host_rsp_len_i}<=max_packet_size_i && enable_i && !flush_i) begin
            if (!packet_pending_q || packet_ready_i) begin
              packet_q<=host_rsp_packet_i; packet_len_q<=host_rsp_len_i;
              packet_pending_q<=1;
            end
          end
        end
      end
    end
  end
endmodule
