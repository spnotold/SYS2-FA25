#include <stdint.h>
#include <string.h>
#include <mm.h>
#include <printk.h>
#include <private_kdefs.h>

extern uint8_t _ekernel[];

// 定义链表节点类型 struct kfreelist，并声明指向链表头的指针变量 kfreelist
// 用页首地址作为节点存储，仅需一个 next 指针串起所有空闲页
static struct kfreelist {
  struct kfreelist *next;
} *kfreelist;

void *alloc_page(void) {
  // 取出空闲链表头节点（即一页物理内存），并把链表头前移
  struct kfreelist *r = kfreelist;
  kfreelist = r->next;
  return r;
}

void free_pages(void *addr) {
  // 将传入地址所在的页回收到空闲链表：
  // 1) PGROUNDDOWN 保证地址落在该页的起始处（页对齐）
  // 2) 用 0xfa 填满整页，便于调试：0xfa 是明显的“垃圾值”，一旦被误用/越界容易发现
  // 3) 头插法，把这一页挂到链表头 kfreelist
  struct kfreelist *r = (void *)PGROUNDDOWN((uintptr_t)addr);
  //memset(r, 0xfa, PGSIZE);
  r->next = kfreelist;
  kfreelist = r;
}

void mm_init(void) {
  // 把内核末尾之后的每块 4KB 空闲区域都登记进空闲链表，方便后面按块分配
  // 简单说：从内核结束处开始，一块块标记为“可用内存”
  uint8_t *s = (void *)PGROUNDUP((uintptr_t)_ekernel);
  const uint8_t *e = (void *)PHY_END;
  for (; s + PGSIZE <= e; s += PGSIZE) {
    free_pages(s);
  }
  printk("...mm_init done!\n");
}
