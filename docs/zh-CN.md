# 中文说明

## 这是什么

HTC One (M8) 在 **hboot 3.19.0.0000** 上的真 S-OFF 工具。2015 年以来社区一直认为
这个 hboot 没有 S-OFF 通路，原因是 hboot 每次开机都给固件分区加上 **eMMC 的
power-on 写保护**，而这种保护按规范只有在**掉电**时才清除。

本工具用一个自编译内核模块，在**内核态**把 PMIC 的 eMMC 供电（PM8941 LDO20）
真的断掉再上电，然后触发 MMC 重新枚举，最后写 `pg1fs` 里那一个字节。

```
之前                              之后
secure_flag: 3                    secure_flag: 0
PVT SHIP S-ON                     PVT SHIP S-OFF
security: on                      security: off
CMD31: aaaaaaaa2aaaaaaa           CMD31: 0000000000000000   ← hboot 不再设写保护
```

## 已验证环境

| 项目 | 值 |
|---|---|
| 机型 | HTC One (M8) `m8_ul` |
| MID / CID | `0P6B62000` / `HTCCN703` |
| 系统 | 6.31.1402.1，Android 6.0.1（MMB29M） |
| 内核 | `3.4.0-perf-ga6393e1`（HTC 官方 2016-01 构建） |
| hboot | `3.19.0.0000` |
| 权限 | adbd 以 root 运行、SELinux Permissive、`modules_disabled=0` |

## 前提条件

1. **已 root**：`adb shell id` 显示 `uid=0`，且能 `insmod`。
2. **对应版本的内核源码**：htcdev.com 上的 `m8ul-3.4.0-perf-ga6393e1.zip`。
3. 能跑 kbuild 的机器 + ARM 交叉工具链（Windows 用 MSYS2，见 `docs/build.md`）。
4. **先备份**。这台机器会短暂失去 eMMC 供电，虽然不会动 hboot，但备份是唯一的保险。

## 步骤

```sh
# 0. 备份 pg1fs / board_info / mfg / radio / misc
scripts/backup.sh

# 1. 从手机读符号地址和 module_layout 的 crc
scripts/gen_addr.sh

# 2. 编译三个模块
scripts/build.sh /path/to/kernel-tree

# 3. 先跑诊断版本，确认能找到稳压器和 mmc_host（无副作用）
adb push kmod/pwrsq_diag.ko /dev/
adb shell 'insmod /dev/pwrsq_diag.ko; dmesg | grep pwrsq'
#   期望：rdev=... name=8941_l20 / consumer 'msm_sdcc.1' / mmc_host=...

# 4. 停框架、sync，然后断电上电
adb shell 'stop; sleep 8; sync'
scripts/powercycle.sh

# 5. 确认写保护已消失（必须全 0）
adb push tools/mmc_cmd /dev/ && adb shell chmod 755 /dev/mmc_cmd
adb shell '/dev/mmc_cmd wp'

# 6. 写 flag
scripts/write_flag.sh 0
#   before: 03 00 00 00 48 54 43 55
#   after : 00 00 00 00 48 54 43 55

# 7. 验证
adb reboot bootloader
fastboot oem readsecureflag        # 应为 0
fastboot getvar all | grep -i security   # security: off
```

重启回系统后再跑一次 `/dev/mmc_cmd wp`，如果仍然是全 0，说明 **hboot 在 S-OFF
状态下不再设置写保护**——这才是真正持久的 S-OFF。

## 原理（一句话版）

hboot 用 power-on 写保护锁住固件分区；这种保护只能靠掉电解除。而内核里
`regulator_enable()` 因为 `is_enabled()` 报告“已开启”直接短路，`sdhci_msm` 又把
这路电标记为 `qcom,vdd-always-on`，所以用户态无论怎么写都补不回电。模块绕过
regulator core 的记账逻辑，直接调用 `desc->ops->disable()/enable()`，再用
`mmc_detect_change()` 让 MMC 核心重新识别卡。

细节见 [how-it-works.md](how-it-works.md)。

## 风险

* 断电期间 `/data` 是 `errors=panic` 挂载的，只要还有写入就会 panic 重启
  （重启后 flag 未变，重来即可）。
* 卡如果没有重新枚举，需要手动长按电源重启，不会变砖。
* `pg1fs` 除 `0x8400` 外的任何字节都不要动。`0x424` 那 4 字节在老版 firewater
  配方里会写，**本工具验证过不需要**：S-OFF 成功后整段头部与备份逐字节一致。
* 没有任何担保。刷坏了自负。

## 常见问题

**模块加载报 `no symbol version for module_layout`**
`addr.h` 里的 `A_MODULE_LAYOUT_CRC` 不对，或者 `__versions` 段是空的。用
`scripts/get_module_layout_crc.py` 从手机上的原厂 `.ko` 重新取。

**报 `version magic ... should be ...`**
内核树不是这台机器的构建，`UTS_RELEASE` 必须正好是 `3.4.0-perf-ga6393e1`。

**`insmod` 报 `Invalid argument` / 无法加载模块**
检查 `CONFIG_MODULE_SIG_FORCE`（若开启则必须签名）、`modules_disabled` 是否为 1。

**写完读回还是 03**
写保护没解除。先看 `/dev/mmc_cmd wp` 是否有非零组；再看 `dmesg` 里有没有
`card status 0x400d00`（bit22 = WP_ERASE_SKIP）。

**想恢复 S-ON**
`scripts/write_flag.sh 3`，重启后写保护会自动回来。
