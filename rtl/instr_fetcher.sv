import cpu_common::*;

// Instruction fetcher continuously fetch instructions until
// it has encountered a PC override.
module instr_fetcher # (
    parameter XLEN = 64,
    parameter C_EXT = 1'b0,
    parameter BRANCH_PRED = 1
) (
    input  logic clk,
    input  logic resetn,

    icache_intf.user cache_uncompressed,

    // When the signals are valid, instruction fetcher needs to flush its pipeline
    // and restart fetching from the specified PC.
    input  [XLEN-1:0] i_pc,
    input  if_reason_t i_reason,
    input  i_valid,
    output i_ready,

    // These should always be valid.
    input  logic           i_prv,
    input  logic           i_sum,
    input  [XLEN-1:0] i_atp,

    input  logic flush_cache,
    input  logic flush_tlb,

    output logic o_valid,
    input  logic o_ready,
    output fetched_instr_t o_fetched_instr
);

    icache_intf cache (clk, resetn);

    if (C_EXT) begin
        icache_compressed comp_inst (cache, cache_uncompressed);
    end
    else begin
        assign cache_uncompressed.req_valid = cache.req_valid;
        assign cache_uncompressed.req_pc = cache.req_pc;
        assign cache_uncompressed.req_reason = cache.req_reason;
        assign cache_uncompressed.req_prv = cache.req_prv;
        assign cache_uncompressed.req_sum = cache.req_sum;
        assign cache_uncompressed.req_atp = cache.req_atp;

        assign cache.resp_valid = cache_uncompressed.resp_valid;
        assign cache.resp_pc = cache_uncompressed.resp_pc;
        assign cache.resp_instr = cache_uncompressed.resp_instr;
        assign cache.resp_exception = cache_uncompressed.resp_exception;

        assign cache_uncompressed.flush_cache = cache.flush_cache;
        assign cache_uncompressed.flush_tlb = cache.flush_tlb;
    end

    logic [XLEN-1:0] pc;
    if_reason_t reason;

    logic [XLEN-1:0] pc_next;
    if_reason_t reason_next;

    // We need to latch ATP so that its change does not affect currently prefetched instructions.
    logic [XLEN-1:0] atp_latch;
    logic prv_latch;
    logic sum_latch;

    always_ff @(posedge clk or negedge resetn)
        if (!resetn) begin
            atp_latch <= '0;
            prv_latch <= 1'b0;
            sum_latch <= 1'b0;
        end
        else begin
            if (i_valid && i_ready) begin
                atp_latch <= i_atp;
                prv_latch <= i_prv;
                sum_latch <= i_sum;
            end
        end

    assign cache.req_pc = pc_next;
    assign cache.req_reason = reason_next;
    assign cache.req_valid = o_valid && o_ready;
    assign cache.req_sum = i_valid && i_ready ? i_sum : sum_latch;
    assign cache.req_atp = i_valid && i_ready ? i_atp : atp_latch;
    assign cache.req_prv = i_valid && i_ready ? i_prv : prv_latch;
    assign cache.flush_cache = flush_cache;
    assign cache.flush_tlb = flush_tlb;

    logic latched;
    logic [31:0] resp_instr_latch;
    logic [XLEN-1:0] resp_pc_latch;
    logic resp_exception_latch;

    assign o_valid = cache.resp_valid || latched;
    assign i_ready = o_valid && o_ready;

    always_ff @(posedge clk or negedge resetn)
        if (!resetn) begin
            // To kick-start the frontend, we need o_valid to be high initially.
            latched <= 1'b1;
            resp_instr_latch <= '0;
            resp_pc_latch <= '0;
            resp_exception_latch <= 1'b0;

            pc <= 0;
            reason <= IF_PREFETCH;
        end
        else begin
            if (!o_ready && cache.resp_valid) begin
                assert (!latched);
                latched <= 1'b1;
                resp_instr_latch <= cache.resp_instr;
                resp_pc_latch <= cache.resp_pc;
                resp_exception_latch <= cache.resp_exception;
            end

            if (o_ready) begin
                latched <= 1'b0;
            end

            if (o_valid && o_ready) begin
                pc <= pc_next;
                reason <= reason_next;
            end
        end

    assign o_fetched_instr.instr_word = latched ? resp_instr_latch : cache.resp_instr;
    assign o_fetched_instr.pc = pc;
    assign o_fetched_instr.if_reason = reason;
    assign o_fetched_instr.exception.valid = latched ? resp_exception_latch : cache.resp_exception;
    assign o_fetched_instr.exception.mcause_interrupt = 1'b0;
    assign o_fetched_instr.exception.mcause_code = 4'hC;
    assign o_fetched_instr.exception.mtval = latched ? resp_pc_latch : cache.resp_pc;

    //
    // Static branch prediction
    //

    wire [XLEN-1:0] instr_word = latched ? resp_instr_latch : cache.resp_instr;

    // Prediction for branch
    wire is_branch = instr_word[6:0] == 7'b1100011;
    // Highest bits are tied to one as we only use b_imm if they're one.
    // wire [XLEN-1:0] b_imm = signed'({instr_word[31], instr_word[7], instr_word[30:25], instr_word[11:8], 1'b0});
    logic [XLEN-1:0] b_imm;
    if (C_EXT) begin
        assign b_imm = signed'({1'b1, instr_word[7], instr_word[30:25], instr_word[11:8], 1'b0});
    end
    else begin
        assign b_imm = signed'({1'b1, instr_word[7], instr_word[30:25], instr_word[11:9], 1'b0, 1'b0});
    end

    // Prediction for jal
    wire is_jal = instr_word[6:0] == 7'b1101111;
    logic [XLEN-1:0] j_imm;
    if (C_EXT) begin
        assign j_imm = signed'({instr_word[31], instr_word[19:12], instr_word[20], instr_word[30:21], 1'b0});
    end
    else begin
        assign j_imm = signed'({instr_word[31], instr_word[19:12], instr_word[20], instr_word[30:22], 1'b0, 1'b0});
    end

    wire is_c_branch = instr_word[1:0] == 2'b01 && instr_word[15:14] == 2'b11;
    // wire [XLEN-1:0] cb_imm = signed'({instr_word[12], instr_word[6:5], instr_word[2], instr_word[11:10], instr_word[4:3], 1'b0});
    wire [XLEN-1:0] cb_imm = signed'({1'b1, instr_word[6:5], instr_word[2], instr_word[11:10], instr_word[4:3], 1'b0});

    wire is_c_jal = instr_word[1:0] == 2'b01 && instr_word[15:13] == 3'b101;
    wire [XLEN-1:0] cj_imm = signed'({instr_word[12], instr_word[8], instr_word[10:9], instr_word[6], instr_word[7], instr_word[2], instr_word[11], instr_word[5:3], 1'b0});

    logic predict_taken;
    logic [XLEN-1:0] predict_target;
    always_comb begin
        unique case (1'b1)
            BRANCH_PRED && is_branch: begin
                predict_taken = instr_word[31];
                predict_target = pc + b_imm;
            end
            BRANCH_PRED && is_jal: begin
                predict_taken = 1'b1;
                predict_target = pc + j_imm;
            end
            BRANCH_PRED && C_EXT && is_c_branch: begin
                predict_taken = instr_word[12];
                predict_target = pc + cb_imm;
            end
            BRANCH_PRED && C_EXT && is_c_jal: begin
                predict_taken = 1'b1;
                predict_target = pc + cj_imm;
            end
            default: begin
                predict_taken = 1'b0;
                predict_target = 'x;
            end
        endcase
    end

    assign o_fetched_instr.prediction.taken = predict_taken;
    assign o_fetched_instr.prediction.target = predict_target;

    // Compute next PC if no branch is taken.
    // This could be just `pc + (instr_word[1:0] == 2'b11 ? 4 : 2)`, but doing so would make the
    // critical path really long. Therefore we just do `pc + 4` instead, and if we need to do +2,
    // instead, we can use MUX to do that.
    wire logic [XLEN-1:0] npc_word = {pc[XLEN-1:2], 2'b0} + 4;
    logic [XLEN-1:0] npc;
    always_comb begin
        npc = npc_word;
        if (C_EXT) begin
            if (instr_word[1:0] == 2'b11) begin
                // Need to do +4, so copy bit 1.
                npc[1] = pc[1];
            end
            else if (!pc[1]) begin
                // Need to do +2.
                // If pc[1] is 1, zeroing out bit 1 and +4 is exactly +2.
                // If pc[1] is 0, just keep the higher bit and set bit 1 to 1.
                npc = {pc[XLEN-1:2], 2'b10};
            end
        end
    end

    if (C_EXT) begin
        assign pc_next = i_valid ? {i_pc[XLEN-1:1], 1'b0} : (predict_taken ? predict_target : npc);
    end
    else begin
        assign pc_next = i_valid ? {i_pc[XLEN-1:2], 2'b0} : (predict_taken ? predict_target : npc);
    end
    assign reason_next = i_valid ? i_reason : (predict_taken ? IF_PREDICT : IF_PREFETCH);

endmodule
