# SSH 登录自动关机（Ubuntu）

给 Ubuntu 服务器装一个 PAM 钩子：**只要有人通过 SSH 成功登录，服务器就在 N 分钟后自动关机**（默认 1 分钟，可设为立即）。整个过程不需要常驻进程，**重启后钩子自动恢复**，开机即生效。

适合自用实验机、蜜罐/反入侵、防止远程登录后忘记关机等场景；**不适合生产环境长期使用**。

> 默认延迟 1 分钟，是为了让你在被触发的那次登录里还有机会执行 `sudo shutdown -c` 取消。

## ⚠️ 安装前必读

- 安装完成后，**任何** SSH 登录都会触发关机，包括 `scp`、`sftp`、`rsync`、Ansible、VS Code Remote SSH、面板自带的终端等。
- **云服务器会直接停机**，必须到云厂商控制台重新开机。请先确认你能用 VNC / 控制台（不是 SSH）登录服务器。
- 本地显示器 / 云控制台的登录**不经过** `/etc/pam.d/sshd`，不会触发关机，这是你的"后门"。
- 关机会中断正在运行的服务和未保存的数据。
- 安装这一步本身建议在控制台里做；用 SSH 安装也可以，但装完后你下一次 SSH 登录就会触发关机。
- 本脚本只适合装在你自己的服务器上。

## 文件说明

| 文件 | 说明 |
| --- | --- |
| `ssh-autoshutdown.sh` | 单文件安装器（内置 PAM 动作脚本），支持 install / status / off / on / uninstall |

安装后会在系统里生成：

| 路径 | 用途 |
| --- | --- |
| `/usr/local/sbin/ssh-login-shutdown.sh` | PAM 触发的动作脚本（root 0755） |
| `/etc/ssh-login-shutdown.conf` | 配置：延迟、白名单、测试模式 |
| `/etc/ssh-login-shutdown.off` | 临时停用开关（存在即不关机） |
| `/var/log/ssh-login-shutdown.log` | 触发记录 |
| `/etc/systemd/system/ssh-login-shutdown-boot.service` | 开机自检/自愈服务 |

## 安装

### 1. 上传脚本

```bash
scp ssh-autoshutdown.sh root@你的服务器IP:/root/
```

这一步还没装钩子，不会触发关机。

> 如果脚本是在 Windows 上编辑后上传的，可能带 CRLF 换行，先转成 LF：
> `sed -i 's/\r$//' /root/ssh-autoshutdown.sh`（从本仓库 `git clone` 下来的文件已通过 `.gitattributes` 保证 LF）。

### 2. 在服务器上安装

```bash
sudo bash /root/ssh-autoshutdown.sh install
```

默认参数：延迟 1 分钟、无白名单、真实关机。

常用变体：

```bash
# 立即关机（不等 1 分钟）
sudo bash /root/ssh-autoshutdown.sh install --delay 0

# 延迟 5 分钟
sudo bash /root/ssh-autoshutdown.sh install --delay 5

# 白名单：ubuntu、root 登录不触发，其他人登录才关机
sudo bash /root/ssh-autoshutdown.sh install --allow "ubuntu root"

# 先只记录日志、不关机（推荐先这样验证）
sudo bash /root/ssh-autoshutdown.sh install --dry-run
```

## 验证（强烈建议先做）

用 `--dry-run` 安装，或把配置里的 `DRY_RUN` 改为 1：

```bash
sudo sed -i 's/^DRY_RUN=.*/DRY_RUN=1/' /etc/ssh-login-shutdown.conf
```

然后从另一台机器 SSH 登录服务器（这次不会关机），查看日志：

```bash
tail -n 5 /var/log/ssh-login-shutdown.log
```

看到类似下面这行，说明钩子已经生效：

```
2026-10-29 14:03:39 user=ubuntu rhost=192.168.1.9 tty=pts/0 dry-run=would-shutdown
```

确认后改回真实关机：

```bash
sudo sed -i 's/^DRY_RUN=.*/DRY_RUN=0/' /etc/ssh-login-shutdown.conf
```

下一次 SSH 登录就会真正关机（默认 1 分钟后，可 `sudo shutdown -c` 取消）。

## 查看状态

```bash
sudo bash /root/ssh-autoshutdown.sh status
```

会显示：PAM 钩子是否启用、动作脚本、配置内容、开机服务状态、临时停用开关、最近 5 条日志。

## 临时停用 / 恢复

```bash
sudo bash /root/ssh-autoshutdown.sh off   # 停用：SSH 登录不再关机
sudo bash /root/ssh-autoshutdown.sh on    # 恢复
```

等价于：

```bash
sudo touch /etc/ssh-login-shutdown.off     # 停用
sudo rm -f /etc/ssh-login-shutdown.off     # 恢复
```

如果被关在 SSH 外面，从云控制台 / 本地终端执行上面的命令即可。

## 卸载

```bash
sudo bash /root/ssh-autoshutdown.sh uninstall
```

会删除 PAM 钩子（原文件备份为 `/etc/pam.d/sshd.bak.*`）、开机服务、动作脚本和配置；日志保留。

## 原理

1. 在 `/etc/pam.d/sshd` 末尾追加一行：

   ```
   session optional pam_exec.so quiet /usr/local/sbin/ssh-login-shutdown.sh
   ```

2. 每次 SSH 会话建立（PAM `open_session`）时，PAM 以 root 执行动作脚本。脚本会：
   - 检查 `/etc/ssh-login-shutdown.off` 是否存在（临时停用）；
   - 检查 `ALLOW_USERS` 白名单；
   - 检查 `DRY_RUN` 测试模式；
   - 记录 `user / rhost / tty / 时间`；
   - 调用 `shutdown -h +N`（或立即 `shutdown -h now`）。

3. `/etc/systemd/system/ssh-login-shutdown-boot.service` 是一个 oneshot 服务，开机时执行
   `ssh-autoshutdown.sh boot`，确保 PAM 钩子仍然存在（例如被系统升级覆盖后自动补回）。
   PAM 配置本身是持久化的，所以即使没有这个服务，重启后钩子也会生效；该服务只是自愈保险。

4. 关于用户名：`pam_exec` 默认只导出 `PAM_RHOST / PAM_RUSER / PAM_SERVICE / PAM_TTY / PAM_TYPE`，
   不一定有 `PAM_USER`。脚本会依次尝试 `PAM_USER` → `PAM_RUSER` → `/proc/self/loginuid`
   反查用户名，所以白名单能正常匹配。

## 配置项

编辑 `/etc/ssh-login-shutdown.conf`（改完立即生效，下一次 SSH 登录即按新配置）：

| 变量 | 说明 |
| --- | --- |
| `GRACE_MIN` | 关机延迟（分钟），`0` = 立即关机 |
| `ALLOW_USERS` | 白名单用户，空格分隔；留空 = 任何 SSH 登录都触发 |
| `DRY_RUN` | `1` = 只写日志不关机（测试用） |

也可以直接编辑 `/usr/local/sbin/ssh-login-shutdown.sh` 顶部的默认值，但配置文件的优先级更高。

## 常见问题

**装完 SSH 连不上了？**
服务器已经关机了。到云控制台（VNC）开机，然后执行 `sudo bash /root/ssh-autoshutdown.sh off` 或 `uninstall`。

**本地显示器登录会关机吗？**
不会。钩子只写在 `/etc/pam.d/sshd`，只对 SSH 会话生效。

**scp / sftp / 自动化工具会触发吗？**
会。它们同样是 SSH 会话。

**容器里能用吗？**
需要 PAM 和 systemd，且容器里通常没有 `/sbin/shutdown` 权限，不建议使用。

**改坏 PAM 会不会登录不了？**
脚本在 PAM 行里使用的是 `optional`，即使动作脚本执行失败也不会阻止登录；卸载时会还原并保留 `/etc/pam.d/sshd.bak.*` 备份。

**怎么确认钩子还在？**
`sudo bash /root/ssh-autoshutdown.sh status`，或 `grep ssh-login-shutdown /etc/pam.d/sshd`。
