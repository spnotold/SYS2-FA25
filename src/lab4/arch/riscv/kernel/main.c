#include <print.h>
#include <sbi.h>

_Noreturn static void ecall_test(void) __attribute__((noinline));
_Noreturn static void ecall_test(void) {
  sbi_ecall(0x53525354, 0, 0, 0, 0, 0, 0, 0);
  __builtin_unreachable();
}

_Noreturn void start_kernel(void) {
  csr_write(sscratch, 0x7e9);
  puti(csr_read(sscratch));
  puts(" ZJU Computer System II");

  ecall_test();
}
