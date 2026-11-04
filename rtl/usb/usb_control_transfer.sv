// Implements USB endpoint-zero transfers above usb_host_engine: SETUP, optional
// DATA packets, then STATUS. Streams received descriptor bytes to the
// enumerator, retries NAK, applies timeout/cancel handling, and reports one
// completion/error result for the whole control request.
module usb_control_transfer #(
  parameter int unsigned CTRL_TIMEOUT_CYCLES = 250_000_000,
  parameter int unsigned NAK_RETRY_LIMIT = 8,
  parameter int unsigned CANCEL_GRACE_CYCLES = 1024
) (
  input logic clk_i, rst_ni,
  input logic ctrl_req_valid_i, output logic ctrl_req_ready_o,
  input logic [63:0] ctrl_setup_i,
  input logic [15:0] ctrl_in_length_i,
  input logic [6:0] ctrl_address_i, ctrl_ep0_size_i,
  input logic ctrl_cancel_i,
  output logic [7:0] ctrl_data_o, output logic ctrl_data_valid_o,
  input logic ctrl_data_ready_i,
  output logic ctrl_done_o, ctrl_error_o,
  output logic [3:0] ctrl_error_code_o,

  output logic host_req_valid_o, input logic host_req_ready_i,
  output logic [7:0] host_req_token_o, output logic [6:0] host_req_addr_o,
  output logic [511:0] host_req_wdata_o, output logic [6:0] host_req_out_len_o,
  output logic host_req_toggle_valid_o, host_req_rcv_toggle_o, host_req_snd_toggle_o,
  output logic host_cancel_o,
  input logic host_rsp_valid_i, output logic host_rsp_ready_o,
  input logic [2047:0] host_rsp_packet_i, input logic [8:0] host_rsp_len_i,
  input logic [3:0] host_rsp_error_i,
  input logic host_rsp_rcv_toggle_i, host_rsp_snd_toggle_i
);
  localparam logic [7:0] TOKEN_SETUP=8'h10, TOKEN_IN=8'h00,
                         TOKEN_HS_IN=8'h80, TOKEN_HS_OUT=8'ha0;
  localparam logic [3:0] ERR_UNSUPPORTED=4'h1, ERR_BAD_REQUEST=4'h2,
                         ERR_HOST=4'h3, ERR_TIMEOUT=4'h4, ERR_CANCEL=4'h5,
                         ERR_PACKET=4'h6, ERR_NAK=4'h7;

  typedef enum logic [3:0] {S_IDLE,S_SETUP_REQ,S_SETUP_WAIT,S_DATA_REQ,
    S_DATA_WAIT,S_STREAM,S_STATUS_REQ,S_STATUS_WAIT,S_CANCEL_WAIT,S_QUARANTINE} state_t;
  state_t state_q;
  logic [63:0] setup_q;
  logic [15:0] length_q, delivered_q;
  logic [6:0] addr_q, ep0_q;
  logic data_in_q, first_in_q, short_packet_q;
  logic [2047:0] packet_q;
  logic [8:0] packet_len_q, packet_idx_q;
  logic [3:0] error_code_q;
  logic [31:0] timer_q;
  logic [31:0] retry_q;
  logic [31:0] cancel_timer_q;
  logic timeout_pending_q, cancel_pending_q;
  logic in_flight_q;

  wire req_hs = host_req_valid_o && host_req_ready_i;
  wire rsp_hs = host_rsp_valid_i && host_rsp_ready_o;
  wire data_hs = ctrl_data_valid_o && ctrl_data_ready_i;
  wire [15:0] setup_wlength = setup_q[63:48];
  wire [7:0] setup_bm = setup_q[7:0];
  wire [7:0] setup_brequest = setup_q[15:8];

  assign ctrl_req_ready_o = state_q == S_IDLE && !ctrl_cancel_i;
  assign ctrl_data_valid_o = state_q == S_STREAM && !timeout_pending_q && !ctrl_cancel_i;
  assign ctrl_data_o = packet_q[packet_idx_q*8 +: 8];
  assign host_req_valid_o = (state_q==S_SETUP_REQ || state_q==S_DATA_REQ || state_q==S_STATUS_REQ) &&
                            !ctrl_cancel_i && !timeout_pending_q;
  assign host_req_token_o = state_q==S_SETUP_REQ ? TOKEN_SETUP :
                            state_q==S_DATA_REQ ? TOKEN_IN :
                            (data_in_q ? TOKEN_HS_OUT : TOKEN_HS_IN);
  assign host_req_addr_o = addr_q;
  assign host_req_wdata_o = state_q==S_SETUP_REQ ? {{448{1'b0}},setup_q} : '0;
  assign host_req_out_len_o = state_q==S_SETUP_REQ ? 7'd8 : 7'd0;
  // SETUP fixes DATA0 and resets the control pipe. Force DATA1 on the first
  // data packet, then leave the MAX3421E toggle state running consecutively.
  assign host_req_toggle_valid_o = state_q==S_DATA_REQ && first_in_q;
  assign host_req_rcv_toggle_o = 1'b1;
  assign host_req_snd_toggle_o = 1'b1;
  assign host_cancel_o = in_flight_q && (ctrl_cancel_i || timeout_pending_q || cancel_pending_q);
  assign host_rsp_ready_o = state_q==S_SETUP_WAIT || state_q==S_DATA_WAIT ||
                            state_q==S_STATUS_WAIT || state_q==S_CANCEL_WAIT || state_q==S_QUARANTINE;

  function automatic logic legal_ep0(input logic [6:0] n);
    legal_ep0 = n==8 || n==16 || n==32 || n==64;
  endfunction

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q<=S_IDLE; setup_q<=0; length_q<=0; delivered_q<=0; addr_q<=0;
      ep0_q<=8; data_in_q<=0; first_in_q<=0; short_packet_q<=0;
      packet_q<=0; packet_len_q<=0; packet_idx_q<=0; error_code_q<=0;
      timer_q<=0; retry_q<=0; timeout_pending_q<=0; cancel_pending_q<=0;
      cancel_timer_q<=0;
      in_flight_q<=0; ctrl_done_o<=0; ctrl_error_o<=0; ctrl_error_code_o<=0;
    end else begin
      ctrl_done_o<=0;
      ctrl_error_o<=0;
      if (state_q==S_IDLE) begin
        timer_q<=0; timeout_pending_q<=0; cancel_pending_q<=0; in_flight_q<=0;
        if (ctrl_req_valid_i && ctrl_req_ready_o) begin
          setup_q<=ctrl_setup_i; length_q<=ctrl_in_length_i; addr_q<=ctrl_address_i;
          ep0_q<=ctrl_ep0_size_i; delivered_q<=0; packet_len_q<=0;
          retry_q<=0; first_in_q<=1; error_code_q<=0;
          data_in_q<=ctrl_setup_i[7];
          if (!legal_ep0(ctrl_ep0_size_i)) begin
            ctrl_error_o<=1; ctrl_error_code_o<=ERR_BAD_REQUEST;
          end else if (ctrl_in_length_i>2048 || ctrl_setup_i[63:48]!=ctrl_in_length_i) begin
            ctrl_error_o<=1; ctrl_error_code_o<=ERR_BAD_REQUEST;
          end else if (ctrl_setup_i[63:48]!=0) begin
            if (!ctrl_setup_i[7] || ctrl_setup_i[15:8]!=8'h06) begin
              ctrl_error_o<=1; ctrl_error_code_o<=ERR_UNSUPPORTED;
            end else state_q<=S_SETUP_REQ;
          end else if (ctrl_in_length_i!=0 || ctrl_setup_i[7] ||
                       !((ctrl_setup_i[15:8]==8'h05 && ctrl_setup_i[7:0]==8'h00) ||
                         (ctrl_setup_i[15:8]==8'h09 && ctrl_setup_i[7:0]==8'h00) ||
                         (ctrl_setup_i[15:8]==8'h0b && ctrl_setup_i[7:0]==8'h01))) begin
            ctrl_error_o<=1; ctrl_error_code_o<=ERR_UNSUPPORTED;
          end else state_q<=S_SETUP_REQ;
        end
      end else if (ctrl_cancel_i && !in_flight_q && state_q!=S_SETUP_REQ &&
                   state_q!=S_DATA_REQ && state_q!=S_STATUS_REQ) begin
        ctrl_error_o<=1; ctrl_error_code_o<=ERR_CANCEL; state_q<=S_IDLE;
      end else begin
        if (timer_q < CTRL_TIMEOUT_CYCLES) timer_q<=timer_q+1'b1;
        else if (!timeout_pending_q) begin
          timeout_pending_q<=1; error_code_q<=ERR_TIMEOUT;
        end
        if (ctrl_cancel_i && !cancel_pending_q) begin
          cancel_pending_q<=1; error_code_q<=ERR_CANCEL;
        end

        case (state_q)
          S_SETUP_REQ: if (ctrl_cancel_i || timeout_pending_q) begin
            ctrl_error_o<=1; ctrl_error_code_o<=ctrl_cancel_i ? ERR_CANCEL : ERR_TIMEOUT; state_q<=S_IDLE;
          end else if (req_hs) begin state_q<=S_SETUP_WAIT; in_flight_q<=1; end
          S_DATA_REQ: if (ctrl_cancel_i || timeout_pending_q) begin
            ctrl_error_o<=1; ctrl_error_code_o<=ctrl_cancel_i ? ERR_CANCEL : ERR_TIMEOUT; state_q<=S_IDLE;
          end else if (req_hs) begin state_q<=S_DATA_WAIT; in_flight_q<=1; retry_q<=retry_q; end
          S_STATUS_REQ: if (ctrl_cancel_i || timeout_pending_q) begin
            ctrl_error_o<=1; ctrl_error_code_o<=ctrl_cancel_i ? ERR_CANCEL : ERR_TIMEOUT; state_q<=S_IDLE;
          end else if (req_hs) begin state_q<=S_STATUS_WAIT; in_flight_q<=1; end
          S_SETUP_WAIT,S_DATA_WAIT,S_STATUS_WAIT,S_CANCEL_WAIT: begin
            if (timeout_pending_q || cancel_pending_q || ctrl_cancel_i) begin
              if (rsp_hs) begin
                in_flight_q<=0; state_q<=S_IDLE; ctrl_error_o<=1;
                ctrl_error_code_o<=cancel_pending_q || ctrl_cancel_i ? ERR_CANCEL : ERR_TIMEOUT;
                timeout_pending_q<=0; cancel_pending_q<=0; cancel_timer_q<=0;
              end else begin
                if (state_q!=S_CANCEL_WAIT) begin
                  cancel_timer_q<=0;
                  state_q<=S_CANCEL_WAIT;
                end else if (cancel_timer_q+1'b1>=CANCEL_GRACE_CYCLES) begin
                  ctrl_error_o<=1;
                  ctrl_error_code_o<=cancel_pending_q || ctrl_cancel_i ? ERR_CANCEL : ERR_TIMEOUT;
                  state_q<=S_QUARANTINE;
                end else begin
                  cancel_timer_q<=cancel_timer_q+1'b1;
                  state_q<=S_CANCEL_WAIT;
                end
              end
            end else if (rsp_hs) begin
              in_flight_q<=0;
              if (host_rsp_error_i==4'h4) begin
                if (retry_q < NAK_RETRY_LIMIT) begin
                  retry_q<=retry_q+1'b1;
                  if (state_q==S_SETUP_WAIT) state_q<=S_SETUP_REQ;
                  else if (state_q==S_DATA_WAIT) state_q<=S_DATA_REQ;
                  else state_q<=S_STATUS_REQ;
                end else begin
                  ctrl_error_o<=1; ctrl_error_code_o<=ERR_NAK; state_q<=S_IDLE;
                end
              end else if (host_rsp_error_i!=0) begin
                ctrl_error_o<=1;
                ctrl_error_code_o<=host_rsp_error_i==5 ? ERR_HOST : ERR_HOST;
                state_q<=S_IDLE;
              end else begin
                retry_q<=0;
                if (state_q==S_SETUP_WAIT) begin
                  if (length_q!=0) state_q<=S_DATA_REQ;
                  else state_q<=S_STATUS_REQ;
                end else if (state_q==S_DATA_WAIT) begin
                  if (host_rsp_len_i>{2'b0,ep0_q} || {7'b0,host_rsp_len_i}>length_q-delivered_q) begin
                    ctrl_error_o<=1; ctrl_error_code_o<=ERR_PACKET; state_q<=S_IDLE;
                  end else begin
                    packet_q<=host_rsp_packet_i; packet_len_q<=host_rsp_len_i;
                    packet_idx_q<=0; short_packet_q<=host_rsp_len_i<{2'b0,ep0_q};
                    first_in_q<=0;
                    if (host_rsp_len_i==0) state_q<=S_STATUS_REQ;
                    else state_q<=S_STREAM;
                  end
                end else begin
                  ctrl_done_o<=1; state_q<=S_IDLE;
                end
              end
            end
          end
          S_STREAM: if (data_hs) begin
            delivered_q<=delivered_q+1'b1;
            if (packet_idx_q+1'b1==packet_len_q) begin
              packet_idx_q<=0; packet_len_q<=0;
              if (short_packet_q || delivered_q+1'b1==length_q) state_q<=S_STATUS_REQ;
              else state_q<=S_DATA_REQ;
            end else packet_idx_q<=packet_idx_q+1'b1;
          end else if (timeout_pending_q || ctrl_cancel_i) begin
            ctrl_error_o<=1; ctrl_error_code_o<=ctrl_cancel_i ? ERR_CANCEL : ERR_TIMEOUT;
            packet_len_q<=0; state_q<=S_IDLE;
          end
          S_QUARANTINE: begin
            // Keep the host transaction drained before accepting a new request;
            // a delayed response can never be mistaken for a later transfer.
            if (rsp_hs) begin
              in_flight_q<=0; timeout_pending_q<=0; cancel_pending_q<=0;
              cancel_timer_q<=0; state_q<=S_IDLE;
            end
          end
          default: state_q<=S_IDLE;
        endcase
      end
    end
  end
endmodule
