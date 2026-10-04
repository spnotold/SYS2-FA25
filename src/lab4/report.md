1. 我们的vmlinux文件由哪些文件编译而成？  
   由 `arch/riscv/kernel` 目录下的 `head.S`、`main.c`、`print.c`、`sbi.c` 编译得到的 `head.o`、`main.o`、`print.o`、`sbi.o`，以及 `lib` 目录下的 `div.S`、`muldi3.S` 编译得到的 `div.o`、`muldi3.o`，再通过链接脚本 `arch/riscv/kernel/vmlinux.lds` 链接而成。
2. 使用 riscv64-linux-gnu-objdump 反汇编 vmlinux，你发现了什么？  
   观察 `vmlinux.asm` 可以看到，我在 `head.S` 中编写的伪指令被展开成具体的 RISC‑V 指令序列。例如：

   - 源代码中的 `_start`：
     ```asm
     .section .text.init
     .globl _start
     _start:
         la sp, _ekernel
         li t0, 4096
         add sp, sp, t0
         tail start_kernel
     ```

   - 反汇编得到的指令（节选）：
     ```asm
     0000000080200000 <_skernel>:
         80200000: 00002117    auipc sp,0x2
         80200004: 00813103    ld    sp,8(sp)
         80200008: 000012b7    lui   t0,0x1
         8020000c: 00510133    add   sp,sp,t0
         80200010: 0340006f    j     80200044 <start_kernel>
     ```

   - 链接脚本 `arch/riscv/kernel/vmlinux.lds` 中规定：
     ```ld
     /* kernel 代码起始位置 */
     BASE_ADDR = 0x80200000;
     SECTIONS {
         . = BASE_ADDR;
         _skernel = .;
         .text : ALIGN(0x1000) { *(.text.init) *(.text .text.*) }
         ...
     }
     ```
     可以看到 `_skernel`/`_start` 的反汇编地址正是 `0x80200000`，与 `BASE_ADDR` 完全一致，说明链接脚本对 `.text` 段布局是生效的。

   综上，`la`、`li` 等伪指令都被展开成具体的 AUIPC/LUI/ADD 指令序列，入口地址和段布局也和链接脚本中的设置一致。


3. 编译的过程是什么  
   在本次实验中，我在 `project/kernel` 目录下执行 `make`，整体流程大致为：

   - **编译/汇编阶段**：  
     `Makefile` 先进入 `lib/` 和 `arch/riscv/kernel/`，对源码分别编译：
     ```sh
     riscv64-linux-gnu-gcc -c lib/div.S     -o lib/div.o
     riscv64-linux-gnu-gcc -c lib/muldi3.S  -o lib/muldi3.o
     riscv64-linux-gnu-gcc -c arch/riscv/kernel/head.S  -o arch/riscv/kernel/head.o
     riscv64-linux-gnu-gcc -c arch/riscv/kernel/main.c  -o arch/riscv/kernel/main.o
     riscv64-linux-gnu-gcc -c arch/riscv/kernel/print.c -o arch/riscv/kernel/print.o
     riscv64-linux-gnu-gcc -c arch/riscv/kernel/sbi.c   -o arch/riscv/kernel/sbi.o
     ```
     其中 `.c` 会先经过 C 预处理/编译再汇编成 `.o`，`.S` 直接由汇编器生成 `.o`。

   - **链接阶段**：  
     然后调用链接器，使用链接脚本 `arch/riscv/kernel/vmlinux.lds` 将所有 `.o` 合并成一个可执行内核：
     ```sh
     riscv64-linux-gnu-ld -T arch/riscv/kernel/vmlinux.lds \
         arch/riscv/kernel/*.o lib/*.o -o vmlinux
     ```
     在这个过程中，链接脚本负责把各个段（`.text/.rodata/.data/.bss`）放到固定地址上，例如 `BASE_ADDR = 0x80200000`，并定义 `_skernel`、`_ekernel` 等符号。

   - **生成镜像和辅助文件**：  
     最后通过 `objcopy/objdump/nm` 等工具，从 `vmlinux` 生成:
     ```sh
     objcopy -O binary vmlinux arch/riscv/boot/Image   # 纯二进制镜像，给 QEMU/Spike 用
     objdump -S vmlinux > vmlinux.asm                 # 带源码的反汇编
     nm vmlinux > System.map                          # 导出符号表
     ```
     至此，一个可以被 QEMU + OpenSBI 启动的 RV64 内核镜像就构建完成了。
4. 编译之后，通过 `System.map` 查看 `vmlinux.lds` 中自定义符号的值，比较它们的地址是否符合你的预期。  
   在 `project/kernel` 目录下生成的 `System.map` 中，可以看到链接脚本里定义的符号被分配到了具体地址，例如（节选）：
   ```text
   0000000080200000 A BASE_ADDR
   0000000080200000 T _skernel
   0000000080200000 T _stext
   0000000080201000 R _srodata
   0000000080202000 D _sdata
   0000000080203000 D _sbss
   0000000080203000 D _ekernel
   ```
   与 `arch/riscv/kernel/vmlinux.lds` 中的设置对比：
   ```ld
   BASE_ADDR = 0x80200000;
   SECTIONS {
       . = BASE_ADDR;
       _skernel = .;
       .text   : ALIGN(0x1000) { _stext = .; *(.text.init) *(.text .text.*) _etext = .; }
       .rodata : ALIGN(0x1000) { _srodata = .; *(.rodata .rodata.*) _erodata = .; }
       .data   : ALIGN(0x1000) { _sdata = .; *(.data .data.*) _edata = .; }
       .bss    : ALIGN(0x1000) { _sbss = .; *(.bss .bss.*) _ebss = .; }
       . = ALIGN(0x1000);
       _ekernel = .;
   }
   ```
   可以发现：`BASE_ADDR`、`_skernel`、`_stext` 都是 `0x80200000`，`.rodata/.data/.bss` 的起始地址分别是 `0x80201000`、`0x80202000`、`0x80203000`，恰好满足 4 KiB 对齐并且按 `.text → .rodata → .data → .bss` 的顺序连续分布，`_ekernel` 也落在 `0x80203000`。这些地址分布与我在链接脚本中对段布局和对齐方式的预期是一致的。
5. 在你的第一条指令处添加断点，观察你的程序开始执行时的特权态是多少，中断的开启情况是怎么样的？  
   - `_start` 首行插入 `csrr a0, mstatus`，使用 `make debug` + gdb（`target remote :1234`）在 `_start` 断点单步。单步执行到这条指令时直接陷入 OpenSBI 的异常处理（PC 跳到 0x8001ac22 的 BIOS 代码，gdb 显示程序停在无符号区)，说明内核开始执行时已经处于 S 模式——S 模式访问 M 模式 CSR 会触发特权异常。由于还未进入内核主体就被 trap，可推知此时 S 态中断默认仍为关闭状态。  
     ![image-20251122175925036](C:\Users\LENOVO\AppData\Roaming\Typora\typora-user-images\image-20251122175925036.png)
   - 把代码改为 `csrr a0, sstatus` 后再单步：指令正常执行，`sstatus = 0x6000`，其中 SIE 位（bit1）为 0（`sstatus & 0x2 = 0`），进一步验证启动时 S 模式中断开关为关闭状态。  
     ![image-20251122181551043](C:\Users\LENOVO\AppData\Roaming\Typora\typora-user-images\image-20251122181551043.png)
6. 在你的第一条指令处添加断点，观察内存中 `.text`、`.data`、`.bss` 段的内容是怎样的？

    ![屏幕截图 2025-11-22 193251](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-11-22 193251.png)

    ![
    ](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-11-22 193731.png)

    ![屏幕截图 2025-11-22 193825](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-11-22 193825.png)

    

    ![屏幕截图 2025-11-22 193924](C:\Users\LENOVO\Pictures\Screenshots\屏幕截图 2025-11-22 193924.png)
    
7. 观察 `vmlinux.asm` 中 `sbi_ecall` 编译得到的汇编代码。这段代码是如何实现正确地将参数 `arg[0-5]` 放置在寄存器 `a[0-5]` 中的？<br>
    同时本题也是一个提示：如果你的程序没有输出正确的字符，有可能是 `sbi_ecall` 的参数没有正确传递。
    在 `vmlinux.asm` 中 `sbi_ecall` 的反汇编（`0x80200198` 起）清晰展示了参数搬运和调用过程：
```asm
0000000080200198 <sbi_ecall>:
    addi   sp,sp,-48
    sd     s0,40(sp)
    mv     t3,a0        # eid
    mv     t1,a1        # fid
    mv     t4,a2        # arg0
    mv     t5,a3        # arg1
    mv     t6,a4        # arg2
    mv     t0,a5        # arg3
    mv     t2,a6        # arg4
    mv     s0,a7        # arg5

    mv     a0,t4        # arg0 -> a0
    mv     a1,t5        # arg1 -> a1
    mv     a2,t6        # arg2 -> a2
    mv     a3,t0        # arg3 -> a3
    mv     a4,t2        # arg4 -> a4
    mv     a5,s0        # arg5 -> a5
    mv     a6,t1        # fid  -> a6
    mv     a7,t3        # eid  -> a7
    ecall
    mv     t3,a0        # error
    mv     t1,a1        # value
    sd     t3,0(sp)
    sd     t1,8(sp)
```
可以看到 `arg0..arg5` 依次放入 `a0..a5`，`fid` 放入 `a6`，`eid` 放入 `a7`，执行 `ecall`，返回后再把 `a0/a1`（error/value）保存下来，完全遵循 RISC-V SBI 调用约定。

8. 尝试从汇编代码中给 C 函数 `start_kernel` 传递参数。
    在head.s中加入![image-20251122195655695](C:\Users\LENOVO\AppData\Roaming\Typora\typora-user-images\image-20251122195655695.png)
    然后调整main.c中的start_kernel函数![image-20251122195739292](C:\Users\LENOVO\AppData\Roaming\Typora\typora-user-images\image-20251122195739292.png)
    在 make run之后成功打印出4660（0x1234转化为十进制)
    ![image-20251122195955664](C:\Users\LENOVO\AppData\Roaming\Typora\typora-user-images\image-20251122195955664.png)

    

9. 了解 C 语言中“有宿主环境”（hosted）和“自立环境”（freestanding）的概念，我们的内核运行在哪种环境下？
   “有宿主环境”（hosted）是指 C 程序运行在一个已有操作系统之上，有完整的 C 标准库和运行时（如 Linux/Windows 用户态的程序）；“自立环境”（freestanding）则没有现成的 OS 和完整标准库，编译器只保证提供极少量的运行时支持，需要自行实现启动代码、内存管理等。我们的内核直接运行在 OpenSBI + 硬件之上，没有依赖标准库和宿主操作系统，因此属于“自立环境”（freestanding）。
10.  解释为什么RV64中没有idiv指令，但是在我们的c代码中可以使用`/`和`%`
    - RV64I 基础指令集本身不包含整数除法指令（如果不启用 M 扩展，就没有硬件除法），所以在我们当前配置的 ISA `rv64ia_zicsr_zifencei` 下不存在 `idiv` 一类的除法指令。
    - 但是 GCC 在编译 C 代码里的 `/` 和 `%` 时，会自动调用运行库中的软件除法例程，例如 `__divdi3`、`__udivdi3`、`__moddi3` 等。这些函数的实现就在本实验的 `lib/div.S`、`lib/muldi3.S` 中，通过移位、减法等基本指令模拟出除法和取模运算。
    - 链接 `vmlinux` 时，这些软件除法函数的目标文件（`lib/div.o`、`lib/muldi3.o`）会一起被链接进去，因此即使底层 ISA 没有硬件除法指令，我们仍然可以在 C 代码中正常使用 `/` 和 `%` 运算符。

    相关代码示例：

    `lib/div.S`：
    ```asm
    
    FUNC_BEGIN (__udivdi3)
      mv    a2, a1
      mv    a1, a0
      li    a0, -1
      beqz  a2, .L5
      li    a3, 1
      bgeu  a2, a1, .L2
    .L1:
      blez  a2, .L2
      slli  a2, a2, 1
      slli  a3, a3, 1
      bgtu  a1, a2, .L1
    .L2:
      li    a0, 0
    .L3:
      bltu  a1, a2, .L4
      sub   a1, a1, a2
      or    a0, a0, a3
    .L4:
      srli  a3, a3, 1
      srli  a2, a2, 1
      bnez  a3, .L3
    .L5:
      ret
    FUNC_END (__udivdi3)
    ```

    `lib/muldi3.S`：
    ```asm
    
    FUNC_BEGIN (__muldi3)
      mv     a2, a0
      li     a0, 0
    .L1:
      andi   a3, a1, 1
      beqz   a3, .L2
      add    a0, a0, a2
    .L2:
      srli   a1, a1, 1
      slli   a2, a2, 1
      bnez   a1, .L1
      ret
    FUNC_END (__muldi3)
    ```
