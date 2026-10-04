#include <stdint.h>
#include <private_kdefs.h>
#include <sbi.h>

void clock_set_next_event(void) {
  uint64_t time;

  // 1. 使用 rdtime 指令读取当前时间
  asm volatile("rdtime %0" : "=r"(time));

  // 2. 计算下一次中断的时间
  uint64_t next = time + TIMECLOCK;

  // 3. 调用 sbi_set_timer 设置下一次时钟中断
  sbi_ecall(0x54494d45, 0, next, 0, 0, 0, 0, 0);
}
