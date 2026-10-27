module spi_uc
  #(parameter NUM_CS=2)
(
                    output start_o,
                    output tx_we_o,
                    output rx_re_i,
                    output [$clog2(NUM_cs)-1:0]cs_sel_o
);

   localparam SEND;
   
endmodule
