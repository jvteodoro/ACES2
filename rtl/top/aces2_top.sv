`timescale 1ns/1ps

// ACES2 real board top-level.
//
// The USB/audio producer is not implemented yet. Until it is integrated,
// SW9 enables a deterministic counter stream so the FPGA-to-ESP32 SPI wiring
// can be validated on hardware without changing this top-level.
module aces2_top (
    input  wire        clk_50,
    input  wire        clk_50_2,
    input  wire        adc_clk_10,
    input  wire [1:0]  key_n,
    input  wire [9:0]  sw,
    output wire [9:0]  ledr,
    output wire [47:0] hex_n,
    inout  wire [35:0] gpio,
    inout  wire [15:0] arduino_io,
    output wire        arduino_reset_n,
    output wire [3:0]  vga_r,
    output wire [3:0]  vga_g,
    output wire [3:0]  vga_b,
    output wire        vga_hs,
    output wire        vga_vs,
    output wire [12:0] dram_addr,
    inout  wire [15:0] dram_dq,
    output wire [1:0]  dram_ba,
    output wire        dram_ldqm,
    output wire        dram_udqm,
    output wire        dram_ras_n,
    output wire        dram_cas_n,
    output wire        dram_cke,
    output wire        dram_clk,
    output wire        dram_we_n,
    output wire        dram_cs_n,
    inout  wire        gsensor_sdi,
    output wire        gsensor_sdo,
    output wire        gsensor_cs_n,
    output wire        gsensor_sclk,
    input  wire        gsensor_int1,
    input  wire        gsensor_int2
);

    localparam int DATA_WIDTH = 32;

    logic [DATA_WIDTH-1:0] spi_tx_data;
    logic                  spi_tx_valid;
    logic                  spi_tx_ready;
    logic                  spi_tx_stall;
    logic [DATA_WIDTH-1:0] spi_rx_data;
    logic                  spi_rx_valid;
    logic                  spi_miso;
    logic                  spi_mosi;
    logic                  spi_sck;
    logic                  spi_cs_n;
    logic                  spi_busy;
    logic                  spi_done;

    logic [DATA_WIDTH-1:0] audio_stub_sample;

    // Temporary source for board-level SPI bring-up. Replace this block with
    // the USB audio stream once its ready/valid interface is available.
    assign spi_tx_valid = sw[9];
    assign spi_tx_data  = audio_stub_sample;

    always_ff @(posedge clk_50) begin
        if (!key_n[0])
            audio_stub_sample <= '0;
        else if (spi_tx_valid && spi_tx_ready)
            audio_stub_sample <= audio_stub_sample + 1'b1;
    end

    // GPIO mapping: GPIO0=SCK, GPIO1=MISO, GPIO2=MOSI, GPIO3=CS_n.
    assign gpio[0]    = spi_sck;
    assign gpio[1]    = 1'bz;
    assign gpio[2]    = spi_mosi;
    assign gpio[3]    = spi_cs_n;
    assign gpio[35:4] = 32'hZZZZZZZZ;
    assign spi_miso   = gpio[1];

    spi #(
        .DATA_WIDTH        (DATA_WIDTH),
        .NUM_CS            (1),
        .SPI_FIFO_DEPTH    (16),
        .SPI_CLK_DIV_WIDTH (8),
        .SPI_CLK_DIV       (1),
        .CPOL              (1'b0),
        .CPHA              (1'b0)
    ) u_spi (
        .clk_i       (clk_50),
        .rst_ni      (key_n[0]),
        .tx_data_i   (spi_tx_data),
        .tx_valid_i  (spi_tx_valid),
        .tx_ready_o  (spi_tx_ready),
        .tx_stall_o  (spi_tx_stall),
        .rx_data_o   (spi_rx_data),
        .rx_valid_o  (spi_rx_valid),
        .rx_ready_i  (1'b1),
        .miso_i      (spi_miso),
        .mosi_o      (spi_mosi),
        .sck_o       (spi_sck),
        .cs_n_o      (spi_cs_n),
        .busy_o      (spi_busy),
        .xfer_done_o (spi_done)
    );

    // LEDs: SW[1:0], TX ready, busy, CS active, TX stall, RX valid, SW[9:7].
    assign ledr = {sw[9:7], spi_rx_valid, spi_tx_stall, !spi_cs_n,
                   spi_busy, spi_tx_ready, sw[1:0]};
    assign hex_n = 48'hFFFFFFFFFFFF;

    // Safe inactive defaults for board peripherals not used by this top yet.
    assign arduino_reset_n = 1'b1;
    assign arduino_io      = 16'hZZZZ;
    assign vga_r           = 4'b0;
    assign vga_g           = 4'b0;
    assign vga_b           = 4'b0;
    assign vga_hs          = 1'b1;
    assign vga_vs          = 1'b1;
    assign dram_addr       = 13'b0;
    assign dram_ba         = 2'b0;
    assign dram_ldqm       = 1'b1;
    assign dram_udqm       = 1'b1;
    assign dram_ras_n      = 1'b1;
    assign dram_cas_n      = 1'b1;
    assign dram_cke        = 1'b0;
    assign dram_clk        = 1'b0;
    assign dram_we_n       = 1'b1;
    assign dram_cs_n       = 1'b1;
    assign dram_dq         = 16'hZZZZ;
    assign gsensor_sdi     = 1'bZ;
    assign gsensor_sdo     = 1'b0;
    assign gsensor_cs_n    = 1'b1;
    assign gsensor_sclk    = 1'b0;

endmodule
