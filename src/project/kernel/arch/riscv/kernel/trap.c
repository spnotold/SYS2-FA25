#include <inttypes.h>
#include <printk.h>
#include <stdint.h>
#include <proc.h>

void clock_set_next_event(void);

void trap_handler(uint64_t scause, uint64_t sepc) {
  // scause 的 bit63=1 表示中断，低位编码类型；bit63=0 表示异常。
  // Supervisor Timer Interrupt 的编码：bit63=1 且 cause=5（见 spec）。
  const uint64_t SCAUSE_INT_FLAG = 1ull << 63;
  const uint64_t SCAUSE_CODE = 5; // timer interrupt in S-mode

  if ((scause & SCAUSE_INT_FLAG) &&
      ((scause & ~SCAUSE_INT_FLAG) == SCAUSE_CODE)) {
    // S 模式定时器中断：
    // - 只有当硬件触发“Supervisor Timer Interrupt”（即 S 模式时钟中断，cause=5）时才会进入这里，
    //   通常是之前设置的下一次时钟事件到期了（时钟滴答到来）。
    clock_set_next_event(); // 为了让之后还能继续收到时钟中断，这里立刻重新设置下一次时钟触发时间（否则只会响一次）。
    do_timer();             // 利用这次时钟中断的机会更新当前线程的时间片 counter，必要时触发 schedule() 进行线程切换。
  } else {
    // 非预期的 trap：可以在调试时临时打开 printk
    // printk("[!] Unexpected trap: scause=%" PRIx64 ", sepc=%" PRIx64 "\n",
    //        scause, sepc);
  }
}
