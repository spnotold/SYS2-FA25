## 思考题

1. 使用 `printk` 函数输出一个字符 `a` 的过程中需要发生几次特权态切换？请将切换前后的特权态和切换的原因一一列举出来。

答：需要 **2 次特权态切换**（按“输出 1 个字符”这一条 SBI 调用的必经流程计）。

- **S → M**：内核在 S 态调用 `sbi_ecall(...)`，执行 `ecall` 触发异常；该异常在 `medeleg` 中未委托给 S 态，因此陷入 **M 态**，跳到 `mtvec` 进入 `mini_sbi` 处理。
- **M → S**：`mini_sbi` 完成 SBI 请求后执行 `mret`，`CSRModule` 根据 `mepc/mstatus.mpp` 恢复到 **S 态**并跳回 `mepc` 继续执行。



1. 如果流水线的 IF、ID、MEM 阶段都检测到了异常发生，应该选择哪个流水级的异常作为 trap_handler 处理的异常? 请说说为什么这么选择。

答：应该选择 **最老（最接近提交/WB）的那条指令**对应的异常；在 IF/ID/MEM 同时都有异常时，就是选择 **MEM 阶段**那条指令的异常。

原因：为了保证 **精确异常（precise trap）** 的语义——在软件看来，异常发生点之前的指令都已按程序顺序提交生效，异常发生点之后（更年轻）的指令都不应产生任何可见副作用，应当被 flush 掉。选择最老的异常才能满足“按程序顺序先处理最早发生的异常”。


3. 现在你能够在你自己设计的 CPU 上运行你自己编写的操作系统内核了，这给你带来了很大的自由度，你可以做到很多你直接在自己的电脑上编程可能做不到的事情。你想挑战在你的最小系统上实现什么？无需真的实现，给出大致思路即可。

答：我想在这个“最小系统”上整一个偏 AI 方向的小活——在内核里跑一个极简的强化学习（Q-learning）demo，让它在一个玩具环境里自己学会“走到终点”，然后通过 `printk` 在串口上把训练进度打出来（比如 episode 数、平均步数、学出来的策略）。

**我做了什么 / 怎么做的：**

- 我没去改硬件，就只在内核 `arch/riscv/kernel/proc.c` 里动手。
- 选择放在 `dummy_task()` 里做：因为它本来就是“死循环跑着打印”，很适合塞一个“每个 tick 干一点点活”的小任务。
- 打印也尽量短：只在 episode 结束时打印，并且前几次 episode 先每次都打印让你能看见现象，后面再降低频率防止刷屏。

**代码逻辑（我这次的理解版）：**

- 环境是一个 1D 走廊：状态 `s=0..N-1`，从 `0` 出发，走到 `N-1` 就算到终点（episode 结束）。
- 动作就两个：`L` 左 / `R` 右。
- 奖励：到终点给 `+1`，否则每走一步给 `-1`（用定点数缩放，避免浮点）。
- 用 Q-learning 更新 `Q[s][a]`：每步根据 `r + γ*maxQ(s')` 更新当前动作的 Q 值（α/γ 都用移位实现）。
- 学到一定程度后，“贪心策略”会变成一路向右（`RRRR...G`），平均步数也会下降，这就是它“学会了”的表现。

**强化学习代码（我写在内核里的那段，摘自 `proc.c`）：**

```c
// ------------ Q-learning Demo（toy environment）------------
#define RL_N_STATES 8
#define RL_GOAL (RL_N_STATES - 1)
#define RL_Q_SCALE 1024         // 1.0 => 1024（定点数）
#define RL_ALPHA_SHIFT 3        // α = 1/8
#define RL_GAMMA_NUM 7          // γ = 7/8
#define RL_GAMMA_SHIFT 3
#define RL_STEPS_PER_TICK 4     // 每次 tick 训练几步（加快看到现象）

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

  // ε-greedy：1/16 概率随机探索，否则走贪心动作
  uint64_t r = rl_rand_u64();
  int a = ((r & 0xFULL) == 0) ? (int)((r >> 8) & 1ULL)
                             : rl_argmax2(rl_Q[s][0], rl_Q[s][1]);

  // 环境转移：0=左，1=右
  int ns = s;
  if (a == 0) {
    if (ns > 0) ns--;
  } else {
    if (ns < RL_GOAL) ns++;
  }

  // 奖励：到终点 +1，否则每步 -1（定点数）
  int32_t reward = (ns == RL_GOAL) ? (1 * RL_Q_SCALE) : (-1 * RL_Q_SCALE);

  // target = r + γ*maxQ(ns)
  int32_t maxq = (rl_Q[ns][0] > rl_Q[ns][1]) ? rl_Q[ns][0] : rl_Q[ns][1];
  int32_t target =
      reward + (int32_t)(((int64_t)maxq * RL_GAMMA_NUM) >> RL_GAMMA_SHIFT);

  // Q-learning 更新：Q += α*(target - Q)
  int32_t td = target - rl_Q[s][a];
  rl_Q[s][a] += (td >> RL_ALPHA_SHIFT);

  rl_state = ns;
  rl_ep_len++;

  // 到终点：episode 结束，打印并重置到起点
  if (ns == RL_GOAL) {
    rl_ep++;
    rl_ep_len_sum += rl_ep_len;

    // 前 8 个 episode 都打印；之后每 8 个 episode 打印一次
    if (rl_ep <= 8 || ((rl_ep & 7ULL) == 0)) {
      char policy[RL_N_STATES + 1];
      for (int i = 0; i < RL_N_STATES; ++i) {
        policy[i] = (i == RL_GOAL) ? 'G'
                                   : (rl_argmax2(rl_Q[i][0], rl_Q[i][1]) ? 'R'
                                                                        : 'L');
      }
      policy[RL_N_STATES] = '\0';
      printk("[RL] ep=%" PRIu64 " avg_len=%" PRIu64 " pol=%s\n", rl_ep,
             (rl_ep_len_sum / rl_ep), policy);
    }

    rl_state = 0;
    rl_ep_len = 0;
  }
}

// ------------ 接入 dummy_task（每个线程每个 tick 训练）------------
uint64_t prev_cnt_rl = (uint64_t)-1;
while (1) {
  if (current->counter != prev_cnt_rl) {
    prev_cnt_rl = current->counter;
    for (int i = 0; i < RL_STEPS_PER_TICK; ++i) {
      rl_step();
    }
  }
}
```

![image-20251224211040028](C:\Users\LENOVO\AppData\Roaming\Typora\typora-user-images\image-20251224211040028.png)

图中 `[RL] ...` 这一行是我在 `proc.c` 里加的 Q-learning demo 的训练日志，格式是：

`[RL] ep=<回合编号> avg_len=<平均步数> pol=<当前贪心策略>`

其中 **`ep=1` 的意思是：第 1 个 episode（回合）已经结束**。这里的 episode 定义为：从初始状态 `s=0` 出发，每执行一次 `rl_step()` 算一步，直到到达终点状态 `s==RL_GOAL`（走廊最右端）为止；到达终点后会执行 `rl_ep++`，并把 `rl_state` 重置回 0 开始下一回合。

顺便解释一下同一行里其他字段的含义，便于看日志：

- `avg_len`：到目前为止每个 episode 的平均步数，代码里是 `rl_ep_len_sum / rl_ep`；当 `ep=1` 时它就等于第 1 回合实际走的步数。
- `pol`：按当前 Q 表做贪心选择得到的策略（每个字符对应一个状态）。`L`/`R` 表示该状态更倾向向左/向右走，最后的 `G` 表示终点。

比如：[RL] ep=3 avg_len=26 pol=RLLLRRRG 这一行逐个字段解释就是：

ep=3：第 3 个 episode（回合）已经结束了。也就是它已经从 s=0 出发，走到终点 s==RL_GOAL 三次了。
avg_len=26：到目前为止 前 3 个 episode 的平均步数是 26（avg_len = (len1+len2+len3)/3，代码里就是 rl_ep_len_sum / rl_ep）。
pol=RLLLRRRG：这是当前按 Q 表贪心选择得到的“策略字符串”，长度等于状态数 RL_N_STATES=8。
第 0 个字符 R：在状态 s=0 时更倾向选 Right（向右）
第 1~3 个字符 LLL：在 s=1,2,3 更倾向向左
第 4~6 个字符 RRR：在 s=4,5,6 更倾向向右
最后 G：终点状态 s=7（goal），只是标记，不代表动作

可以从图中看到，随着ep的增加，平均步数越来越少，说明起学习效果了