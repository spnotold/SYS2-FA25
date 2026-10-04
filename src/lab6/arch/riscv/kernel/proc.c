#include <inttypes.h>
#include <mm.h>
#include <printk.h>
#include <private_kdefs.h>
#include <proc.h>
#include <stdlib.h>

static struct task_struct *task[NR_TASKS]; // 线程数组，所有的线程都保存在此
static struct task_struct *idle;           // idle 线程
struct task_struct *current;               // 当前运行线程

void __dummy(void);
void __switch_to(struct task_struct *prev, struct task_struct *next);

void dummy_task(void) {
  unsigned local = 0;
  unsigned prev_cnt = 0;
  while (1) {
    if (current->counter != prev_cnt) {
      if (current->counter == 1) {
        // 若 priority 为 1，则线程可见的 counter 永远为 1（为什么？）
        // 通过设置 counter 为 0，避免信息无法打印的问题
        current->counter = 0;
      }
      prev_cnt = current->counter;
      printk("[PID = %" PRIu64 "] Running. local = %u\n", current->pid,
             ++local);
    }
  }
}

void task_init(void) {
  srand(2025);

  // 1. 为 idle 分配一个物理页并初始化
  idle = (struct task_struct *)alloc_page();
  idle->state = TASK_RUNNING;
  idle->pid = 0;
  idle->priority = 0;
  idle->counter = 0;

  current = idle;
  task[0] = idle;

  // 4. 初始化其余任务 task[1..NR_TASKS-1]
  for (int i = 1; i < NR_TASKS; ++i) {
    struct task_struct *p = (struct task_struct *)alloc_page();

    p->state = TASK_RUNNING;
    p->pid = i;
    p->priority =
        (uint64_t)(rand() % (PRIORITY_MAX - PRIORITY_MIN + 1)) + PRIORITY_MIN;
    p->counter = 0;

    // 为新线程设置初始上下文
    p->thread.ra = (uint64_t)__dummy;
    p->thread.sp = (uint64_t)((uint8_t *)p + PGSIZE);

    task[i] = p;
  }

  printk("...task_init done!\n");
}

void switch_to(struct task_struct *next) {
  if (next == current) {
    return;
  }

  struct task_struct *prev = current;
  current = next;

  printk("switch to [PID = %" PRIu64 ", PRIORITY = %" PRIu64
         ", COUNTER = %" PRIu64 "]\n",
         next->pid, next->priority, next->counter);

  __switch_to(prev, next);
}

void do_timer(void) {
  // 1. 如果当前线程时间片耗尽，则直接进行调度
  if (current->counter == 0) {
    schedule();
    return;
  }

  // 2. 否则将运行剩余时间减 1，若剩余时间仍然大于 0 则直接返回，否则进行调度
  current->counter--;
  if (current->counter > 0) {
    return;
  }

  schedule();
}

void schedule(void) {
  while (1) {
    uint64_t max_counter = 0;
    int next = 0;

    // 1. 在所有可运行线程中寻找 counter 最大的线程（跳过 idle）
    for (int i = 1; i < NR_TASKS; ++i) {
      struct task_struct *p = task[i];
      if (p && p->state == TASK_RUNNING && p->counter > max_counter) {
        max_counter = p->counter;
        next = i;
      }
    }

    // 2. 如果找到了 counter > 0 的线程，则进行切换
    if (max_counter > 0) {
      switch_to(task[next]);
      return;
    }

    // 3. 所有线程 counter 均为 0，重新按照 priority 赋值 counter
    for (int i = 1; i < NR_TASKS; ++i) {
      struct task_struct *p = task[i];
      if (p && p->state == TASK_RUNNING) {
        p->counter = p->priority;
        printk("SET [PID = %" PRIu64 ", PRIORITY = %" PRIu64
               ", COUNTER = %" PRIu64 "]\n",
               p->pid, p->priority, p->counter);
      }
    }
    // 然后重新回到循环顶部再次选择
  }
}
