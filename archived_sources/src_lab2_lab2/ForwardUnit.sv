`include "core_struct.vh"

// ForwardUnit — 前递选择器（按实验图在 ID 段使用）
// 仅负责产生“命中判定与选择编码”；具体数据在 Core 中用多路选择器完成。
// 选择编码：00=RegFile，10=EX/MEM（非 Load），01=MEM/WB（最终写回）。优先级 EX/MEM > MEM/WB。
module ForwardUnit (
    // 当前 ID 阶段需要的源寄存器索引
    input  CorePack::reg_ind_t id_rs1,
    input  CorePack::reg_ind_t id_rs2,

    // 生产者视图（段寄存器）
    input  PipelinePack::EXEMEM exmem_q,
    input  PipelinePack::MEMWB  memwb_q,

    // 输出：ID 段前递选择编码
    output logic [1:0]          fwdA_id_sel,
    output logic [1:0]          fwdB_id_sel
);
    import CorePack::*;
    import PipelinePack::*;

    logic ex_hit_a, ex_hit_b;   // EX/MEM 对 rs1/rs2 命中（且可前递）
    logic mem_hit_a, mem_hit_b; // MEM/WB 对 rs1/rs2 命中（仅在未命中 EX 时生效）

    always_comb begin
        // EX/MEM 命中：必须 valid && we_reg && rd!=0 && 非 Load（当前拍不可前递）
        ex_hit_a  = (exmem_q.valid && exmem_q.we_reg && (exmem_q.rd != 5'd0) && (exmem_q.wb_sel != WB_SEL_MEM) && (exmem_q.rd == id_rs1));
        ex_hit_b  = (exmem_q.valid && exmem_q.we_reg && (exmem_q.rd != 5'd0) && (exmem_q.wb_sel != WB_SEL_MEM) && (exmem_q.rd == id_rs2));
        // MEM/WB 命中：需要在对应 EX 未命中时才生效（保持优先级）
        mem_hit_a = (memwb_q.valid && memwb_q.we_reg && (memwb_q.rd != 5'd0) && !ex_hit_a && (memwb_q.rd == id_rs1));
        mem_hit_b = (memwb_q.valid && memwb_q.we_reg && (memwb_q.rd != 5'd0) && !ex_hit_b && (memwb_q.rd == id_rs2));

        // 编码输出（00:RegFile；10:EX/MEM；01:MEM/WB）
        fwdA_id_sel = ex_hit_a ? 2'b10 : (mem_hit_a ? 2'b01 : 2'b00);
        fwdB_id_sel = ex_hit_b ? 2'b10 : (mem_hit_b ? 2'b01 : 2'b00);
    end

endmodule

