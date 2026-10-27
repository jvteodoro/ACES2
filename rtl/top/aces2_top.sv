// DE10-Lite board-level I/O wrapper.
// Unused digital outputs are held inactive; bidirectional expansion buses are tri-stated.
module aces2_top (
    input  wire        clk_50,
    input  wire        clk_50_2,
    input  wire        adc_clk_10,

    input  wire [1:0]  key_n,
    input  wire [9:0]  sw,
    output wire [9:0]  ledr,
    // Active-low segments; each byte maps to one display: [7:0]=HEX0 ... [47:40]=HEX5.
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

    // Safe inactive defaults for board peripherals not yet used by the design.
    assign ledr            = 10'b0;
    assign hex_n           = 48'hFFFFFFFFFFFF;
    assign arduino_reset_n = 1'b1;

    assign vga_r  = 4'b0;
    assign vga_g  = 4'b0;
    assign vga_b  = 4'b0;
    assign vga_hs = 1'b1;
    assign vga_vs = 1'b1;

    assign dram_addr = 13'b0;
    assign dram_ba   = 2'b0;
    assign dram_ldqm = 1'b1;
    assign dram_udqm = 1'b1;
    assign dram_ras_n = 1'b1;
    assign dram_cas_n = 1'b1;
    assign dram_cke   = 1'b0;
    assign dram_clk   = 1'b0;
    assign dram_we_n  = 1'b1;
    assign dram_cs_n  = 1'b1;
    assign dram_dq    = 16'hZZZZ;

    assign gsensor_sdi  = 1'bZ;
    assign gsensor_sdo  = 1'b0;
    assign gsensor_cs_n = 1'b1;
    assign gsensor_sclk = 1'b0;

    assign gpio       = 36'hZZZZZZZZZ;
    assign arduino_io = 16'hZZZZ;

    // The six Arduino analog inputs are routed to the MAX 10 ADC analog channels.
    // They are not ordinary digital top-level ports; access them through the
    // MAX 10 ADC IP when analog acquisition is needed.
    // USB-Blaster JTAG/configuration signals are dedicated device pins, not user I/O.

    spi_master spi_master
    #(
        .DATA_WIDTH(8),
        .NUM_CS(1),
        .FIFO_DEPTH(),
        .DIV_WIDTH(),
        .CS_DLY_W(),
    )(
        .clk_i(),
        .rst_ni(), // Active Low Reset
        .cpol_i(),
        .cpha_i(),
        .lsb_first_i(),
        .clk_div_i(),
        .cs_sel_i(),
        .cs_setup_cycles_i(),
        .cs_hold_cycles_i(),
        .cs_inter_byte_i(),
        // TX
        .tx_we_i(), // Push Word into TX FIFO
        .tx_wdata_i(),
        .tx_full_o(),
        .tx_empty_o(),
        .tx_count_o(),

        // RX
        .rx_re_i(),
        .rx_rdata_o(),
        .rx_full_o(),
        .rx_empty_o(),
        .rx_count_o(),

        .start_i(),
        .busy_o(),
        .xfer_done_o(),

        .sck_o(),
        .mosi_o(),
        .miso_i(),
        .cs_n_o()
    );

endmodule

