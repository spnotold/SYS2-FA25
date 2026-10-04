#include <inttypes.h>
#include <printk.h>
#include <private_kdefs.h>
#include <sbi.h>
#include <stdint.h>

// 简单的自旋任务：每当时间计数（按 TIMECLOCK 频率）增加时打印一次
_Noreturn static void test(void) __attribute__((noinline));
_Noreturn static void test(void) {
  uint64_t last_timeval = 0; // 记录上一次打印的时间刻度

  while (1) {
    uint64_t timeval;
    asm volatile("rdtime %0" : "=r"(timeval)); // 读取当前 time CSR
    timeval /= TIMECLOCK; // 将硬件计数转换为“秒”级刻度
    if (timeval != last_timeval) { // 只在时间刻度变化时输出
      last_timeval = timeval;
      printk("Kernel is running! timeval = %" PRIu64 "\n", timeval);
    }
  }
}

_Noreturn void start_kernel(void) {
  csr_write(sscratch, 0x7e9); // 与 lab4 一致，先写一个标志值
  uint64_t banner = csr_read(sscratch); // 读回标志，用来打印开机信息
  printk("%" PRIu64 " ZJU Computer System II\n", banner);

  test(); // 进入死循环，持续打印时间
}
