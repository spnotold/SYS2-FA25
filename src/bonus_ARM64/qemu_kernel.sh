ROOTFS_DIR=$PWD
KERNEL_DIR=$PWD

qemu-system-aarch64 \
-machine virt -cpu cortex-a57 \
-nographic -smp 8 -m 2048 \
-kernel $KERNEL_DIR/arch/arm64/boot/Image \
-initrd $ROOTFS_DIR/arm64-rootfs.cpio \
-append "console=ttyAMA0" 
