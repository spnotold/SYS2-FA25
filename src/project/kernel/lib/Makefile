C_SRC := $(wildcard *.c)   # 当前目录下所有 C 源
ASM_SRC := $(wildcard *.S) # 当前目录下所有汇编源
OBJ := $(C_SRC:.c=.o) $(ASM_SRC:.S=.o) # 需要生成的所有目标文件

.PHONY: all clean

all: $(OBJ)

clean:
	rm -f *.o

%.o: %.S
	$(GCC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -c $<

%.o: %.c
	$(GCC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -c $<
