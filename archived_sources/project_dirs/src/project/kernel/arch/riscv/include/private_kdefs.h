#ifndef __PRIVATE_KDEFS_H__
#define __PRIVATE_KDEFS_H__

// QEMU virt 机器的时钟频率为 10 MHz
#define TIMECLOCK 10000000

// 物理内存布局（lab6 内存管理）
#define PHY_START 0x80000000
#define PHY_SIZE  0x400000  // 4 MiB
#define PHY_END   (PHY_START + PHY_SIZE)

// 页大小与对齐相关宏
#define PGSIZE       0x1000 // 4 KiB
// 向下/向上按页对齐：把任意地址规整到页边界，便于页粒度管理
// PGROUNDDOWN:  ~(PGSIZE-1) = 0xfffff000，用与运算清掉低 12 位，得到所在页的起始地址
#define PGROUNDDOWN(addr) ((addr) & ~(PGSIZE - 1))
// PGROUNDUP: 先加 (PGSIZE-1) 再向下取整，若本来没对齐则进到“下一页”起始地址，若已对齐保持不变
#define PGROUNDUP(addr)   PGROUNDDOWN((addr) + PGSIZE - 1)

#endif
