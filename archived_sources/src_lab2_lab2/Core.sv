`include "core_struct.vh"
module Core (
    input clk,
    input rst,

    Mem_ift.Master imem_ift,
    Mem_ift.Master dmem_ift,

    output cosim_valid,
    output CorePack::CoreInfo cosim_core_info
);
    import CorePack::*;
    import PipelinePack::*; // 引入流水段结构体定义
    
    //=============================================================================
    // 顶层说明
    //-----------------------------------------------------------------------------
    // 这份 Core 实现的是一个“无stall”的五级流水线（IF/ID/EX/MEM/WB）：
    // - 取指/访存总线遵循 ready-valid 握手；我们选择“持续发起请求”，通过段间寄存器
    //   的天然一拍延迟来吸收握手延迟。
    // - 控制流采用“EX 判定 + flush”的方式：
    //     * 当 EX 判定分支/跳转采纳时（take_redirect_ex=1），当拍清空 ID/EX（气泡），
    //       并在当拍与下一拍两拍内清空 IF/ID（覆盖错路径回复）。
    //     * next_pc 在 EX 组合产生（jalr 目标按规范清低位）。
    // - 依靠 valid/flush 管控错路径：当 EX 发生重定向时，ID/EX 当拍清空、IF/ID 连续两拍
    //   清空，错误路径的指令不会进入后续阶段或被提交。
    // - 提交（cosim）：以 MEM/WB.valid 为基准触发，加入最小限度的 {pc,inst} 去重。
    //-----------------------------------------------------------------------------
    // 下面的代码按流水级（IF/ID/EX/MEM/WB）分块组织，每段前都有行为说明；
    //=============================================================================
    
    // PC相关信号
    CorePack::addr_t pc;                    // 当前PC值
    CorePack::addr_t next_pc;               // 计算得到的下一个PC的值
    
    // IF阶段信号
    CorePack::data_t inst_raw_from_imem;   // 从内存读回的 64 位指令线
    CorePack::inst_t inst;                 // 对应 32 位指令
    CorePack::addr_t pc_req_q;             // “本次请求发出时”的 PC（与回复对齐）
    // 段间寄存器：IF/ID（结构体自带 valid 字段）
    PipelinePack::IFID ifid_q;             // IF/ID 当前值
    logic flush_ifid;                      // 由 EX 重定向驱动的 IF/ID 清空
    /*
     * flush_ifid 机制：当 EX 采纳了控制流改变（分支/跳转）时：
     *   - 当拍（T）与下一拍（T+1）均把 IF/ID.valid 清零（两拍覆盖），
     *     这样不论错路径回复到达 T 还是 T+1，ID 看到的都是“气泡”。
     */

    // IF/ID 写入策略：仅在 IMEM 回复 fire 当拍装入；其余拍输出气泡；在 stall 时保持不变
    wire imem_reply_fire = core_imem.r_reply_valid & core_imem.r_reply_ready;
    // 时序：T 发请求 → T+1 收到回复并装入 IF/ID（pc/inst/pc4）
    // flush 优先：若 T 或 T+1 正处于重定向覆盖窗口，直接输出气泡
    // imem_reply_fire 已在顶部声明（用于 IF/ID 装载）
    // 读/写回复握手（总线侧）与 MEM2 状态观测
    wire dmem_reply_fire = (dmem_ift.r_reply_valid & dmem_ift.r_reply_ready)
                        | (dmem_ift.w_reply_valid & dmem_ift.w_reply_ready);
    wire state_mem2 = (ifmem_fsm_state == 3'd6);

    // 为在 MEM2 末拍回填 IF/ID，缓存上一条 imem 回复的指令
    CorePack::inst_t if_imem_inst_latched;
    always_ff @(posedge clk) begin
        if (rst) begin
            if_imem_inst_latched <= '0;
        end else if (imem_reply_fire) begin
            if_imem_inst_latched <= inst32_reply;
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            ifid_q.valid <= 1'b0;
        end else if (flush_ifid) begin
            ifid_q.valid <= 1'b0; // 错路径：清空为气泡
        end else if (mem_stall || if_stall_hzd) begin
            // 在数据冒险导致的 stall 时，IF/ID 保持不变
            ifid_q <= ifid_q;
        end else if (imem_reply_fire) begin
            ifid_q.pc    <= pc_req_q;
            ifid_q.pc_4  <= pc_req_q + 64'd4;
            ifid_q.inst  <= inst32_reply;
            ifid_q.valid <= 1'b1;      // 仅在 fire 当拍置 1
        end else if (dmem_reply_fire && state_mem2) begin
            // 在 MEM2 末拍释放 mem_stall 的同时，若上一次取指已返回，则回填 IF/ID
            ifid_q.pc    <= pc_req_q;
            ifid_q.pc_4  <= pc_req_q + 64'd4;
            ifid_q.inst  <= if_imem_inst_latched;
            ifid_q.valid <= 1'b1;
        end else begin
            ifid_q.valid <= 1'b0;      // 无新回复 → 输出气泡
        end
    end

    // ID阶段信号 - 控制信号
    logic we_reg_ctrl, we_mem_ctrl, re_mem_ctrl, npc_sel_ctrl;
    CorePack::imm_op_enum immgen_op_ctrl;
    CorePack::alu_op_enum alu_op_ctrl;
    CorePack::cmp_op_enum cmp_op_ctrl;
    CorePack::alu_asel_op_enum alu_asel_ctrl;
    CorePack::alu_bsel_op_enum alu_bsel_ctrl;
    CorePack::wb_sel_op_enum wb_sel_ctrl;
    CorePack::mem_op_enum mem_op_ctrl;
    
    // ID阶段信号 - 立即数和寄存器
    CorePack::data_t imm_val_internal;
    CorePack::reg_ind_t rs1_addr_internal;
    CorePack::reg_ind_t rs2_addr_internal;
    CorePack::reg_ind_t rd_addr_internal;
    CorePack::data_t rs1_data_internal;
    CorePack::data_t rs2_data_internal;
    
    // 段间寄存器：ID/EX（作为 ID→EX 的“buffer”）
    PipelinePack::IDEXE idex_q;  // 当前拍 EX 看到的值
    PipelinePack::IDEXE idex_d;  // 下一拍要写入的值
    logic flush_idex;            // ID/EX flush：在 EX 重定向那拍清空 ID→EX

    // 段间寄存器：EX/MEM（作为 EX→MEM 的“buffer”）
    PipelinePack::EXEMEM exmem_q;  // 当前拍 MEM 看到的值
    PipelinePack::EXEMEM exmem_d;  // 下一拍要写入的值
    
    // EX阶段信号
    CorePack::data_t alu_in_a;
    CorePack::data_t alu_in_b;
    CorePack::data_t alu_res_internal;
    logic cmp_res_internal;
    wire is_branch_instruction;
    logic br_taken_internal;
    
    // MEM阶段信号
    CorePack::data_t dmem_rdata_raw_internal;  // 从dmem读出的原始64位数据
    CorePack::data_t data_from_mem_final;      // 经过DataTrunc处理后的数据，用于写回
    CorePack::data_t data_to_dmem_packaged;    // 经过DataPkg处理后，准备写入dmem的数据
    CorePack::mask_t dmem_write_mask;          // 写入dmem时的字节掩码
    
    // WB阶段信号
    CorePack::data_t wb_data_internal;         // 最终写回寄存器的数据
    
    // CoSim驱动信号
    CorePack::reg_ind_t rs1, rs2, rd;
    CorePack::data_t read_data_1, read_data_2, alu_res;
    logic we_reg;
    CorePack::data_t wb_val;
    logic br_taken;
    // 冒险与停顿
    logic if_stall;        // 最终 if_stall = 总线 IF 停顿 OR 数据冒险停顿
    logic if_stall_hzd;    // 数据冒险导致的 if_stall（用于向 EX 注入气泡）
    logic if_stall_bus;    // 总线取指导致的 if_stall（冻结 PC/IFID）
    logic mem_stall;       // 总线 MEM 停顿（冻结 PC/IFID/IDEXE/EXEMEM 且 flush MEMWB）
    logic bubble_idex;


    //=============================================================================
    // IF阶段 - 指令获取
    //=============================================================================
    // 内部 mem_ift 接口（Core 侧），由 IFMemFSM 门控后连接到顶层端口
    Mem_ift core_imem();
    Mem_ift core_dmem();
    // PC寄存器
    // 我们“持续发起取指请求”。为保证 64b 指令线的半字选择正确，使用 pc_req_q
    // 锁存“本次真正发出请求时”的 PC；下一拍按 pc_req_q[2] 选择高/低 32 位。
    wire imem_request_fire = core_imem.r_request_valid & core_imem.r_request_ready;
    always_ff @(posedge clk) begin
        if(rst) begin
            pc <= 64'h0; // pc 被复位
            pc_req_q <= 64'h0;
        end
        else begin
            if (imem_request_fire) begin
                pc_req_q <= pc;    // 仅在请求 fire 时记录本拍 PC
            end
            // 重定向优先：即使发生 stall 也要更新 PC
            if (take_redirect_ex) begin
                pc <= next_pc;
            end else if (!if_stall_bus && !mem_stall && !if_stall_hzd) begin
                pc <= next_pc;     // 正常推进 PC
            end
            // 在 if_stall=1 或 mem_stall=1 时冻结 PC，保持地址稳定
        end
    end

    // 连接指令存储器接口（Core 侧），由 IFMemFSM 门控后接到顶层 imem_ift
    assign core_imem.r_request_bits.raddr = pc;  // 直接使用 PC
    // 持续取指请求：简化握手，在 IF/ID 装载与 flush 处确保正确性
    assign core_imem.r_request_valid = 1'b1; 
    // 回复接收 ready：始终拉高；错路径回复由 IF/ID 的 flush_ifid 在装载处丢弃
    assign core_imem.r_reply_ready = 1'b1; 
    assign inst_raw_from_imem = core_imem.r_reply_bits.rdata;

    // 根据“发起该次请求时的 PC”选择高/低 32 位，确保与握手对齐
    wire [31:0] inst32_reply = pc_req_q[2] ? inst_raw_from_imem[63:32] : inst_raw_from_imem[31:0];
    assign inst = inst32_reply;


    //=============================================================================
    // ID阶段 - 指令译码
    //=============================================================================
    // ID 视图：从 IF/ID 段寄存器里拿“上一拍取回”的三元组
    CorePack::inst_t inst_id;           // 本拍要译码的指令
    CorePack::addr_t pc_id, pc4_id;     // 这条指令对应的 PC / PC+4
    assign inst_id = ifid_q.inst;       // 用 IF/ID 的输出
    assign pc_id   = ifid_q.pc;
    assign pc4_id  = ifid_q.pc_4;
    // 实例化控制器
    controller u_controller (
        .inst(inst_id), 
        .we_reg(we_reg_ctrl),
        .we_mem(we_mem_ctrl),
        .re_mem(re_mem_ctrl),
        .npc_sel(npc_sel_ctrl),
        .immgen_op(immgen_op_ctrl),
        .alu_op(alu_op_ctrl),
        .cmp_op(cmp_op_ctrl),
        .alu_asel(alu_asel_ctrl),
        .alu_bsel(alu_bsel_ctrl),
        .wb_sel(wb_sel_ctrl),
        .mem_op(mem_op_ctrl)
    );
    /*
     * npc_sel 的来源与时序：
     * - 由 Controller（ID 阶段）在译码时生成，jal/jalr/branch 为 1。
     * - 当拍打入 ID/EX（idex_q.npc_sel），下一拍在 EX 使用。
     */

    // 实例化立即数生成器
    ImmGen u_imm_gen (
        .inst(inst_id),                 
        .imm_op(immgen_op_ctrl),     
        .imm_out(imm_val_internal)
    );



    // 提取寄存器索引：用 ID 视图的指令编码
    assign rs1_addr_internal = inst_id[19:15];
    assign rs2_addr_internal = inst_id[24:20];
    assign rd_addr_internal  = inst_id[11:7];

    // 实例化寄存器堆（写回应在 WB 门控）
    RegFile u_reg_file (
        .clk(clk),
        .rst(rst),
        .we(memwb_q.we_reg && memwb_q.valid && (memwb_q.rd != 5'd0)),
        .read_addr_1(rs1_addr_internal),
        .read_addr_2(rs2_addr_internal),
        .write_addr(memwb_q.rd),
        .write_data(wb_data_internal), 
        .read_data_1(rs1_data_internal),
        .read_data_2(rs2_data_internal)
    );

    //========================
    // ID 段前递选择器（仅输出选择编码）
    //========================
    logic [1:0] fwdA_id_sel, fwdB_id_sel;
    ForwardUnit u_fwd_id (
        .id_rs1(rs1_addr_internal),
        .id_rs2(rs2_addr_internal),
        .exmem_q(exmem_q),
        .memwb_q(memwb_q),
        .fwdA_id_sel(fwdA_id_sel),
        .fwdB_id_sel(fwdB_id_sel)
    );

    // 规约 EX/MEM 的可前递值（ALU 或 PC+4；Load 不会被选择器选中）
    CorePack::data_t exmem_fwd_val;
    always_comb begin
        unique case (exmem_q.wb_sel)
            WB_SEL_ALU: exmem_fwd_val = exmem_q.alu_res;
            WB_SEL_PC:  exmem_fwd_val = exmem_q.pc_4;
            default:    exmem_fwd_val = 64'bx;
        endcase
    end
    // 规约 EX（上一条）可前递值：ALU 或 PC+4；Load（re_mem）不可用于当拍前递
    CorePack::data_t ex_fwd_val;
    logic ex_hit_a, ex_hit_b;
    always_comb begin
        unique case (idex_q.wb_sel)
            WB_SEL_ALU: ex_fwd_val = alu_res_internal;
            WB_SEL_PC:  ex_fwd_val = idex_q.pc_4;
            default:    ex_fwd_val = 64'bx;
        endcase
        ex_hit_a = (idex_q.valid && idex_q.we_reg && (idex_q.rd != 5'd0) && !idex_q.re_mem && (idex_q.rd == rs1_addr_internal));
        ex_hit_b = (idex_q.valid && idex_q.we_reg && (idex_q.rd != 5'd0) && !idex_q.re_mem && (idex_q.rd == rs2_addr_internal));
    end

    // 两路 3 选 1：用选择编码在 RegFile/EXMEM/MEMWB 之间选择，写入 ID/EX
    CorePack::data_t id_fwd_rs1_val, id_fwd_rs2_val;
    always_comb begin
        // EX 优先，其次 EX/MEM，再次 MEM/WB，最后 RegFile
        if (ex_hit_a) id_fwd_rs1_val = ex_fwd_val;
        else begin
            case (fwdA_id_sel)
                2'b10: id_fwd_rs1_val = exmem_fwd_val;
                2'b01: id_fwd_rs1_val = wb_data_internal; // MEM/WB 最终写回（含 Load）
                default: id_fwd_rs1_val = rs1_data_internal;
            endcase
        end
        if (ex_hit_b) id_fwd_rs2_val = ex_fwd_val;
        else begin
            case (fwdB_id_sel)
                2'b10: id_fwd_rs2_val = exmem_fwd_val;
                2'b01: id_fwd_rs2_val = wb_data_internal;
                default: id_fwd_rs2_val = rs2_data_internal;
            endcase
        end
    end


    //========================
    // HazardDetect（load‑use 等无法前递的 RAW）
    //========================
    // 声明已在前文加入
    logic id_use_rs1, id_use_rs2;
    // 基于译码信号推导“本条指令是否实际使用 rs1/rs2”
    always_comb begin
        id_use_rs1 = 1'b0;
        id_use_rs2 = 1'b0;
        // ALU 源使用
        if (alu_asel_ctrl == ASEL_REG) id_use_rs1 = 1'b1;
        if (alu_bsel_ctrl == BSEL_REG) id_use_rs2 = 1'b1;
        // 分支比较使用 rs1/rs2
        if (cmp_op_ctrl != CMP_NO) begin id_use_rs1 = 1'b1; id_use_rs2 = 1'b1; end
        // load/store 的地址需要 rs1；store 的写数据需要 rs2
        if (re_mem_ctrl || we_mem_ctrl) id_use_rs1 = 1'b1;
        if (we_mem_ctrl) id_use_rs2 = 1'b1;
        // JALR 使用 rs1（已由 ASEL_REG 覆盖，这里冗余保障）
        if (npc_sel_ctrl && (inst_id[6:0] == JALR_OPCODE)) id_use_rs1 = 1'b1;
    end

    HazardDetect u_hzd (
        .ifid_q(ifid_q),
        .idex_q(idex_q),
        .alu_asel_id(alu_asel_ctrl),
        .alu_bsel_id(alu_bsel_ctrl),
        .cmp_op_id(cmp_op_ctrl),
        .we_mem_id(we_mem_ctrl),
        .rs1_id(rs1_addr_internal),
        .rs2_id(rs2_addr_internal),
        .if_stall(if_stall_hzd),
        .bubble_idex(bubble_idex)
    );

    // IF/MEM 门控状态机：负责在 IF/MEM 冲突下进行握手时序管理与 stall 产生
    logic [2:0] ifmem_fsm_state;
    IFMemFSM u_ifmemfsm (
        .clk(clk),
        .rst(rst),
        .core_imem(core_imem),
        .core_dmem(core_dmem),
        .bus_imem(imem_ift),
        .bus_dmem(dmem_ift),
        .if_stall(if_stall_bus),
        .mem_stall(mem_stall),
        .fsm_state(ifmem_fsm_state)
    );

    // 最终 if_stall：数据冒险 if_stall 与 总线 if_stall 的或
    assign if_stall = if_stall_hzd | if_stall_bus;

    // ID/EX d 路组合逻辑（fire：上游有新数据才推进）
    // 仅当 IF/ID 本拍 valid=1 时推进；否则输出气泡。
    always_comb begin
        idex_d = idex_q;                  // 默认保持
        if (flush_idex) begin
            idex_d.valid = 1'b0;          // 变气泡
        end else if (if_stall_hzd) begin
            // 数据冒险：当拍向 EX 注入气泡（冻结 ID/IF 见上文）
            idex_d.valid = 1'b0;
        end else begin
            if (ifid_q.valid) begin
                    // 控制
                    idex_d.we_reg    = we_reg_ctrl;
                    idex_d.we_mem    = we_mem_ctrl;
                    idex_d.re_mem    = re_mem_ctrl;
                    idex_d.npc_sel   = npc_sel_ctrl;
                    idex_d.imm       = imm_val_internal;
                    idex_d.alu_op    = alu_op_ctrl;
                    idex_d.cmp_op    = cmp_op_ctrl;
                    idex_d.alu_a_sel = alu_asel_ctrl;
                    idex_d.alu_b_sel = alu_bsel_ctrl;
                    idex_d.wb_sel    = wb_sel_ctrl;
                    idex_d.mem_op    = mem_op_ctrl;

                    // 数据与索引
                    idex_d.reg_data_1 = id_fwd_rs1_val; // 按选择编码前递后的值
                    idex_d.reg_data_2 = id_fwd_rs2_val;
                    idex_d.rd         = rd_addr_internal;
                    idex_d.rs1        = rs1_addr_internal;
                    idex_d.rs2        = rs2_addr_internal;

                    // 上下文
                    idex_d.pc    = pc_id;
                    idex_d.pc_4  = pc4_id;
                    idex_d.inst  = inst_id;
                    idex_d.valid = 1'b1;
            end else begin
                // 上游没有新指令 → 输出气泡
                idex_d.valid = 1'b0;
            end
        end
    end
    // ID/EX q 路
    always_ff @(posedge clk) begin
        if (rst) begin
            idex_q.valid <= 1'b0;
        end else if (mem_stall) begin
            idex_q <= idex_q; // 冻结 IDEX
        end else begin
            idex_q <= idex_d;
        end
    end
    
    //=============================================================================
    // EX阶段 - 执行
    //=============================================================================
    // ALU输入A选择（用 ID/EX）
    always_comb begin
        case(idex_q.alu_a_sel)
            ASEL_REG: alu_in_a = idex_q.reg_data_1; // rs1 数据
            ASEL_PC:  alu_in_a = idex_q.pc;         // 本条指令的 PC
            ASEL0:    alu_in_a = 64'd0;             // 常数 0
            default:  alu_in_a = 64'bx; 
        endcase
    end
    // ALU输入B选择（用 ID/EX）
    always_comb begin
        case(idex_q.alu_b_sel)
            BSEL_REG: alu_in_b = idex_q.reg_data_2; // rs2 数据
            BSEL_IMM: alu_in_b = idex_q.imm;        // 立即数
            BSEL0:    alu_in_b = 64'd0;
            default:  alu_in_b = 64'bx; 
        endcase
    end
    
    // 实例化ALU
    ALU u_alu (
        .a(alu_in_a),
        .b(alu_in_b),
        .alu_op(idex_q.alu_op), 
        .res(alu_res_internal)
    );

    // 实例化比较单元
    Cmp u_cmp (
        .a(idex_q.reg_data_1),
        .b(idex_q.reg_data_2),
        .cmp_op(idex_q.cmp_op), 
        .cmp_res(cmp_res_internal)
    );

    // 分支逻辑判断：在 EX 判定“是否为分支”与“是否采纳”
    assign is_branch_instruction = (idex_q.inst[6:0] == BRANCH_OPCODE);
    assign br_taken_internal = is_branch_instruction & cmp_res_internal;

    // EX 阶段的“是否发生重定向”（分支采纳或无条件跳转）
    // 依赖 IDEX.valid，避免未初始化字段带来的伪重定向
    wire take_redirect_ex = idex_q.valid && idex_q.npc_sel && (br_taken_internal || idex_q.cmp_op == CMP_NO);
    // IF/ID 两拍覆盖：T 杀错路径；T+1 再覆盖可能到达的迟到回复
    // ID/EX 一拍覆盖：T 清空，阻止错路径进入 EX
    logic redirect_ex_d1; // take_redirect_ex 的一拍延迟，用于 T+1 覆盖
    always_ff @(posedge clk) begin
        if (rst) redirect_ex_d1 <= 1'b0; else redirect_ex_d1 <= take_redirect_ex;
    end
    assign flush_ifid = take_redirect_ex || redirect_ex_d1; // 两拍覆盖 IF/ID
    assign flush_idex = take_redirect_ex;                   // 一拍覆盖 ID/EX
    // 不再在接口层丢弃回复；由 IF/ID 的 flush 来丢弃错路径

    // next_pc计算逻辑
    /*
     * 默认顺序 pc+4；若发生重定向：
     * - JALR 需对齐目标地址（(rs1+imm) & ~1）；
     * - 其它控制流直接用 EX 的 ALU 结果。
     */
    // 预计算 JALR 对齐过的目标
    wire is_jalr_ex = (idex_q.inst[6:0] == JALR_OPCODE);
    wire [63:0] target_pc_aligned = is_jalr_ex ? {alu_res_internal[63:1], 1'b0} : alu_res_internal;
    always_comb begin
        next_pc = pc + 4; // 默认顺序执行
        if (idex_q.valid && idex_q.npc_sel && (br_taken_internal || idex_q.cmp_op == CMP_NO)) begin
            next_pc = target_pc_aligned; // 目标 PC（JALR 低位清 0）
        end
    end

    //========================
    // EX/MEM d 路组合逻辑
    //========================
    always_comb begin
        exmem_d = exmem_q;               // 默认保持
        if (idex_q.valid) begin
            // 控制
            exmem_d.we_reg  = idex_q.we_reg;
            exmem_d.we_mem  = idex_q.we_mem;
            exmem_d.re_mem  = idex_q.re_mem;
            exmem_d.wb_sel  = idex_q.wb_sel;
            exmem_d.mem_op  = idex_q.mem_op;

            // 数据
            exmem_d.alu_res    = alu_res_internal;       // EX 结果
            exmem_d.reg_data_1 = idex_q.reg_data_1;      // 透传
            exmem_d.reg_data_2 = idex_q.reg_data_2;      // 用于打包写数据
            exmem_d.mem_wdata  = data_to_dmem_packaged;  // EX 打包好的写数据

            // 分支观测/目标
            exmem_d.br_taken = take_redirect_ex;
            exmem_d.npc      = next_pc;                  // 目标 PC（观测）

            // 索引
            exmem_d.rd  = idex_q.rd;
            exmem_d.rs1 = idex_q.rs1;
            exmem_d.rs2 = idex_q.rs2;

            // 上下文
            exmem_d.pc   = idex_q.pc;
            exmem_d.pc_4 = idex_q.pc_4;
            exmem_d.inst = idex_q.inst;
            exmem_d.valid= 1'b1;
        end else begin
            // 上游是气泡：本拍输出也应是气泡
            exmem_d.valid = 1'b0;
        end
    end
    // EX/MEM q 路
    always_ff @(posedge clk) begin
        if (rst) begin
            exmem_q.valid <= 1'b0;
        end else if (mem_stall) begin
            exmem_q <= exmem_q; // 冻结 EXEMEM
        end else begin
            exmem_q <= exmem_d;
        end
    end

    //=============================================================================
    // MEM阶段 - 访存
    //=============================================================================
    /*
     * 访存节拍（EX 发起 → MEM 接收）：
     * - T   ：EX 发起读/写；
     * - T+1 ：MEM 接收读回复并截断；
     */
    // 连接数据存储器读端口（Core 侧，使用 EX/MEM 稳定值，FSM 在 MEM1 放行握手）
    assign core_dmem.r_request_bits.raddr = exmem_q.alu_res;         // 使用 EX/MEM 的地址
    assign core_dmem.r_request_valid = exmem_q.valid && exmem_q.re_mem; // 仅对有效指令发起读
    assign core_dmem.r_reply_ready = 1'b1;                             // MEM2 接收
    assign dmem_rdata_raw_internal = core_dmem.r_reply_bits.rdata;

    // 读数据截断
    DataTrunc u_data_trunc (
        .dmem_rdata(dmem_rdata_raw_internal),
        .mem_op(exmem_q.mem_op),
        .dmem_raddr(exmem_q.alu_res),
        .read_data(data_from_mem_final)
    ); // 按 mem_op 与地址低位，从 64b 读数据中取相应字/半字/字节，并做符号/零扩展，得到对齐后的读数据

    // 写数据打包（EX 当拍生成，写入 EX/MEM）
    DataPkg u_data_pkg_ex (
        .mem_op(idex_q.mem_op),
        .reg_data(idex_q.reg_data_2),
        .dmem_waddr(alu_res_internal),
        .dmem_wdata(data_to_dmem_packaged)
    ); // 将待写的寄存器数据根据 mem_op 与地址低位对齐到 64b 总线相应字节段，形成写数据
    // 写掩码生成（MEM 阶段基于 EX/MEM 稳定地址/操作生成）
    MaskGen u_mask_gen_mem (
        .mem_op(exmem_q.mem_op),
        .dmem_waddr(exmem_q.alu_res),
        .dmem_wmask(dmem_write_mask)
    ); // 生成写请求的逐字节掩码（wmask），只使能要写入的字节
    // 发起写请求（Core 侧，使用 EX/MEM 稳定值，FSM 在 MEM1 放行握手）
    assign core_dmem.w_request_bits.waddr = exmem_q.alu_res;
    assign core_dmem.w_request_bits.wdata = exmem_q.mem_wdata; // 由 EX 当拍打包并写入 EX/MEM
    assign core_dmem.w_request_bits.wmask = dmem_write_mask;
    assign core_dmem.w_request_valid = exmem_q.valid && exmem_q.we_mem;
    assign core_dmem.w_reply_ready = 1'b1;

    //========================
    // MEM/WB 段寄存器
    //========================
    PipelinePack::MEMWB memwb_q;  // 当前拍 WB 看到的值
    PipelinePack::MEMWB memwb_d;  // 下一拍要写入的值

    always_comb begin
        memwb_d = memwb_q;              // 默认保持
        if (exmem_q.valid) begin
            // 控制/观测
            memwb_d.we_reg   = exmem_q.we_reg;
            memwb_d.re_mem   = exmem_q.re_mem;
            memwb_d.br_taken = exmem_q.br_taken;
            memwb_d.mem_we   = {{63{1'b0}}, exmem_q.we_mem};
            memwb_d.alu_res  = exmem_q.alu_res;
            memwb_d.data_trunc = data_from_mem_final;  // MEM 产出的读数据
            memwb_d.read_data_1 = exmem_q.reg_data_1;
            memwb_d.read_data_2 = exmem_q.reg_data_2;
            memwb_d.mem_wdata   = exmem_q.mem_wdata;   // EX 打包的写数据（透传）
            memwb_d.mem_rdata   = dmem_rdata_raw_internal; // 原始返回
            memwb_d.mem_addr    = exmem_q.alu_res;
            memwb_d.wb_sel      = exmem_q.wb_sel;

            // 索引
            memwb_d.rd  = exmem_q.rd;
            memwb_d.rs1 = exmem_q.rs1;
            memwb_d.rs2 = exmem_q.rs2;

            // 上下文
            memwb_d.pc   = exmem_q.pc;
            memwb_d.pc_4 = exmem_q.pc_4;
            memwb_d.npc  = exmem_q.npc;
            memwb_d.inst = exmem_q.inst;
            memwb_d.valid= 1'b1;
        end else begin
            // 上游是气泡：本拍输出也应是气泡
            memwb_d.valid = 1'b0;
        end
    end
    always_ff @(posedge clk) begin
        if (rst) begin
            memwb_q.valid <= 1'b0;
        end else if (mem_stall) begin
            memwb_q.valid <= 1'b0; // flush MEMWB 气泡
        end else begin
            memwb_q <= memwb_d;
        end
    end

    //=============================================================================
    // WB阶段 - 写回
    //=============================================================================
    always_comb begin
        wb_data_internal = 64'bx; // 默认值，防止锁存器
        case (memwb_q.wb_sel)
            WB_SEL_ALU: wb_data_internal = memwb_q.alu_res;     // ALU 的计算结果
            WB_SEL_MEM: wb_data_internal = memwb_q.data_trunc;  // 从内存加载的数据（截断后）
            WB_SEL_PC:  wb_data_internal = memwb_q.pc_4;        // PC+4
            WB_SEL0:    wb_data_internal = 64'd0;               // 写回 0
            default:    wb_data_internal = 64'bx;
        endcase
    end

    //=============================================================================
    // CoSim输出信号
    //=============================================================================
    // WB 对齐观测
    assign rs1 = memwb_q.rs1;
    assign rs2 = memwb_q.rs2;
    assign rd  = memwb_q.rd;
    assign read_data_1 = memwb_q.read_data_1;
    assign read_data_2 = memwb_q.read_data_2;
    assign alu_res = memwb_q.alu_res;
    assign we_reg = memwb_q.we_reg && memwb_q.valid && (memwb_q.rd != 5'd0);
    assign br_taken = memwb_q.br_taken;
    assign wb_val = wb_data_internal;

    // WB 阶段提交：以 MEM/WB.valid 为准（不做去重）
    assign cosim_valid = memwb_q.valid;
    assign cosim_core_info.pc        = memwb_q.pc;
    assign cosim_core_info.inst      = {32'b0, memwb_q.inst};   
    assign cosim_core_info.rs1_id    = {59'b0, rs1};
    assign cosim_core_info.rs1_data  = read_data_1;
    assign cosim_core_info.rs2_id    = {59'b0, rs2};
    assign cosim_core_info.rs2_data  = read_data_2;
    assign cosim_core_info.alu       = alu_res;
    assign cosim_core_info.mem_addr  = memwb_q.mem_addr;
    assign cosim_core_info.mem_we    = memwb_q.mem_we;
    assign cosim_core_info.mem_wdata = memwb_q.mem_wdata;
    assign cosim_core_info.mem_rdata = memwb_q.mem_rdata;
    assign cosim_core_info.rd_we     = {63'b0, we_reg};
    assign cosim_core_info.rd_id     = {59'b0, rd}; 
    assign cosim_core_info.rd_data   = wb_val;
    assign cosim_core_info.br_taken  = {63'b0, br_taken};
    assign cosim_core_info.npc       = memwb_q.npc;


endmodule
