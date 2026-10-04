#include <stdint.h>
#include <private_kdefs.h>
#include <sbi.h>

void clock_set_next_event(void) {
  // Lab7: 在 S 态无法直接可靠读取 time 寄存器，
  // 只需把“间隔” TIMECLOCK 交给 mini_sbi，由它在 M 态设置 mtimecmp。
  sbi_ecall(0x54494d45, 0, TIMECLOCK, 0, 0, 0, 0, 0);
}
