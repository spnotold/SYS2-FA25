#include "private_kdefs.h"

    .section .text.init
    .globl _start
_start:
    # 0. 给 C 代码准备好栈：放在内核末尾之后的 4 KiB
    la sp, _ekernel
    li t0, 4096
    add sp, sp, t0

    # 1. 设置 trap 向量基址为 _traps（entry.S 里实现）
    #    stvec 是 S 模式的 trap 入口寄存器：这里直接写入地址，最低两位为 0
    #    表示 Direct 模式——所有 trap 都先跳到同一个 _traps 入口
    la t0, _traps
    csrw stvec, t0

    # 2. 开启 S 模式下的定时器中断（sie.STIE，bit 5）
    li t0, (1 << 5)
    csrs sie, t0

    # 3. 设置第一次时钟中断：next = time + TIMECLOCK，然后调用 sbi_set_timer
    rdtime t1                  # t1 = 当前时间（cycle）
    li t2, TIMECLOCK           # t2 = 一个时钟周期间隔
    add t1, t1, t2             # t1 = 下一次触发时间
    mv a0, t1                  # a0 = next_event
    li a1, 0                   # 其余参数按规范填 0
    li a2, 0
    li a3, 0
    li a4, 0
    li a5, 0
    li a6, 0                   # a6 = fid (set_timer 的 func id)
    li a7, 0x54494d45          # a7 = eid ("TIME")
    ecall                      # 进入 OpenSBI 设置 stimecmp/mtimecmp，返回后继续执行

    # 4. 开启 S 模式全局中断响应（sstatus.SIE，bit 1）
    csrsi sstatus, 0x2

    # 5. 跳转到 C 入口 start_kernel
    #    小结：head.S 定义了内核入口 _start，
    #    由 OpenSBI 跳转到这里后：
    #      - 搭好 C 语言栈（_ekernel 之后 4KiB）
    #      - 设置 stvec -> _traps，准备好 trap 入口
    #      - 开启 S 模式定时器中断 + 全局中断
    #      - 调用 sbi_set_timer 设定第一次定时器触发时间
    #    然后把控制权交给 C 代码的 start_kernel
    tail start_kernel
