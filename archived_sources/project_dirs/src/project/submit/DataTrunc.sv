`include "core_struct.vh"

module DataTrunc (
    input CorePack::data_t dmem_rdata,       // 从内存读取的64位原始数据
    input CorePack::mem_op_enum mem_op,      // 内存操作类型
    input CorePack::addr_t dmem_raddr,       // 读取内存的地址
    output CorePack::data_t read_data        // 截断并扩展后的数据
);

  import CorePack::*;

  // 根据加载类型与地址低位，从 64b 返回值中取段，并按有/无符号扩展
  always_comb begin
    unique case (mem_op)
      MEM_D: begin
        read_data = dmem_rdata;
      end
      MEM_W: begin
        case(dmem_raddr[2])
          1'b0: read_data = {{32{dmem_rdata[31]}}, dmem_rdata[31:0]};
          1'b1: read_data = {{32{dmem_rdata[63]}}, dmem_rdata[63:32]};
        endcase
      end
      MEM_UW: begin
        case(dmem_raddr[2])
          1'b0: read_data = {32'b0, dmem_rdata[31:0]};
          1'b1: read_data = {32'b0, dmem_rdata[63:32]};
        endcase
      end
      MEM_H: begin
        case(dmem_raddr[2:1])
          2'b00: read_data = {{48{dmem_rdata[15]}}, dmem_rdata[15:0]};
          2'b01: read_data = {{48{dmem_rdata[31]}}, dmem_rdata[31:16]};
          2'b10: read_data = {{48{dmem_rdata[47]}}, dmem_rdata[47:32]};
          2'b11: read_data = {{48{dmem_rdata[63]}}, dmem_rdata[63:48]};
        endcase
      end
      MEM_UH: begin
        case(dmem_raddr[2:1])
          2'b00: read_data = {48'b0, dmem_rdata[15:0]};
          2'b01: read_data = {48'b0, dmem_rdata[31:16]};
          2'b10: read_data = {48'b0, dmem_rdata[47:32]};
          2'b11: read_data = {48'b0, dmem_rdata[63:48]};
        endcase
      end
      MEM_B: begin
        case(dmem_raddr[2:0])
          3'b000: read_data = {{56{dmem_rdata[7]}}, dmem_rdata[7:0]};
          3'b001: read_data = {{56{dmem_rdata[15]}}, dmem_rdata[15:8]};
          3'b010: read_data = {{56{dmem_rdata[23]}}, dmem_rdata[23:16]};
          3'b011: read_data = {{56{dmem_rdata[31]}}, dmem_rdata[31:24]};
          3'b100: read_data = {{56{dmem_rdata[39]}}, dmem_rdata[39:32]};
          3'b101: read_data = {{56{dmem_rdata[47]}}, dmem_rdata[47:40]};
          3'b110: read_data = {{56{dmem_rdata[55]}}, dmem_rdata[55:48]};
          3'b111: read_data = {{56{dmem_rdata[63]}}, dmem_rdata[63:56]};
        endcase
      end
      MEM_UB: begin
        case(dmem_raddr[2:0])
          3'b000: read_data = {56'b0, dmem_rdata[7:0]};
          3'b001: read_data = {56'b0, dmem_rdata[15:8]};
          3'b010: read_data = {56'b0, dmem_rdata[23:16]};
          3'b011: read_data = {56'b0, dmem_rdata[31:24]};
          3'b100: read_data = {56'b0, dmem_rdata[39:32]};
          3'b101: read_data = {56'b0, dmem_rdata[47:40]};
          3'b110: read_data = {56'b0, dmem_rdata[55:48]};
          3'b111: read_data = {56'b0, dmem_rdata[63:56]};
        endcase
      end
      default: read_data = '0;
    endcase
  end
endmodule
