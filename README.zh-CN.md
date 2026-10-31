# HTC-S-OFF-M8

[English](README.md) | **中文**

在 HTC One (M8)、**hboot 3.19.0.0000** 上做真 S-OFF —— 这个 hboot 从 2015 年起被社区
当成"没法 S-OFF"的版本。

这不是又一个内存破坏漏洞。hboot 用 eMMC 的 **power-on 写保护**锁住固件分区，而这种保护
按规范只有**掉电**才清除。所有用户态的通路都被堵死，所以这里用一个小内核模块在**内核态**
把 PMIC 的电真断一次再上电，最后写 hboot 读的那一个字节。

```
之前                            之后
secure_flag: 3                  secure_flag: 0
PVT SHIP S-ON                   PVT SHIP S-OFF
security: on                    security: off
CMD31: aaaaaaaa2aaaaaaa         CMD31: 0000000000000000   ← hboot 不再设写保护
```

---

## 设备支持

| 项目 | 实测值 |
|---|---|
| 机型 | HTC One (M8)，`m8_ul` |
| MID / CID | `0P6B62000` / `HTCCN703` |
| 系统 | 6.31.1402.1，Android 6.0.1（MMB29M） |
| 内核 | `3.4.0-perf-ga6393e1`（HTC 官方，2016-01） |
| hboot | `3.19.0.0000` |
| 权限 | adbd 以 root 运行、SELinux Permissive、`modules_disabled=0` |

其它 M8 变体只要跑官方 3.4 内核，行为应当一致。有两样东西**跟构建绑定**、必须自己生成：
符号地址和 `module_layout` 的 crc（见[构建](#构建)）。稳压器名字和 MMC 平台设备名是
`kmod/pwrsq_impl.h` 里的编译期参数。

---

## 工作原理

### 1. 那堵墙

S-OFF 状态就是 `pg1fs` 里的一个字节：

| 偏移 | 含义 | S-ON | S-OFF |
|---|---|---|---|
| `0x8400` | secure flag（u32 LE） | `03 00 00 00` | `00 00 00 00` |
| `0x8404` | 标签 | `"HTCU"` | `"HTCU"` |

`fastboot oem readsecureflag` 读的就是这个值，`getvar all` 里的
`version-misc: PVT SHIP S-ON/S-OFF` 和 `security: on/off` 也都是从它推出来的。

以 root 身份写这个字节会失败，原因既不是 SELinux 也不是文件系统：hboot 每次开机都给固件
分区加上 eMMC 的 **power-on 写保护**。`CMD31`（SEND_WRITE_PROT_TYPE）按每 2 bit 一组
报告类型：

```
00 = 无保护   01 = 临时   10 = power-on   11 = 永久
```

一台正常开机的 M8 回答：

```
CMD31 -> 0000000000000000 aaaaaaaa2aaaaaaa
                            group 0..11 = 10b = power-on
```

power-on 保护只能靠掉电清除。`CMD29`（CLEAR_WRITE_PROT）对它无效，`dd` 写 `pg1fs`
会拿到 `card status 0x400d00` —— 第 22 位，`WP_ERASE_SKIP`。

于是问题收敛成一句话：**把 eMMC 的 VCC 断掉再上电，且不能让 SoC 重启。**

### 2. 用户态为什么做不到

这路电是 **PM8941 LDO20**（`8941_l20`，2.95 V），由 RPM-SMD 管理。eMMC 控制器的
设备树节点写着：

```dts
&sdhc_1 {
	vdd-supply = <&pm8941_l20>;
	qcom,vdd-always-on;
	...
```

三个各自独立的障碍：

1. **`qcom,vdd-always-on`** —— `sdhci_msm` 在 probe 时把这路电打开，之后永不关闭。
2. **regulator core 短路** —— 用 debugfs 把电强制断掉之后，`regulator_enable()` 仍然
   拒绝调用 `->enable()`：

   ```c
   static int _regulator_enable(struct regulator_dev *rdev)
   {
           if (rdev->use_count == 0) {
                   ret = _regulator_is_enabled(rdev);
                   if (ret == -EINVAL || ret == 0) {
                           ...
                           ret = rdev->desc->ops->enable(rdev);
   ```

   `rpm_vreg_is_enabled()` 返回的是驱动缓存的请求位，对 always-on 的稳压器它一直是
   "开"，于是核心认为电还在、根本不去碰硬件。`echo 1 > .../enable` 会返回成功，
   然后什么都不做。
3. **没有重扫入口** —— `sdhci` 没有用户态的 rescan 属性；解绑驱动并不会断电；
   而 `device_release_driver()` 在那个 gendisk 上还有可写文件系统时会永久阻塞。

用户态只能做到前一半：

```sh
echo 1 > /sys/kernel/debug/regulator/8941_l20/force_disable   # VCC 真的断了
```

卡消失了，`mmcblk0*` 全没了 —— 除了重启没有回头路。这就是墙。

### 3. 模块做了什么

`kmod/pwrsq_impl.h` 只做四件事：

1. **拿到稳压器** —— `regulator_get(NULL, "8941_l20")`。`struct regulator` 是
   `drivers/regulator/core.c` 的私有结构，所以模块里复制了一份，用来取 `->rdev`。
2. **直接调驱动 ops** —— `rdev->desc->ops->disable(rdev)`，之后再 `->enable(rdev)`。
   这一步绕开了 `_regulator_enable()`，也就绕开了 `is_enabled()` 的短路。
3. **找到 mmc_host** —— 遍历 `rdev->consumer_list`，挑出设备名为 `msm_sdcc.1` 的那一项，
   读它的 drvdata（`sdhci_pltfm_init()` 往这里存的就是 `sdhci_host`），取
   `sdhci_host->mmc`。
4. **请求重扫** —— `mmc_detect_change(host, 0)` 调度 `mmc_rescan()`，重新走一遍卡识别。

同一份源码编出三个变体：`diag`（stage 3，只读）、`off`（stage 1）、`on`（stage 2，先
`msleep(1500)` 让电放干净再上电）。

期望的内核日志：

```
pwrsq: init stage=1
pwrsq: rdev=f0326c00 name=8941_l20 use_count=4
pwrsq: consumer 'msm_sdcc.1'
pwrsq: mmc_host=f0032000
pwrsq: ops->disable ret=0
...
pwrsq: init stage=2
pwrsq: ops->enable ret=0
pwrsq: detect_change queued
mmc0: sdhci_cmd_irq: AUTO CMD err sts 0x00000002
mmc0: mmc_reinit_card
mmc0: mmc_reinit_card return 0
```

最后两行是 HTC 自己在 `sdhci_msm` 里的重新初始化路径：卡回来了，分区都在，手机没重启。

### 4. 写哪一个字节

```sh
dd if=/dev/zero of=/dev/block/bootdevice/by-name/pg1fs bs=1 seek=33792 count=1
sync; echo 3 > /proc/sys/vm/drop_caches     # 证明是从卡上读回来的，不是缓存
```

`33792` = `0x8400`。只有最低字节变（`03` -> `00`）；`0x8404` 的标签在出厂机上本来就是
`HTCU`。

`pg1fs + 0x424` 还有 4 个字节，老版 `firewater`/Sunshine 的配方会一起写。**这台机器上
不需要**：S-OFF 成功后，分区头部（0..0x1000，含 `0x424`）与改动前的备份逐字节一致，
手机正常启动。不要动它。

### 5. 为什么之后一直有效

重启后 hboot 读到 `secure_flag = 0`，走它的 S-OFF 分支 —— 其中就包括**不再设置
power-on 写保护**。所以 S-OFF 设备上第二次 `CMD31` 返回全 0，`pg1fs` 从那时起一直可写。
写保护不是被"攻破"的，是**不再被设置**了。

### 6. 模块为什么能加载

内核是 `CONFIG_MODVERSIONS=y` 编的，而我们没有它的 `Module.symvers`。两个后果，都已处理：

* 每个被导入的符号都需要匹配的 crc —— 所以模块**一个符号都不导入**：所有函数地址在
  编译时从 `/proc/kallsyms` 生成（`kmod/addr.h`）；
* `module_layout` 是无条件检查的 —— 所以模块自带一条 `__versions` 记录，crc 从设备上
  原厂 `.ko` 里抄出来。

---

## 前提条件

* **已 root 且能加载模块**：`adb shell id` 是 `uid=0`，
  `cat /proc/sys/kernel/modules_disabled` 是 `0`，SELinux Permissive。
* 与设备完全对应的**内核源码**，并已为外部模块 prepare 过。HTC 在 htcdev.com 发布；
  6.0.1 这一版是 `m8ul-3.4.0-perf-ga6393e1.zip`。
* 一套交叉工具链 + 能跑 kbuild 的机器：Linux，或 Windows 上的 MSYS2/Git Bash
  （见 [Windows](#windows)）。
* 备份。见文末的风险一节。

---

## 快速开始

```sh
# 0. 前置检查
adb shell id                                     # uid=0
adb shell getenforce                             # Permissive
adb shell cat /proc/sys/kernel/modules_disabled  # 0
adb shell 'echo 0 > /proc/sys/kernel/kptr_restrict'
adb shell 'mount -t debugfs none /sys/kernel/debug'

# 1. 先备份 pg1fs / board_info / mfg / radio / misc
scripts/backup.sh

# 2. 从手机读符号地址和 module_layout 的 crc
scripts/gen_addr.sh

# 3. 针对准备好的内核树编译三个模块
scripts/build.sh /path/to/kernel-tree

# 4. 先跑诊断版，确认链路正确（无副作用）
adb push kmod/pwrsq_diag.ko /dev/
adb shell 'dmesg -c >/dev/null; insmod /dev/pwrsq_diag.ko; dmesg | grep pwrsq'
#    期望：rdev=... name=8941_l20 / consumer 'msm_sdcc.1' / mmc_host=...

# 5. 停框架、sync，然后断电再上电
adb shell 'stop; sleep 8; sync'
scripts/powercycle.sh

# 6. 确认写保护已消失，再写 flag
adb push tools/mmc_cmd /dev/ && adb shell chmod 755 /dev/mmc_cmd
adb shell '/dev/mmc_cmd wp'                      # 必须全 0
scripts/write_flag.sh 0

# 7. 从 bootloader 验证
adb reboot bootloader && fastboot oem readsecureflag   # 应为 0
```

### 逐条说明与期望输出

**前置检查。** `ls /sys/kernel/debug/regulator/8941_l20/` 应当列出
`consumers enable force_disable mode msm_sdcc.1-vdd open_count use_count voltage`。
如果没有 `insmod`，或 `modules_disabled` 是 1，就到此为止：需要一台能加载模块的 root ROM。

**诊断。** 期望：

```
pwrsq: init stage=3
pwrsq: rdev=f0326c00 name=8941_l20 use_count=4
pwrsq: consumer 'msm_sdcc.1'
pwrsq: mmc_host=f0032000
pwrsq: done
```

`name=8941_l20` 说明稳压器找到了；`consumer 'msm_sdcc.1'` 加上非空的 `mmc_host` 说明
重扫这条路能用。`Failed to create debugfs directory` 是无害的（重复的 consumer 目录）。
卸载：`adb shell rmmod pwrsq_diag`。

**让 eMMC 静下来。** 卡马上要断电，不能有人正在写。`adb shell stop` 停掉框架，adbd 属于
class core 会留着；然后 `sync`。可选地把 `/data` 挂成只读：

```sh
adb shell 'for d in /mnt/runtime/*/emulated /data/media; do umount -l $d; done'
adb shell 'mount -o remount,ro /data'
```

有些 ROM 把 `/su` 挂在 loop 上，这条会以 `Device or resource busy` 失败 —— 那就只保证
框架停了、`sync` 跑过。`/data` 是 `errors=panic` 挂载的，断电期间任何一次写入都会 panic。

**断电上电。** `scripts/powercycle.sh` 先把两个模块推到 `/dev`（tmpfs —— 卡一没，
还在 `/data` 上的文件就读不到了），然后依次 `insmod` off 和 on。期望：

```
--- power off / power on ---
SEQ_DONE
--- result ---
 179        2     121823 mmcblk0p2
...
pwrsq: ops->enable ret=0
pwrsq: detect_change queued
mmc0: mmc_reinit_card
mmc0: mmc_reinit_card return 0
```

如果 `/proc/partitions` 里没有 `mmcblk0`，等几秒再 `insmod` 一次 `on`（stage 2 是幂等的）。
还是不行就只能手动断电重启，见[故障处理](#故障处理)。

**查写保护。** 循环之前 `mmc_cmd wp` 会把 group 0..11 列成 `power-on`，现在必须是：

```
bitmap: 00 00 00 00 00 00 00 00
  -> no write protection at all
```

只要还有任何一组被列出来，就不要往下走。

**写 flag。** `scripts/write_flag.sh 0`：

```
before:
 03 00 00 00 48 54 43 55
after:
 00 00 00 00 48 54 43 55
```

脚本在回读之前做了 `dd` + `sync` + `drop_caches`，所以你看到的值来自卡，不是页缓存。
这个区别很关键：写保护状态下 `dd` 也会"成功"，因为它只更新了缓存。

**验证。**

```
$ fastboot oem readsecureflag
(bootloader) secure_flag: 0
$ fastboot getvar all | grep -Ei 'secure|misc'
(bootloader) version-misc: PVT SHIP S-OFF
(bootloader) security: off
```

回到 Android 再确认一次 hboot 不再设保护：

```sh
adb shell '/dev/mmc_cmd wp'
# bitmap: 00 00 00 00 00 00 00 00
```

最后这一步才是真凭据：flag 之所以持久，是因为保护不再被设置，而不是因为每次开机有人去补。

---

## stool.sh

`scripts/stool.sh` 把上面这些步骤包起来，另外还管那些跟 S-OFF 无关的参数。

```sh
scripts/stool.sh status                  # S 状态 + 全部参数（Android 或 fastboot 都行）
scripts/stool.sh soff                    # 完整 S-OFF：备份、诊断、断电上电、写入、验证
scripts/stool.sh son                     # 回到 S-ON
scripts/stool.sh backup                  # 快照到 backup/<YYYYmmdd-HHMMSS>.txt
scripts/stool.sh restore <snapshot>      # 用快照还原
scripts/stool.sh set cid BS_US001
scripts/stool.sh set mid 0P6B12000
scripts/stool.sh set version 6.12.1540.4
scripts/stool.sh set tamper 0
scripts/stool.sh set secure 0|3
scripts/stool.sh set lock
scripts/stool.sh set unlock Unlock_code.bin
```

每个命令都会先读 S 状态。任何写操作在动卡之前都会把全部参数快照到
`backup/<时间戳>.txt`；这个文件一半是给人看的摘要，一半是
`raw:<分区>:<偏移>=<hex>` 形式的原始字节，`restore` 靠它逐字节写回。

`set secure 0` 在 S-ON 状态下会直接拒绝：写 flag 需要先把写保护清掉，而清写保护正是
`soff` 做的事。

| 参数 | 存储位置 | 改法 |
|---|---|---|
| CID | `board_info`（p3）@ 0x14，8 字符 | `fastboot oem writecid`（会重启到 bootloader） |
| MID | `mfg`（p5）@ 0x4000，9 字符 UTF-16LE | dd |
| version | `misc`（p24）@ 0xA0 | dd |
| tamper | `pg2fs`（p6）@ 0x511804 | dd |
| secure | `pg1fs`（p2）@ 0x8400 | dd，仅 S-OFF |
| lock / unlock | bootloader | `fastboot oem lock` / `flash unlocktoken` |

---

## 构建

### 1. 拿源码

HTC 在 htcdev.com（Kernel Source Code）发布。6.0.1 这一版的包是
`m8ul-3.4.0-perf-ga6393e1.zip`，内含 `kernel570.tar.gz`（`kernel/`）和
`platform.tar.gz`（其余源码树）。只有 `kernel/` 有用。

Windows 上要注意 NTFS 大小写不敏感，而这棵树里有只差大小写的文件
（`net/netfilter/xt_DSCP.c` 与 `xt_dscp.c`）。要么给目录开大小写敏感
（`fsutil file setCaseSensitiveInfo <dir> enable`，需要管理员），要么解包时排除这些
路径 —— 它们是 netfilter 驱动，与本项目无关。

### 2. 取出精确配置

不要相信 `arch/arm/configs/m8_defconfig`：HTC 用一棵树出很多变体。设备自己的配置就
压在 kernel 镜像里（`CONFIG_IKCONFIG=y`，`CONFIG_IKCONFIG_PROC` 关闭）：

```sh
adb shell dd if=/dev/block/bootdevice/by-name/boot of=/sdcard/boot.img bs=4096
adb pull /sdcard/boot.img

python3 - <<'EOF'
import struct, zlib
raw = open('boot.img','rb').read()
ks, ka, rs, ra, ss, sa, tags, page = struct.unpack('<8I', raw[8:40])
k = raw[page:page+ks]
i = k.find(b'\x1f\x8b\x08')
open('vmlinux.bin','wb').write(zlib.decompressobj(31).decompress(k[i:]))
EOF

sh kernel/scripts/extract-ikconfig vmlinux.bin > m8.config
grep -E 'CONFIG_MODULES|CONFIG_MODVERSIONS|CONFIG_LOCALVERSION' m8.config
```

`UTS_RELEASE` 最后必须正好是 `3.4.0-perf-ga6393e1`。因为压缩包里没有 git 历史，
`setlocalversion` 补不出 `-ga6393e1` 后缀，直接写进配置：

```sh
sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION="-perf-ga6393e1"/' m8.config
```

### 3. 准备内核树

```sh
cp m8.config kernel/.config
make -C kernel ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf- oldconfig
make -C kernel ARCH=arm CROSS_COMPILE=arm-none-linux-gnueabihf- modules_prepare
```

检查 `kernel/include/generated/utsrelease.h`：

```c
#define UTS_RELEASE "3.4.0-perf-ga6393e1"
```

如果不是这个字符串，模块会被 `version magic ... should be ...` 拒掉。

### 4. 工具链的五个坑

2016 年的内核 + 现代工具链 + MSYS2，会撞到五件事，补丁都在 `kernel-patches/`。

| 现象 | 处理 |
|---|---|
| `scripts/gcc-wrapper.py` 是 Python 2（`print "..."`） | 命令行传 `CC=` 直接绕过这个 wrapper |
| `fatal error: linux/compiler-gcc13.h: No such file` | 把 `compiler-gcc4.h` 复制成 `compiler-gcc13.h` |
| `fixdep: error opening config file:` 和随机解析错误 | MinGW 的 gcc 写出的 `.d` 是 CRLF，让 fixdep 跳过 `\r` |
| fixdep 在 MSYS2 上段错误 | 把它的 `mmap()` 换成 `malloc()+read()` |
| 编 dtc 报 `multiple definition of 'yylloc'` | `HOSTCFLAGS=-fcommon` |

```sh
cd kernel
git apply ../kernel-patches/0001-fixdep-crlf-and-no-mmap.patch
cp ../kernel-patches/compiler-gcc13.h include/linux/
```

wrapper 之所以会介入，是因为顶层 Makefile 写了
`CC = $(srctree)/scripts/gcc-wrapper.py $(REAL_CC)`；命令行传 `CC=<cross>gcc` 就盖掉了。
在 Linux 上用老工具链时这些都不需要 —— fixdep 那个补丁依旧无害。

### 5. 地址与 module_layout 的 crc

模块不导入符号，所以不需要 `Module.symvers`；它需要五个地址和一个 crc，都是这次内核构建
的属性：

```sh
scripts/gen_addr.sh                 # 读 /proc/kallsyms + 一个原厂 .ko
cat kmod/addr.h
```

* 五个地址都是普通代码符号，`CONFIG_KALLSYMS_ALL=n` 也能在 `/proc/kallsyms` 里看到
  （前提是 `kptr_restrict` 为 0）；
* `A_MODULE_LAYOUT_CRC` 是从设备上原厂模块的 `__versions` 里读出来的
  （`scripts/get_module_layout_crc.py`）。它是内核编译时 genksyms 给 `module_layout`
  算的 crc，猜不出来。

### 6. 编译

```sh
scripts/build.sh /path/to/kernel-tree
# Windows/MSYS2 上必须传 MSYS 路径（/d/kernel-src/kernel），不能是 D:/...
# 因为 kbuild 把 M= 当 make 目标传，盘符里的冒号会被当成目标分隔符。
```

脚本会打印每个 `.ko` 的未定义符号，必须是空的：

```
pwrsq_diag: (no undefined symbols)
pwrsq_off: (no undefined symbols)
pwrsq_on: (no undefined symbols)
```

那里出现的任何符号，内核都会要求对应的版本 crc，加载时报
`no symbol version for <sym>` 或 `disagrees about version of symbol <sym>`。

推到手机之前先自检：

```sh
readelf -S kmod/pwrsq_on.ko | grep __versions    # 64 字节，非空
strings kmod/pwrsq_on.ko | grep vermagic=
nm -u kmod/pwrsq_on.ko                           # 什么都不输出
```

`__versions` 必须正好有一条（`module_layout`）。如果是空的，说明编译时没带上 `addr.h`，
或者结构体被优化掉了。

### 7. 移植

* `kmod/pwrsq_impl.h` 里的 `TARGET_VREG` 和 `TARGET_MMC_DEV` 指定稳压器和 MMC 平台设备。
  其它 msm8974 的 HTC 机型一般还是 `8941_l20` 和 `msm_sdcc.1`，用
  `/sys/kernel/debug/regulator/*/consumers` 核对。
* 换机器/换内核必须重跑 `scripts/gen_addr.sh`：地址和 crc 都跟构建绑定。
* 如果内核开了 `CONFIG_MODULE_SIG_FORCE=y`，这条路直接死 —— 模块必须用内核信任的密钥签名。

---

## Windows

`.sh` 是 POSIX shell 脚本，Windows 不能直接执行。三种跑法：

* **Git Bash**（Git for Windows 自带）或 **MSYS2** —— 本项目开发和验证用的就是它。
  在仓库根目录打开 shell：`./scripts/build.sh /d/kernel-src/kernel`，或者
  `sh scripts/build.sh ...`。
* **WSL** —— 能用，但 `adb`、`make` 和工具链都得装在发行版里，USB 还要 `usbipd`。
* **Cygwin** —— 没试过。

Windows 上有三件事会咬人：

1. **行尾。** 存成 CRLF 的脚本会死在 `$'\r': command not found`。仓库在
   `.gitattributes` 里钉了 `*.sh text eol=lf`，正常 clone 不会出问题；如果你手动拷来拷去，
   跑一次 `sed -i 's/\r$//'`。
2. **路径。** Git Bash 认识 `/d/...`；kbuild 不接受 `D:/...` 作为 `M=`，因为冒号看起来像
   make 的目标分隔符。给 `scripts/build.sh` 传 MSYS 路径。
3. **PATH。** `adb`、`make`、`python3` 都必须在这个 shell 里能找到。Git Bash 本身不带
   `make`，装 MSYS2 或把它加进 PATH。

本次实际使用的组合：Git Bash（WorkBuddy 自带）、MSYS2 的 GNU Make 4.4.1、Python 3.13、
adb 1.0.41、`arm-none-linux-gnueabihf-gcc` 13.3.1（MinGW 宿主版）。README 里的步骤是以
等价的原生命令逐条执行的；`scripts/gen_addr.sh` 另外完整跑通过一次。

---

## 实测记录

参考机的原始输出，已去掉序列号和 IMEI。

**之前**

```
(bootloader) version-bootloader: 3.19.0.0000
(bootloader) version-main: 6.31.1402.1
(bootloader) version-misc: PVT SHIP S-ON
(bootloader) product: m8_ul
(bootloader) modelid: 0P6B62000
(bootloader) cidnum: HTCCN703
(bootloader) security: on

$ fastboot oem readsecureflag
(bootloader) secure_flag: 3

$ mmc_cmd wp
bitmap: aa aa aa aa 2a aa aa aa      -> group 0..11 power-on
```

**断电上电期间**

```
pwrsq: rdev=f0326c00 name=8941_l20 use_count=4
pwrsq: consumer 'msm_sdcc.1'
pwrsq: mmc_host=f0032000
pwrsq: ops->disable ret=0
pwrsq: ops->enable ret=0
pwrsq: detect_change queued
mmc0: sdhci_cmd_irq: AUTO CMD err sts 0x00000002
mmc0: mmc_blk_issue_rw_rq status 4 retry 0
mmc0: mmc_reinit_card
mmc0: mmc_reinit_card return 0
```

**之后**

```
$ mmc_cmd wp
bitmap: 00 00 00 00 00 00 00 00
  -> no write protection at all

00008400  00 00 00 00 48 54 43 55

$ fastboot oem readsecureflag
(bootloader) secure_flag: 0
(bootloader) version-misc: PVT SHIP S-OFF
(bootloader) security: off
```

再冷启动两次，`readsecureflag` 和 `mmc_cmd wp` 依旧全是 0。

**分区其余部分的完整性。** `pg1fs[0x0000..0x1000]` 改动前后的 `md5`：

```
f22ff5ac41ac26e1a3ecd2997ba6ca3a   改动前（备份）
f22ff5ac41ac26e1a3ecd2997ba6ca3a   改动后
```

完全一致，包括 `0x424` 那 4 个设备相关字节。只有 `0x8400` 变了 —— 这就是本工具只写一个
字节的原因。

---

## 故障处理

按顺序排查。

**卡没回来。** 打印了 `SEQ_DONE`，但 `/proc/partitions` 里没有 `mmcblk0`。

1. 等 10 秒 —— `mmc_detect_change()` 是丢到 workqueue 上跑的。
2. `adb shell 'dmesg | tail -40'`，找 `mmc_reinit_card`、`AUTO CMD err`、
   `Controller never released inhibit bit(s)`。
3. 再 `adb shell 'insmod /dev/pwrsq_on.ko'` 一次，stage 2 是幂等的。
4. 如果 adb 也没了，长按电源约 10 秒。手机正常启动，flag 没变，可以重来。

断电失败不会造成永久损坏 —— flag 是在最后一步才写的。

**内核 panic。** `/data` 是 `errors=panic`，任何一次落到死卡上的写都会 panic。手机会自己
重启，写保护重新挂上，flag 没动。修掉原因（停框架、`sync`、把 `/data` 挂只读）再来一次。

**`dd` 报成功但字节没变。** 写根本没到卡上。

```sh
adb shell '/dev/mmc_cmd wp'                    # 有非零组 => 保护还在
adb shell 'dmesg | grep -i "card status"'
```

* `card status 0x400d00`（第 22 位，`WP_ERASE_SKIP`）—— 保护还在，说明断电实际上没发生。
  `dmesg` 里必须有 `pwrsq: ops->disable ret=0`，并且卡消失期间
  `cat /sys/kernel/debug/regulator/8941_l20/enable` 应当是 0。
* 完全没有 card status 报错 —— 你读的是页缓存。验证之前永远先 `sync` +
  `echo 3 > /proc/sys/vm/drop_caches`。

**还原备份。** S-OFF 之后固件分区可写，还原就是普通的 `dd`：

```sh
adb push backup-.../pg1fs.img /dev/pg1fs.img
adb shell 'dd if=/dev/pg1fs.img of=/dev/block/bootdevice/by-name/pg1fs bs=1048576'
adb shell 'sync; rm -f /dev/pg1fs.img'
adb reboot bootloader && fastboot oem readsecureflag
```

`board_info`（p3）、`mfg`（p5）、`radio`（p20）、`misc`（p24）同理。还原 `pg1fs.img`
会把 `0x8400` 写回 `03`，也就是 S-ON。

**不要做**

* **不要 `fastboot flash` 固件分区。** hboot 对每一个都验签并拒绝 —— 这正是本工具要绕的
  行为，也是保护你不会刷进坏镜像的东西。
* **`pg1fs` 里除了 `0x8400` 什么都不要写。** `0x400` 的头部描述三条记录
  （`security`、`simlock`、`simunlock`），`0x424`/`0x824`/`0xc24` 那 4 字节是设备相关的，
  这里刻意没动。
* **不要在 `/data` 正在写的时候做断电上电。** panic 还能恢复，写坏一半的 ext4 日志不一定。

**整机不启动。** 进 bootloader（音量下 + 电源）。如果 hboot 能起来，
`fastboot getvar all`：还是 S-ON 说明什么都没改，正常刷 ROM 即可恢复；S-OFF 但系统坏了，
刷对应 RUU 就行。如果 hboot 都起不来，问题不在 `pg1fs` —— 本流程从不碰 `hboot`、
`sbl1`、`tz`。

---

## 撤销

```sh
scripts/write_flag.sh 3 && adb reboot bootloader && fastboot oem readsecureflag
```

`3` 恢复 S-ON。下一次开机写保护会自动回来，`pg1fs` 也随之不可写。S-ON + 解锁 bootloader
是受支持的状态；S-ON + 改过的 `hboot` 不是 —— 如果你换过 hboot，先刷回官方 hboot。

---

## 风险

* 断电之前把 `/data` 挂成只读，或者至少停掉框架。`/data` 是 `errors=panic`，对死卡的
  一次写入就会 panic。
* 卡如果没重新枚举，手机要手动断电才能再启动。数据不会丢，但你需要能够碰到机器。
* `scripts/backup.sh` 之所以存在，是因为"应该不会出事"不叫恢复方案。镜像留在电脑上，
  不要留在手机里。
* 写 `pg1fs` 是本工具的目的，也是唯一不可逆的一步。`0x8400`：`00` = S-OFF，`03` = S-ON。
  别的字节不要碰。

没有任何担保。刷坏了自负。

---

## 仓库结构

```
kmod/              断电上电模块（三个变体 + addr.h）
tools/             mmc_cmd：CMD31 写保护查询
scripts/           stool.sh 控制工具、备份、地址生成、编译、断电上电、写 flag
kernel-patches/    用现代工具链编 3.4 树所需的修补
```

---

## 致谢

* HTC 公开内核源码，以及 `sdhci_msm` 里那条 `mmc_reinit_card` —— 卡不用重启就能回来。
* XDA/ARHD 社区关于 RUU/CID/MID 的整理，本项目的判断建立在这些之上。
* `firewater`/Sunshine 时代的研究，把 S-OFF flag 到底是什么讲清楚了。

---

## 许可证

GPL-2.0。`kmod/` 里的内核模块链接进 GPL-2.0-only 的内核并声明
`MODULE_LICENSE("GPL")`，不能再授权成别的。

---

## 免责声明

仅用于**自己持有设备**上的安全研究与系统维护。在 Android 运行时切断 eMMC 供电不是受支持
的操作，动手之前先确认你有恢复手段。不提供任何形式的担保；作者不对变砖、数据丢失或保修
失效负责。
