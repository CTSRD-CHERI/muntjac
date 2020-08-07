import riscv::*;
import cpu_common::*;

module cpu #(
    parameter XLEN = 64
) (
    // Clock and reset
    input  logic            clk,
    input  logic            resetn,

    // Memory interfaces
    icache_intf.user icache,
    dcache_intf.user dcache,

    input  logic irq_m_timer,
    input  logic irq_m_software,
    input  logic irq_m_external,
    input  logic irq_s_external,

    input  logic [XLEN-1:0] mhartid,

    // Debug connections
    output logic [XLEN-1:0]    dbg_pc
);

    localparam BRANCH_PRED = 1;

    // CSR
    logic data_prv;
    logic [XLEN-1:0] data_atp;
    logic [XLEN-1:0] insn_atp;
    prv_t prv;
    status_t status;

    // WB-IF interfacing, valid only when a PC override is required.
    logic wb_if_valid;
    if_reason_t wb_if_reason;
    logic [XLEN-1:0] wb_if_pc;

    // IF-DE interfacing
    logic if_de_valid;
    logic if_de_ready;
    fetched_instr_t if_de_instr;

    // DE-EX interfacing
    logic de_ex_valid;
    logic de_ex_ready;
    decoded_instr_t de_ex_decoded;
    logic [XLEN-1:0] de_ex_rs1;
    logic [XLEN-1:0] de_ex_rs2;
    logic de_ex_handshaked;
    assign de_ex_handshaked = de_ex_valid && de_ex_ready;

    // EX-EX2 interfacing
    logic ex_ex2_valid;
    logic ex_ex2_ready;
    decoded_instr_t ex_ex2_decoded;

    logic ex_pending;
    logic [4:0] ex_ex2_rd;
    logic ex_ex2_value_valid;

    // Main value passed from EX1 to EX2.
    logic [XLEN-1:0] ex_ex2_data;
    // Additional value passed from EX1 to EX2. E.g. store value
    logic [XLEN-1:0] ex_ex2_data2;
    logic [XLEN-1:0] ex_ex2_npc;
    wire ex_ex2_handshaked = ex_ex2_valid && ex_ex2_ready;

    // EX2-WB interfacing
    logic ex2_ready;
    logic ex2_wb_valid;
    logic [4:0] ex2_wb_rd;
    logic [XLEN-1:0] ex2_wb_data;
    logic [XLEN-1:0] ex2_wb_pc;
    logic [XLEN-1:0] ex2_wb_npc;
    exception_t ex2_wb_trap;
    logic ex2_wb_pc_override;
    if_reason_t ex2_wb_pc_override_reason;
    logic [XLEN-1:0] wb_tvec;

    //
    // IF stage
    //
    logic flush_tlb;
    instr_fetcher #(
        .XLEN(XLEN),
        .BRANCH_PRED (BRANCH_PRED)
    ) fetcher (
        .clk (clk),
        .resetn (resetn),
        .cache_uncompressed (icache),
        .i_pc (wb_if_pc),
        .i_valid (wb_if_valid),
        .i_reason (wb_if_reason),
        .i_prv (prv[0]),
        .i_sum (status.sum),
        .i_atp (insn_atp),
        .flush_cache (1'b0),
        .flush_tlb,
        .o_valid (if_de_valid),
        .o_ready (if_de_ready),
        .o_fetched_instr (if_de_instr)
    );

    //
    // DE stage
    //
    logic [4:0] de_rs1_select, de_rs2_select;
    csr_t de_csr_sel;
    logic [1:0] de_csr_op;
    logic de_csr_illegal;
    decoded_instr_t de_decoded;

    decoder decoder (
        .fetched_instr (if_de_instr),
        .decoded_instr (de_decoded),
        .prv (prv),
        .status (status),
        .csr_sel (de_csr_sel),
        .csr_op (de_csr_op),
        .csr_illegal (de_csr_illegal)
    );

    assign if_de_ready = de_ex_ready;

    always_ff @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            de_ex_valid <= 1'b0;
            de_ex_decoded <= decoded_instr_t'('x);
            de_rs1_select <= 'x;
            de_rs2_select <= 'x;
        end
        else begin
            // New inbound data
            if (if_de_valid && if_de_ready) begin
                de_ex_valid <= 1'b1;
                de_ex_decoded <= de_decoded;

                // Regfile will read register into rs1_value and rs2_value
                de_rs1_select <= de_decoded.rs1;
                de_rs2_select <= de_decoded.rs2;
            end
            // No new inbound data - deassert valid if ready is asserted.
            else if (de_ex_valid && de_ex_ready) begin
                de_ex_valid <= 1'b0;
            end
        end
    end

    //
    // EX stage
    //
    logic ex_stalled;
    logic [XLEN-1:0] ex_rs1;
    logic [XLEN-1:0] ex_rs2;

    typedef enum logic [1:0] {
        ST_NORMAL,
        ST_MISPREDICT,
        ST_EXCEPTION
    } state_e;

    state_e ex_state_q, ex_state_d;

    logic ex2_pending;

    // EX1 bypass logic
    always_comb begin
        ex_stalled = 1'b0;

        ex_rs1 = de_ex_rs1;
        // RS1 bypass from EX2
        if (ex2_pending && ex2_wb_rd == de_ex_decoded.rs1 && de_ex_decoded.rs1 != 0) begin
            if (ex2_wb_valid) begin
                ex_rs1 = ex2_wb_data;
            end
            else begin
                ex_stalled = 1'b1;
            end
        end
        // RS1 bypass from EX1
        if (ex_pending && ex_ex2_rd == de_ex_decoded.rs1 && de_ex_decoded.rs1 != 0) begin
            if (ex_ex2_value_valid) begin
                ex_rs1 = ex_ex2_data;
            end
            else begin
                ex_stalled = 1'b1;
            end
        end

        ex_rs2 = de_ex_rs2;
        // RS2 bypass from EX2
        if (ex2_pending && ex2_wb_rd == de_ex_decoded.rs2 && de_ex_decoded.rs2 != 0) begin
            if (ex2_wb_valid) begin
                ex_rs2 = ex2_wb_data;
            end
            else begin
                ex_stalled = 1'b1;
            end
        end
        // RS2 bypass from EX1
        if (ex_pending && ex_ex2_rd == de_ex_decoded.rs2 && de_ex_decoded.rs2 != 0) begin
            if (ex_ex2_value_valid) begin
                ex_rs2 = ex_ex2_data;
            end
            else begin
                ex_stalled = 1'b1;
            end
        end
    end

    assign de_ex_ready = !ex_stalled && (ex_ex2_ready || !ex_ex2_valid);

    logic ex_value_valid;
    logic [XLEN-1:0] ex_val, ex_val2, ex_npc;

    stage_ex stage_ex (
        .clk,
        .rstn (resetn),
        .i_decoded (de_ex_decoded),
        .i_rs1 (ex_rs1),
        .i_rs2 (ex_rs2),
        .o_value_valid (ex_value_valid),
        .o_val (ex_val),
        .o_val2 (ex_val2),
        .o_npc (ex_npc)
    );

    logic [XLEN-1:0] ex_expected_pc;

    // Misprediction control
    logic ex_can_issue;
    logic ex2_can_issue;
    always_comb begin
        ex_can_issue = 1'b0;
        ex2_can_issue = 1'b0;
        unique case (ex_state_q)
            ST_NORMAL: begin
                ex_can_issue = ex_expected_pc == de_ex_decoded.pc;
                // TODO: Try to remove override from this equation
                ex2_can_issue = !(ex2_wb_valid && ex2_wb_pc_override) && !ex2_wb_trap.valid;
            end
            ST_MISPREDICT: begin
                ex_can_issue = de_ex_decoded.if_reason !=? 4'bxxx0;
            end
            ST_EXCEPTION: begin
                ex_can_issue = de_ex_decoded.if_reason == 4'b1011;
            end
            default:;
        endcase
    end

    always_comb begin
        ex_state_d = ex_state_q;
        // When EX2 stage says we had a misprediction, or went through a trap, we have to
        // flush the pipeline, otherwise we can forward from speculatively executed EX stage.
        if (ex2_wb_trap.valid) begin
            ex_state_d = ST_EXCEPTION;
        end else if (ex2_wb_valid && ex2_wb_pc_override && ex2_wb_pc_override_reason !== IF_MISPREDICT) begin
            ex_state_d = ST_MISPREDICT;
        end else if (ex_state_q == ST_NORMAL && de_ex_handshaked && ex_expected_pc != de_ex_decoded.pc) begin
            ex_state_d = ST_MISPREDICT;
        end
        if (de_ex_handshaked && de_ex_decoded.if_reason !=? 4'bxxx0 && ex_can_issue) begin
            ex_state_d = ST_NORMAL;
        end
    end

    typedef enum logic [1:0] {
        FU_ALU,
        FU_MEM,
        FU_MUL,
        FU_DIV
    } func_unit_e;

    always_ff @(posedge clk or negedge resetn)
        if (!resetn) begin
            ex_ex2_valid <= 1'b0;
            ex_pending <= 1'b0;
            ex_ex2_value_valid <= 1'b0;
            ex_ex2_rd <= '0;
            ex_ex2_data <= 'x;
            ex_ex2_data2 <= 'x;
            ex_ex2_npc <= 'x;
            ex_ex2_decoded <= decoded_instr_t'('x);
            ex_state_q <= ST_MISPREDICT;

            ex_expected_pc <= '0;
        end
        else begin
            ex_state_q <= ex_state_d;

            if (ex_ex2_handshaked) begin
                ex_ex2_valid <= 1'b0;
                ex_pending <= 1'b0;
                ex_ex2_value_valid <= 1'b0;
                ex_ex2_rd <= '0;
                ex_ex2_data <= 'x;
                ex_ex2_data2 <= 'x;
                ex_ex2_npc <= 'x;
            end

            if (de_ex_handshaked && ex_can_issue) begin
                ex_ex2_valid <= 1'b1;
                ex_pending <= 1'b1;
                ex_ex2_rd <= de_ex_decoded.rd;
                ex_ex2_value_valid <= ex_value_valid;
                ex_ex2_data <= ex_val;
                ex_ex2_data2 <= ex_val2;
                ex_ex2_npc <= ex_npc;
                ex_ex2_decoded <= de_ex_decoded;

                ex_expected_pc <= ex_npc;
            end
        end

    //
    // EX2 stage
    //
    logic [XLEN-1:0] ex2_npc;
    assign ex2_npc = ex_ex2_decoded.pc + (ex_ex2_decoded.exception.mtval[1:0] == 2'b11 ? 4 : 2);

    // Selecting which unit to choose from
    logic ex2_select_valid = 1'b0;
    func_unit_e ex2_select;
    logic ex2_select_mem;
    logic ex2_select_flush;
    logic ex2_select_wfi;
    logic ex2_select_mul;
    logic ex2_select_div;

    // Results to mux from
    logic ex2_alu_valid;
    logic [XLEN-1:0] ex2_alu_data;
    exception_t ex2_alu_trap;
    logic ex2_mem_valid;
    logic [XLEN-1:0] ex2_mem_data;
    exception_t ex2_mem_trap;
    logic ex2_mem_notif_ready;

    // CSRs
    csr_t ex2_csr_select;
    logic [XLEN-1:0] ex2_csr_operand;
    logic [XLEN-1:0] ex2_csr_read;
    logic [XLEN-1:0] ex2_er_epc;
    logic ex2_int_valid;
    logic ex2_wfi_valid;
    logic [3:0] ex2_int_cause;
    assign ex2_csr_select = csr_t'(ex_ex2_decoded.exception.mtval[31:20]);
    assign ex2_csr_operand = ex_ex2_data;

    wire ex2_valid = ex_ex2_handshaked && ex2_can_issue && !ex_ex2_decoded.exception.valid && !ex2_int_valid;

    // Flush control
    assign flush_tlb = ex2_valid && ex_ex2_decoded.op_type == SFENCE_VMA;

    // Multiplier
    logic [XLEN-1:0] ex2_mul_data;
    logic ex2_mul_valid;
    mul_unit mul (
        .clk       (clk),
        .rstn      (resetn),
        .operand_a (ex_ex2_data),
        .operand_b (ex_ex2_data2),
        .i_32      (ex_ex2_decoded.is_32),
        .i_op      (ex_ex2_decoded.mul.op),
        .i_valid   (ex2_valid && ex_ex2_decoded.op_type == MUL),
        .o_value   (ex2_mul_data),
        .o_valid   (ex2_mul_valid)
    );

    // Divider
    logic [XLEN-1:0] ex2_div_quo, ex2_div_rem;
    logic ex2_div_valid;
    logic ex2_div_use_rem;
    div_unit div (
        .clk        (clk),
        .rstn       (resetn),
        .operand_a  (ex_ex2_data),
        .operand_b  (ex_ex2_data2),
        .i_32       (ex_ex2_decoded.is_32),
        .i_unsigned (ex_ex2_decoded.div.is_unsigned),
        .i_valid    (ex2_valid && ex_ex2_decoded.op_type == DIV),
        .o_quo      (ex2_div_quo),
        .o_rem      (ex2_div_rem),
        .o_valid    (ex2_div_valid)
    );

    assign ex_ex2_ready = ex2_ready || ex2_wb_valid || ex2_wb_trap.valid;
    always_comb begin
        unique case (1'b1)
            ex2_select_valid && ex2_select == FU_ALU: begin
                ex2_wb_valid = ex2_alu_valid;
                ex2_wb_data = ex2_alu_data;
                ex2_wb_trap = ex2_alu_trap;
            end
            ex2_select_valid && ex2_select == FU_MEM: begin
                ex2_wb_valid = ex2_mem_valid;
                ex2_wb_data = ex2_mem_data;
                ex2_wb_trap = ex2_mem_trap;
            end
            ex2_select_flush: begin
                ex2_wb_valid = ex2_mem_notif_ready;
                ex2_wb_data = ex2_alu_data;
                ex2_wb_trap = exception_t'('x);
                ex2_wb_trap.valid = 1'b0;
            end
            ex2_select_wfi: begin
                ex2_wb_valid = ex2_wfi_valid;
                ex2_wb_data = 'x;
                ex2_wb_trap = exception_t'('x);
                ex2_wb_trap.valid = 1'b0;
            end
            ex2_select_valid && ex2_select == FU_MUL: begin
                ex2_wb_valid = ex2_mul_valid;
                ex2_wb_data = ex2_mul_data;
                ex2_wb_trap = exception_t'('x);
                ex2_wb_trap.valid = 1'b0;
            end
            ex2_select_valid && ex2_select == FU_DIV: begin
                ex2_wb_valid = ex2_div_valid;
                ex2_wb_data = ex2_div_use_rem ? ex2_div_rem : ex2_div_quo;
                ex2_wb_trap = exception_t'('x);
                ex2_wb_trap.valid = 1'b0;
            end
            default: begin
                ex2_wb_valid = 1'b0;
                ex2_wb_data = 'x;
                ex2_wb_trap = exception_t'('x);
                ex2_wb_trap.valid = 1'b0;
            end
        endcase
    end

    always_ff @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            ex2_ready <= 1'b1;
            ex2_pending <= 1'b0;
            ex2_select_valid <= 1'b0;
            ex2_select <= FU_ALU;
            ex2_select_flush <= 1'b0;
            ex2_select_wfi <= 1'b0;
            ex2_alu_valid <= 1'b0;
            ex2_alu_data <= 'x;
            ex2_alu_trap <= exception_t'('x);
            ex2_alu_trap.valid <= 1'b0;
            ex2_div_use_rem <= 'x;
            ex2_wb_pc <= 'x;
            ex2_wb_rd <= '0;
            ex2_wb_npc <= '0;
            ex2_wb_pc_override <= 1'b1;
            ex2_wb_pc_override_reason <= IF_FLUSH;
        end
        else begin
            if (ex_ex2_handshaked && ex2_can_issue) begin
                ex2_ready <= 1'b0;
                ex2_pending <= 1'b1;
                ex2_select_valid <= 1'b1;
                ex2_select <= FU_ALU;
                ex2_select_flush <= 1'b0;
                ex2_select_wfi <= 1'b0;
                ex2_alu_valid <= 1'b1;
                ex2_alu_trap <= exception_t'('x);
                ex2_alu_trap.valid <= 1'b0;
                ex2_alu_data <= 'x;
                ex2_wb_pc <= ex_ex2_decoded.pc;
                ex2_wb_rd <= ex_ex2_decoded.rd;
                ex2_wb_npc <= ex_ex2_npc;
                ex2_wb_pc_override <= 1'b0;
                ex2_wb_pc_override_reason <= IF_FLUSH;
                case (1'b1)
                    ex_ex2_decoded.exception.valid: begin
                        ex2_alu_valid <= 1'b0;
                        ex2_alu_trap <= ex_ex2_decoded.exception;
                    end
                    ex2_int_valid: begin
                        ex2_alu_valid <= 1'b0;
                        ex2_alu_trap.valid <= 1'b1;
                        ex2_alu_trap.mcause_interrupt <= 1'b1;
                        ex2_alu_trap.mcause_code <= ex2_int_cause;
                        ex2_alu_trap.mtval <= '0;
                    end
                    default:
                        case (ex_ex2_decoded.op_type)
                            ALU, BRANCH: begin
                                ex2_alu_data <= ex_ex2_data;
                            end
                            CSR: begin
                                ex2_alu_data <= ex2_csr_read;
                                // Because SUM and SATP's mode & ASID bits are all high, we don't need to flush
                                // the pipeline on CSRxxI instructions.
                                if (ex_ex2_decoded.csr.op != 2'b00 && !ex_ex2_decoded.csr.imm) begin
                                    case (ex2_csr_select)
                                        CSR_SATP: begin
                                            ex2_select_valid <= 1'b0;
                                            ex2_select_flush <= 1'b1;
                                            ex2_wb_pc_override <= 1'b1;
                                            ex2_wb_pc_override_reason <= IF_SATP_CHANGED;
                                        end
                                        CSR_MSTATUS: begin
                                            ex2_wb_pc_override <= 1'b1;
                                            ex2_wb_pc_override_reason <= IF_PROT_CHANGED;
                                        end
                                        CSR_SSTATUS: begin
                                            ex2_wb_pc_override <= 1'b1;
                                            ex2_wb_pc_override_reason <= IF_PROT_CHANGED;
                                        end
                                    endcase
                                end
                            end
                            MEM: begin
                                ex2_select <= FU_MEM;
                            end
                            MUL: begin
                                ex2_select <= FU_MUL;
                            end
                            DIV: begin
                                ex2_select <= FU_DIV;
                                ex2_div_use_rem <= ex_ex2_decoded.div.rem;
                            end
                            ERET: begin
                                ex2_wb_pc_override <= 1'b1;
                                ex2_wb_pc_override_reason <= IF_PROT_CHANGED;
                                ex2_wb_npc <= ex2_er_epc;
                            end
                            FENCE_I: begin
                                ex2_wb_pc_override <= 1'b1;
                                ex2_wb_pc_override_reason <= IF_FLUSH;
                            end
                            SFENCE_VMA: begin
                                ex2_select_valid <= 1'b0;
                                ex2_select_flush <= 1'b1;
                                ex2_wb_pc_override <= 1'b1;
                                ex2_wb_pc_override_reason <= IF_FLUSH;
                            end
                            WFI: begin
                                ex2_select_valid <= 1'b0;
                                ex2_select_wfi <= 1'b1;
                            end
                        endcase
                endcase
            end
            else if (ex2_wb_valid || ex2_wb_trap.valid) begin
                // Reset to default values.
                ex2_ready <= 1'b1;
                ex2_pending <= 1'b0;
                ex2_wb_rd <= '0;
                ex2_alu_valid <= 1'b0;
                ex2_select_valid <= 1'b0;
                ex2_select <= FU_ALU;
                ex2_select_flush <= 1'b0;
                ex2_select_wfi <= 1'b0;
                ex2_alu_trap <= exception_t'('x);
                ex2_alu_trap.valid <= 1'b0;
            end
        end
    end

    //
    // EX stage - load & store
    //

    assign dcache.req_valid    = ex2_valid && ex_ex2_decoded.op_type == MEM;
    assign dcache.req_op       = ex_ex2_decoded.mem.op;
    assign dcache.req_amo      = ex_ex2_decoded.exception.mtval[31:25];
    assign dcache.req_address  = ex_ex2_data;
    assign dcache.req_size     = ex_ex2_decoded.mem.size;
    assign dcache.req_unsigned = ex_ex2_decoded.mem.zeroext;
    assign dcache.req_value    = ex_ex2_data2;
    assign dcache.req_prv      = data_prv;
    assign dcache.req_sum      = status.sum;
    assign dcache.req_mxr      = status.mxr;
    assign dcache.req_atp      = data_atp;
    assign ex2_mem_valid = dcache.resp_valid;
    assign ex2_mem_data  = dcache.resp_value;
    assign ex2_mem_trap  = dcache.resp_exception;
    assign ex2_mem_notif_ready = dcache.notif_ready;

    assign dcache.notif_valid = ex2_valid && (ex_ex2_decoded.op_type == SFENCE_VMA || (ex_ex2_decoded.op_type == CSR && ex_ex2_decoded.csr.op != 2'b00 && !ex_ex2_decoded.csr.imm && ex2_csr_select == CSR_SATP));
    assign dcache.notif_reason = ex_ex2_decoded.op_type == SFENCE_VMA;

    //
    // Register file instantiation
    //
    reg_file # (
        .XLEN (XLEN)
    ) regfile (
        .clk (clk),
        .rstn (resetn),
        .ra_sel (de_rs1_select),
        .ra_data (de_ex_rs1),
        .rb_sel (de_rs2_select),
        .rb_data (de_ex_rs2),
        .w_sel (ex2_wb_rd),
        .w_data (ex2_wb_data),
        .w_en (ex2_wb_valid)
    );

    csr_regfile # (
        .XLEN (XLEN)
    ) csr_regfile (
        .clk (clk),
        .resetn (resetn),
        .pc_sel (de_csr_sel),
        .pc_op (de_csr_op),
        .pc_illegal (de_csr_illegal),
        .a_valid (ex2_valid && ex_ex2_decoded.op_type == CSR),
        .a_sel (ex2_csr_select),
        .a_op (ex_ex2_decoded.csr.op),
        .a_data (ex2_csr_operand),
        .a_read (ex2_csr_read),
        .ex_valid (ex2_wb_trap.valid),
        .ex_exception (ex2_wb_trap),
        .ex_epc (ex2_wb_pc),
        .ex_tvec (wb_tvec),
        .er_valid (ex2_valid && ex_ex2_decoded.op_type == ERET),
        .er_prv (ex_ex2_decoded.exception.mtval[29] ? PRV_M : PRV_S),
        .er_epc (ex2_er_epc),
        .int_valid (ex2_int_valid),
        .int_cause (ex2_int_cause),
        .wfi_valid (ex2_wfi_valid),
        .mhartid (mhartid),
        .hpm_instret (ex2_wb_valid),
        .*
    );

    always_comb begin
        wb_if_valid = 1'b0;
        wb_if_reason = if_reason_t'('x);
        wb_if_pc = 'x;

        // WB
        if (ex2_wb_trap.valid) begin
            wb_if_pc = wb_tvec;
            wb_if_valid = 1'b1;
            // PRV change
            wb_if_reason = IF_EXCEPTION;
        end
        else if (ex2_wb_valid && ex2_wb_pc_override) begin
            wb_if_pc = ex2_wb_npc;
            wb_if_valid = 1'b1;
            wb_if_reason = ex2_wb_pc_override_reason;
        end
        else if (ex_state_q == ST_NORMAL && de_ex_handshaked && ex_expected_pc != de_ex_decoded.pc) begin
            wb_if_pc = ex_expected_pc;
            wb_if_valid = 1'b1;
            wb_if_reason = IF_MISPREDICT;
        end
    end

    always_ff @(posedge clk) begin
        if (ex2_wb_trap.valid) begin
            $display("%t: trap %x", $time, ex2_wb_pc);
        end
    end

    // Debug connections
    assign dbg_pc = ex2_wb_pc;

endmodule
