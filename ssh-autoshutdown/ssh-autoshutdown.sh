#!/bin/bash
# =============================================================================
#  Ubuntu：SSH 登录成功 → 服务器自动关机
#
#  安装后由 PAM（pam_exec）在「每次 SSH 会话建立」时以 root 身份触发关机，
#  并通过一个 systemd oneshot 服务保证每次开机后钩子仍然有效。
#
#  用法：
#    sudo bash ssh-autoshutdown.sh install              # 安装（默认延迟 1 分钟关机）
#    sudo bash ssh-autoshutdown.sh install --delay 0    # 立即关机
#    sudo bash ssh-autoshutdown.sh install --dry-run    # 只写日志、不关机（测试用）
#    sudo bash ssh-autoshutdown.sh install --allow "ubuntu admin"   # 白名单用户
#    sudo bash ssh-autoshutdown.sh status               # 查看状态与最近日志
#    sudo bash ssh-autoshutdown.sh off                  # 临时停用（SSH 登录不再关机）
#    sudo bash ssh-autoshutdown.sh on                   # 恢复
#    sudo bash ssh-autoshutdown.sh uninstall            # 完全卸载
#
#  文件位置：
#    /usr/local/sbin/ssh-login-shutdown.sh        PAM 触发的动作脚本
#    /etc/ssh-login-shutdown.conf                 配置（延迟/白名单/测试模式）
#    /etc/ssh-login-shutdown.off                  临时停用开关（存在即不关机）
#    /var/log/ssh-login-shutdown.log              触发记录
#    /etc/systemd/system/ssh-login-shutdown-boot.service   开机自检/自愈
#
#  ⚠️ 安装后，任何 SSH 登录（含 scp / sftp / rsync / 自动化工具）都会触发关机。
#     云服务器会直接停机，需要到云控制台重新开机；请务必先准备好控制台通道。
# =============================================================================
set -euo pipefail

ACTION=/usr/local/sbin/ssh-login-shutdown.sh
CONF=/etc/ssh-login-shutdown.conf
PAM_FILE=/etc/pam.d/sshd
PAM_LINE='session optional pam_exec.so quiet /usr/local/sbin/ssh-login-shutdown.sh'
UNIT_PATH=/etc/systemd/system/ssh-login-shutdown-boot.service
UNIT_NAME=ssh-login-shutdown-boot.service
SELF=/usr/local/sbin/ssh-autoshutdown.sh
OFF_FILE=/etc/ssh-login-shutdown.off
LOG_FILE=/var/log/ssh-login-shutdown.log
WARNINGS=()

die()  { printf '错误：%s\n' "$*" >&2; exit 1; }
info() { printf '%s\n' "$*"; }
warn() { WARNINGS+=("$*"); }

usage() {
  cat <<'USAGE'
SSH 登录成功 → 自动关机（Ubuntu）

用法：
  sudo bash ssh-autoshutdown.sh install [选项]
  sudo bash ssh-autoshutdown.sh status
  sudo bash ssh-autoshutdown.sh off | on
  sudo bash ssh-autoshutdown.sh uninstall

install 选项：
  --delay N        关机延迟分钟数，默认 1；0 表示立即关机
  --allow "u1 u2"  白名单用户（这些用户的 SSH 登录不触发关机）
  --dry-run        只记录日志、不真正关机（用于验证）

示例：
  sudo bash ssh-autoshutdown.sh install
  sudo bash ssh-autoshutdown.sh install --delay 0
  sudo bash ssh-autoshutdown.sh install --dry-run
USAGE
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "需要 root 权限：sudo bash $0 ${cmd:-install}"
}

# 生成 PAM 动作脚本（root:root 0755）
write_action() {
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<'ACTION_EOF'
#!/bin/bash
# 由 PAM（pam_exec）在 SSH 会话建立时以 root 调用。
# 配置：/etc/ssh-login-shutdown.conf
# 临时停用：touch /etc/ssh-login-shutdown.off
set -u

CONF=/etc/ssh-login-shutdown.conf
OFF_FILE=/etc/ssh-login-shutdown.off
LOG_FILE=/var/log/ssh-login-shutdown.log

GRACE_MIN=1
ALLOW_USERS=""
DRY_RUN=0

if [ -r "$CONF" ]; then
  . "$CONF"
fi

# 只在会话打开时动作，忽略 close_session
case "${PAM_TYPE:-open_session}" in
  open_session) ;;
  *) exit 0 ;;
esac

USER_NAME=${PAM_USER:-}
if [ -z "$USER_NAME" ]; then
  USER_NAME=${PAM_RUSER:-}
fi
# pam_exec 默认只导出 PAM_RHOST/PAM_RUSER/PAM_SERVICE/PAM_TTY/PAM_TYPE，
# 不一定有 PAM_USER；此时用 audit loginuid 反查登录用户名。
if [ -z "$USER_NAME" ] && [ -r /proc/self/loginuid ]; then
  AUDIT_UID=$(/bin/cat /proc/self/loginuid 2>/dev/null || true)
  if [ -n "${AUDIT_UID:-}" ] && [ "$AUDIT_UID" != "4294967295" ]; then
    USER_NAME=$(/usr/bin/getent passwd "$AUDIT_UID" 2>/dev/null | /usr/bin/cut -d: -f1 || true)
  fi
fi
USER_NAME=${USER_NAME:-unknown}
RHOST=${PAM_RHOST:-unknown}
TTY_NAME=${PAM_TTY:-?}
STAMP=$(/bin/date '+%F %T')

log_line() {
  local line="$STAMP user=$USER_NAME rhost=$RHOST tty=$TTY_NAME $*"
  printf '%s\n' "$line" >> "$LOG_FILE" 2>/dev/null || true
  /usr/bin/logger -t ssh-autoshutdown "$line" 2>/dev/null || true
}

if [ -e "$OFF_FILE" ]; then
  log_line "skip=disabled"
  exit 0
fi

for u in $ALLOW_USERS; do
  if [ "$USER_NAME" = "$u" ]; then
    log_line "skip=allowlist"
    exit 0
  fi
done

if [ "$DRY_RUN" = "1" ]; then
  log_line "dry-run=would-shutdown"
  exit 0
fi

if [[ "$GRACE_MIN" =~ ^[0-9]+$ ]] && [ "$GRACE_MIN" -gt 0 ]; then
  log_line "action=shutdown delay=${GRACE_MIN}m"
  /sbin/shutdown -h "+${GRACE_MIN}" "SSH 登录（${USER_NAME}@${RHOST}）触发自动关机（${GRACE_MIN} 分钟后）" \
    || /sbin/poweroff || /usr/sbin/poweroff
else
  log_line "action=shutdown now"
  /sbin/shutdown -h now "SSH 登录（${USER_NAME}@${RHOST}）触发自动关机" \
    || /sbin/poweroff || /usr/sbin/poweroff
fi

exit 0
ACTION_EOF
  install -o root -g root -m 0755 "$tmp" "$ACTION"
  rm -f "$tmp"
}

# 生成配置文件
write_conf() {
  local delay=$1 allow=$2 dry=$3
  cat > "$CONF" <<CONF_EOF
# SSH 登录自动关机 · 配置
# 修改后无需重启，下一次 SSH 登录即生效。
# 关机延迟（分钟），0 = 立即关机
GRACE_MIN=${delay}
# 不触发关机的用户，空格分隔；留空 = 任何 SSH 登录都触发
ALLOW_USERS="${allow}"
# 1 = 只写日志不真正关机（测试用）
DRY_RUN=${dry}
CONF_EOF
  chmod 0644 "$CONF"
}

# 生成开机自检服务
write_unit() {
  [ -d /etc/systemd/system ] || return 0
  cat > "$UNIT_PATH" <<UNIT_EOF
[Unit]
Description=Re-arm SSH login auto shutdown hook (ssh-autoshutdown)
After=local-fs.target
ConditionPathExists=/usr/local/sbin/ssh-autoshutdown.sh

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ssh-autoshutdown.sh boot
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT_EOF
  chmod 0644 "$UNIT_PATH"
}

# 检查 pam_exec 模块
check_pam_exec() {
  if ! find /lib /usr/lib -type f -name pam_exec.so -print -quit 2>/dev/null | grep -q .; then
    die "未找到 pam_exec.so，请先安装：apt update && apt install -y libpam-modules"
  fi
}

# 检查 sshd 是否启用了 PAM
check_use_pam() {
  local f
  if grep -Eq '^[[:space:]]*UsePAM[[:space:]]+no' /etc/ssh/sshd_config 2>/dev/null; then
    warn "/etc/ssh/sshd_config 中 UsePAM 为 no，PAM 钩子不会生效；请改为 yes 后重启 ssh"
  fi
  for f in /etc/ssh/sshd_config.d/*.conf; do
    [ -e "$f" ] || continue
    if grep -Eq '^[[:space:]]*UsePAM[[:space:]]+no' "$f"; then
      warn "$f 中 UsePAM 为 no，PAM 钩子不会生效"
    fi
  done
}

# 写入 PAM 钩子（backup=1 时先备份）
ensure_pam_hook() {
  local backup=$1
  if grep -qF "$PAM_LINE" "$PAM_FILE"; then
    return 0
  fi
  if [ "$backup" = "1" ]; then
    cp -a "$PAM_FILE" "${PAM_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  fi
  {
    printf '\n# >>> ssh-autoshutdown >>>\n'
    printf '%s\n' "$PAM_LINE"
    printf '# <<< ssh-autoshutdown <<<\n'
  } >> "$PAM_FILE"
}

# 移除 PAM 钩子
remove_pam_hook() {
  local tmp
  cp -a "$PAM_FILE" "${PAM_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  tmp=$(mktemp)
  grep -vF "$PAM_LINE" "$PAM_FILE" \
    | grep -vF '# >>> ssh-autoshutdown >>>' \
    | grep -vF '# <<< ssh-autoshutdown <<<' > "$tmp" || true
  cat "$tmp" > "$PAM_FILE"
  rm -f "$tmp"
}

print_warnings() {
  if [ "${#WARNINGS[@]}" -eq 0 ]; then
    return 0
  fi
  info ""
  info "提示："
  local w
  for w in "${WARNINGS[@]}"; do
    info "  - $w"
  done
}

do_install() {
  local boot=0 delay=1 allow="" dry=0 delay_text
  require_root
  while [ $# -gt 0 ]; do
    case "$1" in
      --boot) boot=1; shift ;;
      --delay)
        [ $# -ge 2 ] || die "--delay 需要一个数字参数"
        delay=$2; shift 2 ;;
      --allow)
        [ $# -ge 2 ] || die "--allow 需要一个参数"
        allow=$2; shift 2 ;;
      --dry-run) dry=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1（用 --help 查看用法）" ;;
    esac
  done

  [[ "$delay" =~ ^[0-9]+$ ]] || die "--delay 必须是 0 或正整数（分钟）"
  [ -f "$PAM_FILE" ] || die "找不到 $PAM_FILE，请先安装 openssh-server"

  check_pam_exec
  check_use_pam

  write_action
  if [ "$boot" = "1" ]; then
    ensure_pam_hook 0
    print_warnings
    exit 0
  fi

  write_conf "$delay" "$allow" "$dry"
  ensure_pam_hook 1

  # 安装自身副本供开机服务调用
  if [ "$(readlink -f "$0")" != "$(readlink -f "$SELF")" ]; then
    install -o root -g root -m 0755 "$0" "$SELF"
  fi

  write_unit
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now "$UNIT_NAME" >/dev/null 2>&1 \
      || warn "systemctl enable 失败，开机自检可能不生效（PAM 钩子本身仍然有效）"
  else
    warn "未检测到 systemd，跳过开机守护服务；PAM 钩子每次 SSH 登录仍会生效"
  fi

  delay_text="${delay} 分钟"
  if [ "$delay" -eq 0 ]; then
    delay_text="立即"
  fi

  info ""
  info "✅ 安装完成：SSH 登录成功 → 自动关机"
  info "   动作脚本：$ACTION"
  info "   PAM 钩子：$PAM_FILE"
  info "   配置文件：$CONF"
  info "   关机延迟：${delay_text}"
  if [ -z "$allow" ]; then
    info "   白名单  ：无（任何 SSH 登录都会触发）"
  else
    info "   白名单  ：$allow"
  fi
  if [ "$dry" = "1" ]; then
    info "   测试模式：DRY_RUN=1（只写日志，不关机）"
  fi
  info ""
  info "⚠️ 从现在开始，任何一次 SSH 登录（含 scp / sftp / rsync）都会触发关机。"
  info "   · 想取消已排队的关机：登录后 1 分钟内执行 sudo shutdown -c"
  info "   · 想临时停用：sudo bash $SELF off"
  info "   · 想先验证：把 $CONF 里的 DRY_RUN 改成 1，登录一次看日志，确认后改回 0"
  print_warnings
}

do_status() {
  require_root
  local en act
  info "===== SSH 登录自动关机 · 状态 ====="
  if grep -qF "$PAM_LINE" "$PAM_FILE" 2>/dev/null; then
    info "PAM 钩子      ：已启用"
  else
    info "PAM 钩子      ：未启用"
  fi
  if [ -x "$ACTION" ]; then
    info "动作脚本      ：已安装（$ACTION）"
  else
    info "动作脚本      ：未安装"
  fi
  if [ -f "$CONF" ]; then
    info "配置文件      ：$CONF"
    sed -n '1,40p' "$CONF" | sed 's/^/    /'
  else
    info "配置文件      ：未安装"
  fi
  if command -v systemctl >/dev/null 2>&1; then
    en=$(systemctl is-enabled "$UNIT_NAME" 2>/dev/null || echo "未安装")
    act=$(systemctl is-active "$UNIT_NAME" 2>/dev/null || echo "未知")
    info "开机守护服务  ：${en} / ${act}"
  fi
  if [ -e "$OFF_FILE" ]; then
    info "临时停用开关  ：已停用（存在 $OFF_FILE）"
  else
    info "临时停用开关  ：未停用（SSH 登录会关机）"
  fi
  info "日志文件      ：$LOG_FILE"
  if [ -s "$LOG_FILE" ]; then
    info "最近记录："
    tail -n 5 "$LOG_FILE" | sed 's/^/  /'
  else
    info "最近记录：暂无（还没有因 SSH 登录触发过）"
  fi
}

do_off() {
  require_root
  touch "$OFF_FILE"
  chmod 0644 "$OFF_FILE"
  info "已临时停用：现在 SSH 登录不会再关机。"
  info "恢复：sudo bash $SELF on"
}

do_on() {
  require_root
  rm -f "$OFF_FILE"
  info "已恢复：SSH 登录成功将自动关机。"
}

do_uninstall() {
  require_root
  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now "$UNIT_NAME" >/dev/null 2>&1 || true
  fi
  if [ -f "$UNIT_PATH" ]; then
    rm -f "$UNIT_PATH"
    if command -v systemctl >/dev/null 2>&1; then
      systemctl daemon-reload >/dev/null 2>&1 || true
    fi
  fi
  if grep -qF "$PAM_LINE" "$PAM_FILE" 2>/dev/null; then
    remove_pam_hook
  fi
  rm -f "$ACTION" "$CONF" "$OFF_FILE" "$SELF"
  info "已卸载：SSH 登录不再触发关机。"
  info "PAM 配置备份保留在 /etc/pam.d/sshd.bak.*，日志保留在 $LOG_FILE。"
}

cmd=${1:-install}
if [ $# -gt 0 ]; then
  shift
fi

case "$cmd" in
  install)   do_install "$@" ;;
  boot)      do_install --boot ;;
  status)    do_status ;;
  off)       do_off ;;
  on)        do_on ;;
  uninstall) do_uninstall ;;
  -h|--help|help) usage ;;
  *) usage; exit 1 ;;
esac
