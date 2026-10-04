#include <string.h>

void *memset(void *restrict dst, int c, size_t n) {
  // 将缓冲区 dst 的前 n 个字节全部填成同一个字节值
  unsigned char *p = (unsigned char *)dst;
  unsigned char val = (unsigned char)c;

  for (size_t i = 0; i < n; ++i) {
    p[i] = val;
  }

  return dst;
}

size_t strnlen(const char *restrict s, size_t maxlen) {
  // 从 s 开始计数，遇到 '\0' 或者计满 maxlen 就停止
  size_t len = 0;

  while (len < maxlen && s[len] != '\0') {
    ++len;
  }

  return len;
}
