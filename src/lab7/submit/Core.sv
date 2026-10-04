`include "core_struct.vh"
`include "mem_ift.vh"

module Core (
    input clk,
    input rst,
    input time_int,

    Mem_ift.Master imem_ift,
    Mem_ift.Master dmem_ift,
    output cosim_valid,
    output CorePack::CoreInfo cosim_core_info,
    output CsrPack::CSRPack cosim_csr_info,
    output cosim_interrupt,
    output cosim_switch_mode,
    output CorePack::data_t cosim_cause
);


endmodule
