    .section .text.entry
    .align 4
    .globl _traps
_traps:
    # 1. 把所有通用寄存器 + sepc 压栈保存，留出 256 字节空间
    addi sp, sp, -256

    # 1.1 依次保存各寄存器的原值
    sd ra, 0(sp)
    sd gp, 16(sp)
    sd tp, 24(sp)
    sd t0, 32(sp)
    sd t1, 40(sp)
    sd t2, 48(sp)
    sd s0, 56(sp)
    sd s1, 64(sp)
    sd a0, 72(sp)
    sd a1, 80(sp)
    sd a2, 88(sp)
    sd a3, 96(sp)
    sd a4, 104(sp)
    sd a5, 112(sp)
    sd a6, 120(sp)
    sd a7, 128(sp)
    sd s2, 136(sp)
    sd s3, 144(sp)
    sd s4, 152(sp)
    sd s5, 160(sp)
    sd s6, 168(sp)
    sd s7, 176(sp)
    sd s8, 184(sp)
    sd s9, 192(sp)
    sd s10, 200(sp)
    sd s11, 208(sp)
    sd t3, 216(sp)
    sd t4, 224(sp)
    sd t5, 232(sp)
    sd t6, 240(sp)

    # 1.2 保存触发时的 sp（旧栈顶）到偏移 8 处
    addi t0, sp, 256
    sd t0, 8(sp)

    # 1.3 保存 sepc，用于恢复返回点
    csrr t0, sepc
    sd t0, 248(sp)

    # 2. 准备参数并调用 C 的 trap_handler(scause, sepc)
    csrr a0, scause          # a0 = scause
    mv   a1, t0              # a1 = sepc（刚才读到 t0）
    call trap_handler

    # 3. 从栈恢复上下文（先写回 sepc，再恢复寄存器，最后恢复 sp）
    ld t0, 248(sp)
    csrw sepc, t0 #sepc 不是通用寄存器，它是一个 CSR，
    #所以不能像 ra/gp/... 
    #那样用 ld 直接恢复，要用 csrw sepc, t0 单独写。

    ld ra, 0(sp)
    ld gp, 16(sp)
    ld tp, 24(sp)
    ld t0, 32(sp)
    ld t1, 40(sp)
    ld t2, 48(sp)
    ld s0, 56(sp)
    ld s1, 64(sp)
    ld a0, 72(sp)
    ld a1, 80(sp)
    ld a2, 88(sp)
    ld a3, 96(sp)
    ld a4, 104(sp)
    ld a5, 112(sp)
    ld a6, 120(sp)
    ld a7, 128(sp)
    ld s2, 136(sp)
    ld s3, 144(sp)
    ld s4, 152(sp)
    ld s5, 160(sp)
    ld s6, 168(sp)
    ld s7, 176(sp)
    ld s8, 184(sp)
    ld s9, 192(sp)
    ld s10, 200(sp)
    ld s11, 208(sp)
    ld t3, 216(sp)
    ld t4, 224(sp)
    ld t5, 232(sp)
    ld t6, 240(sp)

    ld t0, 8(sp)             # 取回旧 sp
    mv sp, t0                # 恢复栈顶

    # 4. sret 返回到 sepc 指定位置
    sret
