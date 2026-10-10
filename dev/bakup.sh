#!/usr/bin/env bash
set -e
set -o pipefail

OUTPUT_DIR="${BACKUP_OUTPUT_DIR:-$PWD}"
STAMP="$(date +%Y%m%d%H%M%S)"
SKIP_MISSING=0

usage() {
    cat <<'EOF'
用法:
  backup_all.sh [g] [nvm] [pyenv] [all]

不传参数时默认备份全部已安装工具: g / nvm / pyenv。
指定 all 也会备份全部，并跳过未安装的工具。
指定具体工具时，如果该工具不存在则报错退出。

环境变量:
  BACKUP_OUTPUT_DIR  备份输出目录，默认当前目录
  PYENV_ROOT         pyenv 根目录，默认 $HOME/.pyenv

示例:
  ./backup_all.sh
  ./backup_all.sh g nvm
  ./backup_all.sh pyenv
  BACKUP_OUTPUT_DIR=~/backups ./backup_all.sh all
EOF
}

backup_g() {
    local tool_name="g"
    local backup_dirs=(
        "$HOME/.${tool_name}"
        "$HOME/.goenv"
        "$HOME/.config/${tool_name}"
    )
    local found=0
    local dir
    local tmp
    local out

    tmp="$(mktemp -d)"
    out="$OUTPUT_DIR/${tool_name}_backup_${STAMP}.tar.gz"

    for dir in "${backup_dirs[@]}"; do
        if [ -d "$dir" ]; then
            cp -rp "$dir" "$tmp/"
            found=1
        fi
    done

    if [ "$found" -eq 0 ]; then
        rm -rf "$tmp"
        if [ "$SKIP_MISSING" -eq 1 ]; then
            echo "警告: 未找到 g 相关目录，跳过 g 备份。" >&2
            return 0
        else
            echo "错误: 未找到 g 相关目录: ${backup_dirs[*]}" >&2
            return 1
        fi
    fi

    # 备份环境变量（从当前 Shell 配置中提取）
    grep -E "PATH.*\.${tool_name}/bin" "$HOME"/.{bashrc,zshrc,profile} 2>/dev/null > "$tmp/env_config" || true

    # 记录平台信息
    {
        echo "ARCH=$(uname -m)"
        echo "OS=$(uname -s)"
    } > "$tmp/platform_info"

    tar -czf "$out" -C "$tmp" .
    rm -rf "$tmp"

    echo "备份已创建: $out"
    echo "注意: g/go 版本依赖平台，平台信息已保存在归档内的 ./platform_info"
}

backup_nvm() {
    local tmp
    local out

    if [ ! -d "$HOME/.nvm" ]; then
        if [ "$SKIP_MISSING" -eq 1 ]; then
            echo "警告: $HOME/.nvm 不存在，跳过 nvm 备份。" >&2
            return 0
        else
            echo "错误: .nvm 目录不存在: $HOME/.nvm" >&2
            return 1
        fi
    fi

    tmp="$(mktemp -d)"
    out="$OUTPUT_DIR/nvm_backup_${STAMP}.tar.gz"

    mkdir -p "$tmp/.nvm"

    (
        cd "$HOME/.nvm" &&
        tar --exclude='.git/objects/pack/.l2s.tmp_*' \
            --exclude='.git/index.lock' \
            -cf - . | tar -xpf - -C "$tmp/.nvm"
    )

    tar -czf "$out" -C "$tmp" .
    rm -rf "$tmp"

    echo "备份已创建: $out"
}

backup_pyenv() {
    local pyenv_root
    local out

    pyenv_root="${PYENV_ROOT:-$HOME/.pyenv}"
    out="$OUTPUT_DIR/pyenv_backup_${STAMP}.tar.gz"

    if [ ! -d "$pyenv_root" ]; then
        if [ "$SKIP_MISSING" -eq 1 ]; then
            echo "警告: pyenv 根目录不存在: $pyenv_root，跳过 pyenv 备份。" >&2
            return 0
        else
            echo "错误: pyenv 根目录不存在: $pyenv_root" >&2
            return 1
        fi
    fi

    # 排除缓存和 pyc 文件
    tar --exclude=".cache" --exclude="*.pyc" -czf "$out" -C "$pyenv_root" .

    echo "备份已创建: $out"
}

# 参数解析：无参数默认全部
if [ "$#" -eq 0 ]; then
    SELECTED=(g nvm pyenv)
    SKIP_MISSING=1
else
    SELECTED=()
    for arg in "$@"; do
        case "$arg" in
            all)
                SELECTED+=(g nvm pyenv)
                SKIP_MISSING=1
                ;;
            g)
                SELECTED+=(g)
                ;;
            nvm)
                SELECTED+=(nvm)
                ;;
            pyenv)
                SELECTED+=(pyenv)
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "未知参数: $arg" >&2
                usage
                exit 1
                ;;
        esac
    done
fi

# 去重
UNIQUE=()
for t in "${SELECTED[@]}"; do
    skip=0
    for u in "${UNIQUE[@]}"; do
        if [ "$u" = "$t" ]; then
            skip=1
            break
        fi
    done
    if [ "$skip" -eq 0 ]; then
        UNIQUE+=("$t")
    fi
done
SELECTED=("${UNIQUE[@]}")

if [ "${#SELECTED[@]}" -eq 0 ]; then
    usage
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"

for tool in "${SELECTED[@]}"; do
    case "$tool" in
        g)
            backup_g
            ;;
        nvm)
            backup_nvm
            ;;
        pyenv)
            backup_pyenv
            ;;
    esac
done

echo "全部选定备份已完成，输出目录: $OUTPUT_DIR"