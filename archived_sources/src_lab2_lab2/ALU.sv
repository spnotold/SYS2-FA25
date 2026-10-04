`include "core_struct.vh"
module ALU (
  input  CorePack::data_t a,
  input  CorePack::data_t b,
  input  CorePack::alu_op_enum  alu_op,
  output CorePack::data_t res
);

  import CorePack::*;

  always_comb begin
    logic [31:0] res32;
    res = 64'bx;
    res32 = 32'bx;

    case (alu_op)
      ALU_ADD:   res = a + b;
      ALU_SUB:   res = a - b;
      ALU_AND:   res = a & b;
      ALU_OR:    res = a | b;
      ALU_XOR:   res = a ^ b;
      ALU_SLL:   res = a << b[5:0];
      ALU_SRL:   res = a >> b[5:0];
      ALU_SRA:   res = $signed(a) >>> b[5:0];
      ALU_SLT:   res = ($signed(a) < $signed(b)) ? 64'd1 : 64'd0;
      ALU_SLTU:  res = (a < b) ? 64'd1 : 64'd0;

      ALU_ADDW: begin
        res32 = a[31:0] + b[31:0];
        res   = {{32{res32[31]}}, res32};
      end
      ALU_SUBW: begin
        res32 = a[31:0] - b[31:0];
        res   = {{32{res32[31]}}, res32};
      end
      ALU_SLLW: begin
        res32 = a[31:0] << b[4:0];
        res   = {{32{res32[31]}}, res32};
      end
      ALU_SRLW: begin
        res32 = a[31:0] >> b[4:0];
        res   = {{32{res32[31]}}, res32};
      end
      ALU_SRAW: begin
        res32 = $signed(a[31:0]) >>> b[4:0];
        res   = {{32{res32[31]}}, res32};
      end

      default:   res = 64'bx;
    endcase
  end

endmodule
