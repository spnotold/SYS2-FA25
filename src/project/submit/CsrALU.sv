`include "core_struct.vh"

/*
 * CSR-ALU（CSR 流水线的专用运算单元）
 * -----------------------------------------------------------------------------
 * CSR 指令属于“读-改-写”范式：先读出 CSR_old，再根据指令类型生成 CSR_new 写回 CSR。
 * 本模块实现三类更新规则：
 *   - CSR_ALU_ADD    : CSR_new = A + B
 *   - CSR_ALU_OR     : CSR_new = A | B
 *   - CSR_ALU_ANDNOT : CSR_new = A & ~B
 *
 * 其中 A/B 的选择由 csr_alu_asel / csr_alu_bsel 控制：
 *   ASEL_CSR0    -> A = 0
 *   ASEL_CSRREG  -> A = CSR_old
 *
 *   BSEL_CSR0    -> B = 0
 *   BSEL_GPREG   -> B = gpreg_val   （寄存器版本 csrrw/csrrs/csrrc 的 rs1）
 *   BSEL_CSRIMM  -> B = csr_imm_val （立即数版本 csrrwi/csrrsi/csrrci 的 zimm[4:0] 零扩展）
 *
 * 说明：
 *   - csrrw/csrrwi：直接写入 B，因此可用 (CSR_ALU_ADD + ASEL_CSR0) 实现“直通 B”。
 *   - csrrs/csrrsi：CSR_old | mask（mask=rs1 或 zimm）
 *   - csrrc/csrrci：CSR_old & ~mask
 */
module CsrALU (
    input  CsrPack::csr_alu_op_enmu      csr_alu_op,
    input  CsrPack::csr_alu_asel_op_enum csr_alu_asel,
    input  CsrPack::csr_alu_bsel_op_enum csr_alu_bsel,

    input  CorePack::data_t              csr_old,
    input  CorePack::data_t              gpreg_val,
    input  CorePack::data_t              csr_imm_val,

    output CorePack::data_t              csr_new
);
    import CorePack::*;
    import CsrPack::*;

    data_t a;
    data_t b;

    always_comb begin
        a = 'x;
        b = 'x;
        csr_new = 'x;

        unique case (csr_alu_asel)
            ASEL_CSR0:   a = 64'd0;
            ASEL_CSRREG: a = csr_old;
            default:     a = 'x;
        endcase

        unique case (csr_alu_bsel)
            BSEL_CSR0:   b = 64'd0;
            BSEL_GPREG:  b = gpreg_val;
            BSEL_CSRIMM: b = csr_imm_val;
            default:     b = 'x;
        endcase

        unique case (csr_alu_op)
            CSR_ALU_ADD:    csr_new = a + b;
            CSR_ALU_OR:     csr_new = a | b;
            CSR_ALU_ANDNOT: csr_new = a & ~b;
            default:        csr_new = 'x;
        endcase
    end
endmodule

