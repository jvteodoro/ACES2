// Converts one MAX3421E register/FIFO request into a single SPI burst. The
// request/response interface is ready/valid; byte zero occupies [7:0], and
// CS remains asserted for the command plus all data bytes. This module owns
// no USB protocol state; it only moves register bytes over SPI.
module max3421e_spi_bridge (
  input logic clk_i, rst_ni,
  input logic req_valid_i, output logic req_ready_o,
  input logic req_write_i, input logic [4:0] req_addr_i,
  input logic [6:0] req_len_i, input logic [511:0] req_wdata_i,
  output logic rsp_valid_o, input logic rsp_ready_i,
  output logic [511:0] rsp_rdata_o, output logic rsp_error_o,
  output logic busy_o,
  output logic sck_o, mosi_o, input logic miso_i, output logic cs_n_o
);
  typedef enum logic [2:0] {IDLE, FILL, LAUNCH, XFER, DRAIN, RESP, BAD} state_t;
  state_t state_q;
  logic [6:0] len_q, fill_idx_q, drain_idx_q;
  logic write_q;
  logic [4:0] addr_q;
  logic [511:0] wdata_q, rdata_q;
  logic tx_we, tx_full, tx_empty, start, xdone, core_busy;
  logic rx_re, rx_empty;
  logic [7:0] rx_data;
  logic [$clog2(129)-1:0] tx_count, rx_count;
  logic cs_n_q;

  assign req_ready_o = (state_q == IDLE);
  assign busy_o = (state_q != IDLE && state_q != RESP && state_q != BAD);
  assign rsp_valid_o = (state_q == RESP || state_q == BAD);
  assign rsp_rdata_o = rdata_q;
  assign rsp_error_o = (state_q == BAD);
  assign tx_we = (state_q == FILL) && !tx_full;
  // Command byte is {register[7:3], reserved=0, DIR, ACKSTAT=0}.
  // The request's write flag is placed directly in the MAX3421E DIR bit.
  logic [7:0] tx_data;
  always_comb begin
    if (fill_idx_q == 0) tx_data = {addr_q, 1'b0, write_q, 1'b0};
    else tx_data = write_q ? wdata_q[(fill_idx_q-1)*8 +: 8] : 8'h00;
  end
  assign start = (state_q == LAUNCH);
  assign rx_re = (state_q == DRAIN) && !rx_empty && (drain_idx_q <= len_q);

  spi_master #(.DATA_WIDTH(8), .NUM_CS(2), .FIFO_DEPTH(128), .DIV_WIDTH(8), .CS_DLY_W(1), .CS_GAP_CYCLES(0), .WORDS_PER_FRAME(1), .RX_SAMPLE_TRAILING_EDGE(1'b1)) u_spi (
    .clk_i, .rst_ni, .cpol_i(1'b0), .cpha_i(1'b0), .lsb_first_i(1'b0),
    // Hold SS for two input-clock periods after the terminal SCK edge
    // (40 ns at 50 MHz), satisfying MAX3421E tT >= 30 ns.
    .clk_div_i(8'd0), .cs_sel_i(1'b0), .cs_setup_cycles_i(1'b0), .cs_hold_cycles_i(1'b1), .cs_inter_byte_i(1'b1),
    .tx_we_i(tx_we), .tx_wdata_i(tx_data), .tx_full_o(tx_full), .tx_empty_o(tx_empty), .tx_count_o(tx_count),
    .rx_re_i(rx_re), .rx_rdata_o(rx_data), .rx_full_o(), .rx_empty_o(rx_empty), .rx_count_o(rx_count),
    .start_i(start), .busy_o(core_busy), .xfer_done_o(xdone), .sck_o, .mosi_o, .miso_i, .cs_n_o(core_cs)
  );
  logic [1:0] core_cs;
  // Register the external select at the bridge boundary. This keeps the
  // SPI engine's decoded state off the CS pad path; it also adds one full
  // input-clock period of lead/hold around the SCK burst.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) cs_n_q <= 1'b1;
    else         cs_n_q <= core_cs[0];
  end
  assign cs_n_o = cs_n_q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= IDLE; len_q <= 0; fill_idx_q <= 0; drain_idx_q <= 0;
      write_q <= 0; addr_q <= 0; wdata_q <= 0; rdata_q <= 0;
    end else begin
      case (state_q)
        IDLE: if (req_valid_i) begin
          if (req_len_i == 0 || req_len_i > 64) state_q <= BAD;
          else begin
            len_q <= req_len_i; write_q <= req_write_i; addr_q <= req_addr_i;
            wdata_q <= req_wdata_i; fill_idx_q <= 0; rdata_q <= 0; state_q <= FILL;
          end
        end
        FILL: if (!tx_full) begin
          if (fill_idx_q == len_q) state_q <= LAUNCH;
          else fill_idx_q <= fill_idx_q + 1'b1;
        end
        LAUNCH: state_q <= XFER;
        XFER: if (xdone) begin drain_idx_q <= 0; state_q <= DRAIN; end
        DRAIN: begin
          // FIFO read data is registered: consume the result of the prior
          // cycle's read while issuing the next read.
          if (drain_idx_q >= 2) rdata_q[(drain_idx_q-2)*8 +: 8] <= rx_data;
          if (rx_re) drain_idx_q <= drain_idx_q + 1'b1;
          else if (drain_idx_q == len_q + 7'd1) state_q <= RESP;
        end
        RESP, BAD: if (rsp_ready_i) state_q <= IDLE;
        default: state_q <= IDLE;
      endcase
    end
  end
endmodule
