# out-of-tree build of the pwrsq helper modules
#
#   make -C <prepared-kernel-tree> M=$PWD \
#        ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf- \
#        CC=arm-none-linux-gnueabihf-gcc modules
#
# scripts/build.sh wraps this.
obj-m := pwrsq_diag.o pwrsq_off.o pwrsq_on.o

# The module must not pull in any external symbol: no stack protector
# (__stack_chk_fail), no compiler helpers (__aeabi_unwind_cpp_pr0), no
# builtin memcpy/memset.  See docs/build.md.
ccflags-y += -fno-stack-protector -fno-builtin \
             -fno-unwind-tables -fno-asynchronous-unwind-tables
