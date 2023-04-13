import "DPI-C" function byte get_dii_pad(int idx);
import "DPI-C" function byte get_dii_cmd(int idx);
import "DPI-C" function shortint get_dii_time(int idx);
import "DPI-C" function int get_dii_insn(int idx);
import "DPI-C" function void rvfi_dii_bridge_rst(int log_buff_size);
import "DPI-C" function void put_rvfi_pkt(
  int   idx,
  longint rvfi_order,
  longint rvfi_pc_rdata,
  longint rvfi_pc_wdata,
  longint rvfi_insn,
  longint rvfi_rs1_data,
  longint rvfi_rs2_data,
  longint rvfi_rd_wdata,
  longint rvfi_mem_addr,
  longint rvfi_mem_rdata,
  longint rvfi_mem_wdata,
  byte  rvfi_mem_rmask,
  byte  rvfi_mem_wmask,
  byte  rvfi_rs1_addr,
  byte  rvfi_rs2_addr,
  byte  rvfi_rd_addr,
  byte  rvfi_trap,
  byte  rvfi_halt,
  byte  rvfi_intr
);

module muntjac_rvfi_dii import muntjac_pkg::*; #(
) (
    input  logic           clk_i,
    input  logic           rst_ni,

    output logic           fetch_valid_o,
    input  logic           fetch_ready_i,
    output fetched_instr_t fetch_instr_o,

    output logic           rst_no,

    input instr_trace_t    trace_i
);

  logic [3:0] dii_seq;
  logic [3:0] rvfi_seq;
  logic [3:0] next_dii_seq;
  logic [3:0] next_rvfi_seq;
  logic [63:0] fake_pc;
  if_reason_e fake_if_reason;

  logic await_finish;

  assign next_dii_seq = dii_seq + 1;
  assign next_rvfi_seq = rvfi_seq + 1;

  assign fetch_instr_o.pc = fake_pc;
  assign fetch_instr_o.if_reason = fake_if_reason;
  assign fetch_instr_o.ex_valid = 0;
  assign fetch_instr_o.exception = 0;
  assign fetch_instr_o.instr_word = get_dii_insn(dii_seq);
  assign fetch_valid_o = get_dii_cmd(dii_seq) == 1 && rst_no;

  initial rvfi_dii_bridge_rst(4);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      dii_seq <= ~0;
      rvfi_seq <= ~0;
      await_finish <= 1;
      rst_no <= 1;
    end else begin
      if (fetch_valid_o && fetch_ready_i) begin
        $display("xact on id: ", dii_seq);
        dii_seq <= next_dii_seq;
        fake_pc <= fake_pc + (fetch_instr_o.instr_word[1:0] == 2'b11 ? 4 : 2);
        fake_if_reason <= 4'b0000;
      end
      if (trace_i.valid) begin
        rvfi_seq <= next_rvfi_seq;
        put_rvfi_pkt(.idx(rvfi_seq), .rvfi_intr(0), .rvfi_halt(0), .rvfi_trap(0), .rvfi_rd_addr(trace_i.gpr), .rvfi_rs2_addr(0), .rvfi_rs1_addr(0), .rvfi_mem_wmask(0), .rvfi_mem_rmask(0), .rvfi_mem_wdata(0), .rvfi_mem_rdata(0), .rvfi_mem_addr(0), .rvfi_rd_wdata(trace_i.gpr_data), .rvfi_rs2_data(0), .rvfi_rs1_data(0), .rvfi_insn(trace_i.instr_word), .rvfi_pc_wdata(0), .rvfi_pc_rdata(trace_i.pc), .rvfi_order(0) );
      end else if (!await_finish && get_dii_cmd(dii_seq) == 0) begin
        put_rvfi_pkt(.idx(dii_seq), .rvfi_intr(0), .rvfi_halt(1), .rvfi_trap(0), .rvfi_rd_addr(0), .rvfi_rs2_addr(0), .rvfi_rs1_addr(0), .rvfi_mem_wmask(0), .rvfi_mem_rmask(0), .rvfi_mem_wdata(0), .rvfi_mem_rdata(0), .rvfi_mem_addr(0), .rvfi_rd_wdata(0), .rvfi_rs2_data(0), .rvfi_rs1_data(0), .rvfi_insn(0), .rvfi_pc_wdata(0), .rvfi_pc_rdata(0), .rvfi_order(0) );
        await_finish <= 1;
      end
      if (await_finish && rvfi_seq == dii_seq) begin
        await_finish <= 0;
        dii_seq <= next_dii_seq;
        rvfi_seq <= next_rvfi_seq;
        rst_no <= 0;
        fake_if_reason <= 4'b1011;
        fake_pc <= 'h8000_0000;
      end else begin
        rst_no <= 1;
      end
    end
  end
endmodule
