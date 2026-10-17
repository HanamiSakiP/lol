#!/usr/bin/env bash
set -euo pipefail

OUTPUT_DIR="${BACKUP_OUTPUT_DIR:-$PWD}"
STAMP="$(date +%Y%m%d%H%M%S)"
SKIP_MISSING=0

# 通用排除模式（tar 参数形式，必须以 --exclude= 开头）
EXCLUDES=(
    '--exclude=.git'
    '--exclude=.github'
    '--exclude=.gitignore'
    '--exclude=.gitmodules'
    '--exclude=.gitattributes'
    '--exclude=.cache'
    '--exclude=test'
    '--exclude=tests'
    '--exclude=docs'
    '--exclude=man'
    '--exclude=*.md'
    '--exclude=LICENSE'
    '--exclude=LICENSE.*'
    '--exclude=Makefile'
    '--exclude=Dockerfile'
    '--exclude=*.png'
    '--exclude=*.gif'
    '--exclude=*.jpg'
    '--exclude=*.jpeg'
    '--exclude=*.svg'
    '--exclude=*.ico'
    '--exclude=*.pyc'
    '--exclude=__pycache__'
    '--exclude=*.pyo'
    '--exclude=*.log'
    '--exclude=tmp'
    '--exclude=temp'
    '--exclude=rename_test.sh'
    '--exclude=update_test_mocks.sh'
    '--exclude=install.sh'
    '--exclude=package.json'
    '--exclude=package-lock.json'
)

usage() {
    cat <<'EOF'
用法:
  backup.sh [g] [nvm] [pyenv] [all]

不传参数时默认备份全部已安装工具: g / nvm / pyenv。
指定 all 也会备份全部，并跳过未安装的工具。
指定具体工具时，如果该工具不存在则报错退出。

环境变量:
  BACKUP_OUTPUT_DIR  备份输出目录，默认当前目录
  PYENV_ROOT         pyenv 根目录，默认 $HOME/.pyenv
  GOPATH             Go 工作目录，默认 $HOME/go；若 /go 存在也会一并打包

示例:
  ./backup.sh
  ./backup.sh g nvm
  ./backup.sh pyenv
  BACKUP_OUTPUT_DIR=~/backups ./backup.sh all
EOF
}

backup_g() {
    local tool_name="g"
    local out="$OUTPUT_DIR/${tool_name}_backup_${STAMP}.tar.gz"
    local tmp
    local found=0
    local packed_paths=()

    tmp="$(mktemp -d)"

    # pack_dir <源目录> <归档内目标路径> [strict]
    #   strict=1（默认）：失败返回非零
    #   strict=0        ：失败仅警告并跳过
    # 会把真实路径记录到 packed_paths 中，避免同一目录被重复打包
    pack_dir() {
        local src="$1"
        local dst="$2"
        local strict="${3:-1}"
        [ -d "$src" ] || return 0

        local abs
        abs="$(cd "$src" && pwd)"

        local p
        for p in "${packed_paths[@]+"${packed_paths[@]}"}"; do
            [ "$p" = "$abs" ] && return 0
        done

        mkdir -p "$tmp/$dst"

        if ! (cd "$src" && tar "${EXCLUDES[@]}" -cf - .) \
                | (cd "$tmp/$dst" && tar -xpf -); then
            if [ "$strict" -eq 1 ]; then
                return 1
            fi
            echo "警告: 打包 $src 时出错（可能权限不足），已跳过。" >&2
            rm -rf "${tmp:?}/$dst"
            return 0
        fi

        packed_paths+=("$abs")
        found=1
        return 0
    }

    # 原有 g 相关目录（保留相对结构，便于恢复）
    pack_dir "$HOME/.${tool_name}" ".${tool_name}" \
        || { rm -rf "$tmp"; echo "错误: 打包 $HOME/.${tool_name} 失败" >&2; return 1; }
    pack_dir "$HOME/.goenv" ".goenv" \
        || { rm -rf "$tmp"; echo "错误: 打包 $HOME/.goenv 失败" >&2; return 1; }
    pack_dir "$HOME/.config/${tool_name}" ".config/${tool_name}" \
        || { rm -rf "$tmp"; echo "错误: 打包 $HOME/.config/${tool_name} 失败" >&2; return 1; }

    # GOPATH（install.sh 默认 $HOME/go；容器中常为 /go）
    local gopath="${GOPATH:-$HOME/go}"
    if [ -d "$gopath" ]; then
        local gopath_arc
        case "$gopath" in
            "$HOME"/*) gopath_arc="${gopath#"$HOME"/}" ;;      # 归档内用相对 $HOME 的路径
            "/go")     gopath_arc="_go" ;;                     # 与下面的 /go 分支对应
            *)         gopath_arc="_abs$(printf '%s' "$gopath" | tr '/' '_')" ;;
        esac
        pack_dir "$gopath" "$gopath_arc" \
            || { rm -rf "$tmp"; echo "错误: 打包 GOPATH($gopath) 失败" >&2; return 1; }
    fi

    # /go 目录（当 GOPATH 不是 /go 时单独打包；失败仅警告）
    if [ -d "/go" ]; then
        pack_dir "/go" "_go" 0
    fi

    if [ "$found" -eq 0 ]; then
        rm -rf "$tmp"
        if [ "$SKIP_MISSING" -eq 1 ]; then
            echo "警告: 未找到 g/go 相关目录，跳过 g 备份。" >&2
            return 0
        fi
        echo "错误: 未找到 g/go 相关目录（\$HOME/.g、\$GOPATH、/go 等均不存在）" >&2
        return 1
    fi

    grep -E "(PATH.*\.${tool_name}/bin|GOROOT|GOPATH|/go/bin)" \
        "$HOME"/.{bashrc,zshrc,profile} 2>/dev/null \
        > "$tmp/env_config" || true

    {
        echo "ARCH=$(uname -m)"
        echo "OS=$(uname -s)"
        echo "GOPATH=$gopath"
    } > "$tmp/platform_info"

    tar -czf "$out" -C "$tmp" .
    rm -rf "$tmp"

    echo "备份已创建: $out"
    echo "注意: g/go 版本依赖平台，平台信息已保存在归档内的 ./platform_info"
}

backup_nvm() {
    local out="$OUTPUT_DIR/nvm_backup_${STAMP}.tar.gz"

    if [ ! -d "$HOME/.nvm" ]; then
        if [ "$SKIP_MISSING" -eq 1 ]; then
            echo "警告: $HOME/.nvm 不存在，跳过 nvm 备份。" >&2
            return 0
        fi
        echo "错误: .nvm 目录不存在: $HOME/.nvm" >&2
        return 1
    fi

    # 从 $HOME 打包，归档内第一层为 .nvm/
    tar "${EXCLUDES[@]}" -czf "$out" -C "$HOME" .nvm
    echo "备份已创建: $out"
}

backup_pyenv() {
    local pyenv_root
    local pyenv_parent
    local pyenv_base
    local out

    pyenv_root="${PYENV_ROOT:-$HOME/.pyenv}"
    out="$OUTPUT_DIR/pyenv_backup_${STAMP}.tar.gz"

    if [ ! -d "$pyenv_root" ]; then
        if [ "$SKIP_MISSING" -eq 1 ]; then
            echo "警告: pyenv 根目录不存在: $pyenv_root，跳过 pyenv 备份。" >&2
            return 0
        fi
        echo "错误: pyenv 根目录不存在: $pyenv_root" >&2
        return 1
    fi

    # 绝对化，便于取父目录
    pyenv_root="$(cd "$pyenv_root" && pwd)"
    pyenv_parent="$(dirname "$pyenv_root")"
    pyenv_base="$(basename "$pyenv_root")"

    # 从父目录打包，归档内第一层为 <pyenv_base>/（默认即 .pyenv/）
    tar "${EXCLUDES[@]}" -czf "$out" -C "$pyenv_parent" "$pyenv_base"
    echo "备份已创建: $out"
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
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
            g|nvm|pyenv)
                SELECTED+=("$arg")
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
        g)     backup_g ;;
        nvm)   backup_nvm ;;
        pyenv) backup_pyenv ;;
    esac
done

echo "全部选定备份已完成，输出目录: $OUTPUT_DIR"
