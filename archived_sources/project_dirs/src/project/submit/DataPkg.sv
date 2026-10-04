`include "core_struct.vh"

module DataPkg(
    input CorePack::mem_op_enum mem_op,      // 内存操作类型
    input CorePack::data_t reg_data,         // 来自寄存器的原始数据
    input CorePack::addr_t dmem_waddr,       // 写入地址
    output CorePack::data_t dmem_wdata       // 打包后写入的数据
);

  import CorePack::*;

  // 根据存储类型和地址低位，将写数据对齐到相应字节段
  always_comb begin
    dmem_wdata = '0;  // 默认清零
    case(mem_op)
      MEM_D: begin
        dmem_wdata = reg_data;
      end
      MEM_W: begin
        case (dmem_waddr[2])
          1'b0: dmem_wdata[31:0]  = reg_data[31:0];
          1'b1: dmem_wdata[63:32] = reg_data[31:0];
        endcase
      end
      MEM_H: begin
        case (dmem_waddr[2:1])
          2'b00: dmem_wdata[15:0]  = reg_data[15:0];
          2'b01: dmem_wdata[31:16] = reg_data[15:0];
          2'b10: dmem_wdata[47:32] = reg_data[15:0];
          2'b11: dmem_wdata[63:48] = reg_data[15:0];
        endcase
      end
      MEM_B: begin
        case (dmem_waddr[2:0])
          3'b000: dmem_wdata[7:0]   = reg_data[7:0];
          3'b001: dmem_wdata[15:8]  = reg_data[7:0];
          3'b010: dmem_wdata[23:16] = reg_data[7:0];
          3'b011: dmem_wdata[31:24] = reg_data[7:0];
          3'b100: dmem_wdata[39:32] = reg_data[7:0];
          3'b101: dmem_wdata[47:40] = reg_data[7:0];
          3'b110: dmem_wdata[55:48] = reg_data[7:0];
          3'b111: dmem_wdata[63:56] = reg_data[7:0];
        endcase
      end
      default: dmem_wdata = '0;
    endcase
  end
endmodule
