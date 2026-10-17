#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_BACKUP_BASE="${BACKUP_BASE:-$SCRIPT_DIR/dev/tools}"

# ---------------------------------------------------------------------------
# 用法
# ---------------------------------------------------------------------------
usage() {
    cat <<'EOF'
用法:
  ./restore.sh                                # 自动模式（默认）
                                              # 检查当前未安装的工具，从
                                              # <script_dir>/dev/tools/<tool>/ 恢复
  ./restore.sh <type>                         # 单类型自动模式
  ./restore.sh <backup_file.tar.gz>          # 单文件，自动检测类型
  ./restore.sh <dir>                          # 目录，恢复其中所有匹配的备份
  ./restore.sh <type> <backup_file.tar.gz>   # 指定类型 + 文件
  ./restore.sh <type> <dir>                   # 指定类型 + 目录

  type 可选: pyenv | g | nvm | auto

自动模式行为:
  - 检查 $HOME/.g、$HOME/.nvm、$PYENV_ROOT（默认 $HOME/.pyenv）是否存在
  - 已存在的工具跳过（避免误覆盖已安装环境）
  - 未安装的工具，从 $BACKUP_BASE/<tool>/ 中查找备份并恢复
  - 默认 $BACKUP_BASE = <script_dir>/dev/tools

目录结构:
  <script_dir>/dev/tools/
  ├── g/
  │   ├── g_backup_20250101120000.tar.gz
  │   └── g_backup_20250102120000.tar.gz
  ├── nvm/
  │   └── nvm_backup_20250101120000.tar.gz
  └── pyenv/
      └── pyenv_backup_20250101120000.tar.gz

  （也支持扁平结构: $BACKUP_BASE/g_backup_*.tar.gz）

环境变量:
  BACKUP_BASE   自动模式的备份基础目录（默认: <script_dir>/dev/tools）
  PYENV_ROOT    pyenv 安装目录（默认: $HOME/.pyenv）

同一类型存在多个备份时:
  - 交互式终端下让用户选择
  - 非交互环境下自动使用最新（按文件名时间戳）的那个

结束时脚本会自动 source ~/.bashrc 刷新自身环境，并提示你
在当前终端执行 source ~/.bashrc（或重开终端）让配置生效。
EOF
    exit 1
}

log()   { printf '\033[36m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m[WARN]\033[0m %s\n' "$*" >&2; }
error() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }

# ---------------------------------------------------------------------------
# 临时目录管理
# ---------------------------------------------------------------------------
CLEANUP_DIRS=()
_cleanup_trap() {
    local d
    for d in "${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}"; do
        [[ -d "$d" ]] && rm -rf -- "$d"
    done
}
trap _cleanup_trap EXIT

new_tmpdir() {
    local var_name="$1"
    local d
    d=$(mktemp -d)
    CLEANUP_DIRS+=("$d")
    printf -v "$var_name" '%s' "$d"
}

# ---------------------------------------------------------------------------
# 通用工具
# ---------------------------------------------------------------------------
check_backup_file() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        error "备份文件不存在: $file"
        exit 1
    fi
    if ! tar -tzf "$file" >/dev/null 2>&1; then
        error "备份文件不是有效的 tar.gz: $file"
        exit 1
    fi
}

add_line_if_missing() {
    local file="$1" line="$2"
    touch "$file"
    if ! grep -Fqx -- "$line" "$file"; then
        printf '%s\n' "$line" >> "$file"
        log "已向 $file 添加: $line"
    fi
}

add_block_if_missing() {
    local file="$1" marker="$2" block="$3"
    touch "$file"
    if ! grep -qF -- "$marker" "$file"; then
        printf '\n%s\n' "$block" >> "$file"
        log "已向 $file 添加配置块"
    fi
}

# ---------------------------------------------------------------------------
# 各工具的实际恢复逻辑
# ---------------------------------------------------------------------------
restore_pyenv() {
    local backup_file="$1"
    local pyenv_root="${PYENV_ROOT:-$HOME/.pyenv}"

    check_backup_file "$backup_file"

    local temp_dir
    new_tmpdir temp_dir
    log "解压 pyenv 备份到临时目录..."
    tar -xzf "$backup_file" -C "$temp_dir"

    local source_dir="$temp_dir"
    if [[ -d "$temp_dir/.pyenv" ]]; then
        source_dir="$temp_dir/.pyenv"
    else
        local entries=() e
        shopt -s dotglob nullglob
        for e in "$temp_dir"/*; do entries+=("$e"); done
        shopt -u dotglob nullglob
        if (( ${#entries[@]} == 1 )) && [[ -d "${entries[0]}" ]]; then
            source_dir="${entries[0]}"
        fi
    fi

    log "恢复 pyenv 到: $pyenv_root"
    mkdir -p "$pyenv_root"
    cp -a "$source_dir"/. "$pyenv_root"/

    local pyenv_config_root
    if [[ "$pyenv_root" == "$HOME/.pyenv" ]]; then
        pyenv_config_root='$HOME/.pyenv'
    else
        pyenv_config_root="$pyenv_root"
    fi

    local rc_files=("$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile") f
    for f in "${rc_files[@]}"; do
        add_line_if_missing "$f" "export PYENV_ROOT=\"$pyenv_config_root\""
        add_line_if_missing "$f" '[[ -d $PYENV_ROOT/bin ]] && export PATH="$PYENV_ROOT/bin:$PATH"'
        add_line_if_missing "$f" 'eval "$(pyenv init - bash)"'
    done

    log "pyenv 恢复完成。"
}

restore_g() {
    local backup_file="$1"
    check_backup_file "$backup_file"

    local restore_dir
    new_tmpdir restore_dir
    log "解压 g 备份到临时目录..."
    tar -xzf "$backup_file" -C "$restore_dir"

    # 平台兼容信息（只打印，不再等待回车）
    local platform_file="" cand
    for cand in "$restore_dir/platform_info" "$restore_dir/.platform_info"; do
        if [[ -f "$cand" ]]; then
            platform_file="$cand"
            break
        fi
    done
    if [[ -n "$platform_file" ]]; then
        echo "=== Platform Compatibility Info ==="
        echo "Backup created on:"
        cat "$platform_file"
        echo -e "\nCurrent system:"
        echo "ARCH=$(uname -m)"
        echo "OS=$(uname -s)"
        echo "==================================="
    fi

    local entries=() e
    shopt -s dotglob nullglob
    for e in "$restore_dir"/*; do entries+=("$e"); done
    shopt -u dotglob nullglob

    local dir base_dir target_dir
    for dir in "${entries[@]+"${entries[@]}"}"; do
        base_dir=$(basename "$dir")
        case "$base_dir" in
            platform_info|.platform_info|env_config) continue ;;
        esac
        [[ -d "$dir" ]] || continue

        case "$base_dir" in
            _go)
                if [[ -w / ]] || { [[ -d /go ]] && [[ -w /go ]]; }; then
                    target_dir="/go"
                else
                    target_dir="$HOME/_go"
                    warn "无权限写入 /go，恢复为 $target_dir，请手动迁移"
                fi
                ;;
            _abs*)
                target_dir="$HOME/$base_dir"
                warn "归档目录 $base_dir 来自外部绝对路径（编码有损），恢复到 $target_dir，请手动迁移"
                ;;
            *)
                target_dir="$HOME/$base_dir"
                ;;
        esac

        log "恢复目录: $base_dir -> $target_dir"
        rm -rf -- "$target_dir"
        cp -rp -- "$dir" "$target_dir"
    done

    local f
    for f in "$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile"; do
        [[ -f "$f" ]] || continue
        sed -i '/GOROOT="\$HOME\/\.g\/versions\/current\/go"/d' "$f" 2>/dev/null || true
    done

    local env_config
    env_config=$(cat <<'EOF'
# g (Go Version Manager) configuration
export GOROOT="$HOME/.g/go"
export PATH="$HOME/.g/bin:$GOROOT/bin:$PATH"
export GOPATH="$HOME/go"
EOF
)

    local rc_files=("$HOME/.bashrc" "$HOME/.zshrc" "$HOME/.profile")
    for f in "${rc_files[@]}"; do
        add_block_if_missing "$f" 'GOROOT="$HOME/.g/go"' "$env_config"
    done

    log "g 恢复完成。"
}

restore_nvm() {
    local backup_file="$1"
    check_backup_file "$backup_file"

    local temp_dir
    new_tmpdir temp_dir

    log "解压 nvm 备份到临时目录..."
    tar -xzf "$backup_file" -C "$temp_dir"

    if [[ ! -d "$temp_dir/.nvm" ]]; then
        error "备份中未找到 .nvm 目录"
        exit 1
    fi

    log "恢复 ~/.nvm ..."
    rm -rf "$HOME/.nvm"
    mv "$temp_dir/.nvm" "$HOME/.nvm"

    local nvm_init
    nvm_init=$(cat <<'EOF'
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion
EOF
)

    local config_files=("$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.zshrc" "$HOME/.profile") f
    for f in "${config_files[@]}"; do
        add_block_if_missing "$f" 'NVM_DIR' "$nvm_init"
    done

    log "nvm 恢复完成。"
}

# ---------------------------------------------------------------------------
# 单文件类型自动检测
# ---------------------------------------------------------------------------
detect_type() {
    local backup_file="$1"
    local list
    list=$(tar -tzf "$backup_file" 2>/dev/null || true)

    if grep -qE '(^|/)\.nvm(/|$)' <<<"$list"; then
        echo "nvm"
    elif grep -qE '(^|/)\.g(/|$)|(^|/)platform_info$' <<<"$list"; then
        echo "g"
    elif grep -qE '(^|/)(versions|shims)/' <<<"$list"; then
        echo "pyenv"
    else
        echo ""
    fi
}

# ---------------------------------------------------------------------------
# 目录扫描 / 备份选择
# ---------------------------------------------------------------------------
declare -a BACKUPS_G=()
declare -a BACKUPS_NVM=()
declare -a BACKUPS_PYENV=()

sort_array() {
    local -n _arr="$1"
    if (( ${#_arr[@]} <= 1 )); then
        return 0
    fi
    local sorted
    sorted=$(printf '%s\n' "${_arr[@]}" | LC_ALL=C sort)
    _arr=()
    local line
    while IFS= read -r line; do
        [[ -n "$line" ]] && _arr+=("$line")
    done <<<"$sorted"
}

# 按类型扫描某个目录中的 <type>_backup_*.tar.gz
scan_one_backup() {
    local dir="$1" type="$2"
    local -n _arr="BACKUPS_${type^^}"
    _arr=()
    if [[ ! -d "$dir" ]]; then
        return 0
    fi
    local f
    shopt -s nullglob
    for f in "$dir/${type}_backup_"*.tar.gz; do
        _arr+=("$f")
    done
    shopt -u nullglob
    sort_array "BACKUPS_${type^^}"
}

# 一次性扫描目录中三类备份
scan_backup_dir() {
    local dir="$1"
    if [[ ! -d "$dir" ]]; then
        error "目录不存在: $dir"
        exit 1
    fi
    scan_one_backup "$dir" g
    scan_one_backup "$dir" nvm
    scan_one_backup "$dir" pyenv
}

# 在备份基础目录中定位某工具的备份目录：
#   1) 优先 <base>/<tool>/  （推荐结构）
#   2) 扁平结构 <base>/<tool>_backup_*.tar.gz
#   3) 都没有则输出空
find_backup_dir() {
    local tool="$1" base="$2"
    if [[ -d "$base/$tool" ]]; then
        printf '%s' "$base/$tool"
        return 0
    fi
    if compgen -G "$base/${tool}_backup_*.tar.gz" >/dev/null; then
        printf '%s' "$base"
        return 0
    fi
    printf ''
}

# pick_backup <type>
pick_backup() {
    local type="$1"
    local -n _files="BACKUPS_${type^^}"

    local n=${#_files[@]}
    if (( n == 0 )); then
        return 1
    fi

    local chosen
    if (( n == 1 )); then
        chosen="${_files[0]}"
    elif [[ -t 0 && -t 1 ]]; then
        {
            echo "为 $type 找到多个备份:" >&2
            local i
            for i in "${!_files[@]}"; do
                echo "  [$((i+1))] $(basename "${_files[$i]}")" >&2
            done
        }
        local ans
        while true; do
            read -r -p "选择 [1-$n]（回车默认最新 $n）: " ans || ans=""
            [[ -z "$ans" ]] && ans="$n"
            if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= n )); then
                chosen="${_files[$((ans-1))]}"
                break
            fi
            echo "无效输入，请重试" >&2
        done
    else
        chosen="${_files[$((n-1))]}"
        warn "非交互式环境，$type 自动选择最新备份: $(basename "$chosen")"
    fi

    printf '%s' "$chosen"
}

# ---------------------------------------------------------------------------
# 分发 + 记录
# ---------------------------------------------------------------------------
declare -a RESTORED_TOOLS=()

dispatch() {
    local type="$1" file="$2"
    case "$type" in
        pyenv) restore_pyenv "$file" ;;
        g)     restore_g     "$file" ;;
        nvm)   restore_nvm   "$file" ;;
        *)     error "未知类型: $type"; exit 1 ;;
    esac
    RESTORED_TOOLS+=("$type")
}

# ---------------------------------------------------------------------------
# 刷新 shell 环境（与 install.sh 的 reload_shell_env 思路一致）
# ---------------------------------------------------------------------------
reload_shell_env() {
    log "尝试 source \"$HOME/.bashrc\" 以刷新当前脚本环境..."

    set +u
    set +e
    # shellcheck disable=SC1090
    source "$HOME/.bashrc" >/dev/null 2>&1
    local rc=$?
    set -e
    set -u

    if [[ $rc -ne 0 ]]; then
        warn "source ~/.bashrc 返回非零（$rc），继续做兜底加载..."
    fi

    # 兜底：~/.bashrc 中的 case $- in *i*) ;; *) return;; esac 在非交互脚本里
    # 会提前 return，导致 source 实际没有加载任何工具
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
        [[ -s "$NVM_DIR/bash_completion" ]] && \. "$NVM_DIR/bash_completion"
    fi
}

print_final_hint() {
    echo
    echo "注意: 脚本内的 source 只作用于脚本自身进程，不会改变你当前交互式 shell 的环境。"
    echo "请在你的当前终端执行以下命令之一，使配置生效:"
    echo "    source ~/.bashrc"
    echo "    exec bash"
    echo "或者直接重开一个终端。"
}

finalize_restore() {
    if (( ${#RESTORED_TOOLS[@]} > 0 )); then
        log "本次恢复的工具: ${RESTORED_TOOLS[*]}"
        reload_shell_env
        print_final_hint
    fi
}

# ---------------------------------------------------------------------------
# 自动模式：检测未安装的工具并从 dev/tools/<tool>/ 恢复
#   auto_mode [<only_tool>]
#   - 不传参数：对 g / nvm / pyenv 三类都做检测
#   - 传参：只处理指定的那一类
# ---------------------------------------------------------------------------
auto_mode() {
    local only="${1:-}"
    local base="$DEFAULT_BACKUP_BASE"

    log "=== 自动恢复模式 ==="
    log "备份基础目录: $base"

    declare -A INSTALL_DIR=(
        [g]="$HOME/.g"
        [nvm]="$HOME/.nvm"
        [pyenv]="${PYENV_ROOT:-$HOME/.pyenv}"
    )

    local -a candidates=(g nvm pyenv)
    if [[ -n "$only" ]]; then
        candidates=("$only")
    fi

    local -a to_restore=()
    local tool dir backup_dir n
    for tool in "${candidates[@]}"; do
        dir="${INSTALL_DIR[$tool]}"
        backup_dir=$(find_backup_dir "$tool" "$base")

        log "[$tool]"
        log "  安装目录: $dir"
        log "  备份目录: ${backup_dir:-<未找到>}"

        if [[ -e "$dir" ]]; then
            log "  状态: 已安装（$dir 存在），跳过"
            continue
        fi

        if [[ -z "$backup_dir" ]]; then
            warn "  状态: 未安装，但找不到 $tool 的备份目录/文件，跳过"
            continue
        fi

        scan_one_backup "$backup_dir" "$tool"
        local -n _barr="BACKUPS_${tool^^}"
        n=${#_barr[@]}
        if (( n == 0 )); then
            warn "  状态: 未安装，备份目录中无 ${tool}_backup_*.tar.gz，跳过"
            continue
        fi

        log "  状态: 未安装，可用备份 $n 个"
        to_restore+=("$tool")
    done

    if (( ${#to_restore[@]} == 0 )); then
        log "没有需要恢复的工具（全部已安装，或未找到备份）"
        return 0
    fi

    for tool in "${to_restore[@]}"; do
        log "===== 恢复 $tool ====="
        local file
        if ! file=$(pick_backup "$tool"); then
            warn "$tool 备份选择失败，跳过"
            continue
        fi
        log "使用备份: $(basename "$file")"
        dispatch "$tool" "$file"
    done

    finalize_restore
}

# ---------------------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------------------
main() {
    # 默认：无参数 -> 自动模式
    if [[ $# -eq 0 ]]; then
        auto_mode
        return 0
    fi

    if [[ $# -gt 2 ]]; then
        usage
    fi

    local restore_type=""
    local target=""

    if [[ $# -eq 1 ]]; then
        target="$1"
        if [[ ! -e "$target" ]]; then
            # 不是文件也不是目录 —— 尝试当作 type
            local t="${target,,}"
            [[ "$t" == "go" ]] && t="g"
            case "$t" in
                g|nvm|pyenv) auto_mode "$t"; return 0 ;;
                auto)        auto_mode;        return 0 ;;
                *) error "路径不存在，也不是有效的 type: $target"; exit 1 ;;
            esac
        fi
    else
        restore_type="$1"
        target="$2"
        if [[ ! -e "$target" ]]; then
            error "路径不存在: $target"
            exit 1
        fi
    fi

    restore_type="${restore_type,,}"
    [[ "$restore_type" == "go" ]] && restore_type="g"
    case "$restore_type" in
        ""|auto|pyenv|g|nvm) ;;
        *) error "未知类型: $restore_type（用法: pyenv | g | nvm | auto）"; exit 1 ;;
    esac

    # ===== 单文件模式 =====
    if [[ -f "$target" ]]; then
        if [[ -z "$restore_type" || "$restore_type" == "auto" ]]; then
            restore_type=$(detect_type "$target")
            if [[ -z "$restore_type" ]]; then
                error "无法自动检测备份类型，请手动指定: pyenv | g | nvm"
                exit 1
            fi
            log "自动检测类型: $restore_type"
        fi
        dispatch "$restore_type" "$target"
        finalize_restore
        return 0
    fi

    # ===== 目录模式 =====
    scan_backup_dir "$target"
    log "扫描目录: $target"
    log "  g     备份: ${#BACKUPS_G[@]} 个"
    log "  nvm   备份: ${#BACKUPS_NVM[@]} 个"
    log "  pyenv 备份: ${#BACKUPS_PYENV[@]} 个"

    local -a todo=()
    case "$restore_type" in
        ""|auto)
            if (( ${#BACKUPS_G[@]} ));     then todo+=(g);     fi
            if (( ${#BACKUPS_NVM[@]} ));   then todo+=(nvm);   fi
            if (( ${#BACKUPS_PYENV[@]} )); then todo+=(pyenv); fi
            ;;
        g)
            if (( ${#BACKUPS_G[@]} == 0 )); then
                error "目录中未找到 g 备份: $target/g_backup_*.tar.gz"
                exit 1
            fi
            todo+=(g)
            ;;
        nvm)
            if (( ${#BACKUPS_NVM[@]} == 0 )); then
                error "目录中未找到 nvm 备份: $target/nvm_backup_*.tar.gz"
                exit 1
            fi
            todo+=(nvm)
            ;;
        pyenv)
            if (( ${#BACKUPS_PYENV[@]} == 0 )); then
                error "目录中未找到 pyenv 备份: $target/pyenv_backup_*.tar.gz"
                exit 1
            fi
            todo+=(pyenv)
            ;;
    esac

    if (( ${#todo[@]} == 0 )); then
        error "目录中未找到任何匹配的备份文件: $target"
        error "预期文件名形如: g_backup_*.tar.gz / nvm_backup_*.tar.gz / pyenv_backup_*.tar.gz"
        exit 1
    fi

    local tool file
    for tool in "${todo[@]}"; do
        log "===== 处理 $tool ====="
        if ! file=$(pick_backup "$tool"); then
            warn "$tool 备份选择失败，跳过"
            continue
        fi
        log "使用备份: $(basename "$file")"
        dispatch "$tool" "$file"
    done

    finalize_restore
}

main "$@"
