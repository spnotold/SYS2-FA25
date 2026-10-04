`include "core_struct.vh"
`include "csr_struct.vh"

/*
 * CSR / 特权指令译码器（ID 阶段使用）
 * -----------------------------------------------------------------------------
 * 本模块只做“组合逻辑译码”，不包含任何时序状态。
 *
 * 它负责识别两类指令：
 *   1) CSR 指令：csrrw/csrrwi/csrrs/csrrsi/csrrc/csrrci
 *      - 这 6 条都属于 SYSTEM opcode（CSR_OPCODE = 7'b1110011），且 funct3 != 3'b000。
 *      - 语义共同点：rd <- CSR_old，然后（可能）更新 CSR。
 *        * csrrw/csrrwi：CSR <- rs1/zimm（总会写 CSR）
 *        * csrrs/csrrsi：CSR <- CSR_old | mask（mask=0 时只读不写）
 *        * csrrc/csrrci：CSR <- CSR_old & ~mask（mask=0 时只读不写）
 *
 *   2) 特权指令：ecall / mret / sret
 *      - 同样属于 SYSTEM opcode，但 funct3=000 且指令编码固定。
 *      - 这些指令的异常/返回、特权态切换由 CSRModule 统一判定与输出（pc_csr/switch_mode）。
 *
 * 输出信号设计（给后续 CSR 流水线使用）：
 *   - csr_valid：该指令是否为“CSR 指令”（不是 ecall/mret/sret）
 *   - csr_addr ：要访问的 CSR 编号（inst[31:20]）
 *   - csr_is_imm + csr_zimm：是否为 *I 版本以及 zimm（inst[19:15]）
 *   - csr_we   ：是否需要写 CSR（csrrs/csrrc 在 mask==0 时为 0）
 *   - csr_we_reg：是否需要写回 rd（rd==x0 时为 0；CSR 指令 rd 写的是 CSR_old）
 *   - csr_alu_*：给 CSR-ALU 的控制信号（用来生成 CSR_new）
 *
 * 注意：
 *   - 本模块不做“权限检查/非法指令”判断；非法情况由 IDExceptExamine/CSRModule 处理。
 *   - csr_we_reg 与 csr_we 是两个不同概念：即使不写 CSR（mask==0），仍然可以写回 rd（读 CSR）。
 */
module csr_controller (
    input CorePack::inst_t inst,

    // CSR 指令（csrr*）解码结果
    output logic csr_valid,                       // 1: csrr* 指令（不是 ecall/mret/sret）
    output logic csr_we,                          // 1: 需要写 CSR（csrrs/csrrc 的 mask!=0；csrrw 总为 1）
    output logic csr_we_reg,                      // 1: 需要写回 rd（rd!=x0；写回值为 CSR_old）
    output logic csr_is_imm,                      // 1: *I 版本（csrrwi/csrrsi/csrrci）
    output logic [4:0] csr_zimm,                  // zimm（立即数版本 mask/写入值；位于 inst[19:15]）
    output CsrPack::csr_reg_ind_t csr_addr,
    output CsrPack::csr_alu_op_enmu csr_alu_op,
    output CsrPack::csr_alu_asel_op_enum csr_alu_asel,
    output CsrPack::csr_alu_bsel_op_enum csr_alu_bsel,

    // 特权指令
    output logic is_ecall,
    output logic is_mret,
    output logic is_sret
);
    import CsrPack::*;

    wire [6:0] opcode = inst[6:0];
    wire [2:0] funct3 = inst[14:12];
    // 在 CSR 指令里，inst[19:15]：
    //   - 对寄存器版本：是 rs1
    //   - 对立即数版本：是 zimm
    // 因此这里统一命名为 rs1_or_zimm。
    wire [4:0] rs1_or_zimm = inst[19:15];
    wire [4:0] rd = inst[11:7];

    always_comb begin
        // 默认值
        csr_valid = 1'b0;
        csr_we = 1'b0;
        csr_we_reg = 1'b0;
        csr_is_imm = 1'b0;
        csr_zimm = rs1_or_zimm;
        csr_addr = '0;
        // CSR-ALU 默认选择“直通 B”（CSR_ALU_ADD + ASEL_CSR0）
        csr_alu_op = CSR_ALU_ADD;
        csr_alu_asel = ASEL_CSR0;
        csr_alu_bsel = BSEL_CSR0;

        is_ecall = 1'b0;
        is_mret = 1'b0;
        is_sret = 1'b0;

        // 特权指令（SYSTEM opcode + funct3=000，且编码固定）
        // - 这三条不走 CSR-ALU；后续由异常/ret 通路交给 CSRModule 决策。
        if (inst == ECALL) begin
            is_ecall = 1'b1;
        end else if (inst == MRET) begin
            is_mret = 1'b1;
        end else if (inst == SRET) begin
            is_sret = 1'b1;
        end

        // CSR 指令（SYSTEM opcode + funct3 属于 csrr* 六条）
        // - funct3[2] 用来区分寄存器版/立即数版：
        //     001/010/011 = reg  ；101/110/111 = imm
        if (opcode == CSR_OPCODE) begin
            unique case (funct3)
                CSRRW_FUNCT3, CSRRWI_FUNCT3: begin
                    csr_valid = 1'b1;
                    csr_is_imm = funct3[2];
                    csr_addr = inst[31:20];
                    // csrrw/csrrwi：CSR_new = rs1/zimm（直接写入，不依赖 CSR_old）
                    // 用 CSR_ALU_ADD + ASEL_CSR0 实现“输出 = B”
                    csr_alu_asel = ASEL_CSR0;
                    csr_alu_bsel = csr_is_imm ? BSEL_CSRIMM : BSEL_GPREG;
                    csr_we = 1'b1;                  // csrrw/csrrwi 总会写 CSR
                end
                CSRRS_FUNCT3, CSRRSI_FUNCT3: begin
                    csr_valid = 1'b1;
                    csr_is_imm = funct3[2];
                    csr_addr = inst[31:20];
                    // csrrs/csrrsi：CSR_new = CSR_old | mask
                    csr_alu_op = CSR_ALU_OR;
                    csr_alu_asel = ASEL_CSRREG;
                    csr_alu_bsel = csr_is_imm ? BSEL_CSRIMM : BSEL_GPREG;
                    // rs1/x0 或 zimm=0 时只读不写
                    csr_we = (rs1_or_zimm != 5'd0);
                end
                CSRRC_FUNCT3, CSRRCI_FUNCT3: begin
                    csr_valid = 1'b1;
                    csr_is_imm = funct3[2];
                    csr_addr = inst[31:20];
                    // csrrc/csrrci：CSR_new = CSR_old & ~mask
                    csr_alu_op = CSR_ALU_ANDNOT;
                    csr_alu_asel = ASEL_CSRREG;
                    csr_alu_bsel = csr_is_imm ? BSEL_CSRIMM : BSEL_GPREG;
                    // rs1/x0 或 zimm=0 时只读不写
                    csr_we = (rs1_or_zimm != 5'd0);
                end
                default: begin
                    // 其它 SYSTEM 指令：在本模块不处理
                end
            endcase
        end

        // CSR 指令都会把 CSR 旧值写回 rd（rd=x0 时不写回）
        // - 即使 csr_we=0（只读），仍然可能需要写回 rd。
        csr_we_reg = csr_valid & (rd != 5'd0);
    end

endmodule
