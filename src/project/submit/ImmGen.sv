`include "core_struct.vh"
module ImmGen (
    input CorePack::inst_t inst,          // 32位指令输入
    input CorePack::imm_op_enum imm_op,   // 立即数类型
    output CorePack::data_t imm_out       // 64位立即数
);
    import CorePack::*;

    always_comb begin
        imm_out = 64'bX; 
        unique case (imm_op)
            IMM0:   imm_out = 64'b0;
            I_IMM:  imm_out = {{52{inst[31]}}, inst[31:20]};
            S_IMM:  imm_out = {{52{inst[31]}}, inst[31:25], inst[11:7]};
            B_IMM:  imm_out = {{51{inst[31]}}, inst[31], inst[7], inst[30:25], inst[11:8], 1'b0};
            U_IMM:  imm_out = {{32{inst[31]}}, inst[31:12], 12'b0};
            UJ_IMM: imm_out = {{43{inst[31]}}, inst[31], inst[19:12], inst[20], inst[30:21], 1'b0};
            default: imm_out = 64'bX;
        endcase
    end
endmodule

