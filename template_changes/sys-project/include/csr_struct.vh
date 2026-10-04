`ifndef __CSR_STRUCT__
`define __CSR_STRUCT__

package CsrPack;
    //=============================================================================
    // CSR-ALU 控制信号（用于 CSR 指令计算 CSR_new）
    //-----------------------------------------------------------------------------
    // CSR 指令语义：
    // - csrrw : CSR_new = rs1/zimm（直接写入）
    // - csrrs : CSR_new = CSR_old | (rs1/zimm)
    // - csrrc : CSR_new = CSR_old & ~(rs1/zimm)
    // 其中 CSR_old 是“执行这条 CSR 指令之前 CSR 的旧值”，CSR_new 是“这条指令写入 CSR 的新值”。
    //=============================================================================
    typedef enum logic [1:0] {
        // CSR_new = A + B（在本实验里经常配合 ASEL_CSR0，用作“直通写入”：CSR_new = B）
        CSR_ALU_ADD, CSR_ALU_OR, CSR_ALU_ANDNOT
        // CSR_new = CSR_old | B
        // CSR_new = CSR_old & ~B
    } csr_alu_op_enmu;

    typedef enum logic [1:0] {
        // CSR-ALU 的 A 端选择：
        // - ASEL_CSR0  : A = 0
        // - ASEL_CSRREG: A = CSR_old（当前 CSR 寄存器旧值）
        ASEL_CSR0, ASEL_CSRREG
    } csr_alu_asel_op_enum;

    typedef enum logic [1:0] {
        // CSR-ALU 的 B 端选择：
        // - BSEL_CSR0  : B = 0
        // - BSEL_GPREG : B = rs1（通用寄存器读出的值）
        // - BSEL_CSRIMM: B = zimm（立即数 CSR 指令 inst[19:15]，零扩展）
        BSEL_CSR0,  BSEL_GPREG,  BSEL_CSRIMM
    } csr_alu_bsel_op_enum;

    typedef struct{
        // 是否真的发生异常/中断（有效位）。except=0 时其余字段可忽略。
        logic except;
        // 异常/中断发生时的 PC（会写入 sepc/mepc）。
        logic [63:0] epc;
        // 异常/中断原因码（会写入 scause/mcause）。
        // 一般约定：最高位为 1 表示“中断”，为 0 表示“异常”；低位是具体原因编号。
        logic [63:0] ecause;
        // 附加信息（会写入 stval/mtval），例如非法指令可放指令编码。
        logic [63:0] etval;
    } ExceptPack;

    typedef struct{
        //=============================================================================
        // CSRPack：把 CSRModule 内部的一组关键 CSR/状态信号打包输出（主要给 cosim/波形观察）
        //-----------------------------------------------------------------------------
        // 注意：这些字段里既包含“真实 CSR 的内容”，也包含一些“方便外部观察的派生信号”。
        //=============================================================================
        // -------- S 模式相关 CSR --------
        //
        // 这些寄存器在“陷入/中断/返回”的过程中会被 CSRModule 自动读写：
        // - 陷入 S 态 trap 时：写 sepc/scause/stval，并更新 sstatus 里的 {SIE,SPIE,SPP}
        // - sret 返回时：用 sepc 作为返回 PC，并恢复 sstatus/priv
        //
        // sstatus：S 态状态寄存器（可理解为 mstatus 的一个子集/视图）
        // - SIE  (Supervisor Interrupt Enable)：S 态全局中断使能（开/关“在 S 态是否响应中断”）
        // - SPIE (Supervisor Previous IE)：陷入时保存旧的 SIE，sret 时恢复到 SIE
        // - SPP  (Supervisor Previous Privilege)：陷入前的特权级（U=0/S=1），sret 用它恢复 priv
        // 备注：本实验主要关心的就是这些与“中断开关/返回”有关的位。
        logic [63:0] sstatus;
        //
        // sie：S 态中断“分项使能”寄存器（只控制某一类中断是否允许触发）
        // - SSIE：Supervisor Software Interrupt Enable
        // - STIE：Supervisor Timer Interrupt Enable（本实验最关键：允许 S 态时钟中断）
        // - SEIE：Supervisor External Interrupt Enable
        // 备注：需要同时满足“分项使能 sie” + “全局使能 sstatus.SIE” + “pending(sip)”才会真正触发。
        logic [63:0] sie;
        //
        // stvec：S 态 trap 向量寄存器（陷入 S 态时 CPU 要跳转到哪里）
        // - BASE：trap handler 入口地址基址
        // - MODE：0=Direct（直接跳 BASE），1=Vectored（按 cause 进行向量化跳转）
        // 备注：本实验一般使用 Direct 模式，把 stvec 设为 kernel 的 trap 入口函数地址。
        logic [63:0] stvec;
        //
        // sscratch：S 态 scratch 寄存器（软件自用，不由硬件自动解释）
        // 常见用途：trap handler 用它临时保存指针/栈顶等（比如保存当前 sp 或指向 trap frame 的指针）。
        logic [63:0] sscratch;
        //
        // sepc：S 态 Exception PC（陷入 S 态时保存的返回地址）
        // - trap 发生时由硬件写入（保存“被打断的位置”）
        // - sret 执行时由硬件读出（pc <= sepc 返回）
        logic [63:0] sepc;
        //
        // scause：S 态 cause（陷入原因）
        // - 最高位=1 表示中断，=0 表示异常
        // - 低位是具体原因号（例如 STI=5 表示 Supervisor Timer Interrupt）
        // 备注：本文件下方定义了 STI/MTI/… 等常量（例如 STI = 0x800...0005）。
        logic [63:0] scause;
        //
        // stval：S 态 trap value（附加信息）
        // - 例如：非法指令可放入指令编码；访存异常可放“出错地址”等
        // 本实验里除了 ecall/中断外，其他异常多数不会用到，但接口预留以兼容扩展。
        logic [63:0] stval;
        //
        // sip：S 态 interrupt pending（中断等待/挂起位）
        // - SSIP/STIP/SEIP 等位表示“这类中断已经 pending，等着被响应”
        // 备注：pending 不等于会立即进入中断，还需对应使能位打开。
        logic [63:0] sip;

        // -------- M 模式相关 CSR --------
        //
        // 这些寄存器与 S 态同理，但发生在 M 态 trap / mret 返回路径上：
        // - 陷入 M 态 trap 时：写 mepc/mcause/mtval，并更新 mstatus 里的 {MIE,MPIE,MPP}
        // - mret 返回时：用 mepc 作为返回 PC，并恢复 mstatus/priv
        //
        // mstatus：M 态状态寄存器（全局状态/中断开关/返回信息都在这里）
        // - MIE  (Machine Interrupt Enable)：M 态全局中断使能
        // - MPIE (Machine Previous IE)：陷入时保存旧的 MIE，mret 时恢复到 MIE
        // - MPP  (Machine Previous Privilege)：陷入前的特权级（U/S/M），mret 用它恢复 priv
        logic [63:0] mstatus;
        //
        // mie：M 态中断“分项使能”
        // - MSIE：Machine Software Interrupt Enable
        // - MTIE：Machine Timer Interrupt Enable（本实验里 time_int 对应的 pending 位是 MTIP）
        // - MEIE：Machine External Interrupt Enable
        logic [63:0] mie;
        //
        // mtvec：M 态 trap 向量寄存器（陷入 M 态时跳转目标）
        // 用法与 stvec 类似：BASE + MODE（Direct/Vectored）。
        logic [63:0] mtvec;
        //
        // mscratch：M 态 scratch（软件自用）
        // 常见用途：M 态 trap handler 临时保存指针/栈顶。
        logic [63:0] mscratch;
        //
        // mepc：M 态 Exception PC（陷入 M 态时保存返回地址，mret 用它返回）
        logic [63:0] mepc;
        //
        // mcause：M 态 cause（陷入原因，格式同 scause）
        logic [63:0] mcause;
        //
        // mtval：M 态 trap value（附加信息，格式同 stval）
        logic [63:0] mtval;
        //
        // mip：M 态 interrupt pending（中断等待/挂起位）
        // - MSIP/MTIP/MEIP 等位表示“这类中断 pending”
        // 本实验里：time_int 会驱动 MTIP（即“机器时钟中断 pending”）。
        logic [63:0] mip;

        // -------- 委托/托管 CSR --------
        // medeleg：异常委托（哪些异常从 M 委托给 S 处理）
        // mideleg：中断委托（哪些中断从 M 委托给 S 处理）
        logic [63:0] medeleg;
        logic [63:0] mideleg;
        
        // -------- 方便外部观察的控制/状态（不是标准 CSR 本体字段）--------
        // 当前特权级（项目内编码常见为：M=2'b11，S=2'b01，U=2'b00；这里打包成 64b 便于观察）
        logic [63:0] priv;
        // CSRModule 判定发生 trap/ret 时拉高：提示 Core 需要清空流水线并跳转
        logic [63:0] switch_mode;
        // trap/ret 时应跳转到的地址（mtvec/stvec/mepc/sepc 之一）
        logic [63:0] pc_csr;
        // cosim 相关观测值（用于让仿真器(spike)“屈从于”DUT 的 trap 行为，保持指令流一致）
        logic [63:0] cosim_epc;
        logic [63:0] cosim_cause;
        logic [63:0] cosim_tval;
        // 返回指令信息（例如 sret/mret 的编码），便于外部观察
        logic [63:0] csr_ret;
    } CSRPack;
    
    typedef logic [11:0] csr_reg_ind_t;

    parameter CSR_OPCODE    = 7'b1110011;

    parameter CSRRW_FUNCT3 =   3'b001;
    parameter CSRRS_FUNCT3 =   3'b010;
    parameter CSRRC_FUNCT3 =   3'b011;
    parameter CSRRWI_FUNCT3 =  3'b101;
    parameter CSRRSI_FUNCT3 =  3'b110;
    parameter CSRRCI_FUNCT3 =  3'b111;

    parameter TIME_BASE = 64'h2000000;
    parameter TIME_LEN = 64'h10000;
    parameter MTIME_BASE = 64'h200bff8;
    parameter MTIME_LEN = 64'h8;
    parameter MTIMECMP_BASE = 64'h2004000;
    parameter MTIMECMP_LEN = 64'h8;
    parameter DISP_BASE = 64'h3000000;
    parameter DISP_LEN = 64'h1;
    parameter UART_BASE = 64'h4000000;
    parameter UART_LEN = 64'h10;

    parameter ROM_BASE = 64'h0;
    parameter ROM_LEN = 64'h1000;
    parameter BUFFER_BASE = 64'h10000;
    parameter BUFFER_LEN = 64'h4000;
    parameter MEM_BASE = 64'h80000000;
    parameter MEM_LEN = 64'h80000000;

    parameter USI = 64'h8000000000000000;
    parameter SSI = 64'h8000000000000001;
    parameter HSI = 64'h8000000000000002;
    parameter MSI = 64'h8000000000000003;
    parameter UTI = 64'h8000000000000004;
    parameter STI = 64'h8000000000000005;
    parameter HTI = 64'h8000000000000006;
    parameter MTI = 64'h8000000000000007;
    parameter UEI = 64'h8000000000000008;
    parameter SEI = 64'h8000000000000009;
    parameter HEI = 64'h800000000000000a;
    parameter MEI = 64'h800000000000000b;
    parameter INST_ADDR_UNALIGN =  64'h0;
    parameter INST_ACCESS_FAULT =  64'h1;
    parameter ILLEAGAL_INST =      64'h2;
    parameter BREAKPOINT =         64'h3;
    parameter LOAD_ADDR_UNALIGN =  64'h4;
    parameter LOAD_ACCESS_FAULT =  64'h5;
    parameter STORE_ADDR_UNALIGN = 64'h6;
    parameter STORE_ACCESS_FAULT = 64'h7;
    parameter U_CALL = 64'h8;
    parameter S_CALL = 64'h9;
    parameter H_CALL = 64'ha;
    parameter M_CALL = 64'hb;

    parameter ECALL = 32'h00000073;
    parameter EBREAK = 32'h00100073;

    parameter MRET =  32'h30200073;
    parameter SRET =  32'h10200073;

    parameter SSTATUS =  12'h100;
    parameter SIE     =  12'h104;
    parameter STVEC   =  12'h105;
    parameter SSCRATCH = 12'h140;
    parameter SEPC    =  12'h141;
    parameter SCAUSE  =  12'h142;
    parameter STVAL   =  12'h143;
    parameter SIP     =  12'h144;

    parameter SSTATUS_COMPRESS =  5'b00000;
    parameter SIE_COMPRESS     =  5'b00100;
    parameter STVEC_COMPRESS   =  5'b00101;
    parameter SSCRATCH_COMPRESS = 5'b01000;
    parameter SEPC_COMPRESS    =  5'b01001;
    parameter SCAUSE_COMPRESS  =  5'b01010;
    parameter STVAL_COMPRESS   =  5'b01011;
    parameter SIP_COMPRESS     =  5'b01100;

    parameter MSTATUS  = 12'h300;
    parameter MEDELEG  = 12'h302;
    parameter MIDELEG  = 12'h303;
    parameter MIE      = 12'h304;
    parameter MTVEC    = 12'h305;
    parameter MSCRATCH = 12'h340;
    parameter MEPC     = 12'h341;
    parameter MCAUSE   = 12'h342;
    parameter MTVAL    = 12'h343;
    parameter MIP      = 12'h344;

    parameter MSTATUS_COMPRESS = 5'b10000;
    parameter MEDELEG_COMPRESS = 5'b10010;
    parameter MIDELEG_COMPRESS = 5'b10011;
    parameter MIE_COMPRESS     = 5'b10100;
    parameter MTVEC_COMPRESS   = 5'b10101;
    parameter MSCRATCH_COMPRESS= 5'b11000;
    parameter MEPC_COMPRESS    = 5'b11001;
    parameter MCAUSE_COMPRESS  = 5'b11010;
    parameter MTVAL_COMPRESS   = 5'b11011;
    parameter MIP_COMPRESS     = 5'b11100;
endpackage

`endif 
