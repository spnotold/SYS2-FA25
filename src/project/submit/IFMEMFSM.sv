
// 职责：根据 Lab2 规范，控制取指（IF）与数据访存（MEM）的 ready‑valid 时序，
// 并产生 if_stall/mem_stall 控制流水线的冻结与推进。
//
// 状态：
//   S_IDLE → S_IF1 → S_IF2 → S_IDLE
//   在 IF* 阶段收到数据访存请求：S_WAITFOR1 → S_WAITFOR2 → S_MEM1 → S_MEM2 → S_IDLE
//
module IFMemFSM (
    input  logic clk,
    input  logic rst,

    // 上游：Core 侧（Core 为 Master，本 FSM 以 Slave 端口接收）
    Mem_ift.Slave  core_imem,
    Mem_ift.Slave  core_dmem,

    // 下游：总线/存储器侧（本 FSM 作为 Master 发起）
    Mem_ift.Master bus_imem,
    Mem_ift.Master bus_dmem,

    // 流水线控制输出
    output logic if_stall,   // IF2（等待取指返回）期间冻结 PC/IFID
    output logic mem_stall,  // 冻结 PC/IFID/IDEXE/EXEMEM；Core 端需据此 flush MEMWB

    // 可选：导出 FSM 状态用于调试/观测（编码待实现时确定）
    output logic [2:0] fsm_state
);

    //============================
    // 状态定义
    //============================
    typedef enum logic [2:0] {
        S_IDLE      = 3'd0,
        S_IF1       = 3'd1,
        S_IF2       = 3'd2,
        S_WAITFOR1  = 3'd3,
        S_WAITFOR2  = 3'd4,
        S_MEM1      = 3'd5,
        S_MEM2      = 3'd6
    } state_e;

    state_e state_q, state_d;
    assign fsm_state = state_q;

    // 观测握手（遵循 ready-valid，不改动通路，仅用于状态判断）
    wire i_req_fire   = bus_imem.r_request_valid & bus_imem.r_request_ready;
    wire i_reply_fire = bus_imem.r_reply_valid   & bus_imem.r_reply_ready;

    wire d_r_req_fire   = bus_dmem.r_request_valid & bus_dmem.r_request_ready;
    wire d_r_reply_fire = bus_dmem.r_reply_valid   & bus_dmem.r_reply_ready;
    wire d_w_req_fire   = bus_dmem.w_request_valid & bus_dmem.w_request_ready;
    wire d_w_reply_fire = bus_dmem.w_reply_valid   & bus_dmem.w_reply_ready;

    // 记录是否有待服务的数据访存请求（读或写），用于 IF 结束后进入 MEM1/2
    logic mem_pending_q, mem_pending_d;
    logic mem_is_write_q, mem_is_write_d;
    wire  mem_req_now = core_dmem.r_request_valid | core_dmem.w_request_valid;

    //============================
    // 门控连线（严格按状态放行握手，bits 直通）
    //============================
    // 使能信号（只在对应阶段放行握手）
    wire en_if_req = (state_q == S_IF1) || (state_q == S_WAITFOR1);
    wire en_if_rep = (state_q == S_IF2) || (state_q == S_WAITFOR2);
    wire en_mem_req = (state_q == S_MEM1);
    wire en_mem_rep = (state_q == S_MEM2);

    // 指令端（仅读）：bits 直通，valid/ready 门控
    // 读请求
    assign bus_imem.r_request_bits   = core_imem.r_request_bits;
    assign bus_imem.r_request_valid  = en_if_req ? core_imem.r_request_valid  : 1'b0;
    assign core_imem.r_request_ready = en_if_req ? bus_imem.r_request_ready   : 1'b0;
    // 读响应
    assign core_imem.r_reply_bits    = bus_imem.r_reply_bits;
    assign core_imem.r_reply_valid   = en_if_rep ? bus_imem.r_reply_valid     : 1'b0;
    assign bus_imem.r_reply_ready    = en_if_rep ? core_imem.r_reply_ready    : 1'b0;
    // 写通道（IF 端不使用，全部屏蔽）
    assign bus_imem.w_request_bits   = core_imem.w_request_bits;
    assign bus_imem.w_request_valid  = 1'b0;
    assign core_imem.w_request_ready = 1'b0;
    assign core_imem.w_reply_bits    = bus_imem.w_reply_bits;
    assign core_imem.w_reply_valid   = 1'b0;
    assign bus_imem.w_reply_ready    = 1'b0;

    // 数据端：按读/写二选一放行
    // bits 直通
    assign bus_dmem.r_request_bits   = core_dmem.r_request_bits;
    assign core_dmem.r_reply_bits    = bus_dmem.r_reply_bits;
    assign bus_dmem.w_request_bits   = core_dmem.w_request_bits;
    assign core_dmem.w_reply_bits    = bus_dmem.w_reply_bits;

    // 读请求/响应门控
    assign bus_dmem.r_request_valid  = (en_mem_req && !mem_is_write_q) ? core_dmem.r_request_valid : 1'b0;
    assign core_dmem.r_request_ready = (en_mem_req && !mem_is_write_q) ? bus_dmem.r_request_ready  : 1'b0;
    assign core_dmem.r_reply_valid   = (en_mem_rep && !mem_is_write_q) ? bus_dmem.r_reply_valid    : 1'b0;
    assign bus_dmem.r_reply_ready    = (en_mem_rep && !mem_is_write_q) ? core_dmem.r_reply_ready   : 1'b0;

    // 写请求/响应门控
    assign bus_dmem.w_request_valid  = (en_mem_req &&  mem_is_write_q) ? core_dmem.w_request_valid : 1'b0;
    assign core_dmem.w_request_ready = (en_mem_req &&  mem_is_write_q) ? bus_dmem.w_request_ready  : 1'b0;
    assign core_dmem.w_reply_valid   = (en_mem_rep &&  mem_is_write_q) ? bus_dmem.w_reply_valid    : 1'b0;
    assign bus_dmem.w_reply_ready    = (en_mem_rep &&  mem_is_write_q) ? core_dmem.w_reply_ready   : 1'b0;

    //============================
    // 状态机（仅观测与产生 stall 信号；不阻断通路）
    //============================
    // next-state
    always_comb begin
        state_d        = state_q;
        mem_pending_d  = mem_pending_q;
        mem_is_write_d = mem_is_write_q;

        unique case (state_q)
            S_IDLE: begin
                // 默认立即进入 IF1
                state_d = S_IF1;
            end
            S_IF1: begin
                // IF 请求阶段；若看到数据访存请求，转入挂起等待
                if (mem_req_now) begin
                    state_d        = S_WAITFOR1;
                    mem_pending_d  = 1'b1;
                    mem_is_write_d = core_dmem.w_request_valid;
                end else if (i_req_fire) begin
                    state_d = S_IF2;
                end
            end
            S_IF2: begin
                // IF 等待回复
                if (i_reply_fire) begin
                    // 对标参考实现：IF2 完成后回到 IDLE（不在 IF2 记录新的 MEM 请求）
                    state_d = S_IDLE;
                end
            end
            S_WAITFOR1: begin
                // 等待 IF1 的请求握手完成
                if (i_req_fire) state_d = S_WAITFOR2;
            end
            S_WAITFOR2: begin
                // 等待 IF2 的回复握手完成
                if (i_reply_fire) state_d = S_MEM1;
            end
            S_MEM1: begin
                // 发起一次数据访存请求（读或写）
                if (mem_is_write_q ? d_w_req_fire : d_r_req_fire) begin
                    state_d = S_MEM2;
                end
            end
            S_MEM2: begin
                // 等待数据访存回复（读或写的响应）
                if (mem_is_write_q ? d_w_reply_fire : d_r_reply_fire) begin
                    state_d       = S_IDLE;
                    mem_pending_d = 1'b0;
                end
            end
            default: state_d = S_IDLE;
        endcase
    end

    // state reg
    always_ff @(posedge clk) begin
        if (rst) begin
            // 对标参考实现：复位后直接进入 S_IF1
            state_q       <= S_IF1;
            mem_pending_q <= 1'b0;
            mem_is_write_q<= 1'b0;
        end else begin
            state_q       <= state_d;
            mem_pending_q <= mem_pending_d;
            mem_is_write_q<= mem_is_write_d;
        end
    end

    //============================
    // stall 信号（先提供给 Core 使用；实际冻结逻辑在 Core 内实现）
    //============================
    // if_stall：对标参考实现，除 IDLE 外均保持冻结
    assign if_stall = (state_q != S_IDLE);
    // mem_stall：
    // - 在 WAITFOR* 与 MEM* 阶段冻结前端与中间段、并 flush MEMWB（由 Core 执行）；
    // - 在 IF2 若出现 dmem 请求，提前拉高，避免 Core 丢失当拍 EX 的请求；
    // - 在 IF1 当拍若出现 dmem 请求，同样提前拉高，确保 IDEXE/EXEMEM 在这一拍就被冻结，
    //   使 EX 发起的 re_mem/we_mem 请求保持不被下一条覆盖（“先完成一次取指再服务 MEM”）。
    assign mem_stall = (state_q == S_WAITFOR1) || (state_q == S_WAITFOR2)
                    || (state_q == S_MEM1)
                    // 在 MEM2 阶段：当看到 dmem 回复 valid 时即可释放 mem_stall
                    || ((state_q == S_MEM2) && (mem_is_write_q ? !bus_dmem.w_reply_valid : !bus_dmem.r_reply_valid))
                    // 在 IF1 当拍若出现 dmem 请求，提前拉高
                    || ((state_q == S_IF1) && mem_req_now);

endmodule
