`include "core_struct.vh"

// CsrForwardUnit — CSR 前递选择器（ID 段使用）
// -----------------------------------------------------------------------------
// 目的：解决 CSR 指令之间的 RAW 冒险（同一个 csr_addr 连续被读/改/写）。
//
// 思路和 ForwardUnit.sv 一样：
//   - 仅负责产生“命中判定与选择编码”；
//   - 具体的数据多路选择在 Core.sv 中完成；
//   - 优先级：EX/MEM > MEM/WB > CSRModule(原始读值)。
//
// 注意：
//   - 这里不包含 EX 阶段（IDEXE）前递，原因同 ForwardUnit：
//     Core.sv 会单独对 idex_q 做一层更高优先级的 bypass。
//
// 编码约定（与 ForwardUnit 一致）：
//   00 = 使用 CSRModule 读出的 csr_old（不前递）
//   10 = 前递自 EX/MEM（csr_alu_res）
//   01 = 前递自 MEM/WB（csr_alu_res）
module CsrForwardUnit (
    input  CsrPack::csr_reg_ind_t id_csr_addr,

    input  PipelinePack::EXEMEM    exmem_q,
    input  PipelinePack::MEMWB     memwb_q,

    output logic [1:0]             fwd_csr_id_sel
);
    import PipelinePack::*;

    logic ex_hit;
    logic mem_hit;

    always_comb begin
        // EX/MEM 命中：valid && we_csr && csr_addr 相同
        ex_hit  = (exmem_q.valid && exmem_q.we_csr && (exmem_q.csr_addr == id_csr_addr));
        // MEM/WB 命中：在未命中 EX/MEM 时才生效，保持优先级
        mem_hit = (memwb_q.valid && memwb_q.we_csr && !ex_hit && (memwb_q.csr_addr == id_csr_addr));

        // 编码输出（00:raw；10:EX/MEM；01:MEM/WB）
        fwd_csr_id_sel = ex_hit ? 2'b10 : (mem_hit ? 2'b01 : 2'b00);
    end

endmodule

