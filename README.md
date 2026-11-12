# WSL 中文与剪贴板一键安装

WSL 中文的粘贴、复制、文件及截图，与windows 主机的互操作。

在目标主机的 Debian / Ubuntu WSLg 普通用户终端中执行。

```bash
curl -fL --retry 3 https://raw.githubusercontent.com/9848987/WSL/main/install.sh -o /tmp/wsl-ai-install.sh && bash /tmp/wsl-ai-install.sh
```

安装时按终端提示输入该 Linux 用户的 sudo 密码。此前手动运行了 `xclip --watch` 时，先在对应终端按 Ctrl+C 结束该进程，再运行安装命令。

`install.sh` 是自包含脚本，已内嵌完整剪贴板桥接源码，下载单个文件即可运行。默认安装会更新 APT 软件索引并执行 `apt-get upgrade -y`。

## 安装内容

| 内容 | 设置结果 |
|---|---|
| 中文字体和语言 | 安装 Noto CJK、文泉驿字体，生成 zh_CN.UTF-8，设置系统默认 LANG |
| Fcitx5 | 安装中文输入法和 GTK3 / Qt5 模块，新用户配置默认拼音，配置用户级后台服务 |
| 纯文本剪贴板 | UTF-8 传输，CRLF / CR 换行转换为 LF |
| Windows 截图 | 常驻桥接读取 Bitmap，转换 PNG，向同一 DISPLAY 的 X11 剪贴板发布 |
| 文件及文件夹 | 复制实体至 Linux /tmp/chatgpt-clipboard.随机串/序号/原名称，再向输入框发布副本路径 |
| 自动启动 | 配置 xclip-bridge.service 和 wsl-fcitx5.service，随该 WSL 用户服务管理器启动 |

脚本适用于 amd64、Debian / Ubuntu、WSLg X11 环境，DISPLAY 形如 `:0`。

首次运行若 PID 1 尚非 systemd，脚本会合并 `/etc/wsl.conf` 的 systemd 与互操作设置，保留其他键，然后以状态码 2 结束。保存工作后使用 `wsl -t <发行版名>` 停止目标发行版，再用 `wsl -d <发行版名>` 启动并重新运行安装命令。该 Linux 安装脚本会修改 Linux 内的 wsl.conf。Windows 端的 WSL 版本升级和发行版重启由用户完成。

## 常用选项

```bash
# 查看计划
bash /tmp/wsl-ai-install.sh --dry-run

# 只装文本、截图、文件剪贴板和自启
bash /tmp/wsl-ai-install.sh --clipboard-only

# 安装中文与剪贴板，跳过系统升级
bash /tmp/wsl-ai-install.sh --skip-upgrade

# 显式执行 Linux 根文件系统 TRIM
bash /tmp/wsl-ai-install.sh --trim

# 查看安装结果
bash /tmp/wsl-ai-install.sh --check
```

## 完成后的验证

重新进入同一 WSL 用户会话，让语言和输入法环境生效。完全退出并重新打开需要中文输入的应用。新建的输入法配置包含英文键盘和拼音，可以通过 Fcitx5 配置工具调整。已有输入法 profile 会保留。

依次验证 Windows 复制中文多行文本、Win+Shift+S 截图、资源管理器复制一个小文件和一个小目录，在目标 WSL 内运行的主聊天输入框按 Ctrl+V。截图应显示图片附件，文件和目录应显示 `/tmp` 副本路径，目录实体应包含内容。

自动启动表示用户服务在该 WSL 用户会话启动时运行。重启电脑后，重新进入该 WSL 和同一 Linux 用户，再测试截图粘贴。首次启动成功仍需要实际重启验收。WSL 尚未启动时，Linux 内的服务会等待 WSL 启动。

同一 Windows 主机此前出现两套桥接同时运行后截图失效的用户反馈，暂时停止其中一套并重启另一套后恢复，具体相互影响机制尚待核实。部署另一发行版时，应同时核对已有桥接的状态。不同主机的同名发行版分别安装和验证。

## 服务管理

在目标 WSL 普通用户终端执行。

```bash
export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"

systemctl --user status xclip-bridge.service --no-pager -l
systemctl --user restart xclip-bridge.service
journalctl --user -u xclip-bridge.service -n 30 --no-pager

# 停止并关闭自动启动
systemctl --user disable --now xclip-bridge.service wsl-fcitx5.service
```

遇到 `Unit not found`，先确认当前主机、WSL 名称、Linux 用户和安装时相同，再重新执行安装脚本。

遇到 `a clipboard bridge is already running`，先结束手动启动的 `xclip --watch`，再重启服务。通过服务启动的桥接应使用 systemctl 管理。

前台排查可执行 `/usr/local/bin/xclip --watch`，保持终端打开并重新截图测试。排查完成按 Ctrl+C，再恢复后台服务。

## 配置保护与重复运行

已有被修改文件备份到 `~/.local/state/wsl-ai-setup/backups/时间-进程号/`，备份按原绝对路径保存。安装进程通过锁串行执行。配置写入前检查当前内容，修改范围限于本方案管理的文件与配置段。重复运行会检查配置并重启用户服务。

为整合原始操作步骤，脚本会移除 `.bashrc` / `.profile` 中原样的 `fcitx5 --disable=wayland -d --replace` 启动行和 `eval $(dbus-launch --sh-syntax)` 行，改由用户服务管理输入法。其他自定义 shell 内容保留，修改前会备份。

成功复制的资料保留在 `/tmp`，系统清理临时目录后需重新复制。后台以剪贴板变化触发复制，源文件后续变化需要重新复制触发。后台按内容摘要去重，若同一列表被跳过，可先复制其他文本，再重新复制文件。

原始材料中的 `wsl --manage ... --set-sparse` 和 `Optimize-VHD` 属于 Windows 虚拟磁盘维护步骤，需在 Windows 端按实际发行版和磁盘路径单独办理。原文固定的 `F:\wsl\ai\ext4.vhdx` 路径仅适用于相应机器。Linux 根盘空间回收可使用本脚本的 `--trim`。

## 验证范围

本次完成 Bash 语法、参数处理、dry-run、内嵌剪贴板源码 SHA256、配置合并及重复执行、备份、权限、服务生成与 systemd 单元验证，以及原生 X11 剪贴板辅助程序检查。剪贴板源码来自已通过用户实际截图粘贴验收的版本，SHA256 为 `3684dec327501136544c744e58584d604f2d0a7a14bd6a537bd243204d76b82c`。

2026-11-12 在 Ubuntu 24.04 的独立 Test 发行版完成 `--clipboard-only` 实际安装、20 项隔离测试、10 项宿主剪贴板测试，以及 3 项后台 X11 发布测试。已验证中文文本、PNG 图片持续保留、文件及目录完整复制后发布副本路径。使用 `wsl -t Test` 后重新启动，桥接服务自动运行，根文件系统读写验证通过。

原生输入框的 Ctrl+V 图片附件和中文输入法界面仍需在目标应用中由用户验收。

## 官方参考

- [WSL 的 systemd 设置](https://learn.microsoft.com/en-us/windows/wsl/systemd)
- [Fcitx5 配置](https://fcitx-im.org/wiki/Setup_Fcitx_5/en)
