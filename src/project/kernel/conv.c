#include "conv.h"

uint64_t* CONV_BASE = (uint64_t*)0x10001000L;
const size_t CONV_KERNEL_OFFSET = 0;
const size_t CONV_DATA_OFFSET = 1;
const size_t CONV_RESULT_LO_OFFSET = 0;
const size_t CONV_RESULT_HI_OFFSET = 1;
const size_t CONV_STATE_OFFSET = 2;
const unsigned char READY_MASK = 0b01;
const size_t CONV_ELEMENT_LEN = 4;

uint64_t* MISC_BASE = (uint64_t*)0x10002000L;
const size_t MISC_TIME_OFFSET = 0;

uint64_t get_time(void){
    return MISC_BASE[MISC_TIME_OFFSET];
}

/*
 * 轻量 128 位结构与运算（文件内可复用，且不使用乘法运算符）
 * - 在不依赖编译器内建 128 位整数的前提下，用两个 64 位拼出 128 位。
 * - 提供：
 *     u128_add_impl        —— 128 位加法（低 64 位相加并产生进位，进位再加到高 64 位）
 *     mul64x64_to128_impl  —— 64×64 → 128 的“移位-累加”乘法（完全无乘法指令）
 */
typedef struct { uint64_t hi; uint64_t lo; } u128_t;

/*
 * 128 位加法：r = a + b
 * 步骤：
 * 1) 先做低 64 位相加，若发生溢出说明产生进位（lo < a.lo）。
 * 2) 高 64 位相加再加上进位。
 */
static inline u128_t u128_add_impl(u128_t a, u128_t b){
    u128_t r;
    uint64_t lo = a.lo + b.lo;                  /* 低 64 位相加 */
    uint64_t carry = (lo < a.lo) ? 1u : 0u;     /* 无符号溢出检测得到进位 */
    r.lo = lo;
    r.hi = a.hi + b.hi + carry;                 /* 高 64 位叠加进位 */
    return r;
}

/*
 * 无乘法 64×64 → 128 乘法（移位-累加法）：返回 x * y 的 128 位结果。
 * 原理：按 y 的二进制展开，逐位处理：
 *   若当前位为 1，则把当前 addend(=x 左移若干位) 加到累加器 acc；
 *   然后将 addend 左移 1 位，y 右移 1 位，继续下一位。
 * 结束条件：y 被右移为 0，所有有效位处理完毕。
 */
static inline u128_t mul64x64_to128_impl(uint64_t x, uint64_t y){
    u128_t acc; acc.hi = 0; acc.lo = 0;                 /* 累加器（部分和） */
    u128_t addend; addend.hi = 0; addend.lo = x;        /* 当前应累加的被乘数左移量（128 位） */
    uint64_t m = y;                                     /* 作为乘数的位扫描寄存器 */
    while(m){
        if(m & 1u){                                     /* 若最低位为 1，累加 addend */
            acc = u128_add_impl(acc, addend);
        }
        /* addend <<= 1 ：128 位左移 1 位，低位溢出的最高位进入高 64 位 */
        uint64_t new_hi = (addend.hi << 1) | (addend.lo >> 63);
        uint64_t new_lo = (addend.lo << 1);
        addend.hi = new_hi;
        addend.lo = new_lo;
        m >>= 1;                                        /* m 右移 1 位，处理下一位 */
    }
    return acc;                                         /* 返回 128 位乘积 */
}

void conv_compute(const uint64_t* data_array, size_t data_len, const uint64_t* kernel_array, size_t kernel_len, uint64_t* dest){
    /*
     * 一维卷积（硬件加速版，MMIO 驱动）
     * - 硬件卷积核长度固定为 4，因此这里以 4 为准；传入 kernel_len 若不为 4，仅使用其前 4 个元素，不足补 0。
     * - 时序协议：READY 置位(STATE bit0=1)表示“上一轮结果已就绪，且可以发起下一轮计算”。
     * - 流水线喂数：先喂入 3 个 0（前导零填充）→ 依次喂入 data → 再喂入 3 个 0（尾随零填充）。
     * - 采样结果：每次 READY=1 先读取上一轮 128 位结果（高/低 64 位），再写入下一轮数据。
     * - 输出个数：data_len + 3；目标数组布局：dest[i<<1] 存高 64 位，dest[(i<<1)+1] 存低 64 位。
     * - 注意：函数体内不使用乘法运算符。
     */

    /* 1) 装载卷积核参数（串行写入 4 次） */
    for(size_t k = 0; k < CONV_ELEMENT_LEN; k++){
        uint64_t param = 0;
        if(k < kernel_len){
            param = kernel_array[k];
        }
        CONV_BASE[CONV_KERNEL_OFFSET] = param;
    }

    const size_t pad = CONV_ELEMENT_LEN - 1;          /* 前后各 3 个 0 */
    const size_t out_len = data_len + pad;             /* 需要读出的结果个数 */
    const size_t total_feed = data_len + pad + pad;    /* 总喂入次数：3 + data_len + 3 */

    size_t fed = 0;        /* 已喂入的数据个数（含前后零） */
    size_t produced = 0;   /* 已写入到 dest 的结果个数 */

    /* 2) 先等待一次 READY，然后写入首个前导 0，避免第一次就绪时读到无效历史值 */
    while((CONV_BASE[CONV_STATE_OFFSET] & READY_MASK) == 0){}
    CONV_BASE[CONV_DATA_OFFSET] = 0;  /* 第 1 次喂入（前导 0） */
    fed++;

    /* 3) 主循环：在 READY=1 时先取出上一轮结果（若已过热身期则写入到 dest），再喂入下一笔数据 */
    while(produced < out_len){
        /* 等待“上一轮计算结束 + 结果就绪” */
        while((CONV_BASE[CONV_STATE_OFFSET] & READY_MASK) == 0){}

        /* 读取 128 位结果（高/低 64 位） */
        if(fed > 0){
            uint64_t lo = CONV_BASE[CONV_RESULT_LO_OFFSET];
            uint64_t hi = CONV_BASE[CONV_RESULT_HI_OFFSET];
            /* 跳过热身阶段的前三次喂入（没有全窗口结果），从第 4 次喂入开始才产出第 1 个有效卷积值 */
            if(fed > pad){
                dest[produced<<1] = hi;
                dest[(produced<<1) + 1] = lo;
                produced++;
            }
        }

        /* 继续喂入下一笔数据（若尚未喂满 total_feed 次） */
        if(fed < total_feed){
            uint64_t next = 0;
            if(fed < pad){
                next = 0;  /* 仍在前导零阶段 */
            }else if(fed < pad + data_len){
                next = data_array[fed - pad];  /* 实际数据阶段 */
            }else{
                next = 0;  /* 尾随零阶段 */
            }
            CONV_BASE[CONV_DATA_OFFSET] = next;
            fed++;
        }
    }
}

void mul_compute(const uint64_t* data_array, size_t data_len, const uint64_t* kernel_array, size_t kernel_len, uint64_t* dest){
    /*
     * 一维卷积（软件版，无乘法指令）：
     * - 64x64 位乘法通过“移位-累加”得到 128 位结果；
     * - 每个位置 i 的窗口覆盖 [i-3, i]，越界按 0 处理；
     * - 输出 (data_len + 3) 个 128 位值，写入 dest：高 64 位在偶数下标，低 64 位在奇数下标。
     * - 注意：函数体内不使用乘法运算符。
     */

    /* 使用文件域的 128 位工具函数（不在函数体内出现乘法符号） */

    const size_t K = 4;                 /* 卷积核长度固定 4 */
    const size_t pad = K - 1;           /* 前后零填充数 3 */
    const size_t out_len = data_len + pad;

    for(size_t i = 0; i < out_len; i++){
        u128_t sum; sum.hi = 0; sum.lo = 0;          /* 累加第 i 个输出对应窗口的 128 位和 */
        /* 遍历核的 4 个系数：第 i 个输出使用窗口 [i-3, i]，左侧越界按 0 处理 */
        for(size_t k = 0; k < K; k++){
            long long idx = (long long)i + (long long)k - (long long)pad; /* 将核下标 k 映射到 data 下标 idx */
            if(idx >= 0 && (size_t)idx < data_len){  /* 仅在 data 的有效范围内参与运算（越界视作 0） */
                /* data[idx] 与 kernel[k] 的 64×64→128 部分积（移位-累加法，无乘号） */
                u128_t p = mul64x64_to128_impl(data_array[(size_t)idx], (k < kernel_len) ? kernel_array[k] : 0);
                sum = u128_add_impl(sum, p);        /* 将部分积累加到 128 位和中 */
            }
        }
        /* 写出第 i 个卷积结果：高 64 位放在偶数位置，低 64 位放在奇数位置 */
        dest[i<<1] = sum.hi;
        dest[(i<<1) + 1] = sum.lo;
    }
}
