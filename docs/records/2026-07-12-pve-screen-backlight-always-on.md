# pve 屏幕常亮排查:setterm powersave 静默失败

**Date:** 2026-07-12
**Host:** pve (192.168.50.4,小新 Pro 14 笔记本,AMD Ryzen 5600H / amdgpu)
**Kernel:** 6.14.8-2-pve

## 问题

pve 内置屏幕一直亮着。而主机上早在 2026-03 就手工配置过
`/etc/systemd/system/setterm-config.service`(`setterm -blank 1 -powersave powerdown`),
内核 `consoleblank=60` 也确实生效——按理 1 分钟就该黑屏断电。

## 根因

**`setterm --powersave` 是对 stdin 的 TIOCLINUX ioctl,而旧 service 没有配 StandardInput。**

setterm 的两个参数走完全不同的通道:

| 参数 | 生效通道 | 旧 service 中的结果 |
|------|----------|--------------------|
| `--blank N` | 写到 tty 的转义序列(stdout) | ✅ 生效(`StandardOutput=tty`) |
| `--powersave powerdown` | stdin 上的 TIOCLINUX ioctl | ❌ 静默失败(stdin 是 /dev/null) |

后果:VESA blank 模式一直是 0(仅像素级 blank)。屏幕 blank 时 fbcon 只画黑屏,
面板 CRTC 保持供电、背光常亮——「黑屏但发光」,持续了三个多月。

### 次要坑:内核对已 blank 屏幕的重复 blank 是 no-op

修好 powersave 模式后直接 `setterm --blank force` 仍无效——vt 层看到
`blank_state == blank_off` 直接 return,新模式不会应用到「当前这次 blank」。
必须先 `--blank poke`(唤醒)再 `--blank force`,让它以 powerdown 模式重新 blank。

## 诊断方法

面板是否真断电,**看 DRM debugfs 的 atomic state,不要信 connector 的 sysfs dpms 属性**
(fbcon blank 路径下该属性可能不更新,也不要信 `/sys/class/backlight/*/bl_power`):

```bash
grep -A2 'crtc\[' /sys/kernel/debug/dri/*/state | grep active=
# active=1 → 面板供电中;active=0 → 真正断电
```

生效链路:`consoleblank` 超时 → vt 层以 `vesa_blank_mode+1 = FB_BLANK_POWERDOWN`
调 fbcon → drm_fb_helper → amdgpu 关闭 CRTC → eDP 面板 + 背光断电。

## 修复

固化为 Ansible playbook:[`proxmox/ansible/playbooks/console-screen-off.yaml`](../../proxmox/ansible/playbooks/console-screen-off.yaml)
(`just console-screen-off`,仅针对 pve-1):

- 重写 `setterm-config.service`:stdin/stdout 都重定向到 `/dev/tty1`
  (`sh -c 'setterm --blank 10 --powersave powerdown < /dev/tty1 > /dev/tty1'`),
  超时改为 10 分钟
- playbook 末尾 poke + force,配置完立即断电,不等 10 分钟
- 验证:`consoleblank=600` + CRTC `active=0`

## 复验(2026-07-12 晚)

主机 21:46 重启后屏幕又被观察到常亮,现场复验结论:**机制健康,不是回归**。

- service 随开机自启,`consoleblank=600` 生效;
- 强制路径:poke + force → CRTC `active=0` ✅
- 定时器路径:临时 `--blank 1`,等 80 秒、全程键盘中断计数(IRQ1)不变,
  自动断电 → `active=0` ✅(测完已恢复 `--blank 10`)
- **屏幕亮着的原因**:任何唤醒事件(键盘/触摸板/电源键/控制台输出)会点亮屏幕
  并重置 10 分钟计时,落在窗口内观察就是「常亮」。唤醒后 powerdown 模式保持
  (全局 `vesa_blank_mode`),会自动再断电,不会退化成「黑而不断电」。
  只有无人碰机器且持续 >10 分钟 `active=1` 才是真异常。

只读诊断入口:`just console-screen-check`(service / consoleblank / CRTC 三项)。

### 顺带发现:repo 里的固化丢过一次

7d4aeae(02:26)写入的完整 playbook(部署 service + 验证)在 21 分钟后被
e0729d4(02:47,本意是替换另一份 vbetool 旧逻辑)整体覆盖成只剩 poke+force,
service 单元一度只存在于主机上——正是下面教训 1 的翻版。当晚已恢复完整固化。

## 经验

1. **手工改的系统配置要当场进 repo**——旧 service 是 3 月手工配的,从未 codify,
   坏了三个月没人知道。
2. systemd oneshot 服务「exit 0」不代表副作用成功;涉及 tty ioctl 的工具要确认
   stdin/stdout 各自指向哪里。
3. 屏幕/背光状态的 sysfs 属性(`dpms`、`bl_power`)在无 X 的 fbcon 场景下不可靠,
   以 debugfs atomic state 为准。
4. 屏幕亮 ≠ 机制坏:先跑只读 check,分清「唤醒窗口内」和「真回归」再动手。
