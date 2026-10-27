`timescale 1ns/1ps

// Project SPI streaming adapter.
//
// The FPGA is the SPI master and the ESP32 is the SPI slave. Audio words are
// accepted through a ready/valid stream and buffered by spi_master's TX FIFO.
// The RX stream is exposed so the ESP32 can return status or flow-control
// words; a consumer may tie rx_ready_i high when responses are not needed.
module spi #(
  parameter int unsigned DATA_WIDTH        = 32,
  parameter int unsigned NUM_CS            = 1,
  parameter int unsigned SPI_FIFO_DEPTH    = 16,
  parameter int unsigned SPI_CLK_DIV_WIDTH = 8,
  parameter int unsigned SPI_CS_DLY_W      = 1,
  parameter int unsigned SPI_CLK_DIV       = 1,
  parameter bit          LSB_FIRST         = 1'b0,
  parameter bit          CPOL              = 1'b0,
  parameter bit          CPHA              = 1'b0,
  parameter int unsigned CS_SEL            = 0,
  parameter int unsigned CS_SETUP_CYCLES   = 0,
  parameter int unsigned CS_HOLD_CYCLES    = 0
) (
  input  logic                         clk_i,
  input  logic                         rst_ni,
  input  logic [DATA_WIDTH-1:0]         tx_data_i,
  input  logic                         tx_valid_i,
  output logic                         tx_ready_o,
  output logic                         tx_stall_o,
  output logic [DATA_WIDTH-1:0]         rx_data_o,
  output logic                         rx_valid_o,
  input  logic                         rx_ready_i,
  input  logic                         miso_i,
  output logic                         mosi_o,
  output logic                         sck_o,
  output logic [NUM_CS-1:0]             cs_n_o,
  output logic                         busy_o,
  output logic                         xfer_done_o
);

  // The upstream core expresses the CS selector as $clog2(NUM_CS) bits. For
  // a single physical ESP32 CS, instantiate its internal core with two legal
  // selector values and expose only CS[0] at this adapter boundary.
  localparam int unsigned CORE_NUM_CS    = (NUM_CS <= 1) ? 2 : NUM_CS;
  localparam int unsigned CS_SEL_WIDTH   = (CORE_NUM_CS <= 1) ? 1 : $clog2(CORE_NUM_CS);

  logic                         spi_cpol;
  logic                         spi_cpha;
  logic                         spi_lsb_first;
  logic [SPI_CLK_DIV_WIDTH-1:0] spi_clk_div;
  logic                         spi_start;
  logic                         spi_rx_re;
  logic                         spi_tx_we;
  logic [DATA_WIDTH-1:0]        spi_tx_wdata;
  logic [CS_SEL_WIDTH-1:0]      spi_cs_sel;
  logic [SPI_CS_DLY_W-1:0]      spi_cs_setup_cycles;
  logic [SPI_CS_DLY_W-1:0]      spi_cs_hold_cycles;
  logic                         spi_cs_inter_byte;
  logic                         spi_tx_full;
  logic                         spi_tx_empty;
  logic                         spi_rx_empty;

  spi_uc #(
    .DATA_WIDTH       (DATA_WIDTH),
    .NUM_CS           (CORE_NUM_CS),
    .FIFO_DEPTH       (SPI_FIFO_DEPTH),
    .DIV_WIDTH        (SPI_CLK_DIV_WIDTH),
    .CS_DLY_W         (SPI_CS_DLY_W),
    .SPI_CLK_DIV      (SPI_CLK_DIV),
    .LSB_FIRST        (LSB_FIRST),
    .CPOL             (CPOL),
    .CPHA             (CPHA),
    .CS_SEL           (CS_SEL),
    .CS_SETUP_CYCLES  (CS_SETUP_CYCLES),
    .CS_HOLD_CYCLES   (CS_HOLD_CYCLES)
  ) u_spi_uc (
    .rst_ni            (rst_ni),
    .tx_data_i         (tx_data_i),
    .tx_valid_i        (tx_valid_i),
    .tx_ready_o        (tx_ready_o),
    .tx_full_i         (spi_tx_full),
    .tx_empty_i        (spi_tx_empty),
    .busy_i            (busy_o),
    .rx_empty_i        (spi_rx_empty),
    .rx_ready_i        (rx_ready_i),
    .rx_re_o           (spi_rx_re),
    .start_o           (spi_start),
    .tx_we_o           (spi_tx_we),
    .tx_wdata_o        (spi_tx_wdata),
    .cpol_o            (spi_cpol),
    .cpha_o            (spi_cpha),
    .lsb_first_o       (spi_lsb_first),
    .cs_sel_o          (spi_cs_sel),
    .clk_div_o         (spi_clk_div),
    .cs_setup_cycles_o (spi_cs_setup_cycles),
    .cs_hold_cycles_o  (spi_cs_hold_cycles),
    .cs_inter_byte_o   (spi_cs_inter_byte)
  );

  spi_master #(
    .DATA_WIDTH (DATA_WIDTH),
    .NUM_CS     (CORE_NUM_CS),
    .FIFO_DEPTH (SPI_FIFO_DEPTH),
    .DIV_WIDTH  (SPI_CLK_DIV_WIDTH),
    .CS_DLY_W   (SPI_CS_DLY_W)
  ) u_spi_master (
    .clk_i             (clk_i),
    .rst_ni            (rst_ni),
    .cpol_i            (spi_cpol),
    .cpha_i            (spi_cpha),
    .lsb_first_i       (spi_lsb_first),
    .clk_div_i         (spi_clk_div),
    .cs_sel_i          (spi_cs_sel),
    .cs_setup_cycles_i (spi_cs_setup_cycles),
    .cs_hold_cycles_i  (spi_cs_hold_cycles),
    .cs_inter_byte_i   (spi_cs_inter_byte),
    .tx_we_i           (spi_tx_we),
    .tx_wdata_i        (spi_tx_wdata),
    .tx_full_o         (spi_tx_full),
    .tx_empty_o        (spi_tx_empty),
    .tx_count_o        (),
    .rx_re_i           (spi_rx_re),
    .rx_rdata_o        (rx_data_o),
    .rx_full_o         (),
    .rx_empty_o        (spi_rx_empty),
    .rx_count_o        (),
    .start_i           (spi_start),
    .busy_o            (busy_o),
    .xfer_done_o       (xfer_done_o),
    .sck_o             (sck_o),
    .mosi_o            (mosi_o),
    .miso_i            (miso_i),
    .cs_n_o            (core_cs_n)
  );

  logic [CORE_NUM_CS-1:0] core_cs_n;
  assign rx_valid_o = !spi_rx_empty;
  // A producer should hold valid/data until ready. This identifies cycles in
  // which the source is back-pressured by a full FIFO.
  assign tx_stall_o = rst_ni && tx_valid_i && !tx_ready_o;
  assign cs_n_o     = core_cs_n[NUM_CS-1:0];

endmodule
