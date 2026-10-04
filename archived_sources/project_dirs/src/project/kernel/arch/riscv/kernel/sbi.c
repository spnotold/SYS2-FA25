#include <stdint.h>
#include <sbi.h>

struct sbiret sbi_ecall(uint64_t eid, uint64_t fid,
                        uint64_t arg0, uint64_t arg1, uint64_t arg2,
                        uint64_t arg3, uint64_t arg4, uint64_t arg5) {
  struct sbiret ret;
  uint64_t error, value;

  // 将 C 函数传入的参数按照 SBI 约定放入 a0~a7
  asm volatile("mv a0, %[arg0]\n"
               "mv a1, %[arg1]\n"
               "mv a2, %[arg2]\n"
               "mv a3, %[arg3]\n"
               "mv a4, %[arg4]\n"
               "mv a5, %[arg5]\n"
               "mv a6, %[fid]\n"
               "mv a7, %[eid]\n"
               // 触发 ecall，进入 M-mode 由 OpenSBI 处理
               "ecall\n"
               // 从 a0/a1 中取回 error 和 value
               "mv %[error], a0\n"
               "mv %[value], a1\n"
               // 输出约束：error/value(C变量) 映射到占位符 %[error]/%[value]，
               // 用寄存器承载，汇编结束后写回 C 变量
               //"=r" 的意思是“用寄存器存放只写输出”
               : [error] "=r"(error), [value] "=r"(value)
               // 输入约束：eid/fid/arg0~arg5 只读输入，
               // "r" 表示用某个寄存器传入，对应汇编里的 %[eid] 等占位符
               : [eid] "r"(eid), [fid] "r"(fid),
                 [arg0] "r"(arg0), [arg1] "r"(arg1), [arg2] "r"(arg2),
                 [arg3] "r"(arg3), [arg4] "r"(arg4), [arg5] "r"(arg5)
               // clobber：声明会修改 a0~a7 以及可能访问内存
               : "a0", "a1", "a2", "a3", "a4", "a5", "a6", "a7", "memory");

  ret.error = error;
  ret.value = value;
  return ret;
}
