`timescale 1ns/1ps

// Control unit for the project SPI streaming adapter.
//
// The input stream uses ready/valid semantics. A word is accepted only when
// tx_valid_i and tx_ready_o are both high, so the audio source cannot lose a
// sample silently when the SPI TX FIFO is full.
module spi_uc #(
  parameter int unsigned DATA_WIDTH       = 32,
  parameter int unsigned NUM_CS           = 1,
  parameter int unsigned FIFO_DEPTH       = 16,
  parameter int unsigned DIV_WIDTH        = 8,
  parameter int unsigned CS_DLY_W         = 1,
  parameter int unsigned SPI_CLK_DIV      = 1,
  parameter bit          LSB_FIRST        = 1'b0,
  parameter bit          CPOL             = 1'b0,
  parameter bit          CPHA             = 1'b0,
  parameter int unsigned CS_SEL           = 0,
  parameter int unsigned CS_SETUP_CYCLES  = 0,
  parameter int unsigned CS_HOLD_CYCLES   = 0
) (
  input  logic                         rst_ni,
  input  logic [DATA_WIDTH-1:0]         tx_data_i,
  input  logic                         tx_valid_i,
  output logic                         tx_ready_o,
  input  logic                         tx_full_i,
  input  logic                         tx_empty_i,
  input  logic                         busy_i,
  input  logic                         rx_empty_i,
  input  logic                         rx_ready_i,
  output logic                         rx_re_o,
  output logic                         start_o,
  output logic                         tx_we_o,
  output logic [DATA_WIDTH-1:0]         tx_wdata_o,
  output logic                         cpol_o,
  output logic                         cpha_o,
  output logic                         lsb_first_o,
  output logic [((NUM_CS <= 1) ? 1 : $clog2(NUM_CS))-1:0] cs_sel_o,
  output logic [DIV_WIDTH-1:0]          clk_div_o,
  output logic [CS_DLY_W-1:0]           cs_setup_cycles_o,
  output logic [CS_DLY_W-1:0]           cs_hold_cycles_o,
  output logic                         cs_inter_byte_o
);

  localparam int unsigned CS_SEL_WIDTH = (NUM_CS <= 1) ? 1 : $clog2(NUM_CS);

  always_comb begin
    tx_ready_o = rst_ni && !tx_full_i;
    tx_we_o    = tx_valid_i && tx_ready_o;
    tx_wdata_o = tx_data_i;
    // Start only after at least one word has reached the TX FIFO. The FIFO
    // remains refillable while the master is busy.
    start_o = rst_ni && !busy_i && !tx_empty_i;
    rx_re_o = rst_ni && rx_ready_i && !rx_empty_i;

    cpol_o            = CPOL;
    cpha_o            = CPHA;
    lsb_first_o       = LSB_FIRST;
    cs_sel_o          = CS_SEL[CS_SEL_WIDTH-1:0];
    clk_div_o         = SPI_CLK_DIV[DIV_WIDTH-1:0];
    cs_setup_cycles_o = CS_SETUP_CYCLES[CS_DLY_W-1:0];
    cs_hold_cycles_o  = CS_HOLD_CYCLES[CS_DLY_W-1:0];
    // Keep CS asserted while queued words are available for continuous audio
    // streaming to the ESP32.
    cs_inter_byte_o   = 1'b1;
  end

endmodule
