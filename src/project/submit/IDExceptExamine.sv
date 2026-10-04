/*
作用就是把“这条指令是否触发异常/异常三要素是什么”在 ID 就算出来，然后像流水线寄存器一样往后带到 EX（再继续往 WB 传，最后交给 CSRModule 处理）。

分两部分看：

InstExamine
输入：pc_i / priv_i / inst_i / valid_i
输出：except_o（一个 ExceptPack，包含 except/epc/ecause/etval）
本实验主要检查：
ecall：按当前特权级生成不同的 ecall cause
ebreak
非法指令（这里用 inst_i[1:0] != 2'b11 简化判断）
IDExceptExamine 顶层
先用 InstExamine 得到本条指令的新异常 except_new
再把它和上游传进来的 except_id 做合并：except_id 已经有异常就优先用它，
否则用 except_new
（兼容更复杂的异常链路：前面模块也能先产生异常）
except_happen_id 用来告诉外面“本拍 ID 刚刚新产生了异常”
最后通过内部的 ExceptReg 把异常信息寄存一拍，
输出到 except_exe（相当于 ID→EX 的异常流水寄存器）
*/





`include "core_struct.vh"
`include "csr_struct.vh"

module IDExceptExamine(
    input clk,
    input rst,
    input stall,
    input flush,

    input CorePack::addr_t pc_id,
    input [1:0] priv,
    input CorePack::inst_t inst_id,
    input valid_id,
    
    input CsrPack::ExceptPack except_id,
    output CsrPack::ExceptPack except_exe,
    output except_happen_id
);
    
    import CsrPack::ExceptPack;
    ExceptPack except_new;
    ExceptPack except;

    InstExamine instexmaine(
        .pc_i(pc_id),
        .priv_i(priv),
        .inst_i(inst_id),
        .valid_i(valid_id),
        .except_o(except_new)
    );

    assign except=except_id.except?except_id:except_new;
    assign except_happen_id=except_new.except&~except_id.except;

    ExceptReg exceptreg(
        .clk(clk),
        .rst(rst),
        .stall(stall),
        .flush(flush),
        .except_i(except),
        .except_o(except_exe)
    );

endmodule 

module InstExamine (
    input CorePack::addr_t pc_i,
    input [1:0] priv_i,
    input CorePack::inst_t inst_i,
    input valid_i,
    output CsrPack::ExceptPack except_o
);
    import CsrPack::*;
    
    wire is_ecall=inst_i==ECALL;
    wire is_ebreak=inst_i==EBREAK;
    wire is_illegal=(inst_i[1:0]!=2'b11)&valid_i;

    wire [63:0] ecall_code [3:0];
    assign ecall_code[0]=U_CALL;
    assign ecall_code[1]=S_CALL;
    assign ecall_code[2]=H_CALL;
    assign ecall_code[3]=M_CALL;

    assign except_o.except=is_ebreak|is_ecall|is_illegal;
    assign except_o.epc=pc_i;
    assign except_o.ecause=is_ebreak?BREAKPOINT:
                           is_ecall?ecall_code[priv_i]:
                           is_illegal?ILLEAGAL_INST:
                           64'h0;
    assign except_o.etval=is_illegal?{32'b0,inst_i}:64'h0;
    
endmodule
