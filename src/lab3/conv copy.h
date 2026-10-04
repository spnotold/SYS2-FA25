#ifndef __CONV_H__
#define __CONV_H__
typedef unsigned long long int uint64_t;
typedef uint64_t size_t;

/*
 * conv_compute
 * 使用卷积加速器（MMIO）完成一维卷积（kernel 长度固定为 4）。
 * - 零填充：前后各填充 3 个零，共产生 (data_len + 3) 个卷积结果。
 * - 结果布局：每个 128 位结果拆成两个 64 位：
 *     dest[i<<1]     存高 64 位
 *     dest[(i<<1)+1] 存低 64 位
 * - 接口时序：
 *     1) 依次写入 4 个 kernel 到 CONV_KERNEL_OFFSET
 *     2) 先喂入 3 个前导零，再依次喂入 data，每次在“就绪位(READY)”=1 时读取上一轮结果；
 *        数据喂入完毕后再喂入 3 个尾随零以冲刷流水线，直到读满 (data_len+3) 个结果。
 */
void conv_compute(const uint64_t* data_array, size_t data_len, const uint64_t* kernel_array, size_t kernel_len, uint64_t* dest);

/*
 * mul_compute
 * 仅用整数与移位实现一维卷积（不使用乘法指令）。
 * - 64x64 位乘法通过“移位-累加”得到 128 位部分积；
 * - 对每个输出位置 i，窗口覆盖 [i-3, i]，越界按 0 处理；
 * - 结果布局同 conv_compute：高 64 位在 dest[i<<1]，低 64 位在 dest[(i<<1)+1]。
 */
void mul_compute(const uint64_t* data_array, size_t data_len, const uint64_t* kernel_array, size_t kernel_len, uint64_t* dest);
uint64_t get_time(void);

#endif
