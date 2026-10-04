## 这个 Makefile 只负责当前目录（arch/riscv/kernel）下的 .c / .S 文件
## 会把它们全部编译成对应的 .o，供上一层 Makefile 链接成 vmlinux 使用。

# C_SRC: 把当前目录下所有以 .c 结尾的文件名收集起来，例如 main.c print.c sbi.c
C_SRC := $(wildcard *.c)

# ASM_SRC: 把当前目录下所有以 .S 结尾的汇编文件名收集起来，例如 head.S
ASM_SRC := $(wildcard *.S)

# OBJ: 把上面两类源文件的后缀替换成 .o，得到需要生成的目标文件列表
#      例如 main.c -> main.o, head.S -> head.o
OBJ := $(C_SRC:.c=.o) $(ASM_SRC:.S=.o)

# 声明 all / clean 是“伪目标”（不是实际文件名），避免和同名文件冲突
.PHONY: all clean

# 默认目标：执行 make 时，如果不写目标名，就会执行 all
# 这里含义是“生成本目录下所有需要的 .o 文件”
all: $(OBJ)

# 清理目标：执行 make clean 时，删除本目录生成的 .o 文件
clean:
	rm -f $(OBJ)

# 模式规则：如何从一个 .S 文件得到同名的 .o 文件
# $< 表示“第一个依赖项”，即对应的那个 .S 文件名
%.o: %.S
	$(GCC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -c $<

# 模式规则：如何从一个 .c 文件得到同名的 .o 文件
# 同样使用上一层 Makefile 里传下来的 GCC / CFLAGS 等交叉编译参数
%.o: %.c
	$(GCC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -c $<
