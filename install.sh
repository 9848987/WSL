#!/usr/bin/env bash
# Debian/Ubuntu WSL setup. Run as the Linux desktop user.
set -Eeuo pipefail
umask 022

DRY_RUN=false
CHECK_ONLY=false
CLIPBOARD_ONLY=false
UPGRADE=true
TRIM=false
STEP=准备
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/wsl-ai-setup"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
TEMP_DIR=
BACKUP_DIR=

log() { printf '\n[%s] %s\n' "$STEP" "$*"; }
fail() { printf '\n安装未完成，%s\n' "$*" >&2; exit 1; }
cleanup() { [[ -z $TEMP_DIR ]] || rm -rf -- "$TEMP_DIR"; }
trap cleanup EXIT
trap 'printf "\n安装在【%s】失败（第%s行）。修复报错后可重新运行。\n" "$STEP" "$LINENO" >&2' ERR

usage() {
    cat <<'HELP'
用法 bash install.sh [选项]
默认安装中文环境、Fcitx5、剪贴板桥接及自动启动。
  --dry-run         显示安装计划，保持系统当前状态
  --check           检查依赖和后台服务状态
  --clipboard-only  仅安装剪贴板及其自动启动服务
  --skip-upgrade    跳过系统软件升级
  --trim            完成后对 Linux 根文件系统执行 fstrim
  -h, --help        显示帮助
请在目标 WSL 的普通用户终端运行，安装过程通过 sudo 请求管理员权限。
HELP
}

parse_args() {
    while (($#)); do
        case "$1" in
            --dry-run) DRY_RUN=true ;;
            --check) CHECK_ONLY=true ;;
            --clipboard-only) CLIPBOARD_ONLY=true; UPGRADE=false ;;
            --skip-upgrade) UPGRADE=false ;;
            --trim) TRIM=true ;;
            -h|--help) usage; exit 0 ;;
            *) fail "未知参数 $1" ;;
        esac
        shift
    done
}

# Preserve other sections and keys when updating wsl.conf.
set_ini_value() {
    local section=$1 key=$2 value=$3 source=$4
    awk -v section="$section" -v key="$key" -v value="$value" '
        function finish_section() {
            if (inside && !written) { print key "=" value; written=1 }
        }
        /^[[:space:]]*\[/ {
            finish_section()
            name=$0
            sub(/^[[:space:]]*\[/, "", name)
            sub(/\].*$/, "", name)
            inside=(name == section)
            if (inside) found=1
        }
        {
            line=$0
            if (inside && line ~ "^[[:space:]]*" key "[[:space:]]*=") {
                if (!written) print key "=" value
                written=1
            } else print
        }
        END {
            finish_section()
            if (!found) print "\n[" section "]\n" key "=" value
        }
    ' "$source"
}

backup() {
    local path=$1
    if [[ -e $path || -L $path ]]; then
        mkdir -p -- "$BACKUP_DIR$(dirname "$path")"
        if [[ -w $path && ! -L $path ]]; then
            cp -a -- "$path" "$BACKUP_DIR$path"
        else
            sudo cp -a -- "$path" "$BACKUP_DIR$path"
        fi
    fi
}

write_user_file() {
    local path=$1 mode=$2
    local staged
    staged=$(mktemp "$TEMP_DIR/user.XXXXXXXX")
    cat > "$staged"
    if [[ -f $path ]] && cmp -s -- "$path" "$staged"; then
        chmod "$mode" -- "$path"
        return
    fi
    backup "$path"
    mkdir -p -- "$(dirname "$path")"
    install -m "$mode" -- "$staged" "$path"
}

user_systemctl() {
    DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus" systemctl --user "$@"
}

apt_run() {
    sudo env DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Options::=--force-confold "$@"
}

check_installation() {
    local failed=0
    for path in /usr/local/bin/xclip "$HOME/.local/lib/xclip-x11/usr/bin/xclip"; do
        if [[ -x $path ]]; then printf '已安装 %s\n' "$path"; else printf '缺少 %s\n' "$path"; failed=1; fi
    done
    user_systemctl is-enabled xclip-bridge.service || failed=1
    user_systemctl is-active xclip-bridge.service || failed=1
    user_systemctl status xclip-bridge.service --no-pager -l || true
    return "$failed"
}

preflight() {
    [[ $(id -u) -ne 0 ]] || fail '请用目标 Linux 普通用户运行，勿在命令前加 sudo。'
    [[ -f /etc/os-release ]] || fail '缺少发行版信息。'
    . /etc/os-release
    case "${ID:-}" in debian|ubuntu) ;; *) fail '支持 Debian 和 Ubuntu。' ;; esac
    [[ -n ${WSL_DISTRO_NAME:-} && -d /run/WSL ]] || fail '请在目标 WSL 的终端中运行。'
    [[ $(dpkg --print-architecture) == amd64 ]] || fail '本版桌面安装包适用 amd64。'
    [[ ${DISPLAY:-} =~ ^:[0-9]+(\.[0-9]+)?$ ]] || fail '请在 WSLg 图形终端运行，DISPLAY 应类似 :0。'
    [[ $WSL_DISTRO_NAME =~ ^[A-Za-z0-9._-]+$ ]] || fail '发行版名称包含暂未支持的字符。'
    [[ $CONFIG_DIR == "$HOME/.config" ]] || fail '当前版本要求 XDG_CONFIG_HOME 使用默认 ~/.config。'
    command -v sudo >/dev/null || fail '请先由管理员安装 sudo 并授予当前用户 sudo 权限。'
    sudo -v
    mkdir -p "$STATE_DIR"
    chmod 700 "$STATE_DIR"
    exec 8> "$STATE_DIR/install.lock"
    flock -n 8 || fail '另一个安装进程正在运行。'
    BACKUP_DIR="$STATE_DIR/backups/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    TEMP_DIR=$(mktemp -d /tmp/wsl-ai-setup.XXXXXXXX)
    chmod 755 "$TEMP_DIR"
}

install_packages() {
    STEP=系统组件
    local packages=(ca-certificates curl wget git coreutils util-linux libc-bin
        xclip libx11-6 libxmu6 libxt6 x11-utils file diffutils dbus-x11 dbus-user-session
        systemd systemd-sysv)
    if [[ $CLIPBOARD_ONLY == false ]]; then
        packages+=(locales fonts-noto-cjk fonts-wqy-microhei fontconfig fcitx5
            fcitx5-chinese-addons fcitx5-config-qt fcitx5-frontend-gtk3 fcitx5-frontend-qt5)
    fi
    apt_run update
    if [[ $UPGRADE == true ]]; then apt_run upgrade -y; fi
    apt_run install -y "${packages[@]}"
}

configure_wsl() {
    STEP=WSL启动设置
    if sudo test -f /etc/wsl.conf; then
        # The redirect writes to the current user's staging directory.
        # shellcheck disable=SC2024
        sudo cat /etc/wsl.conf > "$TEMP_DIR/wsl.conf"
    else
        : > "$TEMP_DIR/wsl.conf"
    fi
    set_ini_value boot systemd true "$TEMP_DIR/wsl.conf" > "$TEMP_DIR/wsl.1"
    set_ini_value interop enabled true "$TEMP_DIR/wsl.1" > "$TEMP_DIR/wsl.2"
    set_ini_value interop appendWindowsPath true "$TEMP_DIR/wsl.2" > "$TEMP_DIR/wsl.3"
    if ! sudo cmp -s /etc/wsl.conf "$TEMP_DIR/wsl.3"; then
        backup /etc/wsl.conf
        sudo install -m 644 "$TEMP_DIR/wsl.3" /etc/wsl.conf
    fi
    if [[ $(ps -p 1 -o comm=) != systemd ]]; then
        log '已启用 systemd。请保存工作，重新启动此 WSL 发行版后，再运行相同安装命令。'
        exit 2
    fi
    [[ -S /run/user/$(id -u)/bus ]] || fail 'systemd 用户总线尚未就绪。请重新进入当前 WSL 用户后再次运行。'
}

configure_chinese() {
    STEP=中文和输入法
    backup /etc/locale.gen
    sudo sed -i -E 's/^[#[:space:]]*(zh_CN.UTF-8[[:space:]]+UTF-8).*$/\1/' /etc/locale.gen
    sudo locale-gen zh_CN.UTF-8
    backup /etc/default/locale
    sudo update-locale LANG=zh_CN.UTF-8
    fc-cache -f
    write_user_file "$CONFIG_DIR/wsl-ai-setup/environment.sh" 644 <<'ENVIRONMENT'
export LANG=zh_CN.UTF-8
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
export XMODIFIERS='@im=fcitx'
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
ENVIRONMENT
    for rc in "$HOME/.profile" "$HOME/.bashrc"; do
        touch "$rc"
        backup "$rc"
        awk '
            /^# BEGIN wsl-ai-setup$/ { managed=1; next }
            /^# END wsl-ai-setup$/ { managed=0; next }
            managed { next }
            /^[[:space:]]*fcitx5[[:space:]]+--disable=wayland[[:space:]]+-d[[:space:]]+--replace([[:space:]].*)?$/ { next }
            /^[[:space:]]*eval \$\(dbus-launch --sh-syntax\)[[:space:]]*$/ { next }
            { print }
        ' "$rc" > "$TEMP_DIR/rc"
        cat >> "$TEMP_DIR/rc" <<'RC'
# BEGIN wsl-ai-setup
. "$HOME/.config/wsl-ai-setup/environment.sh"
# END wsl-ai-setup
RC
        cat "$TEMP_DIR/rc" > "$rc"
    done
    if [[ ! -e $CONFIG_DIR/fcitx5/profile ]]; then
        write_user_file "$CONFIG_DIR/fcitx5/profile" 600 <<'PROFILE'
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=pinyin
[Groups/0/Items/0]
Name=keyboard-us
Layout=
[Groups/0/Items/1]
Name=pinyin
Layout=
[GroupOrder]
0=Default
PROFILE
    fi
}

install_clipboard() {
    STEP=剪贴板
    mkdir -p "$HOME/.local/lib/xclip-x11/usr/bin"
    write_user_file "$HOME/.local/lib/xclip-x11/usr/bin/xclip" 755 < /usr/bin/xclip
    cat > "$TEMP_DIR/xclip" <<'XCLIP_SOURCE'
#!/bin/bash
# WSL clipboard bridge. Payloads cross the console as ASCII base64.
set -euo pipefail
umask 077

die() { printf 'xclip: %s\n' "$*" >&2; exit 1; }

direction=in
watch_mode=false
target=UTF8_STRING
selection=clipboard
files=()
while (($#)); do
    case "$1" in
        --watch) watch_mode=true ;;
        -o|-out) direction=out ;;
        -i|-in) direction=in ;;
        -selection|-sel) shift; (($#)) || die 'missing selection'; selection=$1 ;;
        -target|-t) shift; (($#)) || die 'missing target'; target=$1 ;;
        -silent|-quiet|-verbose) ;;
        -loops|-l) shift; (($#)) || die 'missing loop count' ;;
        -h|-help|--help)
            printf 'Usage: xclip [-in|-out] [-selection clipboard] [-target TARGET] [FILE...]\n'
            printf 'Run xclip --watch to bridge the Windows clipboard to Linux graphical applications.\n'
            printf 'Targets: UTF8_STRING, STRING, TEXT, text/plain, text/plain;charset=utf-8, image/png, TARGETS, text/uri-list\n'
            exit 0 ;;
        -version|--version) printf 'xclip WSL bridge 2.0\n'; exit 0 ;;
        --) shift; files+=("$@"); break ;;
        -*) die "unsupported option: $1" ;;
        *) files+=("$1") ;;
    esac
    shift
done
case "$selection" in
    clipboard|clip|c|primary|p|secondary|s) ;;
    *) die "unsupported selection: $selection" ;;
esac
# Windows has one shared clipboard, so X11 selection names map to it.
case "$target" in
    UTF8_STRING|STRING|TEXT|text/plain|text/plain\;charset=utf-8) kind=text ;;
    image/png) kind=image ;;
    TARGETS) kind=targets ;;
    text/uri-list) kind=uris ;;
    *) die "unsupported target: $target" ;;
esac
if [[ $direction == out && ${#files[@]} != 0 ]]; then
    die 'output mode does not accept input files'
fi
if [[ $direction == in && $kind != text && $kind != image ]]; then
    die 'this target is read-only'
fi

work=$(mktemp -d /tmp/xclip-request.XXXXXXXX)
copy_root=
producer=
keep_copy=false
cleanup() {
    if [[ -n $producer ]]; then kill "$producer" 2>/dev/null || true; wait "$producer" 2>/dev/null || true; fi
    rm -rf -- "$work"
    if [[ -n $copy_root && $keep_copy == false ]]; then
        chmod -R u+rwX -- "$copy_root" 2>/dev/null || true
        rm -rf -- "$copy_root"
    fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

copy_files() {
    : > "$work/paths"
    copy_root=$(mktemp -d /tmp/chatgpt-clipboard.XXXXXXXX)
    index=0
    while IFS= read -r path_b64 <&3; do
        [[ -n $path_b64 ]] || continue
        win_path=$(printf '%s' "$path_b64" | base64 -d) || die 'invalid file path payload'
        source_path=$(wslpath -u "$win_path") || die 'path conversion failed'
        [[ -f $source_path || -d $source_path ]] || die "source unavailable: $source_path"
        name=$(basename -- "$source_path")
        [[ $name != / && $name != . && $name != .. ]] || die 'cannot copy a filesystem root'
        index=$((index + 1))
        # Per-item subdirectories preserve duplicate basenames.
        mkdir -- "$copy_root/$index"
        cp -RL -- "$source_path" "$copy_root/$index/$name" || die "copy failed: $source_path"
        chmod -R u+rwX -- "$copy_root/$index" || die 'cannot set Linux copy permissions'
        destination="$copy_root/$index/$name"
        if [[ $kind == uris ]]; then
            # URI bytes are percent-encoded, including spaces and UTF-8.
            uri=
            LC_ALL=C
            for ((i=0; i<${#destination}; i++)); do
                char=${destination:i:1}
                case "$char" in
                    [a-zA-Z0-9/._~-]) uri+=$char ;;
                    *) printf -v hex '%%%02X' "'$char"; uri+=$hex ;;
                esac
            done
            printf 'file://%s\r\n' "$uri" >> "$work/paths"
        else
            printf '%s\n' "$destination" >> "$work/paths"
        fi
    done
    ((index > 0)) || die 'empty file list'
    # Publish paths only after every copy has completed successfully.
    keep_copy=true
    cat -- "$work/paths"
}

# Services may have a minimal PATH without WSL interop directories.
powershell=$(command -v powershell.exe || true)
if [[ -z $powershell ]]; then powershell=/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe; fi
[[ -x $powershell ]] || die 'Windows PowerShell executable is unavailable'

if [[ $watch_mode == true ]]; then
    native="$HOME/.local/lib/xclip-x11/usr/bin/xclip"
    [[ -x $native ]] || die 'native X11 xclip is missing from ~/.local/lib/xclip-x11'
    lock_dir="${XDG_RUNTIME_DIR:-$HOME/.cache}/xclip-bridge"
    mkdir -p -m 700 -- "$lock_dir"
    exec 9> "$lock_dir/lock"
    flock -n 9 || die 'a clipboard bridge is already running'
    watch_script=$(cat <<'WATCH_POWERSHELL'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class ClipboardSequence { [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber(); [DllImport("user32.dll")] public static extern IntPtr GetClipboardOwner(); [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint p); }'
$utf8 = New-Object System.Text.UTF8Encoding($false)
$previous = -1L
while ($true) {
    $sequence = [ClipboardSequence]::GetClipboardSequenceNumber()
    if ($sequence -ne $previous) {
        try {
            [uint32]$ownerPid = 0
            [void][ClipboardSequence]::GetWindowThreadProcessId([ClipboardSequence]::GetClipboardOwner(), [ref]$ownerPid)
            if ($ownerPid -ne 0) {
                $owner = (Get-Process -Id $ownerPid -ErrorAction SilentlyContinue).ProcessName
                # WSLg republishes Linux selections through its RDP client.
                # Ignore that echo so PNG selections remain PNG selections.
                if ($owner -eq 'msrdc' -or $owner -eq 'mstsc') {
                    $previous = $sequence
                    Start-Sleep -Milliseconds 150
                    continue
                }
            }
            $data = [System.Windows.Forms.Clipboard]::GetDataObject()
            $frame = 'TEXT '
            if ($null -ne $data -and $data.GetDataPresent('Bitmap')) {
                $image = $data.GetData('Bitmap')
                $stream = New-Object System.IO.MemoryStream
                try {
                    $image.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
                    $frame = 'IMAGE ' + [Convert]::ToBase64String($stream.ToArray())
                } finally { $stream.Dispose(); $image.Dispose() }
            } elseif ($null -ne $data -and $data.GetDataPresent('FileDrop')) {
                $paths = @($data.GetData('FileDrop') | ForEach-Object { [Convert]::ToBase64String($utf8.GetBytes([string]$_)) })
                $frame = 'FILES ' + ($paths -join ' ')
            } elseif ($null -ne $data -and $data.GetDataPresent('UnicodeText')) {
                $text = ([string]$data.GetData('UnicodeText')).Replace("`r`n", "`n").Replace("`r", "`n")
                $frame = 'TEXT ' + [Convert]::ToBase64String($utf8.GetBytes($text))
            }
            if ($null -ne $frame -and [ClipboardSequence]::GetClipboardSequenceNumber() -eq $sequence) {
                [Console]::WriteLine($frame)
                [Console]::Out.Flush()
                $previous = $sequence
            }
        } catch {
            [Console]::Error.WriteLine('clipboard watch: ' + $_.Exception.Message)
        }
    }
    Start-Sleep -Milliseconds 150
}
WATCH_POWERSHELL
)
    encoded=$(printf '%s' "$watch_script" | iconv -f UTF-8 -t UTF-16LE | base64 -w 0)
    mkfifo "$work/events"
    "$powershell" -NoLogo -NoProfile -NonInteractive -STA -EncodedCommand "$encoded" > "$work/events" < /dev/null &
    producer=$!
    last_source=
    last_published=
    while IFS=' ' read -r frame_type payload; do
        payload=${payload%$'\r'}
        source_hash=$(printf '%s %s' "$frame_type" "$payload" | sha256sum)
        [[ $source_hash != "$last_source" ]] || continue
        case "$frame_type" in
            IMAGE) mime=image/png; printf '%s' "$payload" | base64 -d > "$work/payload" ;;
            TEXT) mime=UTF8_STRING; printf '%s' "$payload" | base64 -d > "$work/payload" ;;
            FILES)
                mime=UTF8_STRING
                kind=text
                read -r -a encoded_paths <<< "$payload"
                printf '%s\n' "${encoded_paths[@]}" > "$work/file-paths"
                exec 3< "$work/file-paths"
                copy_files > "$work/payload"
                exec 3<&-
                ;;
            *) die 'invalid clipboard watch frame' ;;
        esac
        fingerprint="$mime $(sha256sum "$work/payload")"
        if [[ $fingerprint != "$last_published" ]]; then
            "$native" -selection clipboard -target "$mime" -i "$work/payload" 9>&-
            last_published=$fingerprint
            printf 'xclip bridge: published %s (%s bytes)\n' "$frame_type" "$(wc -c < "$work/payload")" >&2
        fi
        last_source=$source_hash
        copy_root=
        keep_copy=false
    done < "$work/events"
    die 'clipboard monitor stopped'
fi

ps_script=$(cat <<'POWERSHELL'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
function Emit([string]$type, [byte[]]$bytes) {
    [Console]::WriteLine($type)
    [Console]::WriteLine([Convert]::ToBase64String($bytes))
}
try {
    if ($operation -eq 'in') {
        $bytes = [Convert]::FromBase64String([Console]::In.ReadToEnd())
        if ($kind -eq 'image') {
            $stream = New-Object System.IO.MemoryStream(,$bytes)
            try {
                $image = [System.Drawing.Image]::FromStream($stream)
                try { [System.Windows.Forms.Clipboard]::SetImage($image) }
                finally { $image.Dispose() }
            } finally { $stream.Dispose() }
        } else {
            $text = $utf8.GetString($bytes).Replace("`r`n", "`n").Replace("`r", "`n")
            if ($text.Length -eq 0) { [System.Windows.Forms.Clipboard]::Clear() }
            else { [System.Windows.Forms.Clipboard]::SetText($text) }
        }
        exit 0
    }
    $data = $null
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try { $data = [System.Windows.Forms.Clipboard]::GetDataObject(); break }
        catch [System.Runtime.InteropServices.ExternalException] {
            if ($attempt -eq 4) { throw }
            Start-Sleep -Milliseconds 60
        }
    }
    $hasFiles = $null -ne $data -and $data.GetDataPresent('FileDrop')
    $hasImage = $null -ne $data -and $data.GetDataPresent('Bitmap')
    $hasText = $null -ne $data -and $data.GetDataPresent('UnicodeText')
    $pngFile = $null
    if ($hasFiles) {
        $paths = @($data.GetData('FileDrop'))
        if ($paths.Count -eq 1 -and [System.IO.Path]::GetExtension($paths[0]) -ieq '.png') {
            $pngFile = [string]$paths[0]
        }
    }
    if ($kind -eq 'targets') {
        $targets = @('TARGETS')
        if ($hasFiles -or $hasText) {
            $targets += @('UTF8_STRING', 'STRING', 'TEXT', 'text/plain', 'text/plain;charset=utf-8')
        }
        if ($hasFiles) { $targets += 'text/uri-list' }
        if ($hasImage -or $null -ne $pngFile) { $targets += 'image/png' }
        Emit 'DATA' ($utf8.GetBytes(($targets -join "`n") + "`n"))
    } elseif ($kind -eq 'image') {
        if ($hasImage) { $image = $data.GetData('Bitmap') }
        elseif ($null -ne $pngFile) { $image = [System.Drawing.Image]::FromFile($pngFile) }
        else { throw 'Clipboard has no bitmap image.' }
        $stream = New-Object System.IO.MemoryStream
        try {
            $image.Save($stream, [System.Drawing.Imaging.ImageFormat]::Png)
            Emit 'DATA' ($stream.ToArray())
        } finally { $stream.Dispose(); $image.Dispose() }
    } elseif ($hasFiles) {
        [Console]::WriteLine('FILES')
        foreach ($path in $data.GetData('FileDrop')) {
            [Console]::WriteLine([Convert]::ToBase64String($utf8.GetBytes([string]$path)))
        }
    } elseif ($kind -eq 'uris') {
        throw 'Clipboard has no file list.'
    } elseif ($hasText) {
        $text = [string]$data.GetData('UnicodeText')
        $text = $text.Replace("`r`n", "`n").Replace("`r", "`n")
        Emit 'DATA' ($utf8.GetBytes($text))
    } else {
        throw 'Clipboard has no text or files for this target.'
    }
} catch {
    [Console]::Error.WriteLine('xclip clipboard bridge: ' + $_.Exception.Message)
    exit 1
}
POWERSHELL
)
# Only fixed enum values are inserted into the PowerShell source.
encoded=$(printf "\$operation = '%s'\n\$kind = '%s'\n%s\n" "$direction" "$kind" "$ps_script" |
    iconv -f UTF-8 -t UTF-16LE | base64 -w 0)
if [[ $direction == in ]]; then
    if ((${#files[@]})); then cat -- "${files[@]}" > "$work/input"; else cat > "$work/input"; fi
    base64 -w 0 "$work/input" > "$work/input.b64"
    timeout 20s "$powershell" -NoLogo -NoProfile -NonInteractive -STA -EncodedCommand "$encoded" < "$work/input.b64"
    exit 0
fi
timeout 20s "$powershell" -NoLogo -NoProfile -NonInteractive -STA -EncodedCommand "$encoded" > "$work/response" < /dev/null ||
    die 'clipboard read failed'
# Only the ASCII transport is normalized. Decoded image bytes stay untouched.
tr -d '\r' < "$work/response" > "$work/protocol"
exec 3< "$work/protocol"
IFS= read -r response_kind <&3 || die 'empty clipboard bridge response'
case "$response_kind" in
    DATA)
        base64 -d <&3 > "$work/output" || die 'invalid clipboard payload'
        cat -- "$work/output"
        ;;
    FILES)
        copy_files
        ;;
    *) die 'unknown clipboard bridge response' ;;
esac
XCLIP_SOURCE
    bash -n "$TEMP_DIR/xclip"
    if ! cmp -s /usr/local/bin/xclip "$TEMP_DIR/xclip"; then
        backup /usr/local/bin/xclip
        sudo install -m 755 "$TEMP_DIR/xclip" /usr/local/bin/.xclip-wsl-ai-setup.$$
        sudo mv -f /usr/local/bin/.xclip-wsl-ai-setup.$$ /usr/local/bin/xclip
    fi
    sudo chmod 755 /usr/local/bin/xclip
    /usr/local/bin/xclip --version
}

configure_services() {
    STEP=后台服务
    write_user_file "$HOME/.local/bin/xclip-bridge-start" 755 <<'START'
#!/bin/bash
set -euo pipefail
for socket in /run/WSL/1_interop /run/WSL/*_interop; do
    if [[ -S $socket ]]; then
        export WSL_INTEROP="$socket"
        exec /usr/local/bin/xclip --watch
    fi
done
printf '未找到 WSL 互操作 socket\n' >&2
exit 1
START
    write_user_file "$CONFIG_DIR/systemd/user/xclip-bridge.service" 644 <<SERVICE
[Unit]
Description=Windows to WSL clipboard bridge
StartLimitIntervalSec=0
[Service]
Type=simple
ExecStart=/bin/bash %h/.local/bin/xclip-bridge-start
Environment="DISPLAY=$DISPLAY"
Environment="WSL_DISTRO_NAME=$WSL_DISTRO_NAME"
Restart=on-failure
RestartSec=3
KillMode=control-group
TimeoutStopSec=5
UMask=0077
[Install]
WantedBy=default.target
SERVICE
    if [[ $CLIPBOARD_ONLY == false ]]; then
        write_user_file "$CONFIG_DIR/systemd/user/wsl-fcitx5.service" 644 <<SERVICE
[Unit]
Description=Fcitx5 for WSLg
StartLimitIntervalSec=0
[Service]
ExecStart=/usr/bin/fcitx5 --disable=wayland --replace
Environment="DISPLAY=$DISPLAY"
Environment=GTK_IM_MODULE=fcitx
Environment=QT_IM_MODULE=fcitx
Environment=XMODIFIERS=@im=fcitx
Restart=on-failure
RestartSec=3
[Install]
WantedBy=default.target
SERVICE
    fi
    user_systemctl daemon-reload
    user_systemctl enable xclip-bridge.service
    # A manually started watch process owns the same lock and must be stopped by its terminal.
    user_systemctl restart xclip-bridge.service
    if [[ $CLIPBOARD_ONLY == false ]]; then
        user_systemctl enable wsl-fcitx5.service
        user_systemctl restart wsl-fcitx5.service
    fi
    sleep 3
    if ! user_systemctl is-active --quiet xclip-bridge.service; then
        journalctl --user -u xclip-bridge.service -n 20 --no-pager
        fail '桥接未持续运行。若另一个终端正在运行 xclip --watch，请在该终端按 Ctrl+C 后重试。'
    fi
    if [[ $CLIPBOARD_ONLY == false ]] && ! user_systemctl is-active --quiet wsl-fcitx5.service; then
        journalctl --user -u wsl-fcitx5.service -n 20 --no-pager
        fail 'Fcitx5 用户服务启动失败，请检查以上日志后重新运行。'
    fi
}

main() {
    parse_args "$@"
    if [[ $DRY_RUN == true ]]; then
        printf '计划安装中文环境=%s，系统升级=%s，磁盘TRIM=%s\n' \
            "$([[ $CLIPBOARD_ONLY == false ]] && echo 是 || echo 否)" "$UPGRADE" "$TRIM"
        printf '将安装 xclip 包、内嵌桥接源码、原生辅助程序、用户服务及自动启动。\n'
        printf '已有配置备份至 ~/.local/state/wsl-ai-setup/backups。\n'
        return
    fi
    if [[ $CHECK_ONLY == true ]]; then check_installation; return; fi
    preflight
    install_packages
    configure_wsl
    if [[ $CLIPBOARD_ONLY == false ]]; then configure_chinese; fi
    install_clipboard
    configure_services
    if [[ $TRIM == true ]]; then STEP=磁盘TRIM; sudo fstrim -v /; fi
    STEP=完成
    log "配置备份位于 $BACKUP_DIR"
    check_installation
    printf '\n请重新进入 WSL 用户会话，让中文与输入法环境变量生效。\n'
    printf '验证 Windows 文本、截图和文件在主聊天输入框的 Ctrl+V。\n'
    printf '开机后进入该 WSL 用户会话时，systemd 自动启动桥接；重启后的实际粘贴仍需验收。\n'
}

main "$@"
