## 思考题

1. 在 RV64 中共有 32 个通用寄存器，为什么 `__switch_to` 中只需保存 14 个？

我们在 `__switch_to` 里切的是“内核线程上下文”，不是完整的 CPU 上下文。

线程在被时钟中断打断时，`_traps` 已经把 32 个通用寄存器全部压栈到它自己的内核栈里了。  
这些 trap 中保存的寄存器会在 `_traps` 返回前统一恢复，所以不需要再放到 `thread_struct` 里逐个保存。

RISC‑V ABI 里，只有部分寄存器需要在“函数调用/切换”之间保持。

- `x0` 恒为 0，不用保存。  
- `t0–t6`、`a0–a7` 属于 caller‑saved  
  （caller‑saved 寄存器：这些寄存器在调用函数时不保证会被保留，callee 可以随便用、随便改。如果 caller 想在调用前后保留它们的值，必须自己先把它们保存（比如压栈），调用完再恢复，所以叫“由 caller 来保存”的寄存器。），调用别的函数（包括我们自己写的 `__switch_to`）时，调用方本来就不能指望它们被保持；因此切换线程时也不需要为它们保存。  
- `gp`、`tp` 在这个实验里对所有线程是共享/不变的，也不需要按线程单独保存  
  （`gp`（global pointer）是全局指针，通常指向一段全局数据区域，在本实验中对所有线程是共享且基本不变的；  
  `tp`（thread pointer）是线程指针，通常用来指向线程/CPU 本地数据，在本实验中也没有为每个软件线程单独改变。）。

真正需要在线程之间保持的是：返回地址 `ra`、栈指针 `sp`，以及所有 callee‑saved 寄存器 `s0–s11`。  
这 14 个寄存器（`ra + sp + s0–s11`）一起，就构成了一个内核线程继续执行所需的最小“内核上下文”。

而且这两个东西保存寄存器的目的不一样：

- 14 个寄存器：保证“还能沿着原来的内核调用栈（`__switch_to`→`switch_to`→`schedule`→`do_timer`→`trap_handler`→`_traps`）正常走回去”；  
- 32 个寄存器：保证“回到 `_traps` 之后，还能把被打断那一刻的执行现场完整恢复出来”。


2. 线程间什么是共享的，什么是独有的？具体体现在本次实验中是哪些？

线程共享的：所有线程看到的是“同一份”，其中一个改了，别人也会受到影响。  
线程独有的：每个线程有自己的那一份，互相不影响。

**一、线程间共享的东西（本次实验中的体现）**

- **内核代码**

  所有线程共用同一份 `.text`，比如：  
  `dummy_task`、`task_init`、`schedule`、`do_timer`、`switch_to`，  
  `trap_handler`、`clock_set_next_event`、`mm_init` 等。  
  哪个线程在跑这些函数，执行的都是同一段指令。

- **全局变量 / 静态数据**

  `src/project/kernel/arch/riscv/kernel/proc.c` 里的：  
  `static struct task_struct *task[NR_TASKS];`  
  `static struct task_struct *idle;`  
  `struct task_struct *current;`  

  `mm.c` 里的：  
  `static struct kfreelist *kfreelist;`（空闲物理内存链表）  

  这些都是所有线程共享的一份内核状态，谁改了，别人看到的也跟着变化。

- **物理内存池**

  `mm_init()` 从 `_ekernel` 到 `PHY_END` 之间，把每块 4KB 加入 `kfreelist`：

  ```c
  for (s = PGROUNDUP(_ekernel); s + PGSIZE <= PHY_END; s += PGSIZE)
      free_pages(s);
  ```

  之后所有线程通过 `alloc_page` / `free_pages` 都在这同一块物理内存池里要内存、还内存。

- **硬件资源 / 中断系统**

  定时器、中断控制寄存器等：  
  `stvec`、`sie`、`sstatus`、`time` CSR，都只有一份，线程之间靠调度轮流使用。  
  `clock.c` 里的 `clock_set_next_event()` 调的是同一个 `sbi_ecall`，设置的是同一个硬件时钟。  
  SBI 打印（`sbi_ecall` + `printk`）也是所有线程共享一个输出设备。

**二、线程独有的东西（本次实验中的体现）**

- **每个线程自己的 `task_struct` 内容**

  在 `proc.h` 里：

  ```c
  struct task_struct {
    uint64_t pid;      // 线程 ID
    uint64_t state;    // 状态
    uint64_t priority; // 优先级
    uint64_t counter;  // 剩余时间片
    struct thread_struct thread; // 线程上下文
  };
  ```

  对于不同线程（比如 PID=1 和 PID=2）：

  - `pid` 不同；  
  - `priority`、`counter` 各有各的值。

- **每个线程自己的执行上下文**

  `thread_struct`：

  ```c
  struct thread_struct {
    uint64_t ra;
    uint64_t sp;
    uint64_t s[12]; // s0~s11
  };
  ```

  `ra`：这个线程“下次继续执行时要返回到哪”；  
  `sp`：这个线程自己的内核栈指针；  
  `s[0..11]`：这个线程的 callee-saved 寄存器状态。

- **每个线程自己的栈（和对应的 trap 帧）**

  在 `task_init` 里，每个线程分了一块 4KB：

  ```c
  struct task_struct *p = (struct task_struct *)alloc_page();
  // 低地址：task_struct
  p->thread.sp = (uint64_t)((uint8_t *)p + PGSIZE); // 高地址：栈顶
  ```

  这一页内存的低地址部分放 `task_struct`，高地址往下是这个线程的内核栈。  
  `_traps` 保存的那 32 个寄存器快照，是压在“当前线程自己的栈上”的：

  - A 被中断，就压在 A 的栈；  
  - B 被中断，就压在 B 的栈；  

  这些 trap 帧也是按线程分开的，不互相共享。

- **每个线程在 `dummy_task` 里的局部变量**

  `dummy_task` 里的 `local`、`prev_cnt` 是在栈上分配的，所以：

  - 对 PID=1 来说，有自己的一份 `local`、`prev_cnt`；  
  - 对 PID=2 来说，也有自己的一份。

当线程第一次调用 `__switch_to` 时，其 `ra` 寄存器恢复的返回地址是 `__dummy`。线程在之后对 `__switch_to` 的调用中，`ra` 寄存器保存 / 恢复的函数返回地址是什么呢？请使用 gdb 追踪一次完整的线程切换流程（附上你认为关键的截图），并特别关注 `pc`、`ra` 寄存器、`sepc` CSR 的变化。

![屏幕截图 2025-12-09 192402](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-09 192402.png)

![屏幕截图 2025-12-09 192419](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-09 192419.png)

打断点在switch_to和 dummy,然后按c先停在__switch_to查看ra和pc和sepc，数据如上图

- pc = 0x80200194 <__switch_to>：说明现在正在执行 __switch_to。
- ra = 0x80200578 <switch_to+76>：说明这次调用 __switch_to 的人是 switch_to，将来 ret 会回到 switch_to+76 那里。
- sepc = 0x80200270：这是这次中断将来要 sret 回去的地址。

然后再次按c进入__dummy，

![屏幕截图 2025-12-09 192832](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-09 192832.png)

数据如图，

- pc = 0x80200184 <__dummy>
- ra = 0x80200184 <__dummy>
- sepc = 0x80200270（这是 dummy_task 的地址）

含义：

- 这是**第一次切到某个新线程 B**，我们在 task_init 里给它的 thread.ra 填的是 __dummy；
- __switch_to 把这个 ra 恢复出来，ret 跳到 __dummy；
- 在 __dummy 里，看到：
    - pc 在 __dummy；
    - ra 也指向 __dummy（因为是 ret 跳过来的）；
    - 然后 __dummy 把 sepc 改成 dummy_task，sret 出去开始跑 dummy_task。

这对应题目里那句：“**线程第一次调用 __switch_to 时，ra 恢复的是 __dummy**”。继续按c，又回到__switch_to:
![屏幕截图 2025-12-09 193058](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-09 193058.png)
数据如图**后面再发生一次线程切换，在 __switch_to**

下面那张图停在 __switch_to：

- pc = 0x80200194 <__switch_to>
- ra = 0x80200578 <switch_to+76>
- sepc = 0x80200444（这是某个 dummy_task 里被打断的位置）

含义：

- 这时候线程已经在跑 dummy_task 了，被时钟中断打断；
- 中断后走到 do_timer → schedule → switch_to，switch_to 再 call __switch_to；
- 所以现在在 __switch_to 里面：
    - pc 在 __switch_to；
    - ra = switch_to+76，正是“**从 switch_to 调用 __switch_to 那条 call 指令的下一条指令地址**”；
    - sepc = 0x80200444，是这次中断打断的 dummy_task 里的指令地址。

这说明：**后续（非第一次）调用 __switch_to 时，ra 保存的就是 switch_to 的返回地址，而不是 __dummy。**

这个 ra 会被 __switch_to 存进当前线程的 thread_struct 里，下次再切回这个线程时，又会被恢复出来，然后 ret 回到 switch_to+76，再一路退回 schedule → do_timer → trap_handler → _traps，最后 _traps 用那 32 个寄存器把 dummy_task 的现场恢复出来。









尝试回答这些问题。第 2 题的结果对这些问题应当很有帮助：

- 为什么在 `__dummy` 中使用 `#!asm sret` 而不是 `#!asm ret`？
- 为什么在 `__switch_to` 中使用 `#!asm ret` 而不是 `#!asm sret`？
- 为什么我们不直接在 `start_kernel` 中调用 `schedule` 进行调度，而是要把这件事交给第一次时钟中断呢？请尝试直接调用 `schedule` 观察现象。在中断发生时，有哪些重要的 CSR 发生了变化？

1. 为什么在 __dummy 里用 sret 而不是 ret？

线程第一次被调度时（比如 PID=1），它以前从来没跑过，也从来没被中断过，所以：

栈上没有属于它自己的 trap 帧；
但我们在 task_init 里把它的 thread.ra 写成了 __dummy：

```c
p->thread.ra = (uint64_t)__dummy;
```

调度器第一次切到它时，调用链是：

schedule → switch_to → __switch_to →（ret）→ __dummy

这时候我们还在 trap 处理的上下文里，sepc 还是“之前那个线程被打断时的 PC”。

__dummy 做的事情是：

```asm
la   t0, dummy_task
csrw sepc, t0      # 把 sepc 改成 dummy_task 的地址
sret               # 按 sepc/sstatus 退出这次 trap
```

也就是说：我们在“假装”这个新线程是从一次中断里恢复出来的，让它第一次执行就从 dummy_task 开始跑。

如果这里用 ret：

只会“普通函数返回”到 _traps 里的某个位置，而不会退出 trap；
PC 会回到 trap 处理代码，而不是 dummy_task；
sepc/sstatus 完全没用上，线程根本跑不到自己的 dummy_task，整个流程乱掉。
所以：__dummy 的任务就是“设置好 sepc，然后用 sret 正式退出 trap，跳进 dummy_task”，只能用 sret，不能用 ret。

2. 为什么在 __switch_to 里用 ret 而不是 sret？

__switch_to 是从 C 函数 switch_to 调用进来的，一个“普通函数”：

```c
switch_to(next) {
  ...
  __switch_to(prev, next);  // call
}
```

它的工作只有两件：

```asm
# 保存当前线程的 ra/sp/s0~s11 到 prev->thread
# 恢复下一个线程的 ra/sp/s0~s11 从 next->thread
ret   # 回到 switch_to 里 call 的下一条指令
```

也就是说：__switch_to 只是“改寄存器 + 函数返回”，并不想结束这次 trap，也不想根据 sepc 跳回用户/线程代码。

用 ret 正好符合这个语义：
“我干完了，返回到调用我的 C 函数 (switch_to) 继续执行。”

如果这里用 sret：

会被当成“从一次 trap 里返回”，
会按当前的 sepc / sstatus.SPP/SPIE 直接跳走，完全绕开 switch_to/schedule/do_timer/trap_handler/_traps 这条调用链；
流程直接乱掉。
所以：__switch_to 是“内核里的普通 helper 函数”，只需要 ret 回到 switch_to，不应该动 sepc 和特权状态，不能用 sret。

3. 为什么不能在 start_kernel 里直接调 schedule，而要等第一次时钟中断？

核心原因：我们这一套 __dummy + sret 的设计，是建立在“当前是在 trap 处理上下文里”的前提上的——也就是：

硬件已经帮我们做过“进入中断”的那一步：
把被打断位置写进 sepc；
把中断原因写进 scause；
把当前特权级、SIE 位等塞进 sstatus（SPP/SPIE）。
然后 _traps 才会：

在栈上按固定格式压 32 个寄存器 + sepc；
调用 trap_handler → do_timer → schedule → switch_to → __switch_to；
最后由 __dummy 用 sret 退出这次 trap。

如果你在 start_kernel 里直接调 schedule()，会发生什么？

根本还没发生过第一次中断：
没有 _traps；
栈上没有 trap 帧；
sepc/sstatus 里的“上一次被打断的位置和特权信息”也不对。

schedule → switch_to → __switch_to → __dummy → sret：
__dummy 会傻乎乎地认为“我在一次 trap 里”，直接 sret；
但这时的 sepc 要么是垃圾、要么是某个和我们预期不同的内核地址；
sret 就会跳到奇怪的地方去（很可能直接跑飞）。

`dummy_task` 的注释中提到了 `priority` 为 1 时的特殊情况。请解释为什么 `priority` 为 1 时，如果去除对 `counter` 的特殊处理，会导致信息无法打印（即，为什么线程可见的 `counter` 永远为 1）？

每轮重置时间片时，我们做的是：

```c
p->counter = p->priority;
```

`dummy_task` 打印的条件是：

```c
if (current->counter != prev_cnt) {
    prev_cnt = current->counter;
    printk(...);
}
```

也就是：只有当它看到 `counter` 和上次不一样时才打印。

1. priority = 1 的线程，每轮拿到多少时间？

重置时：`counter = priority = 1`。  
每来一次时钟中断，`do_timer` 里会 `current->counter--`，减 1，用完（=0）就调度别的线程。  
所以一轮里这条线程的 `counter` 变化是：

`1`（刚重置） → `0`（扣完马上被切走）

2. 从这个线程“自己能看到”的视角，它什么时候在跑？

分三段看：

刚被切上来的瞬间：

第一轮刚重置完，`counter` 被设成 1；  
`switch_to` 把它切上来，它开始跑 `dummy_task`；  
它看到的是：`current->counter == 1`。

继续跑一会儿，中断来了：

时钟中断触发，CPU 跳到 `_traps`，跑 `trap_handler → do_timer`；  
在 `do_timer` 里，对于这个线程：

```c
current->counter--;  // 1 -> 0
schedule();          // 用完了，切给别的线程
```

注意：这时候线程已经被打断、切走了，`dummy_task` 的那段代码没再执行任何一行。

下一轮又轮到它时：

所有线程跑完一轮 `counter` 都成 0；  
`schedule` 重置：`counter = priority`，对它就是又变回 1；  
再次 `switch_to` 切回来，它又开始跑 `dummy_task`；  
它一抬头又看到：`current->counter == 1`。

3. `dummy_task` 看到的是怎样一条“counter 时间线”？

`dummy_task` 里的逻辑是：

```c
if (current->counter != prev_cnt) {
    prev_cnt = current->counter;
    printk(...);
}
```

但它的“观察点”只有在线程正在跑的时候，结合上面的时间线，它看到的是：

第一次被切上来：`counter = 1`，`prev_cnt` 初始为 0，看到“0 → 1”，可以打印一次；  
之后在它跑的期间，`counter` 始终保持 1，直到中断来；  
真正从 1 减到 0 是发生在 `do_timer` 里、它已经被打断的时候，它看不到这一刻；  
下次再切回来前，`counter` 又从 0 被重置成 1，它再次上线时，看见的还是 1，而 `prev_cnt` 也是 1，因为上次看到的就是 1。

于是对它来说，`counter` 的可见序列就是：

- 第一次：看到 1  
- 之后每次：还是看到 1  

中间的 “1 → 0”、“0 → 1” 变化都发生在它“睡着”的时候，它自己完全看不到。

所以：

它第一次打印后，`prev_cnt` 就变成 1；  
以后再看，`current->counter` 也是 1，`current->counter != prev_cnt` 条件永远不成立；  
日志就不会再打印，看起来就像“`counter` 永远是 1”。

4. 为什么特殊处理能解决？

我们加的特殊逻辑是：

```c
if (current->counter == 1) {
    current->counter = 0;
}
```

效果是：

在线程自己看见 `counter == 1` 的那一刻，主动把它改成 0；  
这样这轮里它看到的是“1 → 0”，`prev_cnt` 记成 0；  
下一轮调度重置时，`counter` 变成 1，它再次上线时，会看到“0 → 1”，条件又成立，可以再打印一次。

1. 阅读并理解 `arch/riscv/kernel/mm.c`。为什么在[准备工程](#_8)中，我们不能直接将 `sp` 设置为 `_ekernel` 加上 4 KiB 偏移量？实际上，如果仍然保持这种设置方式，会发现内核无法正常启动。你的回答应当能够解释这一现象。
   
    !!! tip "提示"

        为了帮助你回答这个问题，请回忆 lab4 中的 `vmlinux.lds` 链接示意图：
        ``` linenums="0"
        ┌──────────────┐◄─── _skernel, _start, 0x80200000
        │ .text        │
        ├──────────────┤
        │ .rodata      │
        ├──────────────┤
        │ .data        │
        ├──────────────┤
        │ .bss         │
        ├──────────────┤◄─── _ekernel
        │ 4 KiB stack  │
        └──────────────┘◄─── sp
        ```
        请画出 lab6 中的链接示意图，并标出 `_sbss`、`.bss.stack`、`_ekernel`、`sp` 和任何你认为重要的其他地址。
   ① 为什么不能再用 sp = _ekernel + 4KiB？

在 lab4 里，链接布局大致是：

_skernel / _start
    │
    ▼
  .text
  .rodata
  .data
  .bss
  ├──────────────┤ ◄── _ekernel
  │ 4 KiB stack  │  ◄── sp = _ekernel + 4KiB
这 4KiB 栈不在任何段里，没人管，也没有内存管理，所以这样用没问题。

在 lab6 里，我们引入了物理内存管理，mm_init 会把 _ekernel 之后的内存都当成“可分配”的空间：

void mm_init(void) {
  uint8_t *s = (void *)PGROUNDUP((uintptr_t)_ekernel);
  const uint8_t *e = (void *)PHY_END;
  for (; s + PGSIZE <= e; s += PGSIZE) {
    free_pages(s);
  }
}
也就是说：从 _ekernel 开始到 PHY_END 整块区域都会被加入空闲页链表。

如果还按照老方法把启动栈放在 _ekernel + 4KiB：

_start 一上来就把 sp 设到 _ekernel + 4KiB，C 代码（包括 mm_init 自己）都在用这块区域当栈；
mm_init 扫描 _ekernel 之后的所有 4KiB 块，调用 free_pages：
把这块栈页也当作“空闲内存”挂进 kfreelist；
用 memset(..., 0xfa, PGSIZE) 把整页填成垃圾；
结果就是：当前正在用的栈被当成空闲页清零并链进去，后面一旦有 alloc_page 或函数调用用到这块栈，内核立刻崩掉，看起来就是“内核无法启动”。
所以在有内存管理之后，_ekernel 之后的内存必须视为“可被分配的区域”，不能再拿来做启动栈。

② lab6 里的新布局长什么样？

看 vmlinux.lds：

.bss : ALIGN(0x1000) {
    *(.bss.stack)
    . = ALIGN(0x1000);
    _sbss = .;

    *(.bss .bss.*)
    
    _ebss = .;
}

. = ALIGN(0x1000);
_ekernel = .;
加上 head.S 里的：

.section .bss.stack
.space PGSIZE

...

_start:
    la sp, _sbss     # 启动栈顶
    call mm_init
可以画成这样（lab6）：

_skernel / _start (0x80200000)
      │
      ▼
    .text
    .rodata
    .data
    .bss
    ├──────────────┐
    │ .bss.stack   │  一页，用作启动栈内存
    ├──────────────┤
    │ (对齐到4KiB) │
    ├──────────────┤ ◄── _sbss  （我们让 sp = _sbss，栈向下长，正好落在 .bss.stack 里）
    │ 其它 .bss    │
    │(.bss .bss.*) │
    ├──────────────┤ ◄── _ebss
    ├──────────────┤
    │   对齐       │
    └──────────────┘ ◄── _ekernel
        ↓
   [从这里开始，到 PHY_END 之间的每一页]
   被 mm_init 当成空闲内存加入 kfreelist
这样有两个重要效果：

启动栈 .bss.stack 被包含在 .bss 里面，它是 _ekernel 之前的一部分内核映像；
mm_init 只会从 _ekernel 往后开始 free_pages，不会把 .bss.stack 那一页当成空闲页清掉。

2. 为什么线程的切换要在S态进行而不能在U态进行，如果在U态会有什么后果？
线程切换本质上是在“摆弄内核的东西”和“摆弄特权寄存器”，这些只有 S 态能干。
如果在 U 态干，要么硬件直接报非法，要么用户程序就能随意毁掉别的线程 / 内核，系统安全性没了。

3. 我们本次lab是在所有线程的时间片都消耗为`0`后再进行设置和调度，如果我们改成每运行减少10次之后就重新设置与调度。会出现什么问题？
假设改成：每过固定 10 个时钟中断，就不管谁的 counter 是多少，直接重新设置 counter = priority 然后继续按最大值调度。

看一个简单例子：

两个线程：
A：priority = 10
B：priority = 1
初始：A.counter = 10，B.counter = 1。
根据“选 counter 最大的”：

前 10 个 tick：

每次比较：A 的 counter 总是比 B 大（10、9、8、...）；
调度器每次都选 A，B 一直没机会跑；
过了 10 次中断，你的规则触发重置：
把所有线程 counter 又设回 priority：
A.counter = 10，B.counter = 1。
下一轮 10 个 tick：

情况和上面一模一样，A 又连跑 10 次；
再重置一遍，A.counter = 10，B.counter = 1；
B 还是一次 CPU 机会都没有。
结果：

在这种“每 10 次就重置”的规则下，高优先级线程的 counter 还没用完就被重新补满了；
低优先级线程的 counter 一直是 1，但永远轮不到它，因为高优先级的 counter 总是更大、也总是先被选；
最终效果：优先级低的线程可能永远得不到调度

 本次实验是最后一次软件实验，你有什么想说的话吗，不记录分数，纯属用于吐槽，可以是助教工作，实验设计，实验流程，实验环境等等。
实验文档中的git时间线管理能讲得详细一点吗，我在lab2那里跟着文档git切换，搞坏了3个仓库

![image-20251209203527211](C:\Users\LENOVO\AppData\Roaming\Typora\typora-user-images\image-20251209203527211.png)
