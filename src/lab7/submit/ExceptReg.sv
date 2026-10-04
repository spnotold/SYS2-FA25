/*
ExceptReg.sv 就是一个“异常信息的流水线寄存器”。
except_i/except_o 是一个结构体 ExceptPack
（里面打包了 except 标志、epc、ecause、etval）。
作用：把 ID 阶段检测到的异常信息（比如 ecall）像普通流水线寄存器那样 
一拍一拍往后传，最终送到 WB 阶段交给 CSRModule 统一处理
（写 xepc/xcause/xtval、产生 switch_mode/pc_csr）。
stall=1 时保持不变（跟着流水线停住）。
flush=1 或 rst=1 时清零（把异常信息变成“气泡”，避免错路径/被清空的指令还触发异常）。
*/

`include "csr_struct.vh"
module ExceptReg(
    input clk,
    input rst,
    input stall,
    input flush,
    input CsrPack::ExceptPack except_i,
    output CsrPack::ExceptPack except_o
);
    import CsrPack::ExceptPack;
    ExceptPack except;    

    always_ff @(posedge clk)begin
        if(rst|flush)begin
            except<='{except:1'b0,epc:64'b0,ecause:64'h0,etval:64'h0};
        end else if(~stall)begin
            except<=except_i;
        end
    end

    assign except_o=except;
    
endmodule
