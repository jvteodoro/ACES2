// Reset conditioner for the DE10-Lite board-level design.
// KEY0 asserts asynchronously; deassertion passes through twelve 50 MHz
// registers so MAX3421E RES# stays low for at least 220 ns after release.
module de10_lite_reset_release (
  input  logic clk_i,
  input  logic key0_n_i,
  output logic rst_ni_o
);
  logic [11:0] reset_release_q;

  always_ff @(posedge clk_i or negedge key0_n_i) begin
    if (!key0_n_i) reset_release_q <= '0;
    else           reset_release_q <= {reset_release_q[10:0], 1'b1};
  end

  assign rst_ni_o = reset_release_q[11];
endmodule
