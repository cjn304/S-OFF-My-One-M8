# static ARM build of mmc_cmd
#
#   make CROSS=arm-none-linux-gnueabihf-
#
CROSS ?= arm-none-linux-gnueabihf-
CC    := $(CROSS)gcc

mmc_cmd: mmc_cmd.c
	$(CC) -O2 -static -Wall -o $@ $<

clean:
	rm -f mmc_cmd

.PHONY: clean
