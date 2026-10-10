#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

# ========== 环境初始化 ==========
# 修复所有 unbound variable 错误
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

# ========== 安装 pyenv ==========
install_pyenv() {
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

  # 需要添加的配置内容
  local pyenv_configs=(
    'export PYENV_ROOT="$HOME/.pyenv"'
    '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
    'eval "$(pyenv init - bash)"'
  )

  # 配置 .bashrc 和 .profile
  for line in "${pyenv_configs[@]}"; do
    add_config "$HOME/.bashrc" "$line"
    add_config "$HOME/.profile" "$line"
  done

  # 让当前脚本环境立即生效
  export PYENV_ROOT="$HOME/.pyenv"
  [[ -d "$PYENV_ROOT/bin" ]] && export PATH="$PYENV_ROOT/bin:$PATH"
  eval "$(pyenv init - bash)"
}

# ========== 安装 g ==========
install_g() {
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

  # 配置环境变量
  local g_path='export PATH="$HOME/.g/go/bin:$PATH"'
  if ! grep -Fxq "$g_path" ~/.bashrc; then
    echo "$g_path" >> ~/.bashrc
  fi

  # 当前脚本环境立即生效
  export PATH="$HOME/.g/go/bin:$PATH"

  # 创建 Go 工作目录
  mkdir -p "$GOPATH"/{bin,src,pkg}
}

# ========== 安装 nvm ==========
install_nvm() {
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

  # 配置环境变量
  local nvm_config=$'\n# nvm配置\nexport NVM_DIR="$HOME/.nvm"\n[ -s "$NVM_DIR/nvm.sh" ] && \\. "$NVM_DIR/nvm.sh"\n[ -s "$NVM_DIR/bash_completion" ] && \\. "$NVM_DIR/bash_completion"'
  if ! grep -q "NVM_DIR" ~/.bashrc; then
    echo "$nvm_config" >> ~/.bashrc
  fi

  # 当前脚本环境立即生效
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
}

# ========== 验证安装 ==========
verify_installation() {
  log_info "验证安装结果..."

  # 验证 pyenv
  if ! command -v pyenv >/dev/null; then
    log_error "pyenv 安装验证失败"
  else
    log_info "pyenv 版本: $(pyenv --version)"
  fi

  # 验证 g
  if ! command -v g >/dev/null; then
    log_error "g 安装验证失败"
  else
    log_info "g 版本: $(g -v)"
  fi

  # 验证 nvm
  if ! command -v nvm >/dev/null; then
    log_error "nvm 安装验证失败"
  else
    log_info "nvm 版本: $(nvm --version)"
  fi

  # 验证环境变量
  if ! grep -qF "PYENV_ROOT" ~/.bashrc; then
    log_warn "pyenv 环境变量未正确配置到 ~/.bashrc"
  fi
  if ! grep -qF "PYENV_ROOT" ~/.profile; then
    log_warn "pyenv 环境变量未正确配置到 ~/.profile"
  fi
  if ! grep -qF ".g/go/bin" ~/.bashrc; then
    log_warn "g 环境变量未正确配置"
  fi
  if ! grep -qF "NVM_DIR" ~/.bashrc; then
    log_warn "nvm 环境变量未正确配置"
  fi
}

# ========== 主流程 ==========
main() {
  # 清理旧配置
  log_info "清理历史配置..."
  rm -rf ~/.g ~/.nvm 2>/dev/null || true
  touch ~/.bashrc ~/.profile
  sed -i '/export PATH="\$HOME\/.g\/go\/bin:\$PATH"/d' ~/.bashrc 2>/dev/null || true
  sed -i '/NVM_DIR/d' ~/.bashrc 2>/dev/null || true

  # 前置检查
  check_dependencies

  # 安装流程
  install_pyenv
  install_g
  install_nvm

  # 验证安装
  verify_installation

  # 最终提示
  echo -e "\n${GREEN}======= 安装成功 =======${NC}"
  echo -e "下一步操作建议:"
  echo -e "1. 重启终端或执行: ${GREEN}source ~/.bashrc${NC}"
  echo -e "2. 安装 Python 版本: ${GREEN}pyenv install 3.12.3 && pyenv global 3.12.3${NC}"
  echo -e "3. 安装 Go 版本: ${GREEN}g install latest${NC}"
  echo -e "4. 安装 Node 版本: ${GREEN}nvm install --lts${NC}"
}

# 执行主程序
main "$@"