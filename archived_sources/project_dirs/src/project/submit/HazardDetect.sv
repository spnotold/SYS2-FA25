`include "core_struct.vh"

// HazardDetect — 数据冒险检测单元（纯组合）
// 职责：
//   - 仅负责“检测”是否需要停顿（stall）与向 EX 注入气泡（bubble）；
//   - 实际冻结 PC/IF/ID 与向 ID/EX 注气泡由 Core 内部时序逻辑执行；
//   - 目前覆盖 Load‑Use RAW：EX 阶段为 Load，ID 阶段使用该 rd 作为 rs1/rs2。
// 设计原则：
//   - 不改写段寄存器；
//   - 依赖 ID 阶段译码得到的 uses_rs1/uses_rs2 判定，避免误报（如 JAL 不读 rs1）。

module HazardDetect (
    // 上游可见队列
    input  PipelinePack::IFID   ifid_q,       // ID 视图（用于 valid）
    input  PipelinePack::IDEXE  idex_q,       // EX 视图（用于判定上一条是否为 Load）

    // ID 阶段译码产物（本拍）的关键信号
    input  CorePack::alu_asel_op_enum alu_asel_id, // 是否使用 rs1 作为 ALU A
    input  CorePack::alu_bsel_op_enum alu_bsel_id, // 是否使用 rs2 作为 ALU B
    input  CorePack::cmp_op_enum      cmp_op_id,   // 分支比较操作（分支读 rs1/rs2）
    input  logic                      we_mem_id,   // Store（必读 rs2）
    input  CorePack::reg_ind_t        rs1_id,
    input  CorePack::reg_ind_t        rs2_id,

    // 输出：Core 据此执行冻结/注泡
    output logic if_stall,     // 冻结 PC 与 IF/ID
    output logic bubble_idex   // 向 ID/EX 注入气泡
);
    import CorePack::*;
    import PipelinePack::*;

    // ID 指令是否真的读取 rs1/rs2（避免对 JAL 之类产生误判）
    logic uses_rs1_id;
    logic uses_rs2_id;
    always_comb begin
        uses_rs1_id = (alu_asel_id == ASEL_REG) || (cmp_op_id != CMP_NO) || we_mem_id; // JALR/分支/Store 等读 rs1
        uses_rs2_id = (alu_bsel_id == BSEL_REG) || (cmp_op_id != CMP_NO) || we_mem_id; // 分支/Store/寄存算术读 rs2
    end

    // EX 为 Load 且 rd 命中 ID 的源寄存器 → 需要 1 拍 stall
    logic load_in_ex;
    logic hit_rs1, hit_rs2;
    always_comb begin
        load_in_ex = idex_q.valid && idex_q.re_mem;   // EX 指令是 Load
        hit_rs1    = uses_rs1_id && (idex_q.rd != 5'd0) && (idex_q.rd == rs1_id);
        hit_rs2    = uses_rs2_id && (idex_q.rd != 5'd0) && (idex_q.rd == rs2_id);

        if_stall   = ifid_q.valid && load_in_ex && (hit_rs1 || hit_rs2);
        bubble_idex= if_stall; // 同拍向 EX 注入一个气泡
    end

endmodule

