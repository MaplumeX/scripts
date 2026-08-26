#!/usr/bin/env bash

# Debian 12 服务器基础初始化：系统更新、SSH 高位端口、UFW、Fail2ban、
# 上海时区与时间同步，以及 BBR + fq。

set -Eeuo pipefail

readonly SSH_DROP_IN="/etc/ssh/sshd_config.d/00-server-init.conf"
readonly FAIL2BAN_JAIL="/etc/fail2ban/jail.d/sshd.local"
readonly BBR_SYSCTL="/etc/sysctl.d/99-bbr.conf"
readonly BBR_MODULE="/etc/modules-load.d/bbr.conf"
readonly BACKUP_TAG="server-init.$(date +%Y%m%d%H%M%S)"

log() {
  printf '\n\033[1;32m==> %s\033[0m\n' "$*"
}

die() {
  printf '\n\033[1;31m错误：%s\033[0m\n' "$*" >&2
  exit 1
}

backup_file() {
  local file=$1
  if [[ -f "$file" ]]; then
    cp -a -- "$file" "${file}.${BACKUP_TAG}.bak"
  fi
}

require_root() {
  [[ ${EUID} -eq 0 ]] || die "请使用 root 用户运行：sudo bash $0"
  [[ -r /etc/os-release ]] || die "无法识别操作系统"

  # shellcheck disable=SC1091
  source /etc/os-release
  [[ ${ID:-} == "debian" ]] || die "此脚本仅支持 Debian"
  [[ ${VERSION_ID:-} == "12" ]] || die "此脚本仅针对 Debian 12，当前版本为 ${VERSION_ID:-未知}"
}

port_is_listening() {
  local port=$1
  ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|[.:])${port}$"
}

choose_ssh_port() {
  local saved_port candidate random_number attempt

  # 重复运行时沿用本脚本之前生成的端口。如需重新生成，设置 FORCE_NEW_SSH_PORT=1。
  if [[ ${FORCE_NEW_SSH_PORT:-0} != "1" && -r "$SSH_DROP_IN" ]]; then
    saved_port=$(awk '$1 == "Port" && $2 ~ /^[0-9]+$/ {print $2; exit}' "$SSH_DROP_IN")
    if [[ ${saved_port:-} =~ ^[0-9]+$ ]] && (( saved_port >= 20000 && saved_port <= 60000 )); then
      printf '%s\n' "$saved_port"
      return
    fi
  fi

  for ((attempt = 0; attempt < 100; attempt++)); do
    random_number=$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')
    candidate=$((20000 + random_number % 40001))
    if ! port_is_listening "$candidate"; then
      printf '%s\n' "$candidate"
      return
    fi
  done

  die "未能找到可用的随机 SSH 端口"
}

update_system() {
  log "更新软件包并安装基础组件"
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  apt-get update
  apt-get -y dist-upgrade
  apt-get install -y --no-install-recommends \
    openssh-server ufw fail2ban python3-systemd chrony
}

configure_time() {
  log "设置亚洲/上海时区并启用时间同步"
  timedatectl set-timezone Asia/Shanghai
  systemctl enable --now chrony.service
  chronyc online >/dev/null 2>&1 || true
}

configure_ssh() {
  local port=$1 file

  log "将 SSH 监听端口设置为 ${port}"
  mkdir -p /etc/ssh/sshd_config.d

  # 避免其他配置中的 Port 指令让旧端口继续监听；Match 块中的内容不改动。
  while IFS= read -r -d '' file; do
    backup_file "$file"
    sed -Ei '/^[[:space:]]*Match[[:space:]]/,$! s/^[[:space:]]*Port[[:space:]]+[0-9]+([[:space:]]*#.*)?$/# &/' "$file"
  done < <(find /etc/ssh -maxdepth 2 -type f \( -path '/etc/ssh/sshd_config' -o -path '/etc/ssh/sshd_config.d/*.conf' \) ! -path "$SSH_DROP_IN" -print0)

  backup_file "$SSH_DROP_IN"
  printf '# 由 debian12-init.sh 管理，请勿手动修改\nPort %s\n' "$port" >"$SSH_DROP_IN"

  /usr/sbin/sshd -t || die "SSH 配置校验失败，备份文件后缀为 .${BACKUP_TAG}.bak"
}

restart_ssh() {
  local port=$1

  # socket 激活会覆盖 sshd_config 中的监听端口，统一切换到 ssh.service。
  if systemctl is-active --quiet ssh.socket; then
    systemctl disable --now ssh.socket
  fi
  systemctl enable ssh.service
  systemctl restart ssh.service

  sleep 1
  port_is_listening "$port" || die "SSH 未在 ${port} 端口监听，暂不启用防火墙"
}

configure_ufw() {
  local port=$1

  log "配置 UFW：仅放行 HTTP、HTTPS 和 SSH ${port}/tcp"
  # 用户要求“只开”这三个端口，因此清空已有 UFW 规则。
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow 80/tcp comment 'HTTP'
  ufw allow 443/tcp comment 'HTTPS'
  ufw allow "${port}/tcp" comment 'SSH'
  ufw --force enable
}

configure_fail2ban() {
  local port=$1

  log "配置 Fail2ban（systemd 日志、3 次失败、封禁 2 小时）"
  mkdir -p /etc/fail2ban/jail.d
  backup_file "$FAIL2BAN_JAIL"
  cat >"$FAIL2BAN_JAIL" <<EOF
[sshd]
enabled = true
backend = systemd
port = ${port}
maxretry = 3
bantime = 2h
EOF

  fail2ban-client -t
  systemctl enable --now fail2ban.service
  systemctl restart fail2ban.service
}

configure_bbr() {
  log "启用 BBR + fq"
  printf 'tcp_bbr\n' >"$BBR_MODULE"
  modprobe tcp_bbr

  cat >"$BBR_SYSCTL" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl --system >/dev/null

  [[ $(sysctl -n net.ipv4.tcp_congestion_control) == "bbr" ]] || die "BBR 未能成功启用"
  [[ $(sysctl -n net.core.default_qdisc) == "fq" ]] || die "fq 未能成功启用"
}

show_result() {
  local port=$1

  log "初始化完成"
  printf 'SSH 新端口：\033[1;33m%s\033[0m\n' "$port"
  printf '时区：%s\n' "$(timedatectl show -p Timezone --value)"
  printf '拥塞控制：%s；默认队列：%s\n' \
    "$(sysctl -n net.ipv4.tcp_congestion_control)" \
    "$(sysctl -n net.core.default_qdisc)"
  printf '\n请保持当前 SSH 会话，另开终端确认新端口可登录：\n'
  printf '  ssh -p %s <用户名>@<服务器IP>\n' "$port"
  if [[ -f /var/run/reboot-required ]]; then
    printf '\n\033[1;33m系统更新了需要重启的组件，请在确认 SSH 新端口可用后执行 reboot。\033[0m\n'
  fi
}

main() {
  local ssh_port

  require_root
  update_system
  ssh_port=$(choose_ssh_port)
  configure_time
  configure_ssh "$ssh_port"
  restart_ssh "$ssh_port"
  configure_ufw "$ssh_port"
  configure_fail2ban "$ssh_port"
  configure_bbr
  show_result "$ssh_port"
}

main "$@"
