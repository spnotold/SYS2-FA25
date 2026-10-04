#include <stdint.h>
#include <printk.h>

void clock_set_next_event(void);

void trap_handler(uint64_t scause, uint64_t sepc) {
  // scause 的 bit63=1 表示中断，低位编码类型；bit63=0 表示异常。
  // Supervisor Timer Interrupt 的编码：bit63=1 且 cause=5（见 spec）。
  const uint64_t SCAUSE_INT_FLAG = 1ull << 63;
  const uint64_t SCAUSE_CODE = 5; // timer interrupt in S-mode

  if ((scause & SCAUSE_INT_FLAG) && ((scause & ~SCAUSE_INT_FLAG) == SCAUSE_CODE)) {
    // S 模式定时器中断
    printk("[S] Supervisor timer interrupt\n");
    clock_set_next_event(); // 安排下一次时钟中断
  } else {
    // 非预期的 trap：打印出来方便调试
    printk("[!] Unexpected trap: scause=%" PRIx64 ", sepc=%" PRIx64 "\n", scause, sepc);
  }
}
