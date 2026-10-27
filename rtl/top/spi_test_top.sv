`timescale 1ns/1ps

// DE10-Lite SPI electrical bring-up top-level.
//
// SW[1:0] selects a test word. KEY1 (active low) sends one word; SW9 enables
// continuous transmission. KEY0 is the active-low synchronous SPI reset.
module spi_test_top (
    input  wire       clk_50,
    input  wire [1:0] key_n,
    input  wire [9:0] sw,
    output wire [9:0] ledr,
    inout  wire [3:0] gpio
);

    logic [31:0] test_word;
    logic [31:0] tx_data;
    logic        tx_valid;
    logic        tx_ready;
    logic        tx_stall;
    logic        rx_valid;
    logic        spi_miso;
    logic        spi_mosi;
    logic        spi_sck;
    logic        spi_cs_n;
    logic        spi_busy;
    logic        spi_done;
    logic        key1_d;
    logic        pending_word;
    logic [31:0] accepted_count;

    always_comb begin
        case (sw[1:0])
            2'b00: test_word = 32'h0000_0000;
            2'b01: test_word = 32'h1234_5678;
            2'b10: test_word = 32'hA5A5_5A5A;
            default: test_word = 32'hDEAD_BEEF;
        endcase
        // SW[8:2] optionally replaces the upper seven bits, allowing the
        // remaining switches to identify a test frame on the oscilloscope.
        if (sw[8:2] != 7'b0)
            test_word[31:25] = sw[8:2];
    end

    // KEY1 falling edge creates a one-word request. SW9 overrides it with a
    // continuous stream, useful for observing a stable SPI waveform.
    always_ff @(posedge clk_50) begin
        if (!key_n[0]) begin
            key1_d        <= 1'b1;
            pending_word  <= 1'b0;
            accepted_count <= '0;
        end else begin
            key1_d <= key_n[1];
            if (key1_d && !key_n[1])
                pending_word <= 1'b1;
            else if (!sw[9] && tx_valid && tx_ready)
                pending_word <= 1'b0;
            if (tx_valid && tx_ready)
                accepted_count <= accepted_count + 1'b1;
        end
    end

    assign tx_data  = test_word;
    assign tx_valid = sw[9] || pending_word;

    // Same physical mapping used by the real top-level.
    assign gpio[0]    = spi_sck;
    assign gpio[1]    = 1'bz;
    assign gpio[2]    = spi_mosi;
    assign gpio[3]    = spi_cs_n;
    assign spi_miso   = gpio[1];

    spi #(
        .DATA_WIDTH        (32),
        .NUM_CS            (1),
        .SPI_FIFO_DEPTH    (16),
        .SPI_CLK_DIV_WIDTH (8),
        .SPI_CLK_DIV       (1),
        .CPOL              (1'b0),
        .CPHA              (1'b0)
    ) u_spi (
        .clk_i       (clk_50),
        .rst_ni      (key_n[0]),
        .tx_data_i   (tx_data),
        .tx_valid_i  (tx_valid),
        .tx_ready_o  (tx_ready),
        .tx_stall_o  (tx_stall),
        .rx_data_o   (),
        .rx_valid_o  (rx_valid),
        .rx_ready_i  (1'b1),
        .miso_i      (spi_miso),
        .mosi_o      (spi_mosi),
        .sck_o       (spi_sck),
        .cs_n_o      (spi_cs_n),
        .busy_o      (spi_busy),
        .xfer_done_o (spi_done)
    );

    // LEDs: selected word, ready, busy, CS, stall, RX valid, continuous mode.
    assign ledr = {sw[9], rx_valid, tx_stall, !spi_cs_n, spi_busy,
                   tx_ready, sw[1:0], accepted_count[0], spi_done};

endmodule
