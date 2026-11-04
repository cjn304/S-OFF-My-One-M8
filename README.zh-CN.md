# S-OFF-My-One-M8

[English](README.md) | **中文**

自从 Sunshine 停止服务后，没有能用的 HTC S-OFF 工具了。

hboot 用 eMMC 的 power-on 写保护锁住固件分区，而这种保护按规范只有掉电才清除。所有用户态的通路都被堵死，所以这里用一个小内核模块在内核态把 PMIC 的电真断一次再上电，最后写 flag 字节。

已在 HTC One M8，hboot 3.19.0.0000 上[测试成功](#实测记录)（其它机型见[移植](#8-移植)）。

---

## 前提条件

* [解锁 BL](http://www.htcdev.com/bootloader/) 并 root，或刷入自带 root 的固件。内核要能加载模块：M8 的 LineageOS 17.1 就不行。像 Sunshine 一样临时 root 就不用解锁 BL，S-OFF 之后随便解锁。
* 与固件接近的内核源码，HTC 官方的在 [htcdev.com](https://www.htcdev.com/devcenter/downloads) 发布。
* 一套交叉工具链 + 能跑 kbuild 的机器：Linux，或 MSYS2/Git Bash（见 [Windows](#windows)）。
* 数据备份（见[风险](#风险)）和[构建](#构建)。

---

## 快速开始

下面的命令假设 `adb shell` 本身就是 root：要么是 userdebug / eng 固件，`adb root` 能生效；要么是已 root 的官方固件，每条 `adb shell ...` 改成 `adb shell 'su -c "..."'`。引号顺序不能反：重定向必须写在 su 里面，否则非 root 的 shell 会先执行它，直接 `Permission denied`。每个 `stool.sh` 命令都会自己探测 root（Magisk 的 `su`、adb root 或 userdebug 固件）；`gen_addr.sh` 不需要，`kptr_restrict` 归零后 `/proc/kallsyms` 对所有人可读。[期望输出与故障处理](#期望输出与故障处理)。

```sh
# 0. 检查 root、S 状态、modules_disabled、SELinux
scripts/stool.sh status

# 1. kptr_restrict 归零，kallsyms 才显示地址，然后读地址
adb shell 'echo 0 > /proc/sys/kernel/kptr_restrict'
scripts/gen_addr.sh

# 2. 编译三个内核模块和 mmc_cmd
scripts/build.sh /path/to/kernel-tree
make -C tools CROSS=arm-none-linux-gnueabihf-

# 3. 在 debugfs 下找稳压器目录，先备份，再诊断、断电上电、写 flag、验证
adb shell 'mount -t debugfs none /sys/kernel/debug'
scripts/stool.sh backup
scripts/stool.sh soff

# 4. 写回一个分区镜像
scripts/stool.sh restore pg2fs 20261104-045201.pg2fs.img
```

---

## stool.sh

`scripts/stool.sh` 是下面全部命令的入口。会写设备的命令（`set`、`lock`、`unlock`、`noredtext`、`splash`）在 dump 和写入之前先查 S 状态，S-ON 直接拒绝，一个字节都不会写。`status`、`backup` 只读，`restore` 的分区由参数给出，`soff`、`son` 和 `set secure 0` 本来就是改 S 状态本身，这几条不预先要求 S-OFF；`set secure 0` 仍会先探测写保护，真还有保护就拒绝。

```sh
scripts/stool.sh status                  # S 状态 + 全部参数（Android 或 fastboot 都行）
scripts/stool.sh soff                    # 完整 S-OFF：诊断、断电上电、写入、验证
scripts/stool.sh son                     # 回到 S-ON
scripts/stool.sh backup [partition]      # 五个整分区 + 参数，或只备一个
scripts/stool.sh restore <partition> <file.img>   # 如 restore pg2fs 20261104-045201.pg2fs.img
scripts/stool.sh set cid <cid>           # 8 字符，11111111 = SuperCID
scripts/stool.sh set mid <mid>           # 9 字符，例如 0P6B12000
scripts/stool.sh set version <version>   # 例如 6.12.1540.4，最长 15
scripts/stool.sh set tamper <0|4>        # 0 = Official，4 = Modified
scripts/stool.sh set secure <0|3>        # 0 = S-OFF，3 = S-ON
scripts/stool.sh lock                    # BL magic -> 锁定
scripts/stool.sh unlock                  # BL magic -> 解锁
scripts/stool.sh noredtext               # 抹掉 hboot 里六行开发警告红字
scripts/stool.sh splash photo.png        # 换开机第一屏，尺寸取自 targets.conf
scripts/stool.sh splash photo.png --size=1440x2560     # 其它分辨率的屏
```

每个参数放在哪、备份哪些分区，都来自 `targets.conf`：一个布局一项，用设备在 `/sys/class/block/*/uevent` 里报的尺寸去匹配。布局对不上的机器会在写入之前被拒绝；要加一项，见[6. 参数偏移](#6-参数偏移)。

每个命令都会先读 S 状态。没有整份备份是自动做的：`backup` 写出 `backup/<时间戳>.{txt,img}`（五个整分区，外加一份可读的 txt 摘要），`restore <partition> <file.img>` 再把其中一张 img 写回去，`pg1fs` 里的 `0x8400` 也在其中。所以镜像里的状态说了算：还原一份 S-ON 时期拍的 `pg1fs.img`，手机就回到 S-ON。不打招呼就 dump 的只有 `noredtext` 和 `splash`：它们只把自己即将覆盖的那一个分区存下来，那是撤销用的，不是别处的保险。

`set tamper` 接受 0..255 的十进制，但有意义的只有 `0` 和 `4`。这一个字节就是 hboot `Software status:` 那行的唯一来源：`04` 显示 `*** Software status: Modified ***`，`00` 显示 `*** Software status: Official ***`。

`set secure` 就是 `soff` 最后一步的那次写入，单独跑：写 `0x8400`，再回读，不断电也不重启。S-ON 时写 `0` 会先探测 `mmc_cmd wp`：只有真的还有写保护才拒绝；位图全零（[移植](#8-移植) A 档那种旧 hboot）就照写。已 S-OFF 的机器上，还原了一份 S-ON 时期拍的 `pg1fs.img` 之后，也用它把 `00` 写回去。

`lock` / `unlock` 直接写 `pg1fs`（p2）0x8404 的四个字节：`HTCU` = 解锁，`00000000` = 锁定。hboot 开机比对的就是这串 magic，所以设备一旦 S-OFF 就不需要在官网申请的解锁码了；也不走 `fastboot oem lock`：那条只会得到 `RELOCKED`，而 hboot 3.19 根本没有 `oem unlock` 命令（返回 `[ERR] Command error`）。

`backup` 写出这些文件：

| 文件 | 内容 | 大小 |
|---|---|---|
| `<timestamp>.txt` | 全部参数的值，连同上一次读到的字节 | 约 0.5 KB |
| `<timestamp>.pg1fs.img` | p2，secure flag、BL magic 在这里 | 119 MB |
| `<timestamp>.board_info.img` | p3，CID、IMEI、板级数据在这里 | 16 KB |
| `<timestamp>.mfg.img` | p5，MID 在这里 | 256 KB |
| `<timestamp>.pg2fs.img` | p6，status flag 在这里 | 24 MB |
| `<timestamp>.misc.img` | p24，version-main 在这里 | 1 MB |

txt 只是给人看的记录。`set cid` 和其它参数一样，用 `dd` 写 `board_info` 0x14 那 8 个字节；hboot 在开机时读它，所以 `getvar cidnum` 要重启后才变。整块 p3 镜像仍然保留：CID 紧挨着 IMEI 和板级数据，那些本工具不碰。radio（p20）本工具不写入，所以不再 dump。整套约 144 MB，走 USB 大概一分钟。

### CID、MID 和刷机的关系

MID 标明机型变体：`0P6B62000` 是国行联通版，`0P6B12000` 是 Dev Edition；CID 标明运营商或地区（国行联通是 `HTCCN703`）。这两项都写在固件包的 `android-info.txt` 里，hboot 在 RUU 模式下解析 zip 时逐项比对。`set mid` 写 mfg 0x4000，`set cid` 写 board_info 0x14；CID 改成 `11111111`（SuperCID）在多数 hboot 上能放行任意 CID，但不是所有构建都认，而且固件层版本本身可能先把 RUU 挡在门外，见[从 4.18 刷 6.12 的 RUU](#从-418-刷-612-的-ruu)。各固件包的对应见这份[表格](https://docs.google.com/spreadsheets/d/10H7RftecZZKb5tT2zpShfYNFAfSe-imhhqtVfeMPVDA/edit?gid=0#gid=0)。

#### 从 4.18 刷 6.12 的 RUU

港版 4.18.708.12（hboot `3aa067db`）直接跑 6.12.1540.4 的 RUU，界面在点 Start 后立刻报 Error 155，日志里真正的错误是：

```text
(bootloader) zip info parsing...
FAILED (status read failed (Too many links))
```

这不是 MID 或 CID 不匹配。RUU 日志（`C:\RUU_log\RUU_*.log`）显示它只读了 `boot-mode`、`battery-status`、`version-main`，随后进入 RUU 模式发送 zip，失败点在 hboot 解析 zip 的位置。把 CID 从 `11111111` 改成包里的 `BS_US001` 后，同一个位置仍然失败。

原因是 RUU exe 里的 `rom.zip` 是 HTC 的 large-zip 容器，htc_fastboot 发送前会打印 `found large-zip header`。4.18 这块 hboot 只认普通 zip，读到分块结构后直接重置 USB 端点，主机端看到的就是 `Too many links`。

解法是先刷同版本的普通固件包（`0P6BIMG`，或 `DevEdition_6.12.1540.4_...zip`，约 53 MB，含 hboot、radio、sbl1、tz），把 hboot 换到 `76df2b54`。实测旧 hboot 能完整刷入这个包，刷完 `commitno` 变成 `76df2b54`、`version-main` 变成 `6.12.1540.4`、radio 变成 `1.29.214500021.24_2G`，同一个 `rom.zip` 随后一次通过。刷完 RUU 再把 CID 改回 `11111111`。

两个看起来像失败、其实不是的地方：

- `fastboot flash hboot hboot_signedbyaa.img` 会被 hboot 拒绝，报 `FAILED (remote: not allowed)`，FASTBOOT 和 RUU 模式下都一样。hboot 分区只接受 zip 流程，不接受裸写镜像。
- 刷完固件包后旧 `/system` 通常起不来：boot 和 radio 已经是 6.12 的，system 还是 4.18 的。这是预期结果，接着跑 RUU 把 system 补上即可。

刷固件包会写 sbl1 和 tz，中断会砖。刷之前确认电量，刷的过程中不要动线。`backup hboot` 只在 hboot 还能进 bootloader 时有用，完全黑屏时它救不了。

### 开机红字

`noredtext` 是按内容找那六行，不是写死偏移。它先把整个 4 MB 的 `hboot` 分区 dump 出来，搜到这六个字符串，把每行首字节改成 `00`，写回，再逐字节读回校验。偏移在不同构建之间是变动的（6.12.1540.4 上是 `0x8C340`，6.31.1402.1 的 dump 上是 `0x8C3F8`，更老的 m8_ul 镜像上是 `0x899CE`），所以必须动态找。

运行前要知道两件事：

- hboot 带 HTC 签名，改字节就会破坏签名，全靠 S-OFF 让 SBL 跳过校验。S-ON 时绝对不能碰，并且一定要保留 dump 出来的 `<timestamp>.hboot.img`：`restore <时间戳>.hboot.img` 就是把它原样写回去。
- 6.12.1540.4 这块 hboot 里，这六个字符串**没有任何静态引用**。绝对地址、文件偏移、低 20 位匹配、ARM 与 Thumb 的 `movw`/`movt`、代码段 literal pool，全部扫过，一个都没有。说明横幅是运行期装配的，所以改字符串本身是唯一安全的最小改动，不存在"参数可改的绘制函数"可找。

### 第一屏

`splash` 把 PNG 转成 `sp1` 分区真正的格式：小端 RGB565，尺寸取 `targets.conf` 里该机型那一项（M8 上是 1080x1920，4,147,200 字节），`--size=WxH` 可以改成其它尺寸；分区其余部分是填充。写之前会先拿帧大小和分区大小比一遍，装不下就直接停。

转换由 `scripts/png2rgb565.py` 完成，刻意只用标准库：精简的 Windows 环境里没有 ffmpeg、没有 PIL、没有 ImageMagick。支持非隔行 8 位 PNG 的灰度、灰度+alpha、RGB、RGBA 和调色板，缩放用双线性；其它格式会明确报错而不是生成一张错图（JPG 也一样，先另存成 PNG）。

源图不是 9:16 时由 `--fit` 决定怎么处理，命令会把这行打出来：

| `--fit` | 行为 |
|---|---|
| `contain`（默认） | 等比缩放到放得下，居中，其余用 `--bg=RRGGBB` 填（默认黑） |
| `cover` | 等比缩放到铺满，居中裁掉溢出部分，没有黑边，但会切边 |
| `stretch` | 两个方向各自拉伸，**会变形**，会打印警告 |

以前固定是 `stretch`，一张 1920×1080 的照片会被悄悄压成 1080×1920。现在默认 `contain`，因为"带黑边的开机图"比"被拉变形的 logo"是更小的错误。

这个转换器检查的是容器不是内容：PNG 能不能读、色彩类型和位深支不支持、结果是不是正好 4,147,200 字节、写进去的字节读回是否一致。它没法告诉你图片是倒的、全黑、全白，或者分辨率太低糊成一片，这些只能你自己看。

---

## 构建

### 1. 拿源码

HTC 在 [htcdev.com](https://www.htcdev.com/devcenter/downloads)（Kernel Source Code）发布。6.0.1 这一版的包是 `m8ul-3.4.0-perf-ga6393e1.zip`，内含 `kernel570.tar.gz`（`kernel/`）和 `platform.tar.gz`（其余源码树）。只有 `kernel/` 有用。

Windows 上要注意 NTFS 大小写不敏感，而这棵树里有只差大小写的文件（`net/netfilter/xt_DSCP.c` 与 `xt_dscp.c`）。要么给目录开大小写敏感（`fsutil file setCaseSensitiveInfo <dir> enable`，需要管理员），要么解包时排除这些路径，它们是 netfilter 驱动，与本项目无关。

### 2. 取出精确配置

不要相信 `arch/arm/configs/m8_defconfig`：HTC 用一棵树出很多变体。设备自己的配置就压在 kernel 镜像里（`CONFIG_IKCONFIG=y`，`CONFIG_IKCONFIG_PROC` 关闭）：

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

`dd` 需要 root：官方 ROM 上写成 `adb shell 'su -c "dd …"'`；这个块里其余命令都在主机上跑。

`UTS_RELEASE` 最后必须正好是 `3.4.0-perf-ga6393e1`。因为压缩包里没有 git 历史，`setlocalversion` 补不出 `-ga6393e1` 后缀，直接写进配置：

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

wrapper 之所以会介入，是因为顶层 Makefile 写了 `CC = $(srctree)/scripts/gcc-wrapper.py $(REAL_CC)`；命令行传 `CC=<cross>gcc` 就盖掉了。在 Linux 上用老工具链时这些都不需要，fixdep 那个补丁依旧无害。

### 5. 地址与 module_layout 的 crc

模块不导入符号，所以不需要 `Module.symvers`；它需要五个地址和一个 crc，都是这次内核构建的属性：

```sh
scripts/gen_addr.sh                 # 读 /proc/kallsyms + 一个原厂 .ko
cat kmod/addr.h
```

* 五个地址都是普通代码符号，`CONFIG_KALLSYMS_ALL=n` 也能在 `/proc/kallsyms` 里看到（前提是 `kptr_restrict` 为 0）；
* `A_MODULE_LAYOUT_CRC` 是从设备上原厂模块的 `__versions` 里读出来的（`scripts/get_module_layout_crc.py`）。它是内核编译时 genksyms 给 `module_layout` 算的 crc，猜不出来。

### 6. 参数偏移

`kmod/addr.h` 管的是内核符号；参数偏移也不由任何脚本生成。它们跟着分区布局走，所以放在 `targets.conf` 里。

选哪一项，是拿它的 `layout` 行去比设备在 `/sys/class/block/*/uevent` 里报的尺寸（`PARTNAME` 加 `size`，单位 512 字节扇区；无需 root）。用尺寸当键是有道理的：改 MID 或 CID 不会挪动任何东西，因为那两项都是分区里的内容；换了固件，装这些记录的分区尺寸就跟着变。一项都对不上时，脚本在动卡之前停下，把看到的布局原样打出来：

```
error: no section in targets.conf matches this device.
  observed: hboot:8192 sp1:10240 pg1fs:243646 board_info:32 ...
```

把这一行贴进新的 `[name]` 项，再补偏移；偏移仍然只能人工推导。做法是把小分区 dump 下来，拿设备自己报出来的值去搜：

```sh
for p in board_info mfg misc pg1fs pg2fs hboot sp1; do
	adb shell "su -c 'dd if=/dev/block/bootdevice/by-name/$p of=/sdcard/$p.img'"
	adb pull /sdcard/$p.img
done
```

`su -c` 是按 Magisk 环境写的；`adb shell` 本身就是 root 时去掉它。

| 字段 | 键 | M8 上的位置 | M8 上的值 | 怎么定位的 |
|---|---|---|---|---|
| CID | `cid` | `board_info` p3 | 0x14，8 字符 ASCII | `fastboot getvar all` 里的 `cidnum` 字符串 |
| MID | `mid` | `mfg` p5 | 0x4000，18 字节 UTF-16LE | `modelid` 字符串的 UTF-16LE 编码，每字符 2 字节 |
| version | `version` | `misc` p24 | 0xA0，16 字节 ASCII | `version-main` 字符串 |
| status | `tamper` | `pg2fs` p6 | 0x511804，u32 LE | hboot 显示 `Software status: Modified` 时读作 4，Official 时是 0 |
| secure | `secure` | `pg1fs` p2 | 0x8400，u32 LE | S-ON 是 `03 00 00 00`，S-OFF 是 `00 00 00 00`；用 `readsecureflag` 对照 |
| BL | `blmagic` | `pg1fs` p2 | 0x8404，4 字符 | flag 紧跟的四个字节：`HTCU` 解锁、`00000000` 锁定 |
| 红字 | `hbootpart` | `hboot` p26 | 运行期 | 六段已知横幅字符串，按镜像搜 |
| 第一屏 | `splash` | `sp1` p12 | 0 | 画面从 0 开始：W x H x 2 字节 |

`screen` 是唯一不带偏移的键：它给出 `splash` 默认转换成的分辨率；`hbootpart` 则提供 noredtext 用来校验镜像大小的分区。

换构建时重复这套流程，有两条规矩：

- 搜设备已经告诉你的东西（`cidnum`、`modelid`、`version-main`、hboot 那行状态），不要猜偏移；同一个值回头还能验证你找到的位置。
- 每次写完先 `sync` + `drop_caches` 再回读。写保护还在时，写入“成功”只是更新了页缓存，这也是 `write_hex` 坚持回读而不是相信 `dd` 的原因。

### 7. 编译

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

那里出现的任何符号，内核都会要求对应的版本 crc，加载时报 `no symbol version for <sym>` 或 `disagrees about version of symbol <sym>`。

推到手机之前先自检：

```sh
readelf -S kmod/pwrsq_on.ko | grep __versions    # 64 字节，非空
strings kmod/pwrsq_on.ko | grep vermagic=
nm -u kmod/pwrsq_on.ko                           # 什么都不输出
```

`__versions` 必须正好有一条（`module_layout`，整段 64 字节）。如果是空的，说明这个段没进 `.ko`：检查 `pwrsq_impl.h` 里 `section("__versions"), used` 的属性还在，以及你看的是不是刚编出来的模块。

`build.sh` 不管用户态那个小工具；`tools/mmc_cmd` 也没有入库，它是一个静态链接的 ARM 可执行文件：

```sh
make -C tools CROSS=arm-none-linux-gnueabihf-
```

`soff` 会把它放进 `/dev`（tmpfs）并以 root 运行：`adb push` 写不了 `/dev`，所以先落到 `/data/local/tmp`，再由 root 在 eMMC 还在的时候拷过去。没有它，`soff` 会在动手机之前停下：写保护检查是唯一能证明断电生效的依据。

### 8. 移植

参考构建是：

| 项目 | 值 |
|---|---|
| 机型 | HTC One M8，`m8_ul` |
| 出厂 MID / CID | `0P6B62000` / `HTCCN703` |
| 测试过的固件 | 6.31.1402.1，之后是 6.12.1540.4（都是 Android 6.0.1） |
| 内核 | `3.4.0-perf-ga6393e1`（2016-01）/ `3.4.0-perf-g708019f`（2015-11） |
| hboot | `3.19.0.0000` |
| root | Magisk 20.1（`su`）、`modules_disabled=0` |

MID 和 CID 是出厂值；参考机后来改成 `0P6B12000` / `11111111` 并刷了 Dev 固件，所以上面列了两个构建。

换机型时有两件事必须同时对上，而且它们会各自独立地失败：内核侧（结构体布局、符号地址）和机型侧（供电轨名、设备名、偏移、分区名）。稳压器名字和 MMC 平台设备名是 `kmod/pwrsq_impl.h` 里的编译期参数。

移植按要重做的量分四种情况，A 到 D，未实测。

**A. hboot 版本在 3.19 以前的：** 如 One M7（msm8960）、One S（msm8260A）、Sensation / XE（msm8260）、Desire HD（msm8255）以及 B 档中没怎么更新系统的。可能不设写保护，先在 S-ON 下跑 `mmc_cmd wp`，位图全零说明 hboot 没设保护。这时不需要模块也不用断电，普通写入就够：按[6. 参数偏移](#6-参数偏移)的办法找出分区、偏移和记录形状，填进 `targets.conf` 的一项，`stool.sh set secure 0` 就是那条写入（它会先探测位图，只有真的还有保护才拒绝）。那里有一点要注意：`03 00 00 00` 后面那 4 字节只有在 bootloader 解锁时才是 `HTCU`，锁着的机器上是 `00000000`，所以这个组合不能当通用锚点；找到候选后用 `readsecureflag` 验证。

**B. 同一世代的：** 如其它 M8 版本（双卡、Sprint、Verizon）、One E8、Butterfly 2、One mini 2，出自同一棵 HTC 3.4 树。机制、结构体、记录布局都成立，需要重新核对的只有板级那几项：

* `TARGET_VREG` 和 `TARGET_MMC_DEV` 仍是 `8941_l20` 和 `msm_sdcc.1`。这两个都是板级字符串，不是驱动名：`board-8974.c` 把 `sdhci-msm` 驱动注册的设备命名为 `msm_sdcc.1`，轨名则来自 `msm-pm8x41-rpm-regulator.dtsi`。
* 安全记录结构不变：pg1fs 0x8400 处的 `{u32 flag; char magic[4]}`，S-ON 时前四字节是 `03 00 00 00`；紧跟的四字节是 bootloader 锁状态 magic，只有解锁时才是 `HTCU`。写之前先核对这八个字节。
* 整个工作就是重跑 `scripts/gen_addr.sh` 再取一次 `module_layout` 的 crc。

**C. 驱动层要重做的：** 如 One M9（msm8994）、One M8s（msm8939）、Desire 816 / 610（msm8928 / msm8926），都落在另一层驱动上。思路照样成立，但有四件事同时变，而且每一件都能让模块“加载成功、然后做错事”：

1. `struct regulator` 是 `drivers/regulator/core.c` 的私有结构，本文件里存的是一份拷贝，必须按目标树重新抄。
2. drvdata：本内核存的是 `sdhci_host`；绑老 `msm_sdcc` 驱动的变体存的是它自己的 host 结构体，从上面读 `->mmc` 拿到的是垃圾。
3. 供电轨名跟的是 PMIC，不是 SoC。
4. `targets.conf` 里每一个偏移都要重新定位。

`pwrsq_diag.ko` 就是为了用设备实测回答第 2、3 条，而不是靠猜：它解析稳压器、打印全部 consumer 和找到的 mmc_host，且不写任何东西。

**D. HTC 10 及以后的：** 如 Desire 10 pro，以及之后仍用 eMMC 的机型，没有任何一项能原样沿用。按 XDA 上的 HTC 10 分区表（thread 3374048）：bootloader 是 `aboot`；参数分区整体挪位：`board_info` 在 p1、`mfg` 在 p2、`pg1fs` 在 p3、`pg2fs` 在 p4（23.6 MB，和 M8 差不多）；`sp1` 在 p21、10 MB，屏幕 1440x2560；by-name 在 `/dev/block/platform/soc/7464900.sdhci/by-name`。by-name 是 ueventd 按分区表建的一组符号链接，一个分区名一个；脚本通过它找分区，而不是写死 `mmcblk0pN`。

要移植到这些机型，需要改的地方按严重程度排：

1. `struct regulator` 按分支重新抄：新版内核跟 3.4 不一样，各分支之间也不一样。
2. drvdata：新内核存 `sdhci_pltfm_host`，要取 `pltfm_host->host`。
3. `targets.conf` 里每个偏移重新定位；只有 pg1fs 那条记录的形状大概能保持不变。

另外从 U11 这一代起，HTC 改用 UFS 2.1 而不是 eMMC。没有 `mmcblk0`，也没有 CMD28/29/31 那套写保护组，所以不管其余部分移植多少，本工具赖以成立的机制在那些机器上都不存在。

---

## 工作原理

### 1. 那堵墙

S-OFF 状态就是 `pg1fs` 里的一个字节：

| 偏移 | 含义 | S-ON | S-OFF |
|---|---|---|---|
| `0x8400` | secure flag（u32 LE） | `03 00 00 00` | `00 00 00 00` |

`fastboot oem readsecureflag` 读的就是这个值，`getvar all` 里的 `version-misc: PVT SHIP S-ON/S-OFF` 和 `security: on/off` 也都是从它推出来的。

`0x8404` 那 4 个字节是另一个字段：bootloader 的锁状态，`HTCU` 解锁、`00000000` 锁定。它不跟 S 状态走，S-ON 的机器可以是解锁的；`lock` / `unlock` 也只动这 4 个字节。

以 root 身份写这个字节会失败，原因既不是 SELinux 也不是文件系统：hboot 每次开机都给固件分区加上 eMMC 的 **power-on 写保护**。`CMD31`（SEND_WRITE_PROT_TYPE）按每 2 bit 一组报告类型：

```
00 = 无保护   01 = 临时   10 = power-on   11 = 永久
```

一台正常开机的 M8 回答：

```
CMD31 -> aaaaaaaa2aaaaaaa
         8 字节，每 2 bit 一组；10b = power-on
```

power-on 保护只能靠掉电清除。`CMD29`（CLEAR_WRITE_PROT）对它无效，`dd` 写 `pg1fs` 会拿到 `card status 0x400d00`，第 22 位，`WP_ERASE_SKIP`。

保护不是按分区挂的，而是按**写保护组**，一组多大由卡自己定。`mmc_cmd extcsd` 把决定这件事的几个 EXT_CSD 字段读出来：

```
  [221] HC_WP_GRP_SIZE     = 16
  [224] HC_ERASE_GRP_SIZE  = 1
  erase group  0.5 MiB
  wp group     8.0 MiB
  32 groups    256 MiB of 14910 MiB (1.7%)
```

每组 8 MiB，CMD31 只报 32 组，所以这张卡最多只能描述前 256 MiB。但在一台 S-ON 的 M8 上实测，位图**并不是**这张卡遵守的东西：它说 32 组里有 31 组受保护，可写 120 MiB 处那一个字节能落盘，写 315 MiB 处却回 `card status 0x400d00`、根本没到卡上。`WP_GRP_ENABLE = 0` 从另一侧说的是同一件事：组机制是关的，hboot 保护的是区间，`mmc_cmd wp` 只能当「有没有保护」的总开关用。

于是问题收敛成一句话：**把 eMMC 的 VCC 断掉再上电，且不能让 SoC 重启。**

### 2. 用户态为什么做不到

这路电是 **PM8941 LDO20**（`8941_l20`，2.95 V），由 RPM-SMD 管理。eMMC 控制器的设备树节点写着：

```dts
&sdhc_1 {
	vdd-supply = <&pm8941_l20>;
	qcom,vdd-always-on;
	...
```

三个各自独立的障碍：

1. **`qcom,vdd-always-on`**：`sdhci_msm` 在 probe 时把这路电打开，之后永不关闭。
2. **regulator core 短路**：用 debugfs 把电强制断掉之后，`regulator_enable()` 仍然拒绝调用 `->enable()`：

   ```c
   static int _regulator_enable(struct regulator_dev *rdev)
   {
           if (rdev->use_count == 0) {
                   ret = _regulator_is_enabled(rdev);
                   if (ret == -EINVAL || ret == 0) {
                           ...
                           ret = rdev->desc->ops->enable(rdev);
   ```

   `rpm_vreg_is_enabled()` 返回的是驱动缓存的请求位，对 always-on 的稳压器它一直是"开"，于是核心认为电还在、根本不去碰硬件。`echo 1 > .../enable` 会返回成功，然后什么都不做。
3. **没有重扫入口**：`sdhci` 没有用户态的 rescan 属性；解绑驱动并不会断电；而 `device_release_driver()` 在那个 gendisk 上还有可写文件系统时会永久阻塞。

用户态只能做到前一半：

```sh
echo 1 > /sys/kernel/debug/regulator/8941_l20/force_disable   # VCC 真的断了
```

eMMC 消失了，`mmcblk0*` 全没了，除了重启没有回头路。这就是墙。

### 3. 模块做了什么

`kmod/pwrsq_impl.h` 只做四件事：

1. **拿到稳压器**：`regulator_get(NULL, "8941_l20")`。`struct regulator` 是 `drivers/regulator/core.c` 的私有结构，所以模块里复制了一份，用来取 `->rdev`。
2. **直接调驱动 ops**：`rdev->desc->ops->disable(rdev)`，之后再 `->enable(rdev)`。这一步绕开了 `_regulator_enable()`，也就绕开了 `is_enabled()` 的短路。
3. **找到 mmc_host**：遍历 `rdev->consumer_list`，挑出设备名为 `msm_sdcc.1` 的那一项，读它的 drvdata（`sdhci_pltfm_init()` 往这里存的就是 `sdhci_host`），取 `sdhci_host->mmc`。
4. **请求重扫**：`mmc_detect_change(host, 0)` 调度 `mmc_rescan()`，重新走一遍 eMMC 的识别。

同一份源码编出三个变体：`diag`（stage 3，只读）、`off`（stage 1）、`on`（stage 2，先 `msleep(1500)` 让电放干净再上电）。

它打出来的日志在[诊断](#诊断)里；这里真正要看的是 `ops->disable ret=0` 和 `ops->enable ret=0` 这两行：它们说明驱动 ops 真的被执行了，而不是被 core 短路掉。末尾那对 `mmc_reinit_card` 是 HTC 自己在 `sdhci_msm` 里的重新初始化路径：eMMC 回来了，分区都在，手机没重启。

### 4. 写哪一个字节

```sh
dd if=/dev/zero of=/dev/block/bootdevice/by-name/pg1fs bs=1 seek=33792 count=1
```

`33792` 就是 `0x8400`。只有最低字节变（`03` -> `00`），上面三个本来就是 0。`0x8404` 那 4 个字节是 bootloader 的锁状态，不属于 flag（`HTCU` 解锁、`00000000` 锁定），只写 0x8400 时它原样不动。回读和之后为什么要 `drop_caches`，见[写 flag](#写-flag)；这里要说清的是：只有一个字节变。

`pg1fs + 0x424` 还有 4 个字节，老版 Firewater/Sunshine 的配方会一起写。**这台机器上不需要**：S-OFF 成功后，分区头部（0..0x1000，含 `0x424`）与改动前的备份逐字节一致，手机正常启动。不要动它。

### 5. 为什么之后一直有效

重启后 hboot 读到 `secure_flag = 0`，走它的 S-OFF 分支，其中就包括**不再设置 power-on 写保护**。所以 S-OFF 设备上第二次 `CMD31` 返回全 0，`pg1fs` 从那时起一直可写。写保护不是被"攻破"的，是**不再被设置**了。

### 6. 模块为什么能加载

内核是 `CONFIG_MODVERSIONS=y` 编的，而我们没有它的 `Module.symvers`。两个后果，都已处理：

* 每个被导入的符号都需要匹配的 crc，所以模块**一个符号都不导入**：所有函数地址在编译时从 `/proc/kallsyms` 生成（`kmod/addr.h`）；
* `module_layout` 是无条件检查的，所以模块自带一条 `__versions` 记录，crc 从设备上原厂 `.ko` 里抄出来。

---

## 期望输出与故障处理

快速开始的每一步，按执行顺序：什么输出说明它成了，以及对应会卡在哪。

### `stool.sh status`

```
== state ==
target  : m8  [htc_m8, hboot 3.19.*]
S state : S-ON  (secure_flag 3)
BL state: unlocked (pg1fs 0x8404 = HTCU)

== parameters ==
CID       11111111     board_info @ 0x14
MID       0P6B12000    mfg @ 0x4000
version   6.12.1540.4  misc @ 0xa0
tamper    0            pg2fs @ 0x511804
secure    3            pg1fs @ 0x8400
BL lock   unlocked     pg1fs @ 0x8404

modules   0
selinux   Enforcing
```

`target` 是 `targets.conf` 里命中的那一项，也是第一个要看的东西：出现 `unknown - no targets.conf section matches` 就说明表里没有这个布局，它下面那行 `observed:` 贴进新增的一项即可（见[6. 参数偏移](#6-参数偏移)）。`S state` 必须是 `S-ON`；出现 `unknown (no root ...)` 说明 `su` 还不通，后面每一步也一样跑不动。`modules` 必须是 `0`，否则 `insmod` 会被拒。`selinux Enforcing` 不致命：`soff` 只告警、照样往下走，模块能不能加载取决于 `su` 落到的域；如果被拒，这次开机先 `setenforce 0` 再重来。

### `gen_addr.sh`

```
wrote .../kmod/addr.h
/* Generated by scripts/gen_addr.sh - do not edit.
 * Kernel: Linux version 3.4.0-perf-g708019f ...
 */
#define A_REGULATOR_GET      0xc04033e0UL
#define A_DEV_GET_DRVDATA    0xc0482948UL
#define A_MMC_DETECT_CHANGE  0xc06aa7d4UL
#define A_PRINTK             0xc097da6cUL
#define A_MSLEEP             0xc01ba260UL

#define A_MODULE_LAYOUT_CRC  0x7d779921UL
```

五个地址都不能是 0，`Kernel:` 那行必须是手机**当前**跑的内核（`adb shell cat /proc/version`）。出现 `symbol '...' unavailable` 说明 `kptr_restrict` 没归零，脚本会把两种设置方式都打出来。

### 编译

```
pwrsq_diag: (no undefined symbols)
pwrsq_off: (no undefined symbols)
pwrsq_on: (no undefined symbols)
```

三个模块一个符号都不导入：所有内核函数都走 `addr.h`。`build.sh` 会在 `addr.h` 缺失、或仍是 `0x00000000UL` 占位值时停下。`make -C tools` 产出 `tools/mmc_cmd`，没有它 `soff` 会拒绝启动：判断断电是否生效只有这一个依据。

### `backup`

```
  pg1fs        124746752 bytes
  board_info       16384 bytes
  mfg             262144 bytes
  pg2fs         24837120 bytes
  misc           1048576 bytes
/path/to/repo/backup/20261104-031826.txt
```

每个分区一行打到 stderr，最后一行是 txt 的路径（stdout）。整套约 144 MB，走 USB 大概一分钟。某个分区读不出来会打 `warning: could not dump <分区>` 然后继续；镜像长度不对会打 `<分区>: expected N bytes, got M`。

写出分区名就只备份那一个，不写 txt：

```sh
scripts/stool.sh backup misc
  misc           1048576 bytes
/path/to/repo/backup/20261104-072924.misc.img
```

这台手机上的固件分区都能这样 dump，不限于那五个。`system`、`cache`、`userdata` 除外：它们是 Android 的文件系统，不是本工具管的固件，`backup system` 会直接拒绝。它不需要 S-OFF（读分区从来不需要），也不需要 `targets.conf` 里有对应的一节：名字和长度都来自设备，所以本工具不认识偏移的机器照样能备份。`noredtext` 和 `splash` 在覆盖自己要改的那个分区之前，调用的就是它。

### `soff`

`== state before ==` 先打印上面那几行状态。之后各阶段按实际顺序排列，每一段都跟着会让它停下的故障。

#### 诊断

```
== diagnostic (no side effects) ==
pwrsq: init stage=3
pwrsq: rdev=f0326c00 name=8941_l20 use_count=4
pwrsq: consumer 'msm_sdcc.1'
pwrsq: mmc_host=f0032000
pwrsq: done
```

`name=8941_l20` 说明稳压器找到了；`consumer 'msm_sdcc.1'` 加上非空的 `mmc_host` 说明重扫这条路能用。`Failed to create debugfs directory` 是无害的（重复的 consumer 目录）。`regulator 8941_l20 not found - wrong device/kernel?` 说明模块和这个内核不匹配，就停在这里。

#### 静默

`== quiesce ==`：`framework stopped, caches flushed`，也就是 `stop`、一次 `sleep`、两次 `sync`。eMMC 马上要断电，不能有人正在写。

`/data` 是 `errors=panic` 挂载的：往已断电的 eMMC 写一次就会 panic。手机会自己重启，写保护重新挂上，flag 没动，所以这里的 panic 只损失时间，修掉原因再来一次。想把 `/data` 也摘出去，先挂成只读：

```sh
adb shell 'su -c "mount -o remount,ro /data"'
```

有些 ROM 把 `/su` 挂在 loop 上，这条会以 `Device or resource busy` 失败，那就靠上面的 `stop` + `sync`。

#### 断电上电

`== power cycle ==`：先 `OFF_DONE`，电源轨保持关断 8 秒（`PWRSQ_OFF_SEC` 可改），再 `ON_DONE`。重扫本身的日志在 `dmesg | grep mmc_reinit_card` 里。

32 GB 的机器上实测：只断 1.5 秒不够，重新上电后位图仍是 31 组；8 秒才真正清掉。断得越久，host 恢复越慢，`pg1fs` 节点可能在 1 到 2 分钟后才出现，期间 `dmesg` 里是 `mmc0: err: runtime_error: -110` 和 `/data` 的 `JBD2: Detected IO errors`。脚本会轮询约 2.5 分钟。

`pg1fs` 这个节点没回来时，`soff` 停在 `eMMC did not come back within ~2 min`。断电失败不会造成永久损坏（flag 要到后面的阶段才写），所以：

1. 等 1 到 2 分钟：`mmc_detect_change()` 是丢到 workqueue 上跑的，`runtime_error` 之后 host 要等 PM 超时才重试。
2. `adb shell 'dmesg | tail -40'`，找 `runtime_error: -110`、`JBD2: Detected IO errors`。
3. 节点出现后 `adb reboot`：framework 还停着，重启一次比手动 `start` 干净。
4. 如果 adb 也没了，长按电源约 10 秒。手机正常启动，flag 没变，可以重来。

#### 写保护

```
== write protection ==
bitmap: 00 00 00 00 00 00 00 00
  -> no write protection at all
```

只要还有任何一组被列出来，`soff` 就停在 `eMMC write protection is still active - power cycle did not take effect`，这个状态下什么都不要写。如果写确实执行了、读回的字节却没变，说明写根本没到 eMMC：

```sh
adb shell 'su -c "/dev/mmc_cmd wp"'            # 有非零组 => 保护还在
adb shell 'dmesg | grep -i "card status"'
```

* `card status 0x400d00`（第 22 位，`WP_ERASE_SKIP`）：保护还在，说明断电实际上没发生。`dmesg` 里必须有 `pwrsq: ops->disable ret=0`，并且 eMMC 消失期间 `cat /sys/kernel/debug/regulator/8941_l20/enable` 应当是 0。
* 完全没有 `card status` 报错，你读的是页缓存。验证之前永远先 `sync` + `echo 3 > /proc/sys/vm/drop_caches`。

#### 写 flag

`== write secure flag ==`：`pg1fs 0x8400 = 0`。写入 `00` 后把这 4 个字节读回来，回读之前做了 `dd` + `sync` + `drop_caches`，所以值来自 eMMC，不是页缓存。对不上时停在 `read-back mismatch`，既然上一阶段过了，那就是写没落上去，回头看上面那两条。

#### 验证

`== verify from bootloader ==`：`secure_flag: 0   security: off`，随后手机重启回 Android，最后一行 `done - S-OFF`。两个值都有断言：`secure_flag is ..., expected 0` 或 `security is ..., expected off` 都会在 `done` 之前停下。

### `son`

同一条流程的反向：`pg1fs 0x8400 = 3`、`secure_flag: 3`、`done - S-ON (write protection comes back on the next boot)`。这一步的 bootloader 检查只告警（`expected 3, got ...`），因为那时 flag 已经写进去并回读过了。

### `restore`

```
== mfg ==
  mfg  262144 bytes  20261104-045201.mfg.img
writing 262144 bytes to mfg
64+0 records in
64+0 records out
262144 bytes transferred in 0.009 secs
  md5 e8301cf5c9c5873972846d54c7cd7040  ok
```

一个分区、一个文件，分区名总是要写：

```sh
scripts/stool.sh restore mfg 20261104-045201.mfg.img
```

这台手机上的固件分区都能写，不限于本工具写的那七个。`system`、`cache`、`userdata` 同样除外，`restore system ...` 会在读文件之前就拒绝。剩下的唯一检查是长度：镜像就是一个完整分区，所以必须正好等于那个分区的长度，长度表来自设备（`/sys/class/block/*/uevent`，也就是选 `targets.conf` 那一节时用的同一份探测）。文件名完全不读，`whatever.img` 效果一样。长度对不上、分区名不存在、或者那不是这台手机 eMMC 上的分区，都在写入前停下。写完回读分区算 md5，与镜像比对。

和备份一样，`restore` 也不需要 `targets.conf` 里有对应的一节：名字和长度都来自设备，所以本工具不认识偏移的机器照样能还原。

判断是否成功靠的是回读，不是写入。S-ON 的机器上，bootloader 在卡这一级保护了部分分区；写这些分区会被拒绝，而 `dd` 照样报成功，抓住它的是 md5 比对。`dmesg` 里对应的记录是 `card status 0x400d00`。S-OFF 让这层保护不再被挂上，但命令本身已经不再强制要求它。

别的一概不动：还原 `pg1fs` 不碰 `hboot`，反之亦然。`hboot` 和 `sp1` 也走同一条命令，所以 `noredtext` 和 `splash` 各自那个 `--restore` 已经去掉。

### 不要做

* **不要 `fastboot flash` 固件分区。** S-ON 时 hboot 会逐个核对它们的签名，签不上就拒绝写入，这道检查同时也挡住了坏镜像和别的机型的镜像。S-OFF 之后它不再核对，`fastboot flash pg1fs ...` 会把你给的文件整块写进去，写坏了没有下一道关。
* **`pg1fs` 里除了 `0x8400` 什么都不要写。** `0x400` 的头部描述三条记录（`security`、`simlock`、`simunlock`），`0x424`/`0x824`/`0xc24` 那 4 字节是设备相关的，这里刻意没动。
* **不要在 `/data` 正在写的时候做断电上电。** panic 还能恢复，写坏一半的 ext4 日志不一定。

### 整机不启动

进 bootloader（音量下 + 电源）。如果 hboot 能起来，`fastboot getvar all`：还是 S-ON 说明什么都没改，正常刷 ROM 即可恢复；S-OFF 但系统坏了，刷对应 RUU 就行。如果 hboot 都起不来，问题不在 `pg1fs`：S-OFF 流程从不碰 `hboot`、`sbl1`、`tz`。唯一会写 `hboot` 的是 `noredtext`，而它会先留一份 dump。

---

## Windows

`.sh` 是 POSIX shell 脚本，Windows 不能直接执行。三种跑法：

* **Git Bash**（Git for Windows 自带）或 **MSYS2**：本项目开发和验证用的就是它。在仓库根目录打开 shell：`./scripts/build.sh /d/kernel-src/kernel`，或者 `sh scripts/build.sh ...`。
* **WSL**：能用，但 `adb`、`make` 和工具链都得装在发行版里，USB 还要 `usbipd`。
* **Cygwin**：没试过。

Windows 上有四件事会咬人：

1. **行尾。** 存成 CRLF 的脚本会死在 `$'\r': command not found`。仓库在 `.gitattributes` 里钉了 `*.sh text eol=lf`，正常 clone 不会出问题；如果你手动拷来拷去，跑一次 `sed -i 's/\r$//'`。
2. **设备路径。** MSYS 会在 `adb` 看到之前把绝对路径改写成 Windows 路径：`adb push x /data/local/tmp/x` 到手的会是 `C:/Program Files/Git/data/local/tmp/x`。手机上的路径前面加 `//`（`//data/local/tmp/x`）才是字面量；仓库里的脚本已经这么写了。
3. **主机路径。** Git Bash 认识 `/d/...`；kbuild 不接受 `D:/...` 作为 `M=`，因为冒号看起来像 make 的目标分隔符。给 `scripts/build.sh` 传 MSYS 路径。
4. **PATH。** `adb`、`make`、`python3` 都必须在这个 shell 里能找到。Git Bash 本身不带 `make`，装 MSYS2 或把它加进 PATH。

本次实际使用的组合：Git Bash、MSYS2 的 GNU Make 4.4.1、Python 3.13、adb 1.0.41、`arm-none-linux-gnueabihf-gcc` 13.3.1（MinGW 宿主版）。README 里的步骤是以等价的原生命令逐条执行的；`scripts/gen_addr.sh` 另外完整跑通过一次。

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
bitmap: aa aa aa aa 2a aa aa aa      -> 10b = power-on
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

完全一致，包括 `0x424` 那 4 个设备相关字节。只有 `0x8400` 变了，这就是本工具只写一个字节的原因。

---

## 风险

仅用于**自己持有设备**上的安全研究与系统维护。在 Android 运行时切断 eMMC 供电不是受支持的操作。

* 断电之前把 `/data` 挂成只读，或者至少停掉框架。`/data` 是 `errors=panic`，往已断电的 eMMC 写一次就会 panic。
* eMMC 如果没重新枚举，手机要手动断电才能再启动。数据不会丢，但你需要能够碰到机器。
* `stool.sh backup` 之所以存在，是因为"应该不会出事"不叫恢复方案。镜像留在电脑上，不要留在手机里。
* 写 `0x8400` 是最后一步，也是唯一改变 S-ON/S-OFF 的一步：`00` = S-OFF，`03` = S-ON，可以写回去。真正没法原地撤销的是改过的 `hboot`（`noredtext`），回 S-ON 之前先把 dump 的镜像写回去。

不提供任何形式的担保；作者不对数据丢失或保修失效负责。刷坏了自负。

---

## 致谢

本项目相当一部分代码和文字是在 AI 协助下写成的。但每一个地址、每一个偏移、每一条声称已验证的结论，都在真机上核对过：实验、失败分析，以及保留什么、放弃什么的决定，是人做的。

* HTC 公开内核源码，以及 `sdhci_msm` 里那条 `mmc_reinit_card`：eMMC 不用重启就能回来。
* XDA/ARHD 社区关于 RUU/CID/MID 的整理，本项目的判断建立在这些之上。
* Firewater/Sunshine 时代的研究，把 S-OFF flag 到底是什么讲清楚了。

---

## 许可证

Copyright (C) 2026 the S-OFF-My-One-M8 contributors. 两套许可证，按文件来源分：

| 路径 | 许可证 | 原因 |
|---|---|---|
| `kmod/`、`kernel-patches/` | GPL-2.0-only（[`kmod/LICENSE`](kmod/LICENSE)、[`kernel-patches/LICENSE`](kernel-patches/LICENSE)） | 内核模块和内核补丁；3.4 树是 v2-only |
| 其余：`tools/`、`scripts/`、`README*.md` | GPL-3.0-or-later（[`LICENSE`](LICENSE)） | 用户态程序和文字；不链接内核代码，所以许可证是选择而非约束 |

`kmod/` 是 Linux 内核模块：包含 GPL-2.0-only 的内核头文件、逐字抄了 `drivers/regulator/core.c` 里的 `struct regulator`，并且被加载进 GPL-2.0-only 的内核，所以同样是 GPL-2.0-only，这里不能用 GPL-3.0，两个版本无法合并。它声明的是 `MODULE_LICENSE("GPL v2")`，这是内核里 v2-only 的写法；裸写 `"GPL"` 会被记成 v2-or-later。用户态那侧只通过系统调用接触内核，GPL-3.0-or-later 属于自选，不是被迫。

每个源文件开头都有一行 `SPDX-License-Identifier`，逐文件看那一行就够了，上表只是索引。《工作原理》里引的 `_regulator_enable` 那段来自内核，仍是 GPL-2.0。
