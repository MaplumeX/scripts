# scripts

个人脚本集合。

## Debian 12 服务器初始化

`debian12-init.sh` 会完成系统升级、随机 SSH 高位端口、UFW、Fail2ban、
上海时区与 Chrony 时间同步，以及 BBR + fq 配置。

### 一键运行

在 Debian 12 服务器上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/MaplumeX/scripts/main/debian12-init.sh | sudo bash
```

如果当前已经是 `root` 用户，也可以执行：

```bash
curl -fsSL https://raw.githubusercontent.com/MaplumeX/scripts/main/debian12-init.sh | bash
```

> 脚本会升级系统、修改 SSH 端口并重置已有 UFW 规则。请保持当前 SSH
> 会话，在执行完成后另开终端测试输出的新 SSH 端口，确认可正常登录后再
> 关闭原会话。

### 下载后运行

```bash
curl -fLO https://raw.githubusercontent.com/MaplumeX/scripts/main/debian12-init.sh
sudo bash debian12-init.sh
```

首次运行会在 `20000-60000` 中选择一个未监听的随机端口；重复运行会沿用该
端口。如需重新随机生成端口：

```bash
curl -fsSL https://raw.githubusercontent.com/MaplumeX/scripts/main/debian12-init.sh | sudo FORCE_NEW_SSH_PORT=1 bash
```

脚本会重置已有 UFW 规则，只放行 `80/tcp`、`443/tcp` 和新的 SSH 端口。
执行完成后先保持当前连接，再开一个终端确认新 SSH 端口可以登录。
