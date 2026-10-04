ASM_SRC := $(wildcard *.S)
OBJ := $(ASM_SRC:.S=.o)

.PHONY: all clean

all: $(OBJ)

clean:
	rm -f *.o

%.o: %.S
	$(GCC) $(CPPFLAGS) $(CFLAGS) $(LDFLAGS) -c $<
