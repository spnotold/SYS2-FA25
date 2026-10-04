`include "core_struct.vh"

module MaskGen(
    input CorePack::mem_op_enum mem_op,      // 内存操作类型
    input CorePack::addr_t dmem_waddr,       // 写入内存的地址
    output CorePack::mask_t dmem_wmask       // 写入掩码（8位，每位对应一个字节）
);

  import CorePack::*;

  // 根据存储类型和地址低位，生成字节写使能掩码
  always_comb begin
    dmem_wmask = 8'b00000000;  // 默认不写
    case (mem_op)
      MEM_B: begin
        case (dmem_waddr[2:0])
          3'b000: dmem_wmask = 8'b00000001;
          3'b001: dmem_wmask = 8'b00000010;
          3'b010: dmem_wmask = 8'b00000100;
          3'b011: dmem_wmask = 8'b00001000;
          3'b100: dmem_wmask = 8'b00010000;
          3'b101: dmem_wmask = 8'b00100000;
          3'b110: dmem_wmask = 8'b01000000;
          3'b111: dmem_wmask = 8'b10000000;
        endcase
      end
      MEM_H: begin
        case (dmem_waddr[2:1])
          2'b00: dmem_wmask = 8'b00000011;
          2'b01: dmem_wmask = 8'b00001100;
          2'b10: dmem_wmask = 8'b00110000;
          2'b11: dmem_wmask = 8'b11000000;
        endcase
      end
      MEM_W: begin
        case (dmem_waddr[2])
          1'b0: dmem_wmask = 8'b00001111;
          1'b1: dmem_wmask = 8'b11110000;
        endcase
      end
      MEM_D: begin
        dmem_wmask = 8'b11111111;
      end
      default: dmem_wmask = 8'b00000000;
    endcase
  end
endmodule
