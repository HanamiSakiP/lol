#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ========== 颜色定义 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ========== 日志函数 ==========
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# ========== 常量 ==========
BACKUP_DIR="$HOME/.toolchain-uninstall-backup.$(date +%Y%m%d-%H%M%S)"

# 与 install.sh 默认值保持一致
GOPATH="${GOPATH:-$HOME/go}"

# 覆盖 install.sh 与官方安装脚本可能写入的所有相关行：
#  - pyenv: PYENV_ROOT / pyenv init / pyenv virtualenv-init / pyenv/bin
#  - g    : .g/ 下的任意路径（.g/env、.g/bin、.g/go、.g/versions…）与 # g shell setup 注释
#  - nvm  : NVM_DIR / nvm.sh / nvm/bash_completion / 自定义中文注释
CONFIG_PATTERN='PYENV_ROOT|pyenv init|pyenv virtualenv-init|pyenv/bin|g shell setup|\.g/|NVM_DIR|nvm\.sh|nvm/bash_completion|^# nvm配置|^# nvm$|^# pyenv'

# ========== 帮助 ==========
usage() {
  cat <<EOF
用法: ./uninstall.sh [-y|--yes] [-k|--keep-gopath] [-h|--help]

  -y, --yes          跳过确认，直接卸载
  -k, --keep-gopath  保留 GOPATH 目录（默认会删除 ${GOPATH}）
  -h, --help         显示帮助

说明:
  1. 备份并清理 ~/.bashrc 与 ~/.profile 中由 install.sh / 官方安装脚本写入的配置
  2. 删除 ~/.pyenv、~/.g、~/.nvm（含已安装的语言版本）
  3. 默认删除 GOPATH 目录（${GOPATH}）；使用 -k 可保留
  4. 结束后尝试 source ~/.bashrc 刷新环境
EOF
}

# ========== 参数解析 ==========
ASSUME_YES=0
KEEP_GOPATH=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) ASSUME_YES=1 ;;
    -k|--keep-gopath) KEEP_GOPATH=1 ;;
    -h|--help) usage; exit 0 ;;
    *) log_error "未知参数: $arg（使用 -h 查看帮助）" ;;
  esac
done

# ========== 确认 ==========
confirm_uninstall() {
  [[ $ASSUME_YES -eq 1 ]] && return 0

  echo -e "${YELLOW}即将卸载以下工具链:${NC}"
  echo "  - pyenv  : $HOME/.pyenv"
  echo "  - g      : $HOME/.g（含 GOROOT/Go SDK 与已安装的 Go 版本）"
  echo "  - nvm    : $HOME/.nvm（含已安装的 Node 版本）"
  if [[ $KEEP_GOPATH -eq 1 ]]; then
    echo -e "  - GOPATH : ${YELLOW}保留${NC}（$GOPATH）"
  else
    echo -e "  - GOPATH : ${GOPATH}（${YELLOW}将被删除，含其中的项目代码与已编译二进制${NC}）"
  fi
  echo
  echo -e "${YELLOW}并会备份后清理以下文件中的相关配置:${NC}"
  echo "  - $HOME/.bashrc"
  echo "  - $HOME/.profile"
  echo

  local ans=""
  read -r -p "确认继续? [y/N] " ans || ans=""
  case "$ans" in
    y|Y|yes|YES) ;;
    *) log_warn "已取消卸载"; exit 0 ;;
  esac
}

# ========== 清理单个配置文件 ==========
cleanup_config_file() {
  local file="$1"

  if [[ ! -f "$file" ]]; then
    log_warn "未找到 $file，跳过"
    return 0
  fi

  if ! grep -qE "$CONFIG_PATTERN" "$file"; then
    log_info "$file 无需清理"
    return 0
  fi

  mkdir -p "$BACKUP_DIR"
  local backup="$BACKUP_DIR/$(basename "$file").bak"
  cp -p "$file" "$backup"
  log_info "已备份 $file -> $backup"

  local before after
  before=$(wc -l < "$file")
  grep -vE "$CONFIG_PATTERN" "$file" > "$file.tmp" || true
  cat "$file.tmp" > "$file"
  rm -f "$file.tmp"
  after=$(wc -l < "$file")

  log_info "已清理 $file（$before -> $after 行）"
}

# ========== 删除工具目录 ==========
remove_pyenv() {
  if [[ -d "$HOME/.pyenv" ]]; then
    log_info "删除 pyenv: $HOME/.pyenv"
    rm -rf "$HOME/.pyenv" || log_error "删除 $HOME/.pyenv 失败"
  else
    log_warn "未发现 $HOME/.pyenv，跳过"
  fi
}

remove_g() {
  if [[ -d "$HOME/.g" ]]; then
    log_info "删除 g 及 Go SDK/版本: $HOME/.g"
    rm -rf "$HOME/.g" || log_error "删除 $HOME/.g 失败"
  else
    log_warn "未发现 $HOME/.g，跳过"
  fi
}

remove_nvm() {
  if [[ -d "$HOME/.nvm" ]]; then
    log_info "删除 nvm 及 Node 版本: $HOME/.nvm"
    rm -rf "$HOME/.nvm" || log_error "删除 $HOME/.nvm 失败"
  else
    log_warn "未发现 $HOME/.nvm，跳过"
  fi
}

remove_gopath() {
  if [[ $KEEP_GOPATH -eq 1 ]]; then
    log_info "按参数要求保留 GOPATH: $GOPATH"
    return 0
  fi

  # 安全校验：拒绝删除根目录、家目录、空路径
  if [[ -z "$GOPATH" || "$GOPATH" == "/" || "$GOPATH" == "$HOME" ]]; then
    log_error "GOPATH 路径异常（'$GOPATH'），拒绝删除，请检查环境变量 GOPATH"
  fi

  # 层级过浅时警告（如 /usr、/opt），提示用户确认
  local depth
  depth=$(echo "$GOPATH" | awk -F/ '{print NF-1}')
  if [[ "$depth" -lt 2 ]]; then
    log_warn "GOPATH 路径 '$GOPATH' 层级较浅，请确认这是期望删除的目录"
  fi

  if [[ -d "$GOPATH" ]]; then
    log_info "删除 GOPATH: $GOPATH"
    rm -rf "$GOPATH" || log_error "删除 $GOPATH 失败"
  else
    log_warn "未发现 $GOPATH，跳过"
  fi
}

# ========== 残留检查 ==========
post_check() {
  log_info "检查残留..."

  local found=0
  for d in "$HOME/.pyenv" "$HOME/.g" "$HOME/.nvm"; do
    if [[ -e "$d" ]]; then
      log_warn "残留目录: $d"
      found=1
    fi
  done

  if [[ $KEEP_GOPATH -eq 0 && -e "$GOPATH" ]]; then
    log_warn "残留目录: $GOPATH"
    found=1
  fi

  for f in "$HOME/.bashrc" "$HOME/.profile"; do
    if [[ -f "$f" ]] && grep -qE "$CONFIG_PATTERN" "$f"; then
      log_warn "残留配置: $f（可手动检查）"
      found=1
    fi
  done

  for f in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.zshrc" "$HOME/.zprofile"; do
    if [[ -f "$f" ]] && grep -qE "$CONFIG_PATTERN" "$f"; then
      log_warn "$f 中仍有相关配置，脚本未修改该文件，请按需手动清理"
      found=1
    fi
  done

  [[ $found -eq 0 ]] && log_info "未发现残留"
}

# ========== 刷新环境变量 ==========
refresh_env() {
  local rc="$HOME/.bashrc"

  if [[ ! -f "$rc" ]]; then
    log_warn "未找到 $rc，跳过环境刷新"
    return 0
  fi

  log_info "执行 source $rc ..."

  # 在子 shell 中执行，避免 .bashrc 内的 exit / set -e / 未定义变量 / IFS 改动影响卸载脚本
  if ( set +euo pipefail; IFS=$' \t\n'; source "$rc" >/dev/null 2>&1 ); then
    log_info "source $rc 执行完成"
  else
    log_warn "source $rc 返回非零（不影响卸载结果），请手动检查该文件"
  fi

  # 脚本是独立进程，source 只能刷新子进程，无法改变父终端环境
  log_info "注意: 当前终端环境需手动刷新，可执行: source ~/.bashrc，或直接执行 exec bash 以替换为新 shell（推荐）"
}

# ========== 主流程 ==========
main() {
  confirm_uninstall

  # 1) 先备份并清理 shell 配置
  log_info "开始清理 shell 配置..."
  cleanup_config_file "$HOME/.bashrc"
  cleanup_config_file "$HOME/.profile"

  # 2) 删除工具目录
  log_info "开始删除工具目录..."
  remove_pyenv
  remove_g
  remove_nvm
  remove_gopath

  # 3) 残留检查
  post_check

  # 4) 完成提示
  echo -e "\n${GREEN}======= 卸载完成 =======${NC}"
  if [[ -d "$BACKUP_DIR" ]]; then
    echo -e "配置备份目录: ${GREEN}$BACKUP_DIR${NC}"
    echo -e "如需回滚，可执行: ${GREEN}cp -p $BACKUP_DIR/.bashrc.bak ~/.bashrc${NC}"
    echo -e "                 ${GREEN}cp -p $BACKUP_DIR/.profile.bak ~/.profile${NC}"
  fi

  # 5) 按要求执行 source ~/.bashrc
  refresh_env
}

main "$@"