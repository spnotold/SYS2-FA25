#include <stdio.h>
#include <sbi.h>
#include <printk.h>

static int printk_sbi_write(FILE *restrict fp, const void *restrict buf, size_t len) {
  (void)fp;

  // 调用 SBI 接口输出 buf 中长度为 len 的内容
  // 返回实际输出的字节数
  // Hint：阅读 SBI v2.0 规范！
  const char *p = (const char *)buf; // 按字节遍历要输出的缓冲区
  for (size_t i = 0; i < len; ++i) {
    // DBCN 扩展的 write_byte：eid=0x4442434e, fid=2
    // a0 传当前字符，其他参数填 0
    sbi_ecall(0x4442434e, 2, (uint64_t)(unsigned char)p[i], 0, 0, 0, 0, 0);
  }

  return (int)len;
}

void printk(const char *fmt, ...) {
  FILE printk_out = {
      .write = printk_sbi_write,
  };

  va_list ap;
  va_start(ap, fmt);
  vfprintf(&printk_out, fmt, ap);
  va_end(ap);
}
