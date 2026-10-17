#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ========== 脚本位置 ==========
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ========== 环境初始化 ==========
export PS1="${PS1:-\\u@\\h:\\w\\$ }"
export debian_chroot="${debian_chroot:-}"
export force_color_prompt="${force_color_prompt:-yes}"
export GOPATH="${GOPATH:-$HOME/go}"

# ========== 颜色定义 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

# ========== 日志函数 ==========
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; exit 1; }

# ========== 配置写入函数 ==========
add_config() {
  local file="$1"
  local content="$2"
  touch "$file"
  if ! grep -qF -- "$content" "$file"; then
    echo "正在配置 $file..."
    echo "$content" >> "$file"
  else
    echo "跳过 $file（配置已存在）"
  fi
}

# ========== 本地备份探测（用于优先恢复） ==========
# 支持两种存放结构：
#   1) <script_dir>/dev/tools/<tool>/<tool>_backup_*.tar.gz     （推荐）
#   2) <script_dir>/dev/tools/<tool>_backup_*.tar.gz           （扁平）
find_backup_tool() {
  local tool="$1"
  local base="$SCRIPT_DIR/dev/tools"
  local -a files=()

  if [[ -d "$base/$tool" ]]; then
    shopt -s nullglob
    files=("$base/$tool/${tool}_backup_"*.tar.gz)
    shopt -u nullglob
  fi

  if (( ${#files[@]} == 0 )); then
    shopt -s nullglob
    files=("$base/${tool}_backup_"*.tar.gz)
    shopt -u nullglob
  fi

  (( ${#files[@]} == 0 )) && return 0

  # 按文件名排序（时间戳形式），取最新一个
  printf '%s\n' "${files[@]}" | LC_ALL=C sort | tail -n1
}

# try_restore_tool <pyenv|g|nvm>
#   成功返回 0（表示已恢复，调用方应直接 return 跳过下载）
#   失败返回 1（表示无备份或恢复失败，调用方继续原有在线安装流程）
try_restore_tool() {
  local tool="$1"

  # 允许用户显式禁用本地恢复，强制在线安装
  if [[ "${SKIP_LOCAL_RESTORE:-0}" == "1" ]]; then
    return 1
  fi

  local restore_script="$SCRIPT_DIR/restore.sh"
  if [[ ! -f "$restore_script" ]]; then
    return 1
  fi

  local backup
  backup=$(find_backup_tool "$tool")
  if [[ -z "$backup" ]]; then
    return 1
  fi

  log_info "检测到 $tool 本地备份: $(basename "$backup")，优先执行恢复（跳过在线下载）"
  if bash "$restore_script" "$tool" "$backup"; then
    log_info "$tool 已从本地备份恢复完成"
    return 0
  else
    log_warn "$tool 本地备份恢复失败，将回退到在线安装"
    return 1
  fi
}

# ========== 依赖检查 ==========
check_dependencies() {
  local deps=("curl" "git")
  for dep in "${deps[@]}"; do
    if ! command -v "$dep" >/dev/null; then
      log_error "必需依赖 '$dep' 未安装，请手动安装后重试"
    fi
  done
  [[ -w "$HOME" ]] || log_error "用户目录 '$HOME' 不可写"
}

# ========== 安装 pyenv（优先恢复本地备份） ==========
install_pyenv() {
  if try_restore_tool pyenv; then
    # 子进程恢复不影响当前 shell，手动重设环境变量
    export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
    [[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init - bash)" 2>/dev/null || true
    return 0
  fi

  log_info "安装 Python 版本管理工具 pyenv..."
  local install_script
  install_script=$(mktemp)

  if ! curl -fsSL https://pyenv.run -o "$install_script"; then
    rm -f "$install_script"
    log_error "下载 pyenv 安装脚本失败"
  fi

  if ! bash "$install_script"; then
    rm -f "$install_script"
    log_error "pyenv 安装执行失败"
  fi
  rm -f "$install_script"

  local pyenv_configs=(
    'export PYENV_ROOT="$HOME/.pyenv"'
    '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
    'eval "$(pyenv init - bash)"'
  )

  for line in "${pyenv_configs[@]}"; do
    add_config "$HOME/.bashrc" "$line"
    add_config "$HOME/.profile" "$line"
  done

  export PYENV_ROOT="$HOME/.pyenv"
  [[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"
  eval "$(pyenv init - bash)"
}

# ========== 安装 g（优先恢复本地备份） ==========
install_g() {
  if try_restore_tool g; then
    export GOROOT="$HOME/.g/go"
    export PATH="$HOME/.g/bin:$GOROOT/bin:$PATH"
    mkdir -p "$GOPATH"/{bin,src,pkg}
    return 0
  fi

  log_info "安装 Go 版本管理工具 g..."
  local install_script
  install_script=$(mktemp)

  if ! curl -fsSL https://raw.githubusercontent.com/voidint/g/master/install.sh -o "$install_script"; then
    rm -f "$install_script"
    log_error "下载 g 安装脚本失败"
  fi

  if ! bash "$install_script"; then
    rm -f "$install_script"
    log_error "g 安装执行失败"
  fi
  rm -f "$install_script"

  # 说明：官方安装脚本会自行写入 [ -s "$HOME/.g/env" ] && \. "$HOME/.g/env"  # g shell setup
  # 这里再补充显式 GOROOT/PATH 作为兜底，防止 .g/env 未加载时找不到 g
  local g_configs=(
    'export GOROOT="$HOME/.g/go"'
    'export PATH="$HOME/.g/bin:$GOROOT/bin:$PATH"'
  )
  for line in "${g_configs[@]}"; do
    add_config "$HOME/.bashrc" "$line"
    add_config "$HOME/.profile" "$line"
  done

  export GOROOT="$HOME/.g/go"
  export PATH="$HOME/.g/bin:$GOROOT/bin:$PATH"

  mkdir -p "$GOPATH"/{bin,src,pkg}
}

# ========== 安装 nvm（优先恢复本地备份） ==========
install_nvm() {
  if try_restore_tool nvm; then
    export NVM_DIR="$HOME/.nvm"
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
    return 0
  fi

  log_info "安装 Node 版本管理工具 nvm..."
  local install_script
  install_script=$(mktemp)

  if ! curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.2/install.sh -o "$install_script"; then
    rm -f "$install_script"
    log_error "下载 nvm 安装脚本失败"
  fi

  if ! bash "$install_script"; then
    rm -f "$install_script"
    log_error "nvm 安装执行失败"
  fi
  rm -f "$install_script"

  local nvm_config=$'\n# nvm配置\nexport NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && \\. "$NVM_DIR/nvm.sh"\n[ -s "$NVM_DIR/bash_completion" ] && \\. "$NVM_DIR/bash_completion"'
  if ! grep -q "NVM_DIR" ~/.bashrc; then
    echo "$nvm_config" >> ~/.bashrc
  fi

  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
}

# ========== 安装后刷新 shell 环境（source ~/.bashrc 后再验证） ==========
reload_shell_env() {
  log_info "执行 source \"$HOME/.bashrc\" 以刷新当前环境..."

  # 暂时关闭 -u / -e，避免 .bashrc 中的未定义变量或失败命令打断安装流程
  set +u
  set +e
  # shellcheck disable=SC1090
  source "$HOME/.bashrc" >/dev/null 2>&1
  local rc=$?
  set -e
  set -u

  [[ $rc -ne 0 ]] && log_warn "source ~/.bashrc 返回非零（$rc），继续做兜底加载..."

  # 兜底：部分发行版 ~/.bashrc 开头有 case $- in *i*) ;; *) return;; esac
  # 在非交互脚本中会提前 return，导致上面的 source 实际没有加载任何工具
  if ! command -v pyenv >/dev/null 2>&1 && [[ -d "$HOME/.pyenv/bin" ]]; then
    export PYENV_ROOT="$HOME/.pyenv"
    export PATH="$PYENV_ROOT/bin:$PATH"
    eval "$(pyenv init - bash)" 2>/dev/null || true
  fi

  if ! command -v g >/dev/null 2>&1 && [[ -x "$HOME/.g/bin/g" ]]; then
    export GOROOT="$HOME/.g/go"
    export PATH="$HOME/.g/bin:$GOROOT/bin:$PATH"
  fi

  if ! command -v nvm >/dev/null 2>&1 && [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    export NVM_DIR="$HOME/.nvm"
    # shellcheck disable=SC1091
    \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
  fi
}

# ========== 验证安装 ==========
verify_installation() {
  log_info "验证安装结果..."

  if ! command -v pyenv >/dev/null; then
    log_error "pyenv 安装验证失败"
  else
    log_info "pyenv 版本: $(pyenv --version)"
  fi

  if ! command -v g >/dev/null; then
    log_error "g 安装验证失败（可执行文件应在 $HOME/.g/bin/g）"
  else
    log_info "g 版本: $(g --version 2>/dev/null || g -v)"
  fi

  if ! command -v nvm >/dev/null; then
    log_error "nvm 安装验证失败"
  else
    log_info "nvm 版本: $(nvm --version)"
  fi

  if ! grep -qF "PYENV_ROOT" ~/.bashrc; then
    log_warn "pyenv 环境变量未正确配置到 ~/.bashrc"
  fi
  if ! grep -qF "PYENV_ROOT" ~/.profile; then
    log_warn "pyenv 环境变量未正确配置到 ~/.profile"
  fi
  if ! grep -qF ".g/bin" ~/.bashrc; then
    log_warn "g 环境变量未正确配置（缺少 ~/.g/bin）"
  fi
  if ! grep -qF "NVM_DIR" ~/.bashrc; then
    log_warn "nvm 环境变量未正确配置"
  fi
}

# ========== 主流程 ==========
main() {
  log_info "清理历史配置..."
  rm -rf ~/.g ~/.nvm 2>/dev/null || true
  touch ~/.bashrc ~/.profile
  # 一般化匹配：覆盖旧版 .g/go/bin、新版 .g/bin、GOROOT 行、
  # 以及官方 g 安装脚本写入的 .g/env 与 # g shell setup 注释
  sed -i '/g shell setup/d; /\.g\//d; /GOROOT="\$HOME\/\.g\/go"/d' ~/.bashrc 2>/dev/null || true
  sed -i '/g shell setup/d; /\.g\//d; /GOROOT="\$HOME\/\.g\/go"/d' ~/.profile 2>/dev/null || true
  sed -i '/NVM_DIR/d' ~/.bashrc 2>/dev/null || true

  check_dependencies

  # 每个 install_* 内部会先尝试本地备份恢复，失败/无备份才在线下载
  install_pyenv
  install_g
  install_nvm

  # 安装/恢复后先 source ~/.bashrc，再验证
  reload_shell_env

  verify_installation

  echo -e "\n${GREEN}======= 安装成功 =======${NC}"
  echo -e "下一步操作建议:"
  echo -e "1. 重启终端或执行: ${GREEN}source ~/.bashrc${NC}"
  echo -e "2. 安装 Python 版本: ${GREEN}pyenv install 3.12.3 && pyenv global 3.12.3${NC}"
  echo -e "3. 安装 Go 版本: ${GREEN}g install latest${NC}"
  echo -e "4. 安装 Node 版本: ${GREEN}nvm install --lts${NC}"
}

main "$@"