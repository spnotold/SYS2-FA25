## 在实现上下文切换部分，我们需要保存寄存器，谈谈为什么需要保存寄存器和sepc，其他的特权寄存器则不需要，以及为什么要保存在栈上

#### 为什么要保存“通用寄存器”？

硬件在发生 trap 时做的事很有限：把“出事的 PC”写到 sepc，把“原因”写到 scause，把中断相关标志写进 sstatus 里；保存 x0–x31 这些通用寄存器。、、当 CPU 跳进 _traps 的时候，寄存器里的内容就是“被打断的那个 C 函数”的东西；但 _traps 本身、trap_handler、printk、clock_set_next_event 又会大量用 a0/a1/.../t*、s* 等寄存器。如果不在 _traps 里把这些寄存器先保存到内存，再恢复，那么：trap 返回之后，被打断的函数会发现寄存器全被中断处理流程改乱了

所以：为了让被打断的代码像什么都没发生过一样继续执行，必须保存+恢复所有通用寄存器。

#### 为什么要保存 sepc？

sepc 是 Supervisor Exception Program Counter，是一个 CSR，不是普通寄存器；trap 发生时，硬件自动把“出事指令的地址”写进去。sret 返回时，会把 PC 设置成当前 sepc 的值：如果 sepc 被改过 （比如嵌套 S‑mode trap、），sret 就会跳到错误的位置

在 _traps 里我们做的是：

csrr t0, sepc  
sd   t0, 248(sp)   # 入栈  
...  
ld   t0, 248(sp)  
csrw sepc, t0      # 出栈恢复  

也就是说：把硬件给我们的“这次 trap 的返回地址”当成上下文的一部分保存起来，再原样还回去。

为什么其他特权寄存器不用保存？

有些 CSR 本来就是“这次 trap 的快照”，不需要我们帮它保存：scause：硬件已经写好了，我们只读一读用来判断类型，不会改它；stval：这次异常的附加信息，本 lab 里我们还没用。

有些 CSR 是“全局配置”，而不是“每次 trap 都不一样”的东西：stvec：trap 入口地址，一般内核启动时设一次（我们在 head.S 里）, 后面不会在 trap 里改。sie：允许/禁止哪些中断类型，按设计是系统状态，不随单次 trap 变化。sstatus：硬件已经自动帮我们把 SIE → SPIE 等标志转存了，我们这次实验也没在 trap 中修改它。

所以在这个实验的简化模型里，真正需要当作“上下文的一部分”保存的就是：全部通用寄存器 + sepc；其他 CSR 要么硬件帮你管，要么我们当全局状态看。

#### 为什么要保存在“栈上”?

每次 trap 进来就 sp -= 256 开一个新的“上下文帧”，出 trap 时恢复并 sp = 旧值，天然支持嵌套 trap / 多次调用。和 C 函数调用栈模型统可以把 _traps 看成一个“特殊的函数”，栈帧里存的就是“这个函数进来时要保护的寄存器”。我们在 head.S 里给每个 hart 配了一个内核栈顶，然后 _traps 就按 256 字节一个帧往下用，非常自然。

#### 不保存的后果：

把代码改成：

#sd s0, 56(sp)  
#ld s0, 56(sp)后  
#在 test() 某个循环位置打断点，让程序先跑起来  
break test  
continue

#走到 test() 后，看一眼 s0 的值（这是被打断前的 s0）  
info registers s0  
![屏幕截图 2025-12-02 210257](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-02 210257.png)

![屏幕截图 2025-12-02 210338](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-02 210338.png)

#继续运行，等第一次时钟中断触发，进入 _traps / trap_handler  
break _traps  
continue

这时：

在 _traps 入口处再看一次 s0：

info registers s0  

![屏幕截图 2025-12-02 210426](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-02 210426.png)

单步执行直到 sret 前看s0：

![屏幕截图 2025-12-02 210826](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-02 210826.png)

然后按s，回去，再看s0![屏幕截图 2025-12-02 210950](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-02 210950.png)  
发现已经变化，不是原来的s0了

查看sret：

原来![image-20251202212333451](C:\Users\LENOVO\AppData\Roaming\Typora\typora-user-images\image-20251202212333451.png)  
现在：  
![image-20251202212402472](C:\Users\LENOVO\AppData\Roaming\Typora\typora-user-images\image-20251202212402472.png)  
打断点，执行  
![屏幕截图 2025-12-02 213120](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-02 213120.png)

![屏幕截图 2025-12-02 213145](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-02 213145.png)

看到当前sepc，然后打断点在csrw，并stepi执行它，能看到sepc发生变化  
![屏幕截图 2025-12-02 214925](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-02 214925.png)  
![屏幕截图 2025-12-02 214948](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-02 214948.png)

现在继续执行完sret，cpu发现是坏地址又进入新的异常处理函数（scause=2)  
![屏幕截图 2025-12-02 220956](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-02 220956.png)
![屏幕截图 2025-12-02 221527](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-02 221527.png)

2. ## 在我们使用 `make run` 时，OpenSBI 会产生如下输出:
    
    ``` linenums="0"
    Boot HART MIDELEG         : 0x0000000000001666
    Boot HART MEDELEG         : 0x0000000000f0b509
    ```
    查阅 The RISC-V Instruction Set Manual: Volume II - Privileged Architecture，解释**你的** OpenSBI 给出的 `MIDELEG` 和 `MEDELEG` 值的含义。如果实验中 `mideleg` 和 `medeleg` CSR 没有被正确设定，会有什么影响？
    - MIDELEG=0x1666：bit 1/5/9 置 1（Supervisor software/timer/external interrupt），表示这三类中断委托给 S 态处理（bit1：SSIP（S-mode software interrupt）bit5：STIP（S-mode timer interrupt）bit9：SEIP（S-mode external interrupt））；M 态自己的 MSIP/MTIP/MEIP 保留在 M 态。  
    - MEDELEG=0x00f0b509：置位了指令/访存对齐与访问错误、非法指令、断点、U/S 态 ECALL、指令/取数/写数页故障等常见异常（原因号 0/1/2/3/4/5/6/7/8/9/12/13/15），委托给 S 态；其他未置位的异常仍由 M 态处理。  
    - 如果委托设置错误：S 态收不到外设/定时中断或应由内核处理的异常，可能直接落在 OpenSBI 报 “unhandled trap” 或停机；反之把不该委托的落到 S 态，内核无法处理也会导致二次异常/崩溃，系统无法正常运行。


3. ## 如何在不支持 M 扩展的处理器上执行 M 扩展指令？<br>
   
   提示：请查阅 The RISC-V Instruction Set Manual: Volume I - Unprivileged Architecture 第 1.2 节。
   
   - 对于不实现 M 扩展的处理器，当执行乘除法相关指令（如 MUL/DIV 等）时，硬件会触发 Illegal Instruction 异常。  
   - 上层软件（通常是 M 模式或 S 模式的 trap handler）在非法指令异常中识别出具体是哪一条 M 扩展指令，然后用软件算法（普通加减/移位等）在 trap handler 中**模拟执行**这条指令的效果，把结果写回相应寄存器，并调整返回地址继续执行后续指令。  
   - 通过这种“异常 + 软件模拟”的方式，即使底层硬件没有 M 扩展，也可以运行包含 M 扩展指令的程序。



4. ## 如果是完全按照我们的实验指导实现的，那么在运行一段时间后，你应当会看到 `test` 函数的输出和时钟中断的输出出现失去同步的情况：
    
    ``` linenums="0"
    [S] Supervisor timer interrupt
    Kernel is running! timeval = 195
    [S] Supervisor timer interrupt
    Kernel is running! timeval = 196
    Kernel is running! timeval = 197
    [S] Supervisor timer interrupt
    Kernel is running! timeval = 198
    [S] Supervisor timer interrupt
    ```
    请分析这种现象的原因，问题出在 `test` 函数还是时钟中断上？请通过gdb调试截图来说明问题。请修改代码，来保持两者的同步<br>
    tips：请备份修改前的代码，这个修改在完成思考题5之后可以复原，便于后续实验的进行
    - 现象分析：一开始输出是严格交替的：“Kernel is running! timeval = n” 和 “[S] Supervisor timer interrupt” 一一对应，但跑到一两百秒以后，偶尔会出现连续两行 `Kernel is running!` 才跟一行 `[S]`，说明 test 这边“走得更快”，时钟中断这一边“慢慢落后”。  
    - 原因定位：`test()` 每次循环直接用 `rdtime` 读 **当前** time，然后除以 `TIMECLOCK` 得到当前“第几秒”，只有在这个秒数变化时才打印一次；所以它的节奏基本就是理想的 `TIMECLOCK` tick 一秒。而 `clock_set_next_event()` 是在中断处理函数里再次 `rdtime`，然后把“当前 time + TIMECLOCK” 作为下一次触发时间。由于每次进入 trap、保存寄存器、`printk`、SBI 调用本身都要消耗几千个甚至更多 tick，这个“当前 time”已经比上一次我们设定的 `next` 晚了一截，相当于下一次中断的间隔是 `TIMECLOCK + 处理开销`。久而久之，中断节奏相对于 `test()` 就会越来越慢，于是出现不同步。换句话说，问题主要出在“时钟中断侧的调度方式”，而不是 `test()` 的写法。  
    - gdb 说明（思路）：我在 `clock_set_next_event` 入口（以及 `trap_handler`）打断点，每次中断时打印当前 `time` 和本次设置的 `next`，比较连续两次中断之间的 `time` 差值，可以看到它略大于 `TIMECLOCK`；而在 `test()` 中打断点观察 `rdtime` 的两次差值，则更接近 `TIMECLOCK`。截图里可以看到：随着时间推移，同样间隔的 `timeval` 变化次数对应的中断次数越来越少，验证了中断节奏比理想值慢。  
    - 修改方案（保持同步）：我改了 `clock_set_next_event()` 的实现，让“下一次中断时间”不再基于“当前 rdtime”，而是基于“上一次设定的 next”往前推，而不是每次 `next = time + TIMECLOCK`，例如：
      ```c
      void clock_set_next_event(void) {
        static uint64_t next = 0;
        if (next == 0) {
          uint64_t now;
          asm volatile("rdtime %0" : "=r"(now));
          next = now + TIMECLOCK;
        } else {
          next += TIMECLOCK;
        }
        sbi_ecall(0x54494d45, 0, next, 0, 0, 0, 0, 0);
      }
      ```
      这样做的效果是：中断的节奏始终以“理论上的时间轴”递增，而不是每次从“当前（已经延迟的）时间点”重新起步，处理开销只会让某次中断稍微晚一点点，但不会累计偏差，所以长期来看 test 的 `timeval` 和中断的次数就能保持同步。实验指导里提醒要备份代码，也是为了方便在完成思考题 5 后再把 `clock_set_next_event()` 改回原版。
      
      ![屏幕截图 2025-12-03 084507](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-03 084507.png)
      
      ![屏幕截图 2025-12-03 084808](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-03 084808.png)
      
      ![屏幕截图 2025-12-03 085002](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-03 085002.png)
      可以看到两次时钟中断之间ticks差了10022302，而不是我们设定的TIMECLOCK=10000000
      ![屏幕截图 2025-12-03 085947](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-03 085947.png)
      
      ![屏幕截图 2025-12-03 090452](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-03 090452.png)
      可以看到两次while循环之间，硬件时钟走了3216个tick
      故问题是在时钟中断那边


5. ## 请自行设计方案，测试 `test` 函数中的 `printk` 输出信息需要的时间。假定时钟频率为 10 MHz，在确保每次 `timeval` 变化时，信息都能被完整输出的情况下，每秒最多可以发生多少次时钟中断？请尝试修改 `TIMECLOCK` 和其他可能需要修改的地方，验证这个值。只需近似计算即可。

​	将main.c改为如下代码

![屏幕截图 2025-12-03 092227](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-03 092227.png)

make run之后![屏幕截图 2025-12-03 092346](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-12-03 092346.png)

可以看到：`printk("Kernel is running! ...")` 一次大约需要 `9833` 个 tick。时钟频率是 10 MHz，也就是每秒有 `10^7` 个 tick。  
如果假设每次时钟中断也调用一次 `printk` 输出中断信息，那么在一秒内，`test` 自己每秒要打印 1 次，再加上 N 次中断打印，总共是 `1 + N` 次 `printk`，需要的时间大约是：
\[
(1 + N) \times 9833 \le 10^7
\]

解出来：

\[
N \le \frac{10^7}{9833} - 1 \approx 1016
\]

所以在保证每次 `timeval` 变化时那条 `Kernel is running! ...` 能完整输出的前提下，每秒最多大约可以发生 **一千次左右的时钟中断**（近似取 \(N \approx 1000\)），再往上的话串口输出时间就会挤占掉一秒的总 tick 数，开始出现丢输出或明显卡顿的情况。
