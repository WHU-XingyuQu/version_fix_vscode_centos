# VS Code ↔ CentOS 7 Remote-SSH 修复

新版 VS Code Server 要求较新的 glibc，CentOS/RHEL 7 自带的 glibc 2.17 会使 Remote-SSH 报“远程主机不满足运行 VS Code 服务器的先决条件”。本脚本使用 [vscode-server-centos7](https://github.com/MikeWang000000/vscode-server-centos7) 的同版本社区补丁，**不更改本机 VS Code 版本**。

**适用：** Windows x64 VS Code → CentOS/RHEL 7 x86_64；本机需有 `code`、`ssh`、`scp`、`tar` 命令，且已能通过 SSH 登录目标主机。

在 Windows PowerShell 中运行：

```powershell
.\Repair-VSCodeCentOS7.ps1 -HostAlias 你的SSH主机名
```

脚本自动匹配 VS Code 版本与 commit，校验发布包 SHA256，备份原 Server CLI，安装补丁，并在远端 localhost 启动一次 Server 验证。出现 `LOCAL_VERIFIED` 后，再用 VS Code Remote-SSH 连接确认编辑器窗口。无 SSH 密钥时可能多次提示输入密码，脚本不会保存密码。

更新 VS Code 后可重新运行。其他参数见 `Get-Help .\Repair-VSCodeCentOS7.ps1 -Full` 或脚本顶部。旧系统兼容补丁不保证所有远端扩展的原生模块均可运行。
