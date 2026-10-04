#include "private_kdefs.h"

    .section .bss.stack
    .space PGSIZE

    .section .text.init
    .globl _start
_start:
    # 0. 给 C 代码准备好栈：使用 .bss.stack 段（_sbss）
    la sp, _sbss

    # 1. 初始化内存管理
    call mm_init

    # 2. 设置 trap 向量基址为 _traps（entry.S 里实现）
    #    stvec 是 S 模式的 trap 入口寄存器：这里直接写入地址，最低两位为 0
    #    表示 Direct 模式——所有 trap 都先跳到同一个 _traps 入口
    la t0, _traps
    csrw stvec, t0

    # 3. 开启 S 模式下的定时器中断（sie.STIE，bit 5）
    li t0, (1 << 5)
    csrs sie, t0

    # 4. 设置第一次时钟中断：在本实验的自制 Core 上，S 态无法读取 time CSR，
    #    因此把“间隔” TIMECLOCK 直接交给 mini_sbi，由它在 M 态设置 mtimecmp。
    li a0, TIMECLOCK           # a0 = interval
    li a1, 0                   # 其余参数按规范填 0
    li a2, 0
    li a3, 0
    li a4, 0
    li a5, 0
    li a6, 0                   # a6 = fid (set_timer 的 func id)
    li a7, 0x54494d45          # a7 = eid ("TIME")
    ecall                      # 进入 OpenSBI 设置 stimecmp/mtimecmp，返回后继续执行

    # 5. 开启 S 模式全局中断响应（sstatus.SIE，bit 1）
    csrsi sstatus, 0x2

    # 6. 跳转到 C 入口 start_kernel
    #    小结：head.S 定义了内核入口 _start，
    #    由 OpenSBI 跳转到这里后：
    #      - 搭好 C 语言栈（.bss.stack 段，sp = _sbss）
    #      - 初始化物理页分配器 mm_init
    #      - 设置 stvec -> _traps，准备好 trap 入口
    #      - 开启 S 模式定时器中断 + 全局中断
    #      - 调用 sbi_set_timer 设定第一次定时器触发时间
    #    然后把控制权交给 C 代码的 start_kernel
    tail start_kernel
