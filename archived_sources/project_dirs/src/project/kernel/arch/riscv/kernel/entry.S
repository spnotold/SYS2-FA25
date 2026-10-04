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

    .globl __dummy
__dummy:
    # 第一次被调度的线程没有旧的上下文可恢复，
    # 直接把 sepc 设置为 dummy_task，然后通过 sret 返回执行。
    la t0, dummy_task
    csrw sepc, t0
    sret

    .globl __switch_to
__switch_to:
    # a0 = prev, a1 = next
    # 1. 将当前线程的上下文保存到当前线程的 thread_struct 中

    # struct task_struct {
    #   uint64_t pid;      // 0
    #   uint64_t state;    // 8
    #   uint64_t priority; // 16
    #   uint64_t counter;  // 24
    #   struct thread_struct thread; // 32
    # };
    #
    # struct thread_struct {
    #   uint64_t ra;       // 0
    #   uint64_t sp;       // 8
    #   uint64_t s[12];    // 16 ...
    # };

    # 保存 ra / sp
    sd ra, 32(a0)          # thread.ra
    sd sp, 40(a0)          # thread.sp

    # 保存 s[0..11]
    sd s0, 48(a0)          # thread.s[0]
    sd s1, 56(a0)          # thread.s[1]
    sd s2, 64(a0)          # thread.s[2]
    sd s3, 72(a0)          # thread.s[3]
    sd s4, 80(a0)          # thread.s[4]
    sd s5, 88(a0)          # thread.s[5]
    sd s6, 96(a0)          # thread.s[6]
    sd s7, 104(a0)         # thread.s[7]
    sd s8, 112(a0)         # thread.s[8]
    sd s9, 120(a0)         # thread.s[9]
    sd s10, 128(a0)        # thread.s[10]
    sd s11, 136(a0)        # thread.s[11]

    # 2. 从下一个线程的 thread_struct 中恢复上下文
    ld ra, 32(a1)
    ld sp, 40(a1)

    ld s0, 48(a1)
    ld s1, 56(a1)
    ld s2, 64(a1)
    ld s3, 72(a1)
    ld s4, 80(a1)
    ld s5, 88(a1)
    ld s6, 96(a1)
    ld s7, 104(a1)
    ld s8, 112(a1)
    ld s9, 120(a1)
    ld s10, 128(a1)
    ld s11, 136(a1)

    ret
