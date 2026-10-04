#include <printk.h>
#include <proc.h>

_Noreturn void start_kernel(void) {
  task_init();
  printk("2025 ZJU Computer System II\n");
  // TA 建议：输出可以适当精简
  // printk("ZJU Computer System II\n");

  // 等待第一次时钟中断
  while (1)
          ;
}
