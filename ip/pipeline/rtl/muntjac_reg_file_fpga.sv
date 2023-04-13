// Register file.
module muntjac_reg_file # (
    parameter int unsigned DataWidth = 64
) (
    // Clock and reset
    input  logic                 clk_i,
    input  logic                 rst_ni,

    // Read port A
    input  logic [4:0]           raddr_a_i,
    output logic [DataWidth-1:0] rdata_a_o,

    // Read port B
    input  logic [4:0]           raddr_b_i,
    output logic [DataWidth-1:0] rdata_b_o,

    // Write port
    input  logic [4:0]           waddr_a_i,
    input  logic [DataWidth-1:0] wdata_a_i,
    input  logic                 we_a_i
);

  bit [DataWidth-1:0] registers [1:31];


  // Read ports
  assign rdata_a_o = raddr_a_i == 0 ? 0 : registers[raddr_a_i];
  assign rdata_b_o = raddr_b_i == 0 ? 0 : registers[raddr_b_i];

  // Write port
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
`ifdef RVFIDII
      integer i;
      for (i = 0; i < 32; i = i + 1) begin
        registers[i] <= 0;
      end
`endif
    end else if (we_a_i)
      registers[waddr_a_i] <= wdata_a_i;
  end

endmodule
