#!/bin/bash
set -euo pipefail

# 合并后的恢复脚本：支持 pyenv / g / nvm
# 用法: ./restore_all.sh <type> <backup_file.tar.gz>
# type: pyenv | g | nvm | auto

usage() {
    cat <<'EOF'
用法:
  ./restore_all.sh pyenv <backup_file.tar.gz>
  ./restore_all.sh g     <backup_file.tar.gz>
  ./restore_all.sh nvm   <backup_file.tar.gz>
  ./restore_all.sh auto  <backup_file.tar.gz>   # 自动检测类型

说明:
  pyenv: 恢复 ~/.pyenv（或 $PYENV_ROOT），并配置 shell
  g:     恢复 ~/.g 等目录，并配置 Go 环境变量
  nvm:   恢复 ~/.nvm，并配置 nvm 初始化
EOF
    exit 1
}

log()  { echo -e "\033[36m[INFO]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*" >&2; }
error(){ echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

check_backup_file() {
    local file="$1"
    if [ ! -f "$file" ]; then
        error "备份文件不存在: $file"
        exit 1
    fi
}

add_line_if_missing() {
    local file="$1"
    local line="$2"
    touch "$file"
    if ! grep -Fqx -- "$line" "$file"; then
        echo "$line" >> "$file"
        log "已向 $file 添加: $line"
    fi
}

add_block_if_missing() {
    local file="$1"
    local marker="$2"
    local block="$3"
    touch "$file"
    if ! grep -q -- "$marker" "$file"; then
        printf '\n%s\n' "$block" >> "$file"
        log "已向 $file 添加配置块"
    fi
}

restore_pyenv() {
    local backup_file="$1"
    local pyenv_root="${PYENV_ROOT:-$HOME/.pyenv}"

    check_backup_file "$backup_file"

    local temp_dir
    temp_dir=$(mktemp -d)
    log "解压 pyenv 备份到临时目录..."
    tar -xzf "$backup_file" -C "$temp_dir"

    local source_dir="$temp_dir"
    if [ -d "$temp_dir/.pyenv" ]; then
        source_dir="$temp_dir/.pyenv"
    fi

    log "恢复 pyenv 到: $pyenv_root"
    mkdir -p "$pyenv_root"
    cp -a "$source_dir"/. "$pyenv_root"/
    rm -rf "$temp_dir"

    # 配置 shell
    local rc_files=("$HOME/.bashrc" "$HOME/.profile")
    for file in "${rc_files[@]}"; do
        add_line_if_missing "$file" 'export PYENV_ROOT="$HOME/.pyenv"'
        add_line_if_missing "$file" '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
        add_line_if_missing "$file" 'eval "$(pyenv init - bash)"'
    done

    log "pyenv 恢复完成。"
    echo "请执行: source ~/.bashrc  或重启终端"
}

restore_g() {
    local backup_file="$1"
    check_backup_file "$backup_file"

    local restore_dir
    restore_dir=$(mktemp -d)

    log "解压 g 备份到临时目录..."
    tar -xzf "$backup_file" -C "$restore_dir"

    # 平台兼容性检查
    local platform_file=""
    if [ -f "$restore_dir/platform_info" ]; then
        platform_file="$restore_dir/platform_info"
    elif [ -f "$restore_dir/.platform_info" ]; then
        platform_file="$restore_dir/.platform_info"
    fi
    if [ -n "$platform_file" ]; then
        echo "=== Platform Compatibility Check ==="
        echo "Backup created on:"
        cat "$platform_file"
        echo -e "\nCurrent system:"
        echo "ARCH=$(uname -m)"
        echo "OS=$(uname -s)"
        echo "===================================="
        read -r -p "Press enter to continue or Ctrl+C to abort..."
    fi

    # 恢复目录到 $HOME
    shopt -s dotglob nullglob
    for dir in "$restore_dir"/*; do
        base_dir=$(basename "$dir")
        case "$base_dir" in
            .|..) continue ;;
            .env_config|platform_info|.platform_info) continue ;;
        esac
        if [ -d "$dir" ]; then
            local target_dir="$HOME/$base_dir"
            log "恢复目录: $base_dir -> $target_dir"
            rm -rf -- "$target_dir"
            cp -rp -- "$dir" "$target_dir"
        fi
    done
    shopt -u dotglob nullglob

    rm -rf "$restore_dir"

    # 配置环境变量
    local env_config
    env_config=$(cat <<'EOF'
# g (Go Version Manager) configuration
export PATH="$HOME/.g/bin:$PATH"
export GOROOT="$HOME/.g/versions/current/go"
export GOPATH="$HOME/go"
EOF
)

    local rc_files=("$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile")
    for rcfile in "${rc_files[@]}"; do
        add_block_if_missing "$rcfile" 'PATH.*\.g/bin' "$env_config"
    done

    log "g 恢复完成。"
    echo "请执行: source ~/.bashrc  或重启终端"
    echo "如果需要重新链接当前版本: g install <version>"
}

restore_nvm() {
    local backup_file="$1"
    check_backup_file "$backup_file"

    local temp_dir
    temp_dir=$(mktemp -d)

    log "解压 nvm 备份到临时目录..."
    tar -xzf "$backup_file" -C "$temp_dir"

    if [ ! -d "$temp_dir/.nvm" ]; then
        error "备份中未找到 .nvm 目录"
        rm -rf "$temp_dir"
        exit 1
    fi

    log "恢复 ~/.nvm ..."
    rm -rf "$HOME/.nvm"
    mv "$temp_dir/.nvm" "$HOME/.nvm"
    rm -rf "$temp_dir"

    local nvm_init
    nvm_init=$(cat <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
EOF
)

    local config_files=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile")
    for config in "${config_files[@]}"; do
        if [ -f "$config" ]; then
            add_block_if_missing "$config" 'NVM_DIR' "$nvm_init"
        else
            case "$config" in
                "$HOME/.bashrc"|"$HOME/.zshrc"|"$HOME/.profile")
                    touch "$config"
                    add_block_if_missing "$config" 'NVM_DIR' "$nvm_init"
                    ;;
            esac
        fi
    done

    log "nvm 恢复完成。"
    echo "请执行: source ~/.bashrc  或重启终端"
}

detect_type() {
    local backup_file="$1"
    local list
    list=$(tar -tzf "$backup_file" 2>/dev/null || true)

    if echo "$list" | grep -qE '(^|/)\.nvm(/|$)'; then
        echo "nvm"
    elif echo "$list" | grep -qE '(^|/)\.g(/|$)|(^|/)platform_info$|(^|/)\.platform_info$'; then
        echo "g"
    elif echo "$list" | grep -qE '(^|/)(versions|shims|version)(/|$)'; then
        echo "pyenv"
    else
        echo ""
    fi
}

main() {
    if [ $# -ne 2 ]; then
        usage
    fi

    local type="$1"
    local backup_file="$2"

    if [ "$type" = "auto" ]; then
        type=$(detect_type "$backup_file")
        if [ -z "$type" ]; then
            error "无法自动检测备份类型，请手动指定: pyenv | g | nvm"
            exit 1
        fi
        log "自动检测类型: $type"
    fi

    case "$type" in
        pyenv) restore_pyenv "$backup_file" ;;
        g|go)  restore_g "$backup_file" ;;
        nvm)   restore_nvm "$backup_file" ;;
        *)     usage ;;
    esac
}

main "$@"