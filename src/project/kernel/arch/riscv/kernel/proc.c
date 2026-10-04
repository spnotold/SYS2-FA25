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

// -----------------------------------------------------------------------------
// “整活”用：一个极简 Q-learning Demo（放在 dummy_task 里跑）
// -----------------------------------------------------------------------------
// 目标：report 的思考题 #3 可行实现思路，同时做到：
// - 不改硬件、不改中断/CSR 机制；
// - 代码量小（100~200 行级别）；
// - 输出尽量短，避免仿真时间都耗在 printk 上。
//
// 环境（toy environment）：
// - 1D 走廊，状态 s ∈ [0, RL_N_STATES-1]，初始 s=0，终点为 RL_GOAL。
// - 动作 a ∈ {0,1}：0=向左，1=向右。
// - 到达终点奖励 +1，否则每步奖励 -1（用定点数缩放）。
//
// 学习算法（tabular Q-learning，定点数实现）：
//   Q[s][a] ← Q[s][a] + α * ( r + γ*max_a' Q[s'][a'] - Q[s][a] )
// 这里用移位实现 α=1/8，γ=7/8。
//
// 运行方式：
// - 让每个（非 idle）线程都在 dummy_task 中训练；
// - 且“每当 current->counter 发生变化”时跑 1 步（基本等价于每次 tick 一步），
//   避免 while(1) 中跑太快导致输出/训练步数爆炸。
// -----------------------------------------------------------------------------
#define RL_N_STATES 8
#define RL_GOAL (RL_N_STATES - 1)
#define RL_Q_SCALE 1024         // Q 值定点缩放：1.0 => 1024
#define RL_ALPHA_SHIFT 3        // α = 1/8
#define RL_GAMMA_NUM 7          // γ = 7/8
#define RL_GAMMA_SHIFT 3

#define RL_STEPS_PER_TICK 4

static uint64_t rl_rng_state = 2025; // 固定种子：每次仿真可复现
static int32_t rl_Q[RL_N_STATES][2];
static int rl_state = 0;
static uint64_t rl_ep = 0;
static uint64_t rl_ep_len = 0;
static uint64_t rl_ep_len_sum = 0;

static uint64_t rl_rand_u64(void) {
  // xorshift64*：简单、可复现、无需 libc
  uint64_t x = rl_rng_state;
  x ^= x >> 12;
  x ^= x << 25;
  x ^= x >> 27;
  rl_rng_state = x;
  return x * 2685821657736338717ull;
}

static int rl_argmax2(int32_t q0, int32_t q1) { return (q1 >= q0) ? 1 : 0; }

static void rl_step(void) {
  int s = rl_state;

  // ε-greedy：以较小概率随机探索，否则选贪心动作
  // 这里用 “低 4 bit 全 0” 作为 1/16 的探索概率（可调）
  uint64_t r = rl_rand_u64();
  int a = ((r & 0xFULL) == 0) ? (int)((r >> 8) & 1ULL)
                             : rl_argmax2(rl_Q[s][0], rl_Q[s][1]);

  // 环境一步转移
  int ns = s;
  if (a == 0) {
    if (ns > 0)
      ns--;
  } else {
    if (ns < RL_GOAL)
      ns++;
  }

  // 奖励：到终点 +1，否则每步 -1（用定点数缩放）
  int32_t reward = (ns == RL_GOAL) ? (1 * RL_Q_SCALE) : (-1 * RL_Q_SCALE);

  // 计算 target = r + γ * maxQ(ns)
  int32_t maxq = (rl_Q[ns][0] > rl_Q[ns][1]) ? rl_Q[ns][0] : rl_Q[ns][1];
  int32_t target =
      reward + (int32_t)(((int64_t)maxq * RL_GAMMA_NUM) >> RL_GAMMA_SHIFT);

  // Q-learning 更新（α=1/8）
  int32_t td = target - rl_Q[s][a];
  rl_Q[s][a] += (td >> RL_ALPHA_SHIFT);

  rl_state = ns;
  rl_ep_len++;

  // 终止并重置 episode（到达目标）
  if (ns == RL_GOAL) {
    rl_ep++;
    rl_ep_len_sum += rl_ep_len;

    // 控制输出频率：
    // - 前 8 个 episode 每次都打印（方便尽快看到现象）
    // - 之后每 8 个 episode 打印一次（避免刷屏）
    // 原版本（更保守、输出更少）：每 32 个 episode 打印一次
    // if ((rl_ep & 31ULL) == 0) { ... }
    if (rl_ep <= 8 || ((rl_ep & 7ULL) == 0)) {
      char policy[RL_N_STATES + 1];
      for (int i = 0; i < RL_N_STATES; ++i) {
        if (i == RL_GOAL) {
          policy[i] = 'G';
        } else {
          policy[i] = rl_argmax2(rl_Q[i][0], rl_Q[i][1]) ? 'R' : 'L';
        }
      }
      policy[RL_N_STATES] = '\0';
      printk("[RL] ep=%" PRIu64 " avg_len=%" PRIu64 " pol=%s\n", rl_ep,
             (rl_ep_len_sum / rl_ep), policy);
    }

    rl_state = 0;
    rl_ep_len = 0;
  }
}

// 所有非 idle 线程运行的入口函数：
// - 线程从这里开始执行，一直在 while(1) 里自旋
// - 它本身不做“真正工作”，只是在合适的时机打印一行“我正在运行”的信息，方便观察调度行为
// 详细说明：
// - local: 记录“当前线程自己已经打印了多少次日志”，每次打印就加 1
// - prev_cnt: 记录“上一次看到的 current->counter 值”，用来判断 counter 有没有发生变化
// - current->counter: 表示当前线程还剩多少“时间片单位”可以继续执行
// 逻辑流程：
// 1) 一直在 while(1) 中循环
// 2) 每次循环检查 current->counter 是否和 prev_cnt 不一样：
//    - 一样：说明这次循环中时间片没变化，不打印，继续下一轮
//    - 不一样：说明时间片发生了变化（被扣减或被重新赋值），这次应该打印一行日志
// 3) 对于 counter == 1 的特殊情况：
//    - 优先级为 1 的线程，每轮只会得到 1 个时间片
//    - 从它“自己能看到”的时刻来看，counter 几乎总是 1
//    - 如果不做特殊处理，它看到的 counter 和 prev_cnt 总是一样，就永远不会进入打印分支
//    - 因此这里在看到 counter == 1 时，手动把 counter 改成 0，制造一个“变化”：
//      这样下一次 counter 从 0 变回 1 时，它就能察觉到变化并打印日志
// 4) 更新 prev_cnt 为当前的 counter，并递增 local，打印一行日志：
//    - 日志格式：[PID = x] Running. local = y
//    - 表示“PID 为 x 的这个线程，第 y 次被观测到在运行”
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
      printk("[P=%" PRIu64 "] %u\n", current->pid, ++local);
    }
  }
// #else
//   unsigned local = 0;
//   uint64_t prev_cnt = (uint64_t)-1;
//   uint64_t prev_cnt_rl = (uint64_t)-1;

//   while (1) {
//     // 保留原有的“调度观测输出”（短输出，便于验收/调试）
//     if (current->counter != prev_cnt) {
//       prev_cnt = current->counter;
//       //printk("[P=%" PRIu64 "] %u\n", current->pid, ++local);
//     }

//     // 逻辑：每个线程每当 tick 导致 counter 变化时训练一步
//     if (current->counter != prev_cnt_rl) {
//       prev_cnt_rl = current->counter;
//       for (int i = 0; i < RL_STEPS_PER_TICK; ++i) {
//         rl_step();
//       }
//     }
//   }
// #endif
}

// 线程系统初始化：
// - 把随机数种子固定为 2025，这样每次启动线程优先级都一样，方便和实验文档对比输出
// - 给内核自己的 idle 线程（PID=0）分一块空间，设置好状态，并让 current/task[0] 指向它
// - 给 1..NR_TASKS-1 号普通线程各分一块 4KB 空间：
//   * 填写状态(state)、线程号(pid)
//   * priority 在 [PRIORITY_MIN, PRIORITY_MAX] 之间随机生成
//   * counter 先设为 0，第一次调度时再统一按 priority 填充
//   * 为第一次被调度时准备好“跳板”：ra = __dummy，sp = 这块 4KB 的高地址作为栈顶
//   * 把指针放进全局数组 task[i] 中，供调度器遍历
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
    // p->priority =
    //     (uint64_t)(rand() % (PRIORITY_MAX - PRIORITY_MIN + 1)) + PRIORITY_MIN;
    // TA 建议：把进程时间片缩到 3（本实验中 counter 由 priority 赋值）
    p->priority = 3;
    p->counter = 0;//初始化时 p->counter = 0;：先都设成 0，等第一次调度时统一分配时间片。

    // 为新线程设置初始上下文
    p->thread.ra = (uint64_t)__dummy;//把返回地址设置为__dummy
    p->thread.sp = (uint64_t)((uint8_t *)p + PGSIZE);

    task[i] = p;
  }

  printk("...task_init done!\n");
}

void switch_to(struct task_struct *next) {
  // 线程切换的“入口函数”（C 级别）：
  // - 参数 next 表示“下一个要运行的线程”
  // - 它本身不直接操作寄存器，而是：
  //   * 做一些简单判断和状态更新（current 指针）
  //   * 打印一行“要切换到谁”的日志
  //   * 最后把真正的寄存器保存/恢复工作交给汇编函数 __switch_to
  if (next == current) {
    // 如果下一个要运行的线程，刚好就是当前线程，那就没必要切换，直接返回
    return;
  }

  // prev 记录“之前运行的线程”
  struct task_struct *prev = current;
  // 更新全局 current：从现在开始，大家口中的“当前线程”就是 next
  current = next;

  // 打印本次要切换到的线程信息，方便和实验文档对比：
  // 形如：switch to [PID = 2, PRIORITY = 10, COUNTER = 10]
  // printk("switch to [PID = %" PRIu64 ", PRIORITY = %" PRIu64
  //        ", COUNTER = %" PRIu64 "]\n",
  //        next->pid, next->priority, next->counter);

  // 调用底层汇编实现的 __switch_to：
  // - 把 prev 的寄存器（ra/sp/s0-s11）保存到 prev->thread 里
  // - 把 next->thread 里的寄存器内容恢复到 CPU 寄存器中
  // 从 __switch_to 返回时，CPU 上的“执行上下文”已经完全变成 next 线程的了
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
        // printk("SET [PID = %" PRIu64 ", PRIORITY = %" PRIu64
        //        ", COUNTER = %" PRIu64 "]\n",
        //        p->pid, p->priority, p->counter);
      }
    }
    // 然后重新回到循环顶部再次选择
  }
}

// 上面的 schedule 函数实现了一个简单的优先级调度器：
// - 不断在所有可运行线程中查找 counter 最大的线程（跳过 idle），并切换过去运行；
// - 如果所有线程的 counter 都为 0，则按各自的 priority 重新赋值 counter（时间片），
//   打印一行 SET 日志后再重新选择；
// - 这样就实现了“优先级高 → 初始 counter 大 → 被调度运行的总时间更长”的效果。
