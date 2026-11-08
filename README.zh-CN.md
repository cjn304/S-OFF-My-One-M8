# S-OFF-My-One-M8

[English](README.md) | **中文**

自从 Sunshine 停止服务后，没有能用的 HTC S-OFF 工具了。

hboot 用 eMMC 的 power-on 写保护锁住固件分区，而这种保护按规范只有掉电才清除。所有用户态的通路都被堵死，所以这里用一个小内核模块在内核态把 PMIC 的电真断一次再上电，最后写 flag 字节。

已在 HTC One M8，hboot 3.19.0.0000 上[测试成功](#实测记录)（其它机型见[移植](#6-移植)）。

---

## 前提条件

* 备份数据并[解锁 BL](http://www.htcdev.com/bootloader/)。然后 root，或刷入自带 root 的固件。像 Sunshine 一样临时 root 可以不用解锁 BL，S-OFF 之后随便解锁。
* 一套交叉工具链 + 能跑 kbuild 的机器：Linux，或 MSYS2/Git Bash（见 [Windows](#windows)）。

---

## 快速开始

下面的命令假设 `adb shell` 本身就是 root：要么是 userdebug / eng 固件，`adb root` 能生效；要么是已 root 的官方固件，每条 `adb shell ...` 改成 `adb shell 'su -c "..."'`。引号顺序不能反：重定向必须写在 su 里面，否则非 root 的 shell 会先执行它，直接 `Permission denied`。每个 `stool.sh` 命令和 `prepare.sh` 都会自己探测 root（Magisk 的 `su`、adb root 或 userdebug 固件）。[期望输出与故障处理](#期望输出与故障处理)。

```sh
# 0. 检查 Security 状态、modules、SELinux
scripts/stool.sh status

# 1. 手机上的配置和地址 → 源码树：m8.config、kmod/addr.h，并把树配好
scripts/prepare.sh /path/to/kernel-tree

# 2. 编译三个内核模块和 mmc_cmd
scripts/build.sh /path/to/kernel-tree
make -C tools CROSS=arm-none-linux-gnueabihf-

# 3. 在 debugfs 下找稳压器目录，先备份，再诊断、断电上电、写 flag、验证
adb shell 'mount -t debugfs none /sys/kernel/debug'
scripts/stool.sh backup
scripts/stool.sh soff

# 4. 写回一个分区镜像
scripts/stool.sh restore pg2fs HT495WM00193-20261104-045201.pg2fs.img
```

---

## stool.sh

`scripts/stool.sh` 是下面全部命令的入口。会写设备的命令（`set`、`lock`、`unlock`、`nowarn`、`splash`）在 dump 和写入之前先查 Security 状态，S-ON 直接拒绝，一个字节都不会写。`status`、`backup` 只读，`restore` 的分区由参数给出，`soff`、`son` 和 `set secure_flag 0` 本来就是改 Security 状态本身，这几条不预先要求 S-OFF；`set secure_flag 0` 仍会先探测写保护，真还有保护就拒绝。

```sh
scripts/stool.sh status                  # Security 状态 + 其他参数（Android 或 fastboot 都行）
scripts/stool.sh soff                    # 完整 S-OFF：诊断、断电上电、写入、验证
scripts/stool.sh son                     # 回到 S-ON
scripts/stool.sh backup [partition]      # 四个整分区 + 参数，或只备一个
scripts/stool.sh restore <partition> <file.img>   # 如 restore pg2fs *.img
scripts/stool.sh set cid <cid>           # 8 字符，11111111 = SuperCID
scripts/stool.sh set mid <mid>           # 9 字符，例如 0P6B12000
scripts/stool.sh set tamper_flag <0|4>   # 0 = Official，4 = Modified
scripts/stool.sh set secure_flag <0|3>   # 0 = S-OFF，3 = S-ON
scripts/stool.sh lock                    # BL magic -> HTCU
scripts/stool.sh unlock                  # BL magic -> 00000000
scripts/stool.sh nowarn                  # 抹掉 hboot 里六行开发警告红字
scripts/stool.sh splash photo.png        # 换开机第一屏，尺寸取自 targets.conf
```

每个参数放在哪、备份哪些分区，都来自 `targets.conf`：一种布局一项，用设备在 `/sys/class/block/*/uevent` 里报的尺寸去匹配。布局对不上的机器会在写入之前被拒绝；要加一项，见[5. 参数偏移](#5-参数偏移)。

没有整份备份是自动做的：`backup` 写出 `backup/<序列号>-<时间戳>.{txt,img}`（四个整分区，外加一份等于 `status` 输出、末尾附还原命令的 txt），`restore <partition> <file.img>` 再把其中一张 img 写回去，`pg1fs` 里的 `0x8400` 也在其中。所以镜像里的状态说了算：还原一份 S-ON 时期拍的 `pg1fs.img`，手机就回到 S-ON。不打招呼就 dump 的只有 `nowarn` 和 `splash`：它们只把自己即将覆盖的那一个分区存下来，那是撤销用的，不是别处的保险。

`set tamper_flag` 接受 0..255 的十进制，标准取值是 `0` 和 `4`。这个 u32（4 字节，只有最低字节非零）就是 hboot `Software status:` 那行的唯一来源：`00` 显示 `*** Software status: Official ***`，其他显示 `*** Software status: Modified ***`。bootloader 侧也能读同一个值：`fastboot oem get_tamper_flag` 返回 `Tamper_Flag: 0x0`，这条命令不在 `getvar all` 里，只在 `oem ?` 的列表里。

`set secure_flag` 就是 `soff` 最后一步的那次写入，单独跑：写 `0x8400`，再回读，不断电也不重启。S-ON 时写 `0` 会先探测 `mmc_cmd wp`：只有真的还有写保护才拒绝；位图全零（[移植](#6-移植) A 档那种旧 hboot）就照写。已 S-OFF 的机器上，还原了一份 S-ON 时期拍的 `pg1fs.img` 之后，也用它把 `00` 写回去。

`lock` / `unlock` 直接写 `pg1fs`（p2）0x8404 的四个字节：`HTCU` = 解锁，`00000000` = 锁定。hboot 开机比对的就是这串 magic，所以设备一旦 S-OFF 就不需要在官网申请的解锁码了；也不走 `fastboot oem lock`：那条只会得到 `RELOCKED`，而 hboot 3.19 根本没有 `oem unlock` 命令（返回 `[ERR] Command error`）。

M8 的 `backup` 写出这些文件：

| 文件 | 内容 | 大小 |
|---|---|---|
| `<serial>-<timestamp>.txt` | `status` 的输出，末尾附上每个镜像的还原命令 | 约 1 KB |
| `<serial>-<timestamp>.pg1fs.img` | p2，secure flag、BL magic 在这里 | 119 MB |
| `<serial>-<timestamp>.board_info.img` | p3，CID、IMEI、板级数据在这里 | 16 KB |
| `<serial>-<timestamp>.mfg.img` | p5，MID 在这里 | 256 KB |
| `<serial>-<timestamp>.pg2fs.img` | p6，tamper flag 在这里 | 24 MB |

文件名以序列号（`ro.serialno`）开头，后接时间戳，两台 M8 的备份放在同一个 `backup/` 里也不会混。`restore` 只比对文件名里的序列号：和当前机器不一致时直接拒绝，一个字节都不写。

txt 里就是 `status` 打到屏幕上的那份内容：`== state ==` 一段（含 `modules` 和 `selinux` 两行）、`== parameters ==` 一段。两处用的是同一个函数（`status_show`），所以文件不会和屏幕上的说法分叉。末尾是 `== restore ==`，每个本次真正落盘的镜像一行，照抄就能写回去：

```text
== restore ==
  stool.sh restore <partition> <file>   (bare filename = look in backup/)
  stool.sh restore pg1fs       HT495WM00193-20261105-215502.pg1fs.img
  stool.sh restore mfg         HT495WM00193-20261105-215502.mfg.img
```

只列 dump 成功的分区，失败的那个不写进来，所以不会出现指向不存在文件的命令。`restore` 只给文件名时到 `backup/` 里找。`set cid` 和其它参数一样，用 `dd` 写 `board_info` 0x14 那 8 个字节；hboot 在开机时读它，所以 `getvar cidnum` 要重启后才变。整块 p3 镜像仍然保留：CID 紧挨着 IMEI 和板级数据，那些本工具不碰。radio（p20）本工具不写入，所以不再 dump。整套约 143 MB，走 USB 大概一分钟。

### CID、MID 和刷机的关系

MID 标明机型变体：`0P6B62000` 是国行联通版，`0P6B12000` 是 Dev Edition；CID 标明运营商或地区（国行联通是 `HTCCN703`）。这两项都写在固件包的 `android-info.txt` 里，hboot 在 RUU 模式下解析 zip 时逐项比对。`set mid` 写 mfg 0x4000，`set cid` 写 board_info 0x14；CID 改成 `11111111`（SuperCID）在多数 hboot 上能放行任意 CID，但不是所有构建都认，而且固件层版本本身可能先把 RUU 挡在门外，见[从 4.18 刷 6.12 的 RUU](#从-418-刷-612-的-ruu)。各固件包的对应见这份[表格](https://docs.google.com/spreadsheets/d/10H7RftecZZKb5tT2zpShfYNFAfSe-imhhqtVfeMPVDA/edit?gid=0#gid=0)。

#### 从 4.18 刷 6.12 的 RUU

港版 4.18.708.12（hboot `3aa067db`）直接跑 6.12.1540.4 的 RUU，界面在点 Start 后立刻报 Error 155，日志里的错误是：

```text
(bootloader) zip info parsing...
FAILED (status read failed (Too many links))
```

这不是 MID 或 CID 不匹配。RUU 日志（`C:\RUU_log\RUU_*.log`）显示它只读了 `boot-mode`、`battery-status`、`version-main`，随后进入 RUU 模式发送 zip，失败点在 hboot 解析 zip 的位置。

原因是 RUU exe 里的 `rom.zip` 是 HTC 的 large-zip 容器，htc_fastboot 发送前会打印 `found large-zip header`。4.18 这块 hboot 只认普通 zip，读到分块结构后直接重置 USB 端点，主机端看到的就是 `Too many links`。

解法是先刷底包（`DevEdition_6.12.1540.4_+StockRecovery+boot.img_0p6bimg.zip`，约 53 MB，含 hboot），把 hboot 换到 `76df2b54`。

`fastboot flash hboot hboot_signedbyaa.img` 会被 hboot 拒绝，报 `FAILED (remote: not allowed)`，FASTBOOT 和 RUU 模式下都一样。hboot 分区只接受 zip 流程，不接受裸写镜像。

刷固件包会写 sbl1 和 tz，中断会砖。刷之前确认电量，刷的过程中不要动线。`backup hboot` 只在 hboot 还能进 bootloader 时有用，完全黑屏时它救不了。

### 警告红字

六行开发警告是 hboot 在启动镜像签名校验失败时画出来的，校验覆盖 `boot` 和 `recovery` 两个分区，任一不符都会画。

在 6.12.1540.4 的 hboot 里，六行共用一个绘制函数（文件偏移 `0x18B64`），全镜像只有一条 `bl` 指令进入它（`0x147EA`）。这条指令位于按分区校验的函数里，而该函数有六个入口：两个把 mode 设为 `9` 或 `0x0F`，读 `boot`；四个设为 `3`，读 `recovery`。任一入口校验失败，都会执行同一条 `bl 0x18B64`。其中两个 recovery 入口在 fastboot 命令处理函数里，调用前刚给主机回过 `OKAY`。

调用点前面紧挨着签名校验（`0x147D4`）：校验返回 0 就直接启动，非 0 才进这个函数画警告、刷屏，然后继续启动。4.18 的 `3aa067db` 是同一结构（函数 `0x18258`，调用点 `0x142AE`，校验 `0x14298`）。

`nowarn` 是按内容找那六行，不是写死偏移。它先把整个 4 MB 的 `hboot` 分区 dump 出来，搜到这六个字符串，把每行首字节改成 `00`，写回，再逐字节读回校验。偏移在不同构建之间是变动的（6.12.1540.4 上是 `0x8C340`，6.31.1402.1 的 dump 上是 `0x8C3F8`，更老的 m8_ul 镜像上是 `0x899CE`），所以必须动态找。

运行前要知道两件事：

- hboot 带 HTC 签名，改一个字节签名就废了。S-OFF 时 SBL 跳过校验，所以还能启动；一旦 `son` 把 secure flag 写回 3，下次启动 SBL 重新验签，失败就停在那里——hboot 不会执行，fastboot、RUU 都进不去，只剩 EDL。改之前必须留下 `nowarn` 打出的 `<serial>-<timestamp>.hboot.img`，并且在 `son` 之前用 `restore hboot <序列号>-<时间戳>.hboot.img` 写回去。`son` 会先检查六行是否还在，发现被清空就直接拒绝。
- 这六行有引用，只是不用 32 位绝对地址：代码先 `ldr rX, [pc, #imm]` 取一个小偏移，再 `add rX, pc` 加上当前 PC，得到字符串地址。所以按 `0x0F58xxxx` 这种绝对地址搜不到，但绘制函数确实存在：6.12.1540.4 上是 `0x18B64`，4.18 的 `3aa067db` 上是 `0x18258`。改字符串仍然是最小改动，因为六行只有这一处绘制，清空内容不影响控制流。

### 第一屏

`splash` 把 PNG 转成 `sp1` 分区真正的格式：小端 RGB565，尺寸取 `targets.conf` 里该机型那一项（M8 上是 1080x1920，4,147,200 字节），分区其余部分是填充。换机型时正确做法是给 `targets.conf` 加一项，把 `screen` 写成它的原生分辨率，之后直接 `splash photo.png` 就会用那个尺寸；`--size=WxH` 只是临时覆盖，不改配置时才用。写之前会先拿帧大小和分区大小比一遍，装不下就直接停。M8 的 `sp1` 是 5,242,880 字节，1080x1920 刚好装下，1440x2560 的 7,372,800 字节会被拒绝，那个尺寸只适合分区更大的机型。

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

下载与固件接近的内核源码，HTC 在 [htcdev.com](https://www.htcdev.com/devcenter/downloads)（Kernel Source Code）发布。例如 `m8ul-3.4.0-perf-ga6393e1.zip`，手机报哪一串就找哪一个。包内有 `kernel570.tar.gz`（`kernel/`）和 `platform.tar.gz`（其余源码树），只有 `kernel/` 有用。

Windows 上要注意 NTFS 大小写不敏感，而这棵树里有只差大小写的文件（`net/netfilter/xt_DSCP.c` 与 `xt_dscp.c`）。要么给目录开大小写敏感（`fsutil file setCaseSensitiveInfo <dir> enable`，需要管理员），要么解包时排除这些路径，它们是 netfilter 驱动，与本项目无关。

### 2. 手机 → 源码树

```sh
scripts/prepare.sh /d/kernel-src/kernel
```

一条命令做六件事，每一步都把结果打出来：

| 步 | 做什么 | 停在这一步说明 |
|---|---|---|
| 1 | `stool.sh backup boot` 取下 boot 分区 | adb 或 root 不通，或者手机在 recovery |
| 2 | 从镜像里挖出编译进内核的 `.config` | 内核没开 `CONFIG_IKCONFIG`，镜像里就没有配置 |
| 3 | 五个符号地址加 `module_layout` crc，写进 `kmod/addr.h` | `kptr_restrict` 不为 0，kallsyms 读出来全是零 |
| 4 | 用配置算出 vermagic 标志位，和手机上的原厂模块逐字比 | 拿到的配置不是这台机内核的 |
| 5 | 覆盖 `kernel/.config`，`oldconfig`，数新符号 | 树离这个构建太远（超过 20 个要 `--force`） |
| 6 | `modules_prepare`，核对 `utsrelease.h` | 工具链，见下一节 |

几处不能想当然的地方：

- 配置不看 `arch/arm/configs/m8_defconfig`：HTC 一棵树出很多变体，设备自己的配置压在 kernel 镜像里（`CONFIG_IKCONFIG=y`，`CONFIG_IKCONFIG_PROC` 关着，所以手机上没有 `/proc/config.gz`）。第 2 步是从 `IKCFG_ST` 标记里把那团 gzip 解出来的。
- 别用 RUU 里的 `boot_signed.img`：它前面多 256 字节签名头，boot header 会从错的偏移读。要的是分区 dump，`backup boot` 给的就是。
- 内核是 zImage 时，压缩体前面还有一段自解压 stub，gzip 不在偏移 0。`extract_config.py` 按魔数找，lz4、lzo、lzma 会明确报出来让你换工具。
- `CONFIG_LOCALVERSION` 从 `uname -r` 推：`3.4.0-perf-gXXXXXXX` 的后半截填进去，同时关掉 `LOCALVERSION_AUTO`，否则打过补丁的树会被追加 `-dirty`。它不是加载条件（下面解释），只是让 `.ko` 里的串和手机一致、便于核对。
- `addr.h` 与源码树无关：它是手机正在跑的那个内核的属性，换哪版树都从手机重读，所以它在这一步，而不是编译前手工做。树已经配好、只想刷新这几个数时，单独跑 `scripts/gen_addr.sh` 就够了——它就是这一步。
- 手机要在正常启动的状态下跑。boot 分区在上次开机之后被刷过的话，取到的配置和正在跑的符号不是同一个内核。

`--force` 只放开第 5 步的阈值。`ADB`、`CROSS`、`MAKE` 三个环境变量分别指定 adb、工具链前缀和 make 程序。MSYS2 上先做完第 3 节那两条 patch 再跑，`oldconfig` 会先编 `fixdep`。

#### 源码和手机内核不是同一次构建

这是常态：HTC 每个固件版本对应一个源码包，`uname -r` 里那截 `gXXXXXXX` 就是源码包的 git 提交。能不能用**不看版本号**，看三件事：

| 必须一致 | 由谁决定 | 不一致的后果 |
|---|---|---|
| vermagic 标志位（`SMP preempt mod_unload modversions ARMv7`） | 树的 `.config` | `insmod` 直接拒 |
| `struct device` / `sdhci_host` / `mmc_host` 的字段偏移 | 树的头文件 + `.config` | 装得进去，解引用错位 |
| 五个地址 + `module_layout` crc | 手机的 `addr.h` | 与树无关，换哪版树都一样 |

第一行脚本已经变成一次编译前的比较：第 4 步从 `.config` 算出那串标志位，和手机上的原厂模块逐字对。对不上就停，不会让你等一次二十分钟的编译再发现 `insmod` 拒。理由是 `same_magic()` 只比这半截：模块带 `__versions` 时，第一个空格之前的 `UTS_RELEASE` 被跳过。

第二行脚本只能给间接信号：第 5 步数出来的 `(NEW)` 个数。0 个说明两边符号表对得上，结构体多半没问题；刷出一大片就是树差得远，超过 20 个要 `--force` 才继续。

第三行每次重读，永远和当前内核一致——`addr.h` 在 `.gitignore` 里，本来就不该跨设备提交。`A_MODULE_LAYOUT_CRC` 读自原厂模块的 `__versions`（`scripts/get_module_layout_crc.py`），那是 genksyms 给 `module_layout` 算的 crc，猜不出来。

第二行的真正验收要编完才能做，见 [3. 编译](#3-编译) 末尾的诊断模块：只有 `name=8941_l20` 才算过。

失败就换树，不要凑合：树差得远时 `oldconfig` 给新符号塞默认值，编出来的结构体可能少字段，这种错 `insmod` 阶段看不出来，要到 `regulator_get` 或写 `ops` 时才崩。诊断模块是断电前最后一次便宜的检查。

`prepare.sh` 第 6 步会顺带核 `UTS_RELEASE` 和 `uname -r` 是否一致。不一致也不影响加载（同上，那半截被跳过），但说明 `CONFIG_LOCALVERSION` 没落进配置。

### 3. 编译

`build.sh` 要读 `kmod/addr.h`（上一节第 3 步写出来的），缺了直接停；它不会去读分区，也不会去读手机。

```sh
scripts/build.sh /path/to/kernel-tree
# Windows/MSYS2 上必须传 MSYS 路径（/d/kernel-src/kernel），不能是 D:/...
# 因为 kbuild 把 M= 当 make 目标传，盘符里的冒号会被当成目标分隔符。
```

编完它自己把三件事查一遍，全过才退出 0：

```
pwrsq_diag: (no undefined symbols), __versions 64 bytes, 1 entry
pwrsq_off: (no undefined symbols), __versions 64 bytes, 1 entry
pwrsq_on: (no undefined symbols), __versions 64 bytes, 1 entry
vermagic: 3.4.0-perf-g708019f SMP preempt mod_unload modversions ARMv7
```

- **未定义符号**：模块一个符号都不导入，列出来的每个都会让内核去要对应的版本 crc，加载时报 `no symbol version for <sym>` 或 `disagrees about version of symbol <sym>`。
- **`__versions`**：必须正好一条 `module_layout`、整段 64 字节（32 位内核的 `struct modversion_info`）。空了照样链接成功，要到手机上才失败——那时先看 `pwrsq_impl.h` 里 `section("__versions"), used` 的属性还在不在。
- **vermagic**：拿 `vermagic=` 那行和 `addr.h` 里记的内核串比，不一致就告警，说明 `.ko` 是另一次构建留下的，或者树还没按手机配好。

这几条用的是 `${CROSS}` 前缀的 binutils（`nm`、`readelf`、`strings`）。Git Bash 和 MSYS2 里没有裸的 `readelf`、`nm`、`strings`，只有 Linux 发行版上才是裸名字；想自己单独看某个模块时记得带上前缀，否则得到的是 `command not found` 而不是“没问题”。

`build.sh` 不管用户态那个小工具；`tools/mmc_cmd` 也没有入库，它是一个静态链接的 ARM 可执行文件：

```sh
make -C tools CROSS=arm-none-linux-gnueabihf-
```

`soff` 会把它放进 `/dev`（tmpfs）并以 root 运行：`adb push` 写不了 `/dev`，所以先落到 `/data/local/tmp`，再由 root 在 eMMC 还在的时候拷过去。没有它，`soff` 会在动手机之前停下：写保护检查是唯一能证明断电生效的依据。

#### 验收：诊断模块

这是唯一能证明结构体偏移对得上的办法：

```sh
adb push kmod/pwrsq_diag.ko //data/local/tmp/
adb shell 'su -c "dmesg -c >/dev/null; insmod /data/local/tmp/pwrsq_diag.ko; sleep 1; dmesg | grep pwrsq"'
adb shell 'su -c "rmmod pwrsq_diag"'
```

看到 `name=8941_l20` 才算过。它一次用上五个地址，以及 `r->rdev`、`rdev->desc->ops`、`consumer_list`、`d->kobj.name`、`drvdata`、`sh->mmc` 这些偏移。被 SELinux 拒的话先 `setenforce 0` 再试一次，只影响这次开机——这也是断电前最后一次便宜的检查。

### 4. 工具链的五个坑

2016 年的内核 + 现代工具链 + MSYS2，会撞到五件事，补丁都在 `kernel-patches/`。`prepare.sh` 的第 5、6 步或者上一节的编译报错时，先来这里对号。

| 现象 | 处理 |
|---|---|
| `scripts/gcc-wrapper.py` 是 Python 2（`print "..."`） | 命令行传 `CC=` 直接绕过这个 wrapper |
| `fatal error: linux/compiler-gcc13.h: No such file` | 把 `compiler-gcc4.h` 复制成 `compiler-gcc13.h` |
| `fixdep: error opening config file:` 和随机解析错误 | MinGW 的 gcc 写出的 `.d` 是 CRLF，让 fixdep 跳过 `\r` |
| fixdep 在 MSYS2 上段错误 | 把它的 `mmap()` 换成 `malloc()+read()` |
| 编 dtc 报 `multiple definition of 'yylloc'` | `HOSTCFLAGS=-fcommon`，`prepare.sh` 已经带上 |

```sh
cd kernel
patch -p1 < ../kernel-patches/0001-fixdep-crlf-and-no-mmap.patch
cp ../kernel-patches/compiler-gcc13.h include/linux/
```

HTC 发的是 tar 包，没有 `.git`，所以用 `patch -p1` 而不是 `git apply`。

wrapper 之所以会介入，是因为顶层 Makefile 写了 `CC = $(srctree)/scripts/gcc-wrapper.py $(REAL_CC)`；命令行传 `CC=<cross>gcc` 就盖掉了。在 Linux 上用老工具链时这些都不需要，fixdep 那个补丁依旧无害。

### 5. 参数偏移

`kmod/addr.h` 管的是内核符号；参数偏移也不由任何脚本生成。它们跟着分区布局走，所以放在 `targets.conf` 里。

选哪一项，是拿它的 `layout` 行去比设备在 `/sys/class/block/*/uevent` 里报的尺寸（`PARTNAME` 加 `size`，单位 512 字节扇区；无需 root）。用尺寸当键是有道理的：改 MID 或 CID 不会挪动任何东西，因为那两项都是分区里的内容；换了固件，装这些记录的分区尺寸就跟着变。一项都对不上时，脚本在动 eMMC 之前停下，把看到的布局原样打出来：

```
error: no section in targets.conf matches this device.
  observed: hboot:8192 sp1:10240 pg1fs:243646 board_info:32 ...
```

把 `observed:` 后面那串（从 `hboot:8192` 开始）填进新 `[name]` 项的 `layout =`，再补偏移；偏移仍然只能人工推导。做法是把小分区 dump 下来，拿设备自己报出来的值去搜：

```sh
for p in board_info mfg pg1fs pg2fs hboot sp1; do
	scripts/stool.sh backup "$p"
done
```

`backup` 只要分区名：名字和长度都读自设备，不需要 `targets.conf` 里有对应的一节——这一节正是还没写出来的东西。镜像落在 `backup/<序列号>-<时间戳>.<分区>.img`，每个都按设备报的长度校验过。脚本在这台机器上跑不起来时，再退回手工：`adb shell 'su -c "dd if=/dev/block/bootdevice/by-name/<分区> of=/sdcard/<分区>.img"'` 加 `adb pull`；`su -c` 按 Magisk 环境写，`adb shell` 本身就是 root 时去掉。

| 字段 | 键 | M8 上的位置 | M8 上的偏移与宽度 | 怎么定位的 |
|---|---|---|---|---|
| CID | `cid` | `board_info` p3 | 0x14，8 字节 ASCII | `fastboot getvar all` 里的 `cidnum` 字符串 |
| MID | `mid` | `mfg` p5 | 0x4000，18 字节 UTF-16LE | `fastboot getvar all` 里的 `modelid` 字符串，每字符 2 字节 |
| tamper flag | `tamper_flag` | `pg2fs` p6 | 0x511804，4 字节 u32 LE | hboot 显示 `Software status: Modified` 时非 0（标准值 4），Official 时是 0 |
| secure flag | `secure_flag` | `pg1fs` p2 | 0x8400，4 字节 u32 LE | S-ON 是 `03 00 00 00`，S-OFF 是 `00 00 00 00`；用 `readsecureflag` 对照 |
| BL magic | `bl_magic` | `pg1fs` p2 | 0x8404，4 字节 ASCII | secure flag 紧跟的四个字节：`HTCU` 解锁、`00000000` 锁定 |
| 警告 | `bl_partition` | `hboot` p26 | 运行期，无固定偏移 | 六段已知横幅字符串，按镜像搜 |
| 第一屏 | `splash` | `sp1` p12 | 0，W×H×2 字节 | 画面从 0 开始 |

`status` 里没有版本行：固件版本（`version-main`）本工具既不读也不写，Android 的系统版本也不显示。

`screen` 是唯一不带偏移的键：它给出 `splash` 默认转换成的分辨率；`bl_partition` 则是 `nowarn` 要改的那个分区（M8 上叫 `hboot`，别的机型可能叫 `aboot`），它的长度也用来校验镜像大小。

换构建时重复这套流程，有两条规矩：

- 搜设备已经告诉你的东西（`cidnum`、`modelid`、hboot 那行状态），不要猜偏移；同一个值回头还能验证你找到的位置。
- 每次写完先 `sync` + `drop_caches` 再回读。写保护还在时，写入“成功”只是更新了页缓存，这也是 `write_hex` 坚持回读而不是相信 `dd` 的原因。

### 6. 移植

参考构建是：

| 项目 | 值 |
|---|---|
| 机型 | HTC One M8，`m8_ul` |
| 出厂 MID / CID | `0P6B62000` / `HTCCN703` |
| 测试过的固件 | 6.31.1402.1，之后是 6.12.1540.4（都是 Android 6.0.1） |
| 内核 | `3.4.0-perf-ga6393e1`（2016-01）/ `3.4.0-perf-g708019f`（2015-11） |
| hboot | `3.19.0.0000` |
| root | Magisk 20.1（`su`）、`modules_disabled=0` |
| 32 GB 测试机 | 4.18.708.12（S-ON），hboot `3aa067db`，Magisk 20.1，eMMC 61071360 扇区 |

MID 和 CID 是出厂值；参考机后来改成 `0P6B12000` / `11111111` 并刷了 Dev 固件，所以上面列了两个构建。

换机型时有两件事必须同时对上，而且它们会各自独立地失败：内核侧（结构体布局、符号地址）和机型侧（供电轨名、设备名、偏移、分区名）。稳压器名字和 MMC 平台设备名是 `kmod/pwrsq_impl.h` 里的编译期参数。

移植按要重做的量分四种情况，A 到 D，未实测。

**A. hboot 版本在 3.19 以前的：** 如 One M7（msm8960）、One S（msm8260A）、Sensation / XE（msm8260）、Desire HD（msm8255）以及 B 档中没怎么更新系统的。可能不设写保护。先在 S-ON 下读一次位图：

```sh
adb shell 'su -c "/dev/mmc_cmd wp"'
```

`mmc_cmd` 是 `make -C tools` 编出来的，`stool.sh` 会把它放进 `/dev`；没走过 `stool.sh` 就自己推一份：

```sh
adb push tools/mmc_cmd //data/local/tmp/
adb shell 'su -c "chmod 755 /data/local/tmp/mmc_cmd; /data/local/tmp/mmc_cmd wp"'
```

位图全零说明 hboot 没设保护。这时不需要模块也不用断电，普通写入就够：按[5. 参数偏移](#5-参数偏移)的办法找出分区、偏移和记录形状，填进 `targets.conf` 的一项，`stool.sh set secure_flag 0` 就是那条写入（它会先探测位图，只有真的还有保护才拒绝）。那里有一点要注意：`03 00 00 00` 后面那 4 字节只有在 bootloader 解锁时才是 `HTCU`，锁着的机器上是 `00000000`，所以这个组合不能当通用锚点；找到候选后用 `readsecureflag` 验证。

**B. 同一世代的：** 如其它 M8 版本（双卡、Sprint、Verizon）、One E8、Butterfly 2、One mini 2，出自同一棵 HTC 3.4 树。机制、结构体、记录布局都成立，需要重新核对的只有板级那几项：

* `TARGET_VREG` 和 `TARGET_MMC_DEV` 仍是 `8941_l20` 和 `msm_sdcc.1`。两个都是板级**数据**，不是驱动名，所以查驱动源码找不到它们：
  * 轨名写在 `arch/arm/boot/dts/msm-pm8x41-rpm-regulator.dtsi` 的 `regulator-name = "8941_l20"` 里（`8941` 是 PM8941，`l20` 是 LDO20），驱动本身是通用的 `qcom,rpm-regulator-smd`。
  * `msm_sdcc.1` 是**平台设备**的名字，来自 `board-8974.c` 的 `OF_DEV_AUXDATA("qcom,sdhci-msm", 0xF9824900, "msm_sdcc.1", NULL)`；`drivers/of/platform.c` 建平台设备时把 `auxdata->name` 当 `bus_id`。驱动自己叫 `sdhci_msm`，靠 `compatible` 匹配，和这个名字无关——沿用它只是为了让 clock、regulator 和老代码还能按名字找到这块控制器。`sdhci-msm` 随后 `devm_regulator_get(dev, "vdd")`，consumer 就记成了 `msm_sdcc.1`，也就是诊断模块打印的那一行。
  * 在目标机上核这两个值，看的是 `/sys/bus/platform/devices/` 和 `/sys/class/regulator/*/name`，不是驱动源码。
* 安全记录结构不变：pg1fs 0x8400 处的 `{u32 flag; char magic[4]}`，S-ON 时前四字节是 `03 00 00 00`；紧跟的四字节是 bootloader 锁状态 magic，只有解锁时才是 `HTCU`。写之前先核对这八个字节。
* 内核侧只有一件事：重跑 `scripts/prepare.sh`，它重写 `addr.h`（五个地址加 crc）并再比一次 `vermagic`。只有树已经配好、又只想刷新地址时，才单独跑 `scripts/gen_addr.sh`——它就是 prepare 的第 3 步。

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

## 期望输出与故障处理

快速开始的每一步，按执行顺序：什么输出说明它成了，以及对应会停在哪。编译那一节的输出贴在[那里](#3-编译)，不在这里重复。

### `stool.sh status`

```
== state ==
target: m8_ul
serial: HT495WM00193
hboot: 3.19.0.0000
Security: ON
BL state: UNLOCKED
Software status: Official
modules: enabled
selinux: Enforcing

== parameters ==
CID         11111111    board_info @ 0x14
MID         0P6B12000   mfg @ 0x4000
BL magic    HTCU        pg1fs @ 0x8404
secure flag 3           pg1fs @ 0x8400
tamper flag 0           pg2fs @ 0x511804
```

`target` 是 `targets.conf` 里命中的那一项（节名就是 `fastboot getvar product` 的输出，这台是 `m8_ul`），也是第一个要看的东西：出现 `unknown - no targets.conf section matches` 就说明表里没有这个布局，它下面那行 `observed:` 贴进新增的一项即可（见[5. 参数偏移](#5-参数偏移)）。下面 `hboot:` 那行是设备实际报告的 bootloader 构建号。`soff` 要的是 `Security: ON`，已经是 S-OFF 时会打印 `already S-OFF` 直接返回；出现 `Security: unknown (no root ...)` 说明 `su` 还不通，后面每一步也一样跑不动。`Software status` 与 bootloader 界面上那行同源，由 `tamper_flag` 那个 u32 决定：`0` 是 `Official`，其它任何值都是 `Modified`。`modules: enabled` 是 `modules_disabled=0` 的另一种说法，内核要能加载模块，`disabled` 时 `insmod` 会被拒：比如 M8 的 LineageOS 17.1。`selinux: Enforcing` 不致命：`soff` 只告警、照样往下走，模块能不能加载取决于 `su` 落到的域；如果被拒，这次开机先 `setenforce 0` 再重来。

### `prepare.sh`

六步里失败会停在哪，「2. 手机 → 源码树」那张表已经列过；这里只看输出形状：

```
== 1/6 boot image ==
  boot          16777216 bytes
/.../backup/<序列号>-<时间戳>.boot.img

== 2/6 config ==
/.../m8.config  1362 symbols, localversion "-perf-g708019f"

== 3/6 addr.h ==
crc 0x7d779921UL

== 4/6 vermagic ==
  config : SMP preempt mod_unload modversions ARMv7
  module : SMP preempt mod_unload modversions ARMv7

== 5/6 configure the tree ==

== 6/6 modules_prepare ==

== summary ==
kernel      3.4.0-perf-g708019f
tree        /d/kernel-src/kernel
config      /.../m8.config
addr.h      /.../kmod/addr.h
```

- 第 2 步的符号数来自手机内核自己的配置，不是树的；`localversion` 那串是从 `uname -r` 推出来的。
- 第 3 步只打印 crc，它和五个地址一样随构建变，别照抄。要看文件本身 `cat kmod/addr.h`：五个地址都不能是 0，`Kernel:` 那行必须是手机**当前**跑的内核（`adb shell cat /proc/version`）。
- 第 4 步两行必须逐字一致；不一致说明这份配置不是这台机内核的，脚本会停下。
- 第 5、6 步没有输出就是没事。出现 `symbol '...' unavailable` 说明 `kptr_restrict` 没归零——脚本会先自己试两种写法（直接写、`su -c`），都不行才由 `gen_addr.sh` 报错。

### `backup`

```
  pg1fs        124746752 bytes
  board_info       16384 bytes
  mfg             262144 bytes
  pg2fs         24837120 bytes
/path/to/repo/backup/HT495WM00193-20261104-031826.txt
```

每个分区一行打到 stderr，最后一行是 txt 的路径（stdout）。txt 在四个镜像都 dump 完之后才写：第一行是 `# <时间戳>`（和文件名里那串一致），空一行，然后就是 `status` 的输出，末尾一段 `== restore ==`，只列成功的那几个分区。整套约 143 MB，走 USB 大概一分钟。某个分区读不出来会打 `warning: could not dump <分区>` 然后继续；镜像长度不对会打 `<分区>: expected N bytes, got M`。

写出分区名就只备份那一个，不写 txt：

```sh
scripts/stool.sh backup hboot
  hboot         4194304 bytes
/path/to/repo/backup/HT495WM00193-20261104-072924.hboot.img
```

这台手机上的固件分区都能这样 dump，不限于那四个。`system`、`cache`、`userdata` 除外：它们是 Android 的文件系统，不是本工具管的固件，`backup system` 会直接拒绝。它不需要 S-OFF（读分区从来不需要），也不需要 `targets.conf` 里有对应的一节：名字和长度都来自设备，所以本工具不认识偏移的机器照样能备份。`nowarn` 和 `splash` 在覆盖自己要改的那个分区之前，调用的就是它。

### `soff`

`== state before ==` 先打印 `status` 开头那四行（`target`、`Security`、`BL state`、`Software status`）。之后各阶段按实际顺序排列，每一段都跟着会让它停下的故障。

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

`/data` 是 `errors=panic` 挂载的：往已断电的 eMMC 写入会报 I/O error 并中止 ext4 日志，最坏触发 panic。真 panic 了手机会自己重启，写保护重新挂上，flag 没动，只损失时间。这台 32 GB 机器上实测断电 25 秒没有 panic，只是 `JBD2: Detected IO errors` 和日志中止，重启后自行恢复。想把 `/data` 也摘出去，先挂成只读：

```sh
adb shell 'su -c "mount -o remount,ro /data"'
```

有些 ROM 把 `/su` 挂在 loop 上，这条会以 `Device or resource busy` 失败，那就靠上面的 `stop` + `sync`。

#### 断电上电

`== power cycle ==`：先 `OFF_DONE`，电源轨保持关断 8 秒（`PWRSQ_OFF_SEC` 可改），再 `ON_DONE`。参考构建上重扫本身的日志是 `dmesg | grep mmc_reinit_card`；32 GB 机器没有这行，只有 `runtime_error -110`，见下。

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

* `card status 0x400d00`（第 22 位，`WP_ERASE_SKIP`）：保护还在，说明断电实际上没发生。`dmesg` 里必须有 `pwrsq: ops->disable ret=0`。按快速开始挂载过 debugfs 的话，`/sys/kernel/debug/regulator/8941_l20/` 下有 `enable`，eMMC 消失期间它应当是 0；没挂 debugfs 时这个路径不存在，只能靠 `ops->disable ret=0` 和断电后的 I/O 错误判断。模块日志里的 `Failed to create debugfs directory` 是因为 regulator core 已经建过同名目录，无害。
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
  mfg  262144 bytes  HT495WM00193-20261104-045201.mfg.img
  writing 262144 bytes to mfg
  64+0 records out
  262144 bytes transferred in 0.009 secs
  md5 e8301cf5c9c5873972846d54c7cd7040  ok
```

一个分区、一个文件，分区名总是要写：

```sh
scripts/stool.sh restore mfg HT495WM00193-20261104-045201.mfg.img
```

这台手机上的固件分区都能写，不限于本工具写的那六个。`system`、`cache`、`userdata` 同样除外，`restore system ...` 会在读文件之前就拒绝。文件名以序列号开头时，序列号必须和当前机器一致，否则拒绝，一个字节都不写（旧备份没有序列号前缀，只提示一行，不阻塞）。剩下的检查是长度：镜像就是一个完整分区，所以必须正好等于那个分区的长度，长度表来自设备（`/sys/class/block/*/uevent`，也就是选 `targets.conf` 那一节时用的同一份探测）。长度对不上、分区名不存在、或者那不是这台手机 eMMC 上的分区，都在写入前停下。写完回读分区算 md5，与镜像比对。

和备份一样，`restore` 也不需要 `targets.conf` 里有对应的一节：名字和长度都来自设备，所以本工具不认识偏移的机器照样能还原。

判断是否成功靠的是回读，不是写入。S-ON 的机器上，bootloader 在 eMMC 这一级保护了部分分区；写这些分区会被拒绝，而 `dd` 照样报成功，抓住它的是 md5 比对。`dmesg` 里对应的记录是 `card status 0x400d00`。S-OFF 让这层保护不再被挂上，但命令本身已经不再强制要求它。

别的一概不动：还原 `pg1fs` 不碰 `hboot`，反之亦然。`hboot` 和 `sp1` 也走同一条命令，所以 `nowarn` 和 `splash` 各自那个 `--restore` 已经去掉。

### 不要做

* **不要 `fastboot flash` 固件分区。** S-ON 时 hboot 会逐个核对它们的签名，签不上就拒绝写入，这道检查同时也挡住了坏镜像和别的机型的镜像。S-OFF 之后它不再核对，`fastboot flash pg1fs ...` 会把你给的文件整块写进去，写坏了没有下一道关。
* **`pg1fs` 里除了 `0x8400` 什么都不要写。** `0x400` 的头部描述三条记录（`security`、`simlock`、`simunlock`），`0x424`/`0x824`/`0xc24` 那 4 字节是设备相关的，这里刻意没动。
* **不要在 `/data` 正在写的时候做断电上电。** panic 还能恢复，写坏一半的 ext4 日志不一定。

### 整机不启动

进 bootloader（音量下 + 电源）。如果 hboot 能起来，`fastboot getvar all`：还是 S-ON 说明什么都没改，正常刷 ROM 即可恢复；S-OFF 但系统坏了，刷对应 RUU 就行。如果 hboot 都起不来，问题不在 `pg1fs`：S-OFF 流程从不碰 `hboot`、`sbl1`、`tz`。会改 `hboot` 内容的只有 `nowarn`，它写之前先留一份 dump；`restore hboot` 也能写，但那是把你自己的镜像原样写回。

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

本次实际使用的组合：Git Bash、MSYS2 的 GNU Make 4.4.1、Python 3.13、adb 1.0.41、`arm-none-linux-gnueabihf-gcc` 13.3.1（MinGW 宿主版）。`scripts/prepare.sh` 在这台机上从头到尾跑通过一次（六步全过），`kmod/addr.h` 和 `kernel/.config` 都是它写出来的。

---

## 工作原理

### 1. 那堵墙

S-OFF 状态是 `pg1fs` 0x8400 处的一个小端 u32，占 4 字节：

| 偏移 | 含义 | S-ON | S-OFF |
|---|---|---|---|
| `0x8400` | secure flag（u32 LE） | `03 00 00 00` | `00 00 00 00` |

`fastboot oem readsecureflag` 读的就是这个值，`getvar all` 里的 `version-misc: PVT SHIP S-ON/S-OFF` 和 `security: on/off` 也都是从它推出来的。

`0x8404` 那 4 个字节是另一个字段：bootloader 的锁状态，`HTCU` 解锁、`00000000` 锁定。它不跟 Security 状态走，S-ON 的机器可以是解锁的；`lock` / `unlock` 也只动这 4 个字节。

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

保护不是按分区挂的，而是按**写保护组**，一组多大由 eMMC 自己定。`mmc_cmd extcsd` 把决定这件事的几个 EXT_CSD 字段读出来：

```
  [221] HC_WP_GRP_SIZE     = 16
  [224] HC_ERASE_GRP_SIZE  = 1
  erase group  0.5 MiB
  wp group     8.0 MiB
  32 groups    256 MiB of 14910 MiB (1.7%)
```

每组 8 MiB，CMD31 只报 32 组，所以这张位图最多只能描述前 256 MiB。但在一台 S-ON 的 M8 上实测，位图**并不是** eMMC 遵守的东西：它说 32 组里有 31 组受保护，可写 120 MiB 处那一个字节能落盘，写 315 MiB 处却回 `card status 0x400d00`、根本没到 eMMC 上。`WP_GRP_ENABLE = 0` 从另一侧说的是同一件事：组机制是关的，hboot 保护的是区间，`mmc_cmd wp` 只能当「有没有保护」的总开关用。

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

它打出来的日志在[诊断](#诊断)里；这里真正要看的是 `ops->disable ret=0` 和 `ops->enable ret=0` 这两行：它们说明驱动 ops 真的被执行了，而不是被 core 短路掉。末尾那对 `mmc_reinit_card` 是 HTC 自己在 `sdhci_msm` 里的重新初始化路径：参考构建上 eMMC 就是这样回来的，分区都在，手机没重启。32 GB 机器断电 8 秒时不走这条路，host 先报 `runtime_error -110`，节点要一两分钟才回来，见[断电上电](#断电上电)。

### 4. 写这个 flag

```sh
dd if=/dev/zero of=/dev/block/bootdevice/by-name/pg1fs bs=1 seek=33792 count=1
```

`33792` 就是 `0x8400`。字段是 4 字节，但值只有 `0` 和 `3`，高三个字节恒为 0，所以从 S-ON 改 S-OFF 时只有最低字节从 `03` 变 `00`；上面这条 `dd` 就是只写这 1 个字节。工具走的是写满 4 字节（`set secure_flag 0` 的输出里是 `4+0 records`），高字节里万一有残留也会一并清掉。`0x8404` 那 4 个字节是 bootloader 的锁状态，不属于 flag（`HTCU` 解锁、`00000000` 锁定），只写 0x8400 时它原样不动。回读和之后为什么要 `drop_caches`，见[写 flag](#写-flag)。

`pg1fs + 0x424` 还有 4 个字节，老版 Firewater/Sunshine 的配方会一起写。**这台机器上不需要**：S-OFF 成功后，分区头部（0..0x1000，含 `0x424`）与改动前的备份逐字节一致，手机正常启动。不要动它。

要读写别的偏移，不经过 `set` 的话：

```sh
# 读 4 字节，0x8400 = 33792
adb shell 'dd if=/dev/block/bootdevice/by-name/pg1fs bs=1 skip=33792 count=4 2>/dev/null' | od -An -tx1

# 写 4 字节
printf '\0\0\0\0' > /tmp/x.bin
adb push /tmp/x.bin //data/local/tmp/x.bin
adb shell 'dd if=/data/local/tmp/x.bin of=/dev/block/bootdevice/by-name/pg1fs bs=1 seek=33792 count=4; sync'
```

大块按 4 KB 对齐，`bs=4096 skip=8 count=1` 就是偏移 32768 处的 4 KB。toybox 的 `dd` 禁用了 `conv=notrunc`，会报 `conv option disabled`，对块设备省略它就行，不会截断分区。写完先 `sync`，再 `echo 3 > /proc/sys/vm/drop_caches`，然后回读，否则读到的是页缓存。脚本里做这件事的是 `hex_at` 和 `write_hex`。

### 5. 为什么之后一直有效

重启后 hboot 读到 `secure_flag = 0`，走它的 S-OFF 分支，其中就包括**不再设置 power-on 写保护**。所以 S-OFF 设备上第二次 `CMD31` 返回全 0，`pg1fs` 从那时起一直可写。写保护不是被"攻破"的，是**不再被设置**了。

### 6. 模块为什么能加载

内核是 `CONFIG_MODVERSIONS=y` 编的，而我们没有它的 `Module.symvers`。两个后果，都已处理：

* 每个被导入的符号都需要匹配的 crc，所以模块**一个符号都不导入**：所有函数地址在编译时从 `/proc/kallsyms` 生成（`kmod/addr.h`）；
* `module_layout` 是无条件检查的，所以模块自带一条 `__versions` 记录，crc 从设备上原厂 `.ko` 里抄出来。

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

$ /dev/mmc_cmd wp
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
$ /dev/mmc_cmd wp
bitmap: 00 00 00 00 00 00 00 00
  -> no write protection at all

00008400  00 00 00 00 48 54 43 55

$ fastboot oem readsecureflag
(bootloader) secure_flag: 0
(bootloader) version-misc: PVT SHIP S-OFF
(bootloader) security: off
```

再冷启动两次，`readsecureflag` 和 `/dev/mmc_cmd wp` 依旧全是 0。

**分区其余部分的完整性。** `pg1fs[0x0000..0x1000]` 改动前后的 `md5`：

```
f22ff5ac41ac26e1a3ecd2997ba6ca3a   改动前（备份）
f22ff5ac41ac26e1a3ecd2997ba6ca3a   改动后
```

完全一致，包括 `0x424` 那 4 个设备相关字节。只有 `0x8400` 那 4 字节变了，其中实际变化的只有最低字节（`03` → `00`）。

**2026-11-08 复验（另一台 `m8_ul`，内核 `3.4.0-perf-g708019f`）。** 按 `prepare.sh` 重新配好的树编出来的诊断模块，加载输出：

```
pwrsq: init stage=3
pwrsq: rdev=f0326c00 name=8941_l20 use_count=84
pwrsq: consumer 'msm_sdcc.1'
pwrsq: mmc_host=f0032000
pwrsq: done
```

`name=8941_l20` 就是通过条件：五个地址，以及 `r->rdev`、`rdev->desc->ops`、`consumer_list`、`d->kobj.name`、`drvdata`、`sh->mmc` 这些偏移都对上了。`use_count=84` 只是当时 `msm_sdcc.1` 的引用计数，每次开机不同。加载后 `rmmod` 卸载，`/data/local/tmp` 里的模块文件也删了。

---

## 风险

仅用于**自己持有设备**上的安全研究与系统维护。在 Android 运行时切断 eMMC 供电不是受支持的操作。

* 断电之前把 `/data` 挂成只读，或者至少停掉框架。`/data` 是 `errors=panic`，往已断电的 eMMC 写入会报 I/O error，最坏触发 panic。
* eMMC 如果没重新枚举，手机要手动断电才能再启动。数据不会丢，但你需要能够碰到机器。
* `stool.sh backup` 之所以存在，是因为"应该不会出事"不叫恢复方案。镜像留在电脑上，不要留在手机里。
* 写 `0x8400` 是最后一步，也是唯一改变 S-ON/S-OFF 的一步：`00` = S-OFF，`03` = S-ON，可以写回去。真正没法原地撤销的是改过的 `hboot`（`nowarn`），回 S-ON 之前先把 dump 的镜像写回去。

不提供任何形式的担保；作者不对数据丢失或保修失效负责。刷坏了自负。

---

## 致谢

本项目相当一部分代码和文字是在 AI 协助下写成的。但每一个地址、每一个偏移、每一条声称已验证的结论，都在真机上核对过；没有条件实测的，文中明确标了「未实测」。实验、失败分析，以及保留什么、放弃什么的决定，是人做的。

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
