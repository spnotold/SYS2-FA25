`include "core_struct.vh"

module controller (
    input CorePack::inst_t inst, // 32 位指令输入
    
    // 输出控制信号
    output logic we_reg,
    output logic we_mem,
    output logic re_mem,
    output logic npc_sel,
    output CorePack::imm_op_enum immgen_op,
    output CorePack::alu_op_enum alu_op,
    output CorePack::cmp_op_enum cmp_op,
    output CorePack::alu_asel_op_enum alu_asel,
    output CorePack::alu_bsel_op_enum alu_bsel,
    output CorePack::wb_sel_op_enum wb_sel,
    output CorePack::mem_op_enum mem_op
);
    import CorePack::*;

    // 提取指令字段
    wire [6:0] opcode = inst[6:0];
    wire [2:0] funct3 = inst[14:12];
    wire [6:0] funct7 = inst[31:25];

    // Funct7 常量 (因为 core_struct.vh 没有定义)
    localparam F7_ZERO = 7'b0000000;
    localparam F7_ALT  = 7'b0100000;

    // 使用 always_comb 块生成控制信号
    always_comb begin
        // 先设置默认值 
        we_reg = 1'b0;
        we_mem = 1'b0;
        re_mem = 1'b0;
        npc_sel = 1'b0;
        immgen_op = IMM0;
        alu_op = ALU_ADD;
        cmp_op = CMP_NO;
        alu_asel = ASEL_REG;
        alu_bsel = BSEL_REG;
        wb_sel = WB_SEL_ALU;
        mem_op = MEM_NO;

        // 根据 opcode 译码
        case (opcode)
            LOAD_OPCODE: begin // Load 类
                we_reg = 1'b1;
                re_mem = 1'b1;
                immgen_op = I_IMM;
                alu_op = ALU_ADD;
                alu_asel = ASEL_REG;
                alu_bsel = BSEL_IMM;
                wb_sel = WB_SEL_MEM;
                case (funct3)
                    LB_FUNCT3:  mem_op = MEM_B;
                    LH_FUNCT3:  mem_op = MEM_H;
                    LW_FUNCT3:  mem_op = MEM_W;
                    LD_FUNCT3:  mem_op = MEM_D;
                    LBU_FUNCT3: mem_op = MEM_UB;
                    LHU_FUNCT3: mem_op = MEM_UH;
                    LWU_FUNCT3: mem_op = MEM_UW;
                    default: ; 
                endcase
            end
            IMM_OPCODE: begin // I-type 算术逻辑
                we_reg = 1'b1;
                immgen_op = I_IMM;
                alu_asel = ASEL_REG;
                alu_bsel = BSEL_IMM;
                wb_sel = WB_SEL_ALU;
                case (funct3)
                    ADD_FUNCT3:  alu_op = ALU_ADD;  // ADDI
                    SLT_FUNCT3:  alu_op = ALU_SLT;  // SLTI
                    SLTU_FUNCT3: alu_op = ALU_SLTU; // SLTIU
                    XOR_FUNCT3:  alu_op = ALU_XOR;  // XORI
                    OR_FUNCT3:   alu_op = ALU_OR;   // ORI
                    AND_FUNCT3:  alu_op = ALU_AND;  // ANDI
                    SLL_FUNCT3:  alu_op = ALU_SLL;  // SLLI
                    SRL_FUNCT3: begin               // SRLI/SRAI
                        if (funct7 == F7_ALT) alu_op = ALU_SRA; // SRAI
                        else                  alu_op = ALU_SRL; // SRLI
                    end
                    default: ;
                endcase
            end
            AUIPC_OPCODE: begin
                we_reg = 1'b1;
                immgen_op = U_IMM;
                alu_op = ALU_ADD;
                alu_asel = ASEL_PC;
                alu_bsel = BSEL_IMM;
                wb_sel = WB_SEL_ALU;
            end
            IMMW_OPCODE: begin // I-type *W
                we_reg = 1'b1;
                immgen_op = I_IMM;
                alu_asel = ASEL_REG;
                alu_bsel = BSEL_IMM;
                wb_sel = WB_SEL_ALU;
                case (funct3)
                    ADDW_FUNCT3: alu_op = ALU_ADDW; // ADDIW
                    SLLW_FUNCT3: alu_op = ALU_SLLW; // SLLIW
                    SRLW_FUNCT3: begin             // SRLIW/SRAIW
                        if (funct7 == F7_ALT) alu_op = ALU_SRAW; // SRAIW
                        else                  alu_op = ALU_SRLW; // SRLIW
                    end
                    default: ;
                endcase
            end
            STORE_OPCODE: begin // Store 类
                we_mem = 1'b1;
                immgen_op = S_IMM;
                alu_op = ALU_ADD;
                alu_asel = ASEL_REG;
                alu_bsel = BSEL_IMM;
                wb_sel = WB_SEL0;
                case (funct3)
                    SB_FUNCT3: mem_op = MEM_B;
                    SH_FUNCT3: mem_op = MEM_H;
                    SW_FUNCT3: mem_op = MEM_W;
                    SD_FUNCT3: mem_op = MEM_D;
                    default: ;
                endcase
            end
            REG_OPCODE: begin // R-type 算术逻辑
                we_reg = 1'b1;
                immgen_op = IMM0;
                alu_asel = ASEL_REG;
                alu_bsel = BSEL_REG;
                wb_sel = WB_SEL_ALU;
                case (funct3)
                    ADD_FUNCT3: begin
                        if (funct7 == F7_ALT) alu_op = ALU_SUB; // SUB
                        else                  alu_op = ALU_ADD; // ADD
                    end
                    SLL_FUNCT3:  alu_op = ALU_SLL;
                    SLT_FUNCT3:  alu_op = ALU_SLT;
                    SLTU_FUNCT3: alu_op = ALU_SLTU;
                    XOR_FUNCT3:  alu_op = ALU_XOR;
                    SRL_FUNCT3: begin
                        if (funct7 == F7_ALT) alu_op = ALU_SRA; // SRA
                        else                  alu_op = ALU_SRL; // SRL
                    end
                    OR_FUNCT3:   alu_op = ALU_OR;
                    AND_FUNCT3:  alu_op = ALU_AND;
                    default: ;
                endcase
            end
            LUI_OPCODE: begin
                we_reg = 1'b1;
                immgen_op = U_IMM;
                alu_op = ALU_ADD;
                alu_asel = ASEL0;
                alu_bsel = BSEL_IMM;
                wb_sel = WB_SEL_ALU;
            end
            REGW_OPCODE: begin // R-type *W
                we_reg = 1'b1;
                immgen_op = IMM0;
                alu_asel = ASEL_REG;
                alu_bsel = BSEL_REG;
                wb_sel = WB_SEL_ALU;
                case (funct3)
                    ADDW_FUNCT3: begin
                        if (funct7 == F7_ALT) alu_op = ALU_SUBW; // SUBW
                        else                  alu_op = ALU_ADDW; // ADDW
                    end
                    SLLW_FUNCT3: alu_op = ALU_SLLW;
                    SRLW_FUNCT3: begin
                        if (funct7 == F7_ALT) alu_op = ALU_SRAW; // SRAW
                        else                  alu_op = ALU_SRLW; // SRLW
                    end
                    default: ;
                endcase
            end
            BRANCH_OPCODE: begin
                npc_sel = 1'b1;
                immgen_op = B_IMM;
                alu_op = ALU_ADD;
                alu_asel = ASEL_PC;
                alu_bsel = BSEL_IMM;
                wb_sel = WB_SEL0;
                case (funct3)
                    BEQ_FUNCT3:  cmp_op = CMP_EQ;
                    BNE_FUNCT3:  cmp_op = CMP_NE;
                    BLT_FUNCT3:  cmp_op = CMP_LT;
                    BGE_FUNCT3:  cmp_op = CMP_GE;
                    BLTU_FUNCT3: cmp_op = CMP_LTU;
                    BGEU_FUNCT3: cmp_op = CMP_GEU;
                    default: cmp_op = CMP_NO;
                endcase
            end
            JALR_OPCODE: begin
                we_reg = 1'b1;
                npc_sel = 1'b1;
                immgen_op = I_IMM;
                alu_op = ALU_ADD;
                alu_asel = ASEL_REG;
                alu_bsel = BSEL_IMM;
                wb_sel = WB_SEL_PC;
            end
            JAL_OPCODE: begin
                we_reg = 1'b1;
                npc_sel = 1'b1;
                immgen_op = UJ_IMM;
                alu_op = ALU_ADD;
                alu_asel = ASEL_PC;
                alu_bsel = BSEL_IMM;
                wb_sel = WB_SEL_PC;
            end
            default: begin
                // 保持默认值
            end
        endcase
    end

endmodule
