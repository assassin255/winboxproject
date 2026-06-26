#!/usr/bin/env bash
set -euo pipefail

# Đảm bảo biến môi trường cơ bản khi chạy qua sudo su (HOME/USER có thể bị unset)
HOME="${HOME:-/root}"
USER="${USER:-$(id -un 2>/dev/null || echo root)}"
LOGNAME="${LOGNAME:-$USER}"
export HOME USER LOGNAME
NO_TUNING="${NO_TUNING:-0}"

# ════════════════════════════════════════════════════════════════
#  WINBOX
#  Rootless: build TẤT CẢ libs từ source thuần túy (zlib/libffi/pixman/pcre2/glib/libslirp)
#  aria2: static binary (primary, ~5s), fallback apt, fallback conda (chậm)
#  Conda: CHỈ dùng làm fallback cuối (aria2 conda rất chậm, 5-20 phút)
#  Fix: removed --user from pip install (virtualenv compatibility)
#  KVM: Auto detect /dev/kvm → enable KVM acceleration if available
#  NEW: CLI flags --auto --winXXXX để chạy hoàn toàn không tương tác
#  NEW: Tự động skip build nếu QEMU đã tồn tại (--rebuild để build lại)
#
#  Cách dùng:
#    bash winbox-stable.sh                          # chế độ interactive như cũ
#    bash winbox-stable.sh --auto --win2012         # auto, Windows Server 2012 R2
#    bash winbox.sh --auto --win2022         # auto, Windows Server 2022
#    bash winbox.sh --auto --win11           # auto, Windows 11 LTSB
#    bash winbox.sh --auto --win10ltsb       # auto, Windows 10 LTSB 2015
#    bash winbox.sh --auto --win10ltsc       # auto, Windows 10 LTSC 2023
#    bash winbox.sh --auto --win2012 --rdp   # auto + mở tunnel RDP
#    bash winbox.sh --iso=URL                # boot từ Windows ISO
#    bash winbox.sh --iso=URL --virtio=URL   # boot ISO + VirtIO driver
# ════════════════════════════════════════════════════════════════

# ── MÀU SẮC ────────────────────────────────────────────────────
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'
B='\033[1;34m'; C='\033[1;36m'; W='\033[0m'

# ── ROOTLESS BUILD PROGRESS ──────────────────────────────────────
_rl_step() {
    local _n="$1" _t="$2"
    printf "${B}[%s/%s]${W}\n" "$_n" "$_t"
}
_rl_ok()   { echo -e "${G}✔${W} $1"; }
_rl_fail() { echo -e "${R}✘${W} $1"; }
_rl_warn() { echo -e "${Y}⚠${W}  $1"; }


# ════════════════════════════════════════════════════════════════
#  BOOTSTRAP TOOLS — đảm bảo wget/curl/gnupg/ca-certificates có sẵn
# ════════════════════════════════════════════════════════════════
_bootstrap_tools() {
    local _apt=""
    if [[ "$(id -u)" == "0" ]] && command -v apt-get &>/dev/null; then _apt="apt-get"
    elif sudo -n true 2>/dev/null && command -v apt-get &>/dev/null; then _apt="sudo apt-get"; fi
    [[ -z "$_apt" ]] && return 0
    local _need=0
    for _t in wget curl gnupg ca-certificates; do command -v "$_t" &>/dev/null || _need=1; done
    [[ "$_need" == "0" ]] && return 0
    echo -e "${B}ℹ${W}  Bootstrap: cài công cụ thiết yếu (wget/curl/gnupg/ca-certificates)..."
    export DEBIAN_FRONTEND=noninteractive
    $_apt update -qq > /dev/null 2>&1 || true
    for _pkg in wget curl gnupg ca-certificates lsb-release; do
        command -v "$_pkg" &>/dev/null || $_apt install -y -qq "$_pkg" > /dev/null 2>&1 || true
    done
    command -v wget &>/dev/null && echo -e "${G}✔${W} wget sẵn sàng" || \
    command -v curl &>/dev/null && echo -e "${G}✔${W} curl sẵn sàng (wget vắng)" || true
}
_http_get() {
    local _url="$1" _out="${2:-}"
    if command -v wget &>/dev/null; then
        [[ -n "$_out" ]] && wget -qO "$_out" "$_url" || wget -qO- "$_url"
    elif command -v curl &>/dev/null; then
        [[ -n "$_out" ]] && curl -fsSL -o "$_out" "$_url" || curl -fsSL "$_url"
    else echo -e "${R}✘${W} Không có wget/curl" >&2; return 1; fi
}
_bootstrap_tools


# ════════════════════════════════════════════════════════════════
#  CLI ARGUMENT PARSER
#  --auto          : bỏ qua tất cả câu hỏi, chạy hoàn toàn tự động
#  --win2012       : Windows Server 2012 R2
#  --win2022       : Windows Server 2022
#  --win11         : Windows 11 LTSB
#  --win10ltsb     : Windows 10 LTSB 2015
#  --win10ltsc     : Windows 10 LTSC 2023
#  --rdp           : tự động mở tunnel RDP sau khi VM chạy
#  --build         : force build QEMU dù đã có sẵn
#  --no-build      : bỏ qua build QEMU
# ════════════════════════════════════════════════════════════════
AUTO_MODE=0        # 1 = không hỏi bất cứ gì
AUTO_WIN=""        # win choice preset: 1-5
AUTO_BUILD=""      # "yes" | "no" | "" (hỏi)
INSTANCE_ID=1      # VM instance id  (--id=N)
EXTRA_FWDS=()      # extra hostfwd   (--port-forward=HOST:GUEST)
STATUS_MODE=0      # --status
STOP_MODE=0        # --stop
RESTART_MODE=0     # --restart
SNAPSHOT_CMD=""    # --snapshot=save:NAME|load:NAME|list
RESIZE_IMG=""      # --resize=+XG
MONITOR_MODE=0     # --monitor (interactive QMP)
DELETE_BUILD_MODE=0  # --delete-build: xoá toàn bộ QEMU build
DELETE_ISO_MODE=0    # --delete-iso: xoá toàn bộ ISO cache
USE_HTTP_BACKEND=0  # --http-img: bật HTTP backend (không tải file)
SAFE_DOWNLOAD=0   # --safe-download: tải theo chunks 900MB (cho môi trường giới hạn)
ISO_MODE=0        # --iso: boot từ ISO thay vì tải Windows image
ISO_WIN_URL=""    # URL Windows ISO
ISO_VIRTIO_URL="" # URL VirtIO ISO (optional)

for _arg in "$@"; do
    case "$_arg" in
        --auto)       AUTO_MODE=1    ;;
        --win2012)    AUTO_WIN=1     ;;
        --win2022)    AUTO_WIN=2     ;;
        --win11)      AUTO_WIN=3     ;;
        --win10ltsb)  AUTO_WIN=4     ;;
        --win10ltsc)  AUTO_WIN=5     ;;
        --build|--rebuild) AUTO_BUILD="yes" ;;
        --no-build)   AUTO_BUILD="no"  ;;
        --http-img|--no-download) USE_HTTP_BACKEND=1 ;;
        --safe-download) SAFE_DOWNLOAD=1 ;;
        --id=*)       INSTANCE_ID="${_arg#--id=}" ;;
        --status)     STATUS_MODE=1 ;;
        --stop)       STOP_MODE=1   ;;
        --restart)    RESTART_MODE=1 ;;
        --monitor)    MONITOR_MODE=1 ;;
        --resize=*)   RESIZE_IMG="${_arg#--resize=}" ;;
        --snapshot=*) SNAPSHOT_CMD="${_arg#--snapshot=}" ;;
        --delete-build) DELETE_BUILD_MODE=1 ;;
        --delete-iso)   DELETE_ISO_MODE=1   ;;
        --port-forward=*|--fwd=*)
            _fwd="${_arg#*=}"; EXTRA_FWDS+=("$_fwd") ;;
        --iso=*)       ISO_MODE=1; ISO_WIN_URL="${_arg#--iso=}" ;;
        --iso)         ISO_MODE=1 ;;
        --virtio=*)    ISO_VIRTIO_URL="${_arg#--virtio=}" ;;
        --no-vnc)      WINBOX_VNC=0 ;;
        --help|-h)
            echo "Usage: bash winbox.sh [OPTIONS]"
            echo ""
            echo "  --auto          Chạy không tương tác (bắt buộc kết hợp với --winXXXX)"
            echo "  --win2012       Windows Server 2012 R2"
            echo "  --win2022       Windows Server 2022"
            echo "  --win11         Windows 11 LTSB"
            echo "  --win10ltsb     Windows 10 LTSB 2015"
            echo "  --win10ltsc     Windows 10 LTSC 2023"
            echo "  --build         Force build QEMU (dù đã có)"
            echo "  --rebuild       Alias của --build"
            echo "  --no-build      Bỏ qua build QEMU"
            echo "  --id=N          Multi-VM: instance id (RDP port=3388+N, default N=1)"
            echo "  --port-forward=H:G  Thêm hostfwd TCP (vd: --port-forward=8080:80)"
            echo "  --status        Xem thông tin VM đang chạy"
            echo "  --stop          Dừng VM gracefully (gửi ACPI shutdown)"
            echo "  --restart       Dừng rồi khởi động lại VM"
            echo "  --monitor       Vào interactive QMP shell"
            echo "  --snapshot=save:NAME|load:NAME|list  Quản lý snapshot"
            echo "  --resize=+XG    Mở rộng disk image (VM phải đang tắt)
  --safe-download Tải file theo chunks 900MB (cho môi trường giới hạn dung lượng)"
            echo "  --http-img      Dùng QEMU HTTP backend (không tải về)"
            echo "  --delete-build  Xoá toàn bộ QEMU build hiện tại (opt/home/rootless)"
            echo "  --delete-iso    Xoá toàn bộ ISO cache (~/.cache/winbox-iso)"
            echo "  --iso=URL       Boot từ Windows ISO (cần --virtio=URL cho driver)"
            echo "  --iso           Boot từ ISO (hỏi URL interactive)"
            echo "  --virtio=URL    VirtIO driver ISO URL (dùng với --iso)"
            echo "  Nếu QEMU đã có sẵn, script tự động bỏ qua build."
            echo "  Dùng --rebuild để build lại từ đầu."
            exit 0
            ;;
        *) echo -e "${Y}⚠${W}  Unknown argument: $_arg (bỏ qua)"; ;;
    esac
done

# Hàm ask có nhận biết AUTO_MODE
ask() {
    local prompt="$1"
    local default="$2"
    if [[ "$AUTO_MODE" == "1" ]]; then
        echo "$default"
        return
    fi
    read -rp "$prompt" ans
    ans="${ans,,}"
    echo "${ans:-$default}"
}

# ════════════════════════════════════════════════════════════════
#  INSTANCE PATHS  (derived from --id=N, default N=1)
# ════════════════════════════════════════════════════════════════
INSTANCE_ID="${INSTANCE_ID:-1}"
WINVM_RDP_PORT=$(( 3388 + INSTANCE_ID ))
WINVM_STATE_FILE="/tmp/winvm-${INSTANCE_ID}.state"
WINVM_QMP_SOCK="/tmp/winvm-${INSTANCE_ID}.qmp"
WINVM_PID_FILE="/tmp/winvm-${INSTANCE_ID}.pid"
WINVM_LOG="/tmp/winvm-${INSTANCE_ID}.log"
WINBOX_DISK_BUS="${WINBOX_DISK_BUS:-ide}"
WIN_IMG_PATH_BASE="${WIN_IMG_PATH_BASE:-win.img}"
WINBOX_NET_DEVICE="${WINBOX_NET_DEVICE:-auto}"
WINBOX_VNC="${WINBOX_VNC:-1}"

# ── Helpers: QMP send ────────────────────────────────────────────
_qmp() {
    local cmd="$1"
    if ! command -v socat &>/dev/null; then echo "socat not found"; return 1; fi
    if [[ ! -S "$WINVM_QMP_SOCK" ]]; then echo "QMP socket not found: $WINVM_QMP_SOCK"; return 1; fi
    printf '{"execute":"qmp_capabilities"}\n{"execute":"%s"}\n' "$cmd" \
        | socat - UNIX-CONNECT:"$WINVM_QMP_SOCK" 2>/dev/null | tail -1
}

# ── Early-exit handlers ──────────────────────────────────────────
if [[ "$STATUS_MODE" == "1" ]]; then
    echo -e "${C}══════════════════════════════════════${W}"
    echo -e "${C}🖥  VM STATUS (instance ${INSTANCE_ID})${W}"
    echo -e "${C}══════════════════════════════════════${W}"
    if [[ -f "$WINVM_PID_FILE" ]]; then
        PID_VM=$(cat "$WINVM_PID_FILE" 2>/dev/null)
        if [[ -n "$PID_VM" ]] && kill -0 "$PID_VM" 2>/dev/null; then
            echo -e "${G}🟢 RUNNING${W}  PID=$PID_VM"
            ps -o pid,etime,pcpu,rss,cmd --no-headers -p "$PID_VM" 2>/dev/null || true
            if [[ -f "$WINVM_STATE_FILE" ]]; then
                python3 -c "import json,sys; d=json.load(open(sys.argv[1])); [print(f\"   {k}: {v}\") for k,v in d.items()]" "$WINVM_STATE_FILE" 2>/dev/null || cat "$WINVM_STATE_FILE"
            fi
        else
            echo -e "${R}🔴 STOPPED / CRASHED${W}  (PID $PID_VM không còn)"
        fi
    else
        echo -e "${R}🔴 NOT RUNNING${W}  (no PID file for instance $INSTANCE_ID)"
    fi
    echo -e "${C}══════════════════════════════════════${W}"
    exit 0
fi

if [[ "$STOP_MODE" == "1" || "$RESTART_MODE" == "1" ]]; then
    PID_VM=$(cat "$WINVM_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$PID_VM" ]] && kill -0 "$PID_VM" 2>/dev/null; then
        echo -e "${B}ℹ${W}  Gửi system_powerdown qua QMP..."
        _qmp "system_powerdown" 2>/dev/null || true
        echo -ne "${B}◜${W} Chờ VM shutdown"
        for _i in $(seq 1 30); do
            kill -0 "$PID_VM" 2>/dev/null || { echo -e "\r${G}✔${W} VM stopped        "; break; }
            echo -ne "."; sleep 1
        done
        kill -0 "$PID_VM" 2>/dev/null && { kill -9 "$PID_VM" 2>/dev/null; echo -e "\r${Y}⚠${W} Force-killed VM"; }
    else
        echo -e "${Y}⚠${W}  Không có VM nào đang chạy (instance $INSTANCE_ID)"
    fi
    rm -f "$WINVM_PID_FILE" "$WINVM_STATE_FILE"
    [[ "$STOP_MODE" == "1" ]] && exit 0
    echo -e "${B}ℹ${W}  Khởi động lại VM..."
fi

if [[ "$MONITOR_MODE" == "1" ]]; then
    if [[ ! -S "$WINVM_QMP_SOCK" ]]; then
        echo -e "${R}✘${W}  QMP socket không tồn tại: $WINVM_QMP_SOCK"; exit 1
    fi
    echo -e "${C}QMP monitor — Ctrl+C để thoát${W}"
    echo -e "${B}ℹ${W}  Gõ lệnh JSON, vd: {"execute":"query-status"}"
    socat READLINE UNIX-CONNECT:"$WINVM_QMP_SOCK"
    exit 0
fi

if [[ -n "$SNAPSHOT_CMD" ]]; then
    if [[ ! -S "$WINVM_QMP_SOCK" ]] && [[ "$SNAPSHOT_CMD" != "list" ]]; then
        echo -e "${R}✘${W}  VM phải đang chạy để dùng snapshot"; exit 1
    fi
    case "$SNAPSHOT_CMD" in
        save:*)
            _sname="${SNAPSHOT_CMD#save:}"
            printf '{"execute":"qmp_capabilities"}\n{"execute":"savevm","arguments":{"name":"%s"}}\n' "$_sname" \
                | socat - UNIX-CONNECT:"$WINVM_QMP_SOCK" 2>/dev/null
            echo -e "${G}✔${W} Saved snapshot: $_sname" ;;
        load:*)
            _sname="${SNAPSHOT_CMD#load:}"
            printf '{"execute":"qmp_capabilities"}\n{"execute":"loadvm","arguments":{"name":"%s"}}\n' "$_sname" \
                | socat - UNIX-CONNECT:"$WINVM_QMP_SOCK" 2>/dev/null
            echo -e "${G}✔${W} Loaded snapshot: $_sname" ;;
        list)
            echo -e "${C}Snapshots trong win.img:${W}"
            qemu-img snapshot -l win.img 2>/dev/null || echo "(không có snapshot)"
            ;;
        *) echo -e "${R}✘${W}  Cú pháp: --snapshot=save:NAME|load:NAME|list"; exit 1 ;;
    esac
    exit 0
fi

if [[ -n "$RESIZE_IMG" ]]; then
    IMG="${WIN_IMG_OVERRIDE:-win.img}"
    [[ ! -f "$IMG" ]] && { echo -e "${R}✘${W}  Không tìm thấy $IMG"; exit 1; }
    PID_VM=$(cat "$WINVM_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$PID_VM" ]] && kill -0 "$PID_VM" 2>/dev/null; then
        echo -e "${R}✘${W}  VM đang chạy — phải stop trước: bash winbox.sh --stop --id=$INSTANCE_ID"; exit 1
    fi
    echo -e "${B}ℹ${W}  Resize $IMG += $RESIZE_IMG..."
    qemu-img resize "$IMG" "$RESIZE_IMG" && echo -e "${G}✔${W} Resize xong: $IMG $(qemu-img info "$IMG" | grep "virtual size")"
    exit 0
fi

if [[ "$DELETE_BUILD_MODE" == "1" ]]; then
    echo -e "${C}══════════════════════════════════════${W}"
    echo -e "${C}🗑️  XOÁ QEMU BUILD${W}"
    echo -e "${C}══════════════════════════════════════${W}"
    # Stop VM trước nếu đang chạy
    _PID=$(cat "$WINVM_PID_FILE" 2>/dev/null || echo "")
    if [[ -n "$_PID" ]] && kill -0 "$_PID" 2>/dev/null; then
        echo -e "${B}ℹ${W}  Dừng VM (PID $_PID) trước khi xoá..."
        kill -SIGTERM "$_PID" 2>/dev/null || true; sleep 2
        kill -0 "$_PID" 2>/dev/null && kill -SIGKILL "$_PID" 2>/dev/null || true
        echo -e "${G}✔${W} VM đã dừng"
    fi
    pkill -f 'qemu-system-x86_64' 2>/dev/null || true
    echo ""
    _DELETED=0
    _del_dir() {
        local d="$1" label="$2"
        if [[ -e "$d" ]]; then
            local _sz; _sz=$(du -sh "$d" 2>/dev/null | cut -f1 || echo "?")
            find "$d" -mindepth 1 -delete 2>/dev/null || true
            rmdir "$d" 2>/dev/null || true
            echo -e "${G}✔${W} Xoá ${label}: ${B}${d}${W} (${_sz})"
            _DELETED=$(( _DELETED + 1 ))
        else
            echo -e "${Y}—${W}  ${label}: ${d} (không có)"
        fi
    }
    _del_dir "/opt/qemu-optimized"         "opt build"
    _del_dir "$HOME/qemu-optimized"        "home build"
    _del_dir "$HOME/qemu-static"           "rootless build"
    _del_dir "$HOME/qemu-env"              "python venv"
    _del_dir "$HOME/qemu-build"            "rootless build dir"
    _del_dir "/tmp/qemu-src"               "QEMU source"
    _del_dir "/tmp/qemu-build"             "build artifacts"
    _del_dir "/tmp/qemu-pgo-prof"          "PGO profiles"
    _del_dir "/tmp/qemu-bolt-prof"         "BOLT profiles"
    # Clean logs
    rm -f /tmp/qemu-*.log /tmp/bolt-*.log /tmp/pip-*.log \
          /tmp/glib-*.log /tmp/venv-*.log 2>/dev/null || true
    echo -e "${G}✔${W} Logs dọn sạch"
    echo ""
    echo -e "${C}══════════════════════════════════════${W}"
    if [[ "$_DELETED" -gt 0 ]]; then
        echo -e "${G}✅ Xoá xong $_DELETED thư mục build${W}"
    else
        echo -e "${Y}⚠️  Không tìm thấy build nào để xoá${W}"
    fi
    echo -e "${B}ℹ${W}  Chạy lại script để build mới: bash winbox.sh --rebuild"
    echo -e "${C}══════════════════════════════════════${W}"
    exit 0
fi

if [[ "$DELETE_ISO_MODE" == "1" ]]; then
    echo -e "${C}══════════════════════════════════════${W}"
    echo -e "${C}🗑️  XOÁ ISO CACHE${W}"
    echo -e "${C}══════════════════════════════════════${W}"
    _ISO_DIR="$HOME/.cache/winbox-iso"
    if [[ ! -d "$_ISO_DIR" ]]; then
        echo -e "${Y}⚠️  Không tìm thấy ISO cache: $_ISO_DIR${W}"
        exit 0
    fi
    echo -e "${B}ℹ${W}  Thư mục: ${B}${_ISO_DIR}${W}"
    echo ""
    # Liệt kê files sẽ bị xóa
    _ISO_COUNT=0
    while IFS= read -r -d '' _f; do
        _fsz=$(stat -c%s "$_f" 2>/dev/null || echo 0)
        _fmb=$(( _fsz / 1024 / 1024 ))
        echo -e "   ${Y}•${W}  $(basename "$_f")  (${_fmb}MB)"
        _ISO_COUNT=$(( _ISO_COUNT + 1 ))
    done < <(find "$_ISO_DIR" -maxdepth 1 -type f -print0 2>/dev/null)
    if [[ "$_ISO_COUNT" -eq 0 ]]; then
        echo -e "${Y}⚠️  Không có file nào trong ISO cache${W}"
        exit 0
    fi
    echo ""
    read -rp "$(echo -e "${Y}?${W}  Xoá tất cả $_ISO_COUNT file trên? [y/N]: ")" _yn
    if [[ "${_yn,,}" != "y" ]]; then
        echo -e "${B}ℹ${W}  Huỷ — không xoá gì"
        exit 0
    fi
    _sz_total=$(du -sh "$_ISO_DIR" 2>/dev/null | cut -f1 || echo "?")
    rm -f "$_ISO_DIR"/*.iso "$_ISO_DIR"/*.aria2 "$_ISO_DIR"/*.qcow2 2>/dev/null || true
    echo -e "${G}✅ Đã xoá $_ISO_COUNT file (${_sz_total}) trong $_ISO_DIR${W}"
    echo -e "${C}══════════════════════════════════════${W}"
    exit 0
fi

# ════════════════════════════════════════════════════════════════
#  RESET ADMINISTRATOR PASSWORD OFFLINE
#  - chntpw clear Administrator pass trên SAM trích từ win.img
#  - LimitBlankPasswordUse=0 → cho phép RDP với pass trống
#  - Nếu NEW_PASS≠"" thì inject RunOnce để Windows set pass khi boot
# ════════════════════════════════════════════════════════════════
# ── Verify RDP connection (poll port, then xfreerdp /auth-only) ──
# ── SPINNER ─────────────────────────────────────────────────────
_SPIN_PID=""

spin_start() {
    local msg="${1:-Processing...}"
    printf "[*] %s\n" "$msg"
    _SPIN_PID=""
    local frames=('◜' '◝' '◞' '◟')
    (
        while :; do
            for f in "${frames[@]}"; do
                printf "\r${B}%s${W} %s" "$f" "$msg"
                sleep 0.1
            done
        done
    ) &
    _SPIN_PID=$!
    disown "$_SPIN_PID"
}

spin_stop() {
    local msg="${1:-Done}"
    if [[ -n "$_SPIN_PID" ]] && kill -0 "$_SPIN_PID" 2>/dev/null; then
        kill "$_SPIN_PID" 2>/dev/null
        wait "$_SPIN_PID" 2>/dev/null || true
    fi
    _SPIN_PID=""
    printf "\r${G}✔${W} %s\n" "$msg"
}

spin_fail() {
    local msg="${1:-Failed}"
    if [[ -n "$_SPIN_PID" ]] && kill -0 "$_SPIN_PID" 2>/dev/null; then
        kill "$_SPIN_PID" 2>/dev/null
        wait "$_SPIN_PID" 2>/dev/null || true
    fi
    _SPIN_PID=""
    printf "\r${R}✘${W} %s\n" "$msg"
}


_download_chunked() {
    local url="$1" output="$2" chunk_mb="${3:-900}"
    local chunk_bytes=$(( chunk_mb * 1024 * 1024 ))

    # Get file size
    local total_size=""
    total_size=$(curl -sI --max-time 15 "$url" 2>/dev/null         | grep -i '^content-length:' | tail -1 | awk '{print $2}'         | tr -d '\r\n') || true
    [[ -z "$total_size" || "$total_size" -lt 1024 ]] &&         total_size=$(wget --spider --server-response "$url" 2>&1         | grep -i 'Content-Length:' | tail -1         | awk '{print $2}' | tr -d '\r\n') || true

    if [[ -z "$total_size" || "$total_size" -lt 1024 ]]; then
        echo -e "${Y}⚠${W}  Không lấy được Content-Length — fallback tải 1 luồng..."
        if command -v aria2c &>/dev/null; then
            aria2c "${ARIA2_OPTS[@]}" \
                "$url" -o "$output"
        else
            wget --progress=dot:giga --continue "$url" -O "$output"
        fi
        return $?
    fi

    local num_chunks=$(( (total_size + chunk_bytes - 1) / chunk_bytes ))
    echo -e "${B}ℹ${W}  Tổng: $(( total_size / 1024 / 1024 ))MB → ${num_chunks} phần × ${chunk_mb}MB"

    truncate -s "$total_size" "$output" 2>/dev/null || \
        dd if=/dev/zero of="$output" bs=1 count=0 seek="$total_size" 2>/dev/null || true

    local _tmp; _tmp=$(mktemp /tmp/win_chunk_XXXXXX)
    local i start end part_num ok seek_blocks
    for i in $(seq 0 $((num_chunks - 1))); do
        start=$(( i * chunk_bytes ))
        end=$(( start + chunk_bytes - 1 ))
        [[ $end -ge $total_size ]] && end=$(( total_size - 1 ))
        part_num=$(( i + 1 ))
        echo -e "${B}ℹ${W}  Phần ${part_num}/${num_chunks} ($(( (end-start+1)/1024/1024 ))MB)..."
        ok=0
        for _try in 1 2 3; do
            if command -v aria2c &>/dev/null; then
                aria2c --header="Range: bytes=${start}-${end}" \
                    "${ARIA2_OPTS[@]}" \
                    "$url" -o "$_tmp" 2>&1 && ok=1 && break
            else
                curl -fL --range "${start}-${end}" --retry 3 \
                    --progress-bar -o "$_tmp" "$url" && ok=1 && break
            fi
            echo -e "${Y}⚠${W}  Thử lại lần ${_try}..."; sleep 3
        done
        if [[ "$ok" -eq 0 ]]; then
            rm -f "$_tmp"
            echo -e "${R}✘${W}  Phần ${part_num} thất bại"; return 1
        fi
        seek_blocks=$(( start / 512 ))
        dd if="$_tmp" of="$output" bs=512 seek="$seek_blocks" conv=notrunc 2>/dev/null
        rm -f "$_tmp"
        echo -e "${G}✔${W}  Phần ${part_num}/${num_chunks} xong"
    done
    echo -e "${G}✔${W}  Ghép xong: $(( total_size / 1024 / 1024 / 1024 ))GB"
}


# ── HÀM HỖ TRỢ ─────────────────────────────────────────────────
silent() { "$@" > /dev/null 2>&1; }

ver_lt() {
    [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]
}

# ── HÀM pip_install: cài vào $PIP_TARGET (tránh --user bị disable trên HPC) ──
PIP_TARGET=""   # set trong _rootless_build

pip_install() {
    local target="${PIP_TARGET:-}"
    if python3 -c "import sys; sys.exit(0 if sys.prefix != sys.base_prefix else 1)" 2>/dev/null; then
        # Đang trong venv → cài bình thường
        python3 -m pip install -q "$@"
    elif [[ -n "$target" ]]; then
        # HPC: cài vào thư mục riêng, tránh --user
        python3 -m pip install -q --target="$target" --no-warn-script-location "$@"
    else
        python3 -m pip install -q --user "$@" 2>/dev/null \
            || python3 -m pip install -q "$@"
    fi
}

# ════════════════════════════════════════════════════════════════
#  KVM DETECTION
#  Kiểm tra /dev/kvm bằng ls -l, xác nhận quyền root/kvm group
# ════════════════════════════════════════════════════════════════
KVM_AVAILABLE=0   # 1 = có thể dùng KVM
KVM_MODE=""       # "kvm" hoặc "tcg"

_detect_kvm() {
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔍 KIỂM TRA KVM ACCELERATION${W}"
    echo -e "${C}════════════════════════════════════${W}"

    # Bước 1: kiểm tra /dev/kvm tồn tại không
    if [[ ! -e /dev/kvm ]]; then
        echo -e "${Y}⚠${W}  /dev/kvm không tồn tại — dùng TCG"
        KVM_AVAILABLE=0
        KVM_MODE="tcg"
        return
    fi

    # Bước 2: ls -l /dev/kvm để xem owner/group/permission
    KVM_LS=$(ls -l /dev/kvm 2>/dev/null)
    :

    KVM_OWNER=$(echo "$KVM_LS" | awk '{print $3}')
    KVM_GROUP=$(echo "$KVM_LS" | awk '{print $4}')
    KVM_PERMS=$(echo "$KVM_LS" | awk '{print $1}')

    echo -e "   Owner : ${Y}${KVM_OWNER}${W} | Group : ${Y}${KVM_GROUP}${W}"
    echo -e "   Perms : ${B}${KVM_PERMS}${W}"

    # Bước 3: kiểm tra owner/group có nằm trong whitelist hợp lệ không
    #   HỢP LỆ:  owner=root  AND  group=root|kvm
    #   KHÔNG:   owner=nobody / nogroup / hoặc bất kỳ owner khác root
    CAN_USE_KVM=0

    if [[ "$KVM_OWNER" == "root" ]] && [[ "$KVM_GROUP" == "root" || "$KVM_GROUP" == "kvm" ]]; then
        echo -e "${G}✔${W}  /dev/kvm owner/group hợp lệ: ${Y}${KVM_OWNER}:${KVM_GROUP}${W}"

        # Bước 3a: nếu đang là root → dùng được ngay
        if [[ "$(id -u)" == "0" ]]; then
            CAN_USE_KVM=1
            echo -e "${G}✔${W}  Đang chạy với quyền root → có thể dùng KVM"

        # Bước 3b: không phải root → kiểm tra user có trong group kvm không
        else
            CURRENT_USER=$(id -un)
            CURRENT_GROUPS=$(id -Gn)
            if echo "$CURRENT_GROUPS" | grep -qw "$KVM_GROUP"; then
                CAN_USE_KVM=1
                echo -e "${G}✔${W}  User '${CURRENT_USER}' thuộc group '${KVM_GROUP}' → có thể dùng KVM"
            else
                echo -e "${Y}⚠${W}  User '${CURRENT_USER}' KHÔNG thuộc group '${KVM_GROUP}' → không dùng được KVM"
            fi
        fi

    else
        # owner/group không phải root:root hoặc root:kvm → coi như không dùng được
        echo -e "${R}✘${W}  /dev/kvm owner/group KHÔNG hợp lệ: ${Y}${KVM_OWNER}:${KVM_GROUP}${W}"
        echo -e "   Chỉ chấp nhận: ${G}root:root${W} hoặc ${G}root:kvm${W}"
        echo -e "   Phát hiện     : ${R}${KVM_OWNER}:${KVM_GROUP}${W} → fallback TCG"
        CAN_USE_KVM=0
    fi

    # Bước 4: nếu owner/group ok nhưng vẫn muốn double-check → thử -r -w
    if [[ $CAN_USE_KVM -eq 0 ]]; then
        if [[ -r /dev/kvm && -w /dev/kvm ]]; then
            CAN_USE_KVM=1
            echo -e "${G}✔${W}  /dev/kvm readable+writable (fallback check) → có thể dùng KVM"
        fi
    fi

    # Bước 4: thử chạy kvm-ok hoặc kiểm tra /proc/cpuinfo flags
    if [[ $CAN_USE_KVM -eq 1 ]]; then
        # Kiểm tra CPU có vmx/svm flag không
        if grep -qE '(vmx|svm)' /proc/cpuinfo 2>/dev/null; then
            echo -e "${G}✔${W}  CPU có hỗ trợ hardware virtualization (vmx/svm)"
            KVM_AVAILABLE=1
            KVM_MODE="kvm"
            echo -e "${G}🚀 KVM ACCELERATION: BẬT${W}"
        else
            echo -e "${Y}⚠${W}  CPU không có vmx/svm flag — KVM sẽ không hoạt động đúng"
            echo -e "${Y}⚠${W}  Fallback sang TCG"
            KVM_AVAILABLE=0
            KVM_MODE="tcg"
        fi
    else
        echo -e "${Y}⚠${W}  Không đủ quyền dùng /dev/kvm — dùng TCG"
        KVM_AVAILABLE=0
        KVM_MODE="tcg"
    fi

    echo -e "${C}════════════════════════════════════${W}"
    echo ""
}

# ════════════════════════════════════════════════════════════════
#  PACKAGE MANAGER — root → sudo apt → rootless build từ source
# ════════════════════════════════════════════════════════════════

APT_CMD=""
APT_OK=0
ROOTLESS=0

# aria2c max-speed flags — dùng chung mọi nơi
ARIA2_OPTS=(
    --split=16
    --max-connection-per-server=16
    --min-split-size=1M
    --max-concurrent-downloads=16
    --file-allocation=none
    --continue=true
    --check-certificate=false
    --max-tries=5
    --retry-wait=3
    --timeout=60
    --connect-timeout=15
    --piece-length=1M
    --human-readable=true
    --download-result=full
    --console-log-level=notice
    --summary-interval=3
)

_detect_apt() {
    echo -ne "${B}◜${W} Kiểm tra quyền package manager..."

    if [[ "$(id -u)" == "0" ]] && apt-get update -qq > /dev/null 2>&1; then
        APT_CMD="apt-get"
        APT_OK=1
        echo -e "\r${G}✔${W} Dùng apt-get (root)              "
        return
    fi

    if sudo -n true 2>/dev/null && sudo apt-get update -qq > /dev/null 2>&1; then
        APT_CMD="sudo apt-get"
        APT_OK=1
        echo -e "\r${G}✔${W} Dùng sudo apt-get                "
        return
    fi

    echo -e "\r${Y}⚠${W}  Không có apt — chuyển sang build rootless từ source"
    APT_OK=0
    ROOTLESS=1
}

apt_install() {
    local pkg="$1"
    $APT_CMD install -y -qq "$pkg" > /dev/null 2>&1
}

# ════════════════════════════════════════════════════════════════
#  BUILD LIBRARIES FROM SOURCE (khi không có conda)
# ════════════════════════════════════════════════════════════════

_build_zlib_from_source() {
    local prefix="$1"; local build_dir="$2"
    _rl_step "${_RL_N:-1}" "${_RL_T:-10}" "zlib 1.3.1"
    cd "$build_dir"
    rm -f zlib.tar.gz
    local _ok=0
    for _url in \
        "https://zlib.net/zlib-1.3.1.tar.gz" \
        "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz" \
        "https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz"; do
        wget -q --timeout=60 --tries=2 "$_url" -O zlib.tar.gz 2>/dev/null \
            && tar tzf zlib.tar.gz &>/dev/null && _ok=1 && break
        echo -e "${Y}⚠${W}  zlib URL thất bại: $_url"
    done
    [[ "$_ok" == "0" ]] && { echo -e "${R}✘${W} Không tải được zlib"; exit 1; }
    tar xzf zlib.tar.gz 2>/dev/null || { echo -e "${R}✘${W} Giải nén zlib thất bại"; exit 1; }
    local _d; _d=$(ls -d zlib-*/ 2>/dev/null | head -1 | tr -d /)
    [[ -d "$_d" ]] || { echo -e "${R}✘${W} Không tìm thấy thư mục zlib"; exit 1; }
    cd "$_d"
    # Patch out the "too harsh" if-block using python3 (safe: removes full if/fi block)
    python3 - configure <<'PYEOF'
import sys
fname = sys.argv[1]
with open(fname, 'r', errors='replace') as f:
    lines = f.readlines()
out = []
i = 0
while i < len(lines):
    line = lines[i]
    if line.strip().startswith('if ') or line.strip().startswith('if\t'):
        block = [line]
        depth = 1
        j = i + 1
        while j < len(lines) and depth > 0:
            bl = lines[j].strip()
            if bl.startswith('if ') or bl.startswith('if\t') or bl == 'if':
                depth += 1
            if bl == 'fi' or bl.startswith('fi;') or bl.startswith('fi '):
                depth -= 1
            block.append(lines[j])
            j += 1
        if 'too harsh' in ''.join(block):
            i = j
            continue
        else:
            out.extend(block)
            i = j
    else:
        out.append(line)
        i += 1
with open(fname, 'w') as f:
    f.writelines(out)
pass  # suppressed
PYEOF
    local _cc="${CC_PLAIN:-$(command -v gcc || command -v cc)}"
    local _cxx="${CXX_PLAIN:-$(command -v g++ || command -v c++)}"
    local _ar="${AR:-ar}"
    local _ranlib="${RANLIB:-ranlib}"

    # Ensure compiler bin dir in PATH so configure can find ar/ranlib
    local _cc_dir; _cc_dir="$(dirname "$_cc")"
    [[ -d "$_cc_dir" ]] && export PATH="$_cc_dir:$PATH"

    # Try shared first, fall back to static
    if env CC="$_cc" CXX="$_cxx" AR="$_ar" RANLIB="$_ranlib" \
        CFLAGS="-w -O2" CXXFLAGS="-w -O2" LDFLAGS="" \
        ./configure --prefix="$prefix" --shared > /tmp/zlib-build.log 2>&1; then
        : # shared OK
    else
        env CC="$_cc" CXX="$_cxx" AR="$_ar" RANLIB="$_ranlib" \
            CFLAGS="-w -O2" CXXFLAGS="-w -O2" LDFLAGS="" \
            ./configure --prefix="$prefix" > /tmp/zlib-build.log 2>&1 \
            || { echo -e "${R}✘${W} Configure zlib thất bại — xem /tmp/zlib-build.log"; exit 1; }
    fi
    ${MAKE:-make} -j"$(nproc)" AR="$_ar" RANLIB="$_ranlib" >> /tmp/zlib-build.log 2>&1 \
        || { echo -e "${R}✘${W} Build zlib thất bại — xem /tmp/zlib-build.log"; exit 1; }
    ${MAKE:-make} install AR="$_ar" RANLIB="$_ranlib" >> /tmp/zlib-build.log 2>&1 \
        || { echo -e "${R}✘${W} Install zlib thất bại — xem /tmp/zlib-build.log"; exit 1; }
    _rl_ok "zlib 1.3.1 xong"
    echo "libffi" > "$BUILD/.rootless-resume"
}

_build_libffi_from_source() {
    local prefix="$1"; local build_dir="$2"
    _rl_step "${_RL_N:-2}" "${_RL_T:-10}" "libffi 3.4.6"
    cd "$build_dir"
    rm -f libffi.tar.gz
    wget -q --timeout=60 --tries=2 \
        "https://github.com/libffi/libffi/releases/download/v3.4.6/libffi-3.4.6.tar.gz" \
        -O libffi.tar.gz 2>/dev/null \
        || wget -q --timeout=60 --tries=2 \
        "https://sourceware.org/pub/libffi/libffi-3.4.6.tar.gz" \
        -O libffi.tar.gz 2>/dev/null \
        || { echo -e "${R}✘${W} Không tải được libffi"; exit 1; }
    tar xzf libffi.tar.gz 2>/dev/null || { echo -e "${R}✘${W} Giải nén libffi thất bại"; exit 1; }
    cd libffi-3.4.6
    local _cc="${CC_PLAIN:-$(command -v gcc || command -v cc)}"
    local _ar="${AR:-ar}"
    local _ranlib="${RANLIB:-ranlib}"
    local _cc_dir; _cc_dir="$(dirname "$_cc")"
    [[ -d "$_cc_dir" ]] && export PATH="$_cc_dir:$PATH"
    env CC="$_cc" AR="$_ar" RANLIB="$_ranlib" \
        ./configure --prefix="$prefix" > /tmp/libffi-build.log 2>&1 \
        || { echo -e "${R}✘${W} Configure libffi thất bại"; exit 1; }
    ${MAKE:-make} -j"$(nproc)" AR="$_ar" RANLIB="$_ranlib" >> /tmp/libffi-build.log 2>&1 \
        || { echo -e "${R}✘${W} Build libffi thất bại"; exit 1; }
    ${MAKE:-make} install AR="$_ar" RANLIB="$_ranlib" >> /tmp/libffi-build.log 2>&1 \
        || { echo -e "${R}✘${W} Install libffi thất bại"; exit 1; }
    _rl_ok "libffi 3.4.6 xong"
    echo "pixman" > "$BUILD/.rootless-resume"
}

_build_pixman_from_source() {
    local prefix="$1"; local build_dir="$2"
    _rl_step "${_RL_N:-3}" "${_RL_T:-10}" "pixman 0.42.2"
    cd "$build_dir"
    rm -f pixman.tar.gz
    wget -q --timeout=60 --tries=2 \
        "https://cairographics.org/releases/pixman-0.42.2.tar.gz" \
        -O pixman.tar.gz 2>/dev/null \
        || { echo -e "${R}✘${W} Không tải được pixman"; exit 1; }
    tar xzf pixman.tar.gz 2>/dev/null || { echo -e "${R}✘${W} Giải nén pixman thất bại"; exit 1; }
    cd pixman-0.42.2
    local _cc="${CC_PLAIN:-$(command -v gcc || command -v cc)}"
    local _ar="${AR:-ar}"
    local _ranlib="${RANLIB:-ranlib}"
    local _cc_dir; _cc_dir="$(dirname "$_cc")"
    [[ -d "$_cc_dir" ]] && export PATH="$_cc_dir:$PATH"
    env CC="$_cc" AR="$_ar" RANLIB="$_ranlib" \
        ./configure --prefix="$prefix" --disable-gtk --enable-shared \
        > /tmp/pixman-build.log 2>&1 \
        || { echo -e "${R}✘${W} Configure pixman thất bại"; exit 1; }
    ${MAKE:-make} -j"$(nproc)" AR="$_ar" RANLIB="$_ranlib" >> /tmp/pixman-build.log 2>&1 \
        || { echo -e "${R}✘${W} Build pixman thất bại"; exit 1; }
    ${MAKE:-make} install AR="$_ar" RANLIB="$_ranlib" >> /tmp/pixman-build.log 2>&1 \
        || { echo -e "${R}✘${W} Install pixman thất bại"; exit 1; }
    _rl_ok "pixman 0.42.2 xong"
    echo "glib" > "$BUILD/.rootless-resume"
}

# ── Thử dùng glib từ conda (nhanh, không cần build) ─────────────
_try_glib_from_conda() {
    local prefix="$1"
    local _GLIB_MIN="2.66.0"

    # helper: trả về 0 nếu version trong .pc >= _GLIB_MIN
    _glib_pc_ver_ok() {
        local _pc="$1/glib-2.0.pc"
        [[ -f "$_pc" ]] || return 1
        local _v
        _v=$(grep "^Version:" "$_pc" 2>/dev/null | awk '{print $2}')
        python3 -c "
a=[int(x) for x in '$_v'.split('.')]
b=[int(x) for x in '${_GLIB_MIN}'.split('.')]
exit(0 if a>=b else 1)
" 2>/dev/null
    }

    # Tìm libglib-2.0.so trong conda
    local _glib_so=""
    for _d in /opt/conda/lib /opt/conda/envs/base/lib "$HOME/.conda/envs/base/lib"; do
        if [[ -f "$_d/libglib-2.0.so" || -f "$_d/libglib-2.0.so.0" ]]; then
            _glib_so="$_d"; break
        fi
    done
    # Kiểm tra pkg-config glib-2.0 từ conda
    local _conda_pc=""
    for _pd in /opt/conda/lib/pkgconfig /opt/conda/share/pkgconfig; do
        [[ -f "$_pd/glib-2.0.pc" ]] && { _conda_pc="$_pd"; break; }
    done
    if [[ -n "$_conda_pc" ]]; then
        # ── Version check: cần >= 2.66.0 ────────────────────────
        if ! _glib_pc_ver_ok "$_conda_pc"; then
            local _found_ver
            _found_ver=$(grep "^Version:" "$_conda_pc/glib-2.0.pc" 2>/dev/null | awk '{print $2}')
            echo -e "${Y}⚠${W}  conda glib ${_found_ver} < ${_GLIB_MIN} — bỏ qua, sẽ build từ source"
            # Không dùng conda glib cũ; fallthrough xuống conda install / build source
        else
            local _found_ver
            _found_ver=$(grep "^Version:" "$_conda_pc/glib-2.0.pc" 2>/dev/null | awk '{print $2}')
            echo -e "${G}✔${W} glib ${_found_ver} tìm thấy trong conda (${_conda_pc}) — bỏ qua build source"
            # KHÔNG copy .pc vào prefix: conda glib build với conda toolchain có
            # GLIB_SIZEOF_SIZE_T khác system gcc → ABI mismatch khi QEMU configure.
            # Thay vào đó: chỉ export header path + LD path, để QEMU meson detect qua
            # PKG_CONFIG_PATH trỏ thẳng vào conda (không qua prefix copy).
            export PKG_CONFIG_PATH="$_conda_pc:${PKG_CONFIG_PATH:-}"
            export PKG_CONFIG_LIBDIR="$_conda_pc:${PKG_CONFIG_LIBDIR:-}"
            # Export LD path
            [[ -n "$_glib_so" ]] && export LD_LIBRARY_PATH="$_glib_so:${LD_LIBRARY_PATH:-}"
            # Mark: đây là conda glib → QEMU configure dùng --without-system-glib nếu cần
            export _GLIB_FROM_CONDA=1
            return 0
        fi  # end version-ok branch
    fi
    # Thử conda install glib nếu có conda
    if command -v conda &>/dev/null; then
        echo -e "${B}ℹ${W}  Thử conda install glib (1-2 phút)..."
        conda install -c conda-forge glib --yes -q > /tmp/conda-glib.log 2>&1 \
            && echo -e "${G}✔${W} conda install glib xong" \
            || { echo -e "${Y}⚠${W}  conda install glib thất bại — sẽ build từ source"; return 1; }
        # Reload + version check
        for _pd in /opt/conda/lib/pkgconfig /opt/conda/share/pkgconfig; do
            if [[ -f "$_pd/glib-2.0.pc" ]]; then
                if ! _glib_pc_ver_ok "$_pd"; then
                    local _cv
                    _cv=$(grep "^Version:" "$_pd/glib-2.0.pc" 2>/dev/null | awk '{print $2}')
                    echo -e "${Y}⚠${W}  conda install glib ${_cv} vẫn < ${_GLIB_MIN} — build từ source"
                    return 1
                fi
                export PKG_CONFIG_PATH="$_pd:${PKG_CONFIG_PATH:-}"
                mkdir -p "$prefix/lib/pkgconfig"
                for _pc in "$_pd"/glib-2.0.pc "$_pd"/gobject-2.0.pc \
                           "$_pd"/gmodule-2.0.pc "$_pd"/gio-2.0.pc; do
                    [[ -f "$_pc" ]] && cp -f "$_pc" "$prefix/lib/pkgconfig/" 2>/dev/null || true
                done
                export LD_LIBRARY_PATH="/opt/conda/lib:${LD_LIBRARY_PATH:-}"
                echo -e "${G}✔${W} glib từ conda sẵn sàng"
                return 0
            fi
        done
    fi
    return 1  # không tìm được — caller sẽ build từ source
}

_build_glib_from_source() {
    local prefix="$1"; local build_dir="$2"; local py_prefix="$3"

    # ── Primary: build glib từ source thuần túy ─────────────────
    # Conda KHÔNG được dùng làm nguồn chính cho glib vì:
    #   conda glib-2.0.pc có Requires: libpcre2-8, nhưng libpcre2-8.pc
    #   không có trong conda → QEMU meson thất bại với "libpcre2-8 not found"
    # Conda chỉ là FALLBACK nếu source build thất bại hoàn toàn.


    # ── Helper: build pcre2 từ source nếu chưa có ───────────────
    _ensure_pcre2() {
        local _ppc="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
        # Kiểm tra pcre2 đã build chưa — dùng pkg-config nếu có, fallback kiểm tra file .pc trực tiếp
        if command -v pkg-config &>/dev/null; then
            PKG_CONFIG_PATH="$_ppc" pkg-config --exists libpcre2-8 2>/dev/null && return 0
        else
            [[ -f "$prefix/lib/pkgconfig/libpcre2-8.pc" || \
               -f "$prefix/lib64/pkgconfig/libpcre2-8.pc" ]] && return 0
        fi
        _rl_step "${_RL_N:-4}" "${_RL_T:-10}" "pcre2 10.42"
        local _p2dir="$build_dir/pcre2-src"
        mkdir -p "$_p2dir"; cd "$_p2dir"
        local _p2ok=0
        for _u in \
            "https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.42/pcre2-10.42.tar.gz" \
            "https://sourceforge.net/projects/pcre/files/pcre2/10.42/pcre2-10.42.tar.gz/download"; do
            wget -q --no-check-certificate -O pcre2.tar.gz "$_u" 2>/dev/null \
                && tar xzf pcre2.tar.gz 2>/dev/null && { _p2ok=1; break; }
        done
        [[ $_p2ok -eq 0 ]] && { echo -e "${R}✘${W} Không tải được pcre2"; return 1; }
        cd pcre2-10.42
        ./configure --prefix="$prefix" --enable-static --disable-shared \
            --enable-pcre2-8 --disable-pcre2-16 --disable-pcre2-32 \
            --disable-jit > /tmp/pcre2-build.log 2>&1 \
            && make -j"$(nproc)" >> /tmp/pcre2-build.log 2>&1 \
            && make install   >> /tmp/pcre2-build.log 2>&1 \
            || { echo -e "${R}✘${W} pcre2 build thất bại — xem /tmp/pcre2-build.log"; return 1; }
        _rl_ok "pcre2 10.42 xong"
    }

    # ── Ưu tiên 2: build glib 2.76.6 từ source ──────────────────
    # Dùng 2.76.6 (không 2.78.x): glib 2.78+ có bug glib-enumtypes codegen
    # với meson 1.x khi python3 trong PATH là conda python — sinh lỗi:
    # "build/-c: not found" do meson pass PYTHON -c như single string.
    local GLIB_VER="2.76.6"
    local GLIB_MAJ="2.76"
    _rl_step "${_RL_N:-5}" "${_RL_T:-10}" "glib ${GLIB_VER}"

    # pcre2 là hard dep từ glib 2.73+ — đảm bảo có trước khi build
    _ensure_pcre2 || exit 1

    # ── Cache check: nếu glib đã build xong → skip ──────────────
    if [[ -f "$prefix/lib/libglib-2.0.a" || -f "$prefix/lib/libglib-2.0.so" \
       || -f "$prefix/lib64/libglib-2.0.a" ]]; then
        local _cached_ver
        _cached_ver=$(PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig:${PKG_CONFIG_PATH:-}" \
                      pkg-config --modversion glib-2.0 2>/dev/null || echo "?")
        echo -e "${G}✔${W} glib ${_cached_ver} đã có trong cache ($prefix) — bỏ qua build"
        export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
        return 0
    fi

    cd "$build_dir"
    rm -f glib.tar.xz
    local _glib_ok=0
    for _url in \
        "https://download.gnome.org/sources/glib/${GLIB_MAJ}/glib-${GLIB_VER}.tar.xz" \
        "https://ftp.gnome.org/pub/gnome/sources/glib/${GLIB_MAJ}/glib-${GLIB_VER}.tar.xz"; do
        wget -c -q --timeout=120 --tries=2 "$_url" -O glib.tar.xz 2>/dev/null \
            && python3 -c "import lzma; lzma.open('glib.tar.xz').read(1024)" 2>/dev/null \
            && _glib_ok=1 && break
        echo -e "${Y}⚠${W}  glib URL thất bại: $_url"
    done
    if [[ "$_glib_ok" == "0" ]]; then
        echo -e "${R}✘${W}  Không tải được glib ${GLIB_VER} từ source."
        echo -e "${Y}⚠${W}  Conda glib fallback bị loại bỏ: ABI mismatch với system gcc trên môi trường này."
        echo -e "${Y}⚠${W}  Kiểm tra kết nối internet hoặc thêm mirror URL cho glib tarball."
        exit 1
    fi
    python3 -c "
import lzma, tarfile
with lzma.open('glib.tar.xz') as f:
    with tarfile.open(fileobj=f) as t:
        t.extractall('.')
" || { echo -e "${R}✘${W} Giải nén glib thất bại"; exit 1; }
    cd "glib-${GLIB_VER}"
    mkdir -p build; cd build

    # ── Detect meson ──────────────────────────────────────────────
    local meson_cmd=""
    if   [[ -x "${PIP_TARGET:-}/bin/meson" ]];   then meson_cmd="${PIP_TARGET}/bin/meson"
    elif [[ -x "$py_prefix/bin/meson" ]];         then meson_cmd="$py_prefix/bin/meson"
    elif command -v meson &>/dev/null;             then meson_cmd="$(command -v meson)"
    elif python3 -c "import mesonbuild" &>/dev/null 2>&1; then
        # Tạo Python script thực — KHÔNG dùng shell -c vì meson dùng sys.argv[0]
        # để tìm binary path → "-c" gây ra "build/-c: not found".
        cat > /tmp/_meson_wrap.py <<'MESONPY'
#!/usr/bin/env python3
import sys
from mesonbuild.mesonmain import main
sys.exit(main())
MESONPY
        chmod +x /tmp/_meson_wrap.py
        meson_cmd="/tmp/_meson_wrap.py"
    else
        echo -e "${R}✘${W} meson không tìm thấy — không thể build glib"; exit 1
    fi
    # Nếu meson_cmd là shell script dùng python3 -c "..." → replace bằng Python wrapper
    # (conda meson hoặc pip wrapper cũ có cùng bug "build/-c: not found")
    if [[ -f "$meson_cmd" ]] && head -3 "$meson_cmd" 2>/dev/null | grep -q "python.*-c"; then
        python3 -c "import mesonbuild" &>/dev/null 2>&1 || \
            PYTHONPATH="${PIP_TARGET:-}:${PYTHONPATH:-}" python3 -c "import mesonbuild" &>/dev/null 2>&1
        if PYTHONPATH="${PIP_TARGET:-}:${PYTHONPATH:-}" python3 -c "import mesonbuild" &>/dev/null 2>&1; then
            cat > /tmp/_meson_wrap.py <<MESONPY2
#!/usr/bin/env python3
import sys, os
_pt = os.environ.get('PIP_TARGET', '${PIP_TARGET:-}')
if _pt: sys.path.insert(0, _pt)
from mesonbuild.mesonmain import main
sys.exit(main())
MESONPY2
            chmod +x /tmp/_meson_wrap.py
            :
            meson_cmd="/tmp/_meson_wrap.py"
        fi
    fi

    # ── Detect ninja ──────────────────────────────────────────────
    local ninja_cmd=""
    if   [[ -x "${PIP_TARGET:-}/bin/ninja" ]];   then ninja_cmd="${PIP_TARGET}/bin/ninja"
    elif command -v ninja &>/dev/null;             then ninja_cmd="$(command -v ninja)"
    elif command -v ninja-build &>/dev/null;       then ninja_cmd="$(command -v ninja-build)"
    else
        local _nj_bin
        _nj_bin=$(find "${PIP_TARGET:-/nonexistent}" -name "ninja" -type f \
            ! -name "*.py" ! -name "*.pyc" ! -path "*__pycache__*" 2>/dev/null | head -1 || true)
        if [[ -n "$_nj_bin" && -x "$_nj_bin" ]]; then ninja_cmd="$_nj_bin"
        else echo -e "${R}✘${W} ninja không tìm thấy"; exit 1; fi
    fi


    # Fix: khi build glib từ source, PHẢI isolate PKG_CONFIG_PATH khỏi conda.
    # Nếu để conda path lẫn vào, pkg-config trả về glib của conda → meson so sánh
    # sizeof(size_t) từ conda glib với system glib → mismatch → lỗi GLIB_SIZEOF_SIZE_T.
    # Chỉ trỏ vào $prefix (libs vừa build từ source: zlib, libffi, pcre2...).
    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig"
    # PKG_CONFIG_LIBDIR override hoàn toàn mọi default path (bao gồm cả conda)
    export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig"

    # Đảm bảo $prefix/bin trong PATH và libs tìm được
    export PATH="$prefix/bin:${PATH}"
    # prefix lib trước conda lib để source-built .so được ưu tiên
    export LD_LIBRARY_PATH="$prefix/lib:$prefix/lib64:${CONDA_ROOT:-/opt/conda}/lib:${LD_LIBRARY_PATH:-}"

    # Tìm pkg-config: ưu tiên $prefix/bin (self-built), KHÔNG dùng conda pkg-config trực tiếp
    # vì conda pkg-config có hardcoded conda paths ignore PKG_CONFIG_LIBDIR.
    local _pc_bin=""
    if [[ -x "$prefix/bin/pkg-config" ]] && "$prefix/bin/pkg-config" --version &>/dev/null; then
        _pc_bin="$prefix/bin/pkg-config"
    elif [[ -x "$(command -v pkgconf 2>/dev/null || true)" ]]; then
        _pc_bin="$(command -v pkgconf)"
    fi
    # Nếu chỉ có conda pkg-config: tạo wrapper script tôn trọng PKG_CONFIG_LIBDIR
    if [[ -z "$_pc_bin" ]] && [[ -x "${CONDA_ROOT:-/opt/conda}/bin/pkg-config" ]]; then
        local _pc_wrapper="$prefix/bin/pkg-config"
        mkdir -p "$prefix/bin"
        cat > "$_pc_wrapper" <<PCWRAP
#!/bin/sh
exec env PKG_CONFIG_SYSTEM_LIBRARY_PATH="" \
     ${CONDA_ROOT:-/opt/conda}/bin/pkg-config "\$@"
PCWRAP
        chmod +x "$_pc_wrapper"
        _pc_bin="$_pc_wrapper"
        :
    fi
    local _no_pkgconfig=0
    if [[ -n "$_pc_bin" ]]; then
        export PKG_CONFIG="$_pc_bin"
        :
        :
    else
        echo -e "${Y}⚠${W}  Không tìm được pkg-config hoạt động — dùng pcre2=internal fallback"
        _no_pkgconfig=1
    fi

    # Helper: chỉ add option nếu glib version này có khai báo trong meson_options.txt
    _has_opt() { grep -qE "option\s*\(\s*'$1'" ../meson_options.txt 2>/dev/null; }

    # Flags luôn hợp lệ cho mọi glib version
    local _meson_flags=(
        --prefix="$prefix"
        --buildtype=plain
        -Dauto_features=disabled
        -Dlibdir="lib"
        -Dman=false
        -Dgtk_doc=false
        -Dlibmount=disabled
        -Dselinux=disabled
        -Ddtrace=false
        -Dsystemtap=false
        -Dlibelf=disabled
    )
    # Thêm options tuỳ theo glib version (tránh "Unknown option" với meson 1.11+)
    _has_opt tests            && _meson_flags+=(-Dtests=false)
    _has_opt installed_tests  && _meson_flags+=(-Dinstalled_tests=false)
    _has_opt xattr            && _meson_flags+=(-Dxattr=false)
    _has_opt nls              && _meson_flags+=(-Dnls=disabled)
    _has_opt introspection    && _meson_flags+=(-Dintrospection=disabled)

    # pcre2: nếu pkg-config hoạt động → glib tự detect qua PKG_CONFIG_PATH (pcre2 đã build từ source)
    # nếu pkg-config KHÔNG hoạt động → dùng -Dpcre2=internal để meson tự build pcre2 từ wrap
    if [[ "$_no_pkgconfig" == "1" ]]; then
        _has_opt pcre2 && _meson_flags+=(-Dpcre2=internal)
        # wrap-mode=nofallback: cho phép internal subproject nhưng không download wrap bên ngoài
        _meson_flags+=(--wrap-mode=nofallback)
        :
    else
        _has_opt pcre2 && _meson_flags+=(-Dpcre2=enabled)
        _meson_flags+=(--wrap-mode=nodownload)
    fi

    local _meson_exit=0
    : # meson setup
( _hb=0; while :; do sleep 30; _hb=$((_hb+1)); printf "[~] meson setup: %d min...
" "$((_hb/2))"; done ) &
_HB_MESON=$!
timeout 3600 "$meson_cmd" setup . .. "${_meson_flags[@]}" > /tmp/glib-meson.log 2>&1
kill "$_HB_MESON" 2>/dev/null; wait "$_HB_MESON" 2>/dev/null || true
_meson_exit=$?; :
    if [[ $_meson_exit -eq 124 ]]; then
        echo -e "${R}✘${W} meson setup glib TIMEOUT (>3600s) — xem /tmp/glib-meson.log"
        tail -30 /tmp/glib-meson.log; exit 1
    elif [[ $_meson_exit -ne 0 ]]; then
        echo -e "${R}✘${W}  meson glib thất bại (exit $_meson_exit) — xem /tmp/glib-meson.log"
        tail -30 /tmp/glib-meson.log
        echo -e "${Y}⚠${W}  Conda glib fallback bị loại bỏ (ABI mismatch với system gcc)."
        echo -e "${Y}⚠${W}  Xoá build cache và thử lại: rm -rf ~/qemu-static ~/qemu-build"
        exit 1
    fi
    local _ninja_exit=0
    :
( _hb=0; while :; do sleep 30; _hb=$((_hb+1)); printf "[~] glib build: %d min elapsed...\n" "$((_hb/2))"; done ) &
_HB_GLIB=$!
timeout 900 "$ninja_cmd" -j"$(nproc)" > /tmp/glib-build.log 2>&1 || _ninja_exit=$?
kill "$_HB_GLIB" 2>/dev/null; wait "$_HB_GLIB" 2>/dev/null || true
:
    if [[ $_ninja_exit -eq 124 ]]; then
        echo -e "${R}✘${W} ninja glib TIMEOUT (>900s)"; tail -20 /tmp/glib-build.log; exit 1
    elif [[ $_ninja_exit -ne 0 ]]; then
        echo -e "${R}✘${W}  ninja glib thất bại — xem /tmp/glib-build.log"
        tail -20 /tmp/glib-build.log
        echo -e "${Y}⚠${W}  Conda glib fallback bị loại bỏ (ABI mismatch với system gcc)."
        echo -e "${Y}⚠${W}  Xoá build cache và thử lại: rm -rf ~/qemu-static ~/qemu-build"
        exit 1
    fi
    timeout 120 "$ninja_cmd" install >> /tmp/glib-build.log 2>&1 \
        || {
            echo -e "${R}✘${W} glib install thất bại — xem /tmp/glib-build.log"; exit 1
        }
    _rl_ok "glib ${GLIB_VER} xong"
    echo "qemu" > "$BUILD/.rootless-resume"
}

# ════════════════════════════════════════════════════════════════
#  ROOTLESS BUILD
# ════════════════════════════════════════════════════════════════
_detect_cross_toolchain() {
    local _cc="${CC_PLAIN:-$(command -v gcc 2>/dev/null || command -v cc 2>/dev/null || echo "")}"
    [[ -z "$_cc" ]] && return

    local _cc_dir; _cc_dir="$(dirname "$_cc")"
    local _cc_bn;  _cc_bn="$(basename "$_cc")"

    # Add compiler bin dir to PATH so ar/ranlib/etc. can be found
    if [[ -d "$_cc_dir" ]] && [[ ":$PATH:" != *":$_cc_dir:"* ]]; then
        export PATH="$_cc_dir:$PATH"
        hash -r 2>/dev/null || true
    fi

    # Derive cross-prefix (e.g. x86_64-conda-linux-gnu from x86_64-conda-linux-gnu-gcc)
    local _cross_prefix=""
    if [[ "$_cc_bn" == *"-gcc" ]]; then
        _cross_prefix="${_cc_bn%-gcc}"
    elif [[ "$_cc_bn" == *"-cc" ]]; then
        _cross_prefix="${_cc_bn%-cc}"
    fi

    if [[ -n "$_cross_prefix" ]]; then
        for _tool in ar ranlib nm strip; do
            local _bin="$_cc_dir/${_cross_prefix}-${_tool}"
            if [[ -x "$_bin" ]]; then
                local _var="${_tool^^}"  # ar→AR, ranlib→RANLIB etc.
                export "${_var}=${_bin}"
                echo -e "${G}✔${W} Cross-toolchain ${_var}=${_bin}"
            fi
        done
    fi

    # Last-resort: if ar still not found, search conda envs
    if ! command -v "${AR:-ar}" &>/dev/null; then
        local _found_ar
        _found_ar=$(find /opt/conda/bin /opt/conda/envs/*/bin -maxdepth 1 \
            -name "*-ar" -o -name "ar" 2>/dev/null | head -1)
        if [[ -n "$_found_ar" ]]; then
            export AR="$_found_ar"
            echo -e "${G}✔${W} AR (fallback search): $AR"
        fi
    fi

    :
}

_qemu_build_tuning() {
    local _cc_hint="${CC_PLAIN:-${CC:-$(command -v gcc 2>/dev/null || command -v cc 2>/dev/null || echo "")}}"
    local _cc_ver=""
    local _is_clang=0
    local _lto_flags=""
    local _lto_ldflags=""
    local _lto_note=""

    if [[ -n "$_cc_hint" ]]; then
        if [[ "$_cc_hint" == *" "* ]]; then
            _cc_ver=$(bash -lc "set -o pipefail; $_cc_hint --version 2>/dev/null | head -1" 2>/dev/null || true)
        else
            _cc_ver=$("$_cc_hint" --version 2>/dev/null | head -1 || true)
        fi
    fi

    if [[ "$_cc_ver" == *clang* || "$_cc_ver" == *"Apple clang"* ]]; then
        _is_clang=1
    fi

    QEMU_BASE_CFLAGS="-O3 -march=native -mtune=native -pipe -fno-plt -fno-semantic-interposition -fomit-frame-pointer -fstack-protector-strong -ffunction-sections -fdata-sections"
    QEMU_BASE_CXXFLAGS="$QEMU_BASE_CFLAGS"
    QEMU_BASE_LDFLAGS="-Wl,-O1 -Wl,--as-needed -Wl,--gc-sections"
    QEMU_CONFIGURE_LTO_OPT=""

    if [[ "${NO_LTO:-0}" == "1" ]]; then
        _lto_note="LTO disabled (NO_LTO=1)"
    elif [[ "$_is_clang" == "1" ]]; then
        _lto_flags="-flto"
        _lto_ldflags="-flto"
        if command -v ld.lld &>/dev/null; then
            _lto_ldflags="-flto -fuse-ld=lld"
        fi
        QEMU_CONFIGURE_LTO_OPT="--enable-lto"
        for _tool in ar ranlib nm; do
            local _cand
            _cand="$(command -v llvm-$_tool 2>/dev/null || true)"
            [[ -n "$_cand" ]] && export "${_tool^^}=$_cand"
        done
        _lto_note="Full LTO enabled (clang)"
    else
        _lto_flags="-flto"
        _lto_ldflags="-flto"
        QEMU_CONFIGURE_LTO_OPT="--enable-lto"

        local _tool_prefix=""
        if [[ "$_cc_hint" == *-gcc ]]; then
            _tool_prefix="${_cc_hint%-gcc}"
        fi

        if [[ -n "$_tool_prefix" ]]; then
            for _tool in ar ranlib nm; do
                local _cand=""
                for _name in "${_tool_prefix}-gcc-${_tool}" "gcc-${_tool}"; do
                    _cand="$(command -v "$_name" 2>/dev/null || true)"
                    [[ -n "$_cand" ]] && break
                done
                [[ -n "$_cand" ]] && export "${_tool^^}=$_cand"
            done
        else
            for _tool in ar ranlib nm; do
                local _cand=""
                _cand="$(command -v "gcc-${_tool}" 2>/dev/null || true)"
                [[ -n "$_cand" ]] && export "${_tool^^}=$_cand"
            done
        fi
        _lto_note="Full LTO enabled (gcc)"
    fi

    QEMU_BASE_CFLAGS+=" ${_lto_flags}"
    QEMU_BASE_CXXFLAGS+=" ${_lto_flags}"
    QEMU_BASE_LDFLAGS+=" ${_lto_ldflags}"

    export QEMU_BASE_CFLAGS QEMU_BASE_CXXFLAGS QEMU_BASE_LDFLAGS QEMU_CONFIGURE_LTO_OPT
    :
    :
    :
}


_rootless_build() {
    local ROOTLESS_QEMU="$HOME/qemu-static/bin/qemu-system-x86_64"

    if [[ -x "$ROOTLESS_QEMU" ]]; then
        local rv
        rv=$("$ROOTLESS_QEMU" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}⚡ QEMU rootless v${rv} đã tồn tại — bỏ qua build${W}"
        export QEMU_BIN="$ROOTLESS_QEMU"
        export PREFIX="$HOME/qemu-static"
        export PIP_TARGET="$PREFIX/pylib"
        export PYTHONPATH="$PIP_TARGET${PYTHONPATH:+:$PYTHONPATH}"
        export PATH="$PREFIX/bin:$PIP_TARGET/bin:$HOME/.local/bin:$PATH"
        export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64:${LD_LIBRARY_PATH:-}"
        return 0
    fi

    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔧 ROOTLESS BUILD MODE${W}"
    echo -e "${C}════════════════════════════════════${W}"

    # Source build là primary — không cần conda cho libs chính.
    # conda chỉ dùng cho: aria2 (download tool) + fallback khi source build thất bại.
    echo -e "${B}ℹ${W}  Thời gian ước tính: 30-60 phút (tùy CPU và mạng)"
    _RL_T=10; _RL_N=0

    rm -rf "$HOME/python-local" "$HOME/qemu-static" "$HOME/qemu-build" "$HOME/certs"
    export PREFIX="$HOME/qemu-static"
    export BUILD="$HOME/qemu-build"
    mkdir -p "$PREFIX" "$BUILD" "$HOME/certs"

    # UPGRADE 30: Pre-flight check — xác nhận các công cụ tối thiểu
    :
    local _missing_tools=()
    for _tool in python3 wget tar; do
        if ! command -v "$_tool" &>/dev/null; then
            _missing_tools+=("$_tool")
        fi
    done
    if [[ ${#_missing_tools[@]} -gt 0 ]]; then
        echo -e "${R}✘${W}  THIẾU CÔNG CỤ BẮT BUỘC: ${_missing_tools[*]}"
        echo -e "${Y}💡 Cài đặt:${W}"
        echo -e "   sudo apt-get install python3 wget tar build-essential"
        exit 1
    fi
    :

    # Capture plain compiler paths (unaffected by later CC= overrides)
    CC_PLAIN="${CC_PLAIN:-$(command -v gcc || command -v cc || echo "gcc")}"
    CXX_PLAIN="${CXX_PLAIN:-$(command -v g++ || command -v c++ || echo "g++")}"
    export CC_PLAIN CXX_PLAIN

    # Thư mục cài pip packages (thay thế --user bị disable trên HPC)
    export PIP_TARGET="$PREFIX/pylib"
    mkdir -p "$PIP_TARGET"
    export PYTHONPATH="$PIP_TARGET${PYTHONPATH:+:$PYTHONPATH}"
    export PATH="$PIP_TARGET/bin:$HOME/.local/bin:$PREFIX/bin:$PATH"

    # ── Detect / install gcc (compiler) ──────────────────────
    CC_PLAIN="$(command -v gcc 2>/dev/null || command -v cc 2>/dev/null || echo "")"
    CXX_PLAIN="$(command -v g++ 2>/dev/null || command -v c++ 2>/dev/null || echo "")"
    if [[ -z "$CC_PLAIN" ]]; then
        echo -e "${Y}⚠${W}  gcc không có — cài qua conda (1-2 phút)..."
        if command -v conda &>/dev/null; then
            conda install -y -q -c conda-forge gcc_linux-64 gxx_linux-64 > /tmp/conda-gcc.log 2>&1 \
                && hash -r 2>/dev/null || true
            CC_PLAIN="$(command -v gcc 2>/dev/null \
                || command -v x86_64-conda-linux-gnu-gcc 2>/dev/null \
                || find "${CONDA_PREFIX:-}/bin" -name "x86_64-*-gcc" 2>/dev/null | head -1 \
                || echo "")"
            CXX_PLAIN="$(command -v g++ 2>/dev/null \
                || command -v x86_64-conda-linux-gnu-g++ 2>/dev/null \
                || find "${CONDA_PREFIX:-}/bin" -name "x86_64-*-g++" 2>/dev/null | head -1 \
                || echo "")"
            [[ -n "$CC_PLAIN" ]] \
                && echo -e "${G}✔${W} gcc từ conda: $CC_PLAIN" \
                || { echo -e "${R}✘${W} Không tìm thấy gcc sau conda — xem /tmp/conda-gcc.log"; exit 1; }
        else
            echo -e "${Y}⚠${W}  Không có conda — thử download static gcc binary..."
            # UPGRADE 20: Thử download static gcc từ musl.cc hoặc dyne.org
            local _gcc_static_ok=0
            local _gcc_static_prefix="$PREFIX/gcc-static"
            mkdir -p "$_gcc_static_prefix"

            # Thử 0: zig cc (modern compiler)
            if [[ "$_gcc_static_ok" == "0" ]] && command -v zig &>/dev/null; then
                CC_PLAIN="zig cc"
                CXX_PLAIN="zig c++"
                _gcc_static_ok=1
                echo -e "${G}✔${W} Dùng zig cc làm compiler"
            fi

            # Thử 1: tcc (tiny c compiler)
            if [[ "$_gcc_static_ok" == "0" ]]; then
                echo -e "${B}ℹ${W}  Thử cài tcc (tiny c compiler)..."
                if command -v tcc &>/dev/null; then
                    CC_PLAIN="tcc"
                    CXX_PLAIN="tcc"
                    _gcc_static_ok=1
                    echo -e "${G}✔${W} tcc tìm thấy: $(command -v tcc)"
                elif wget -q --timeout=60 --tries=2 "https://download.savannah.gnu.org/releases/tinycc/tcc-0.9.27.tar.bz2" -O /tmp/tcc.tar.bz2 2>/dev/null; then
                    tar xjf /tmp/tcc.tar.bz2 -C "$BUILD" 2>/dev/null
                    cd "$BUILD/tcc-0.9.27"
                    ./configure --prefix="$_gcc_static_prefix" > /tmp/tcc-configure.log 2>&1
                    make -j"$(nproc 2>/dev/null || echo 2)" > /tmp/tcc-build.log 2>&1 && make install > /tmp/tcc-install.log 2>&1
                    if [[ -x "$_gcc_static_prefix/bin/tcc" ]]; then
                        CC_PLAIN="$_gcc_static_prefix/bin/tcc"
                        CXX_PLAIN="$_gcc_static_prefix/bin/tcc"
                        _gcc_static_ok=1
                        echo -e "${G}✔${W} tcc build từ source: $CC_PLAIN"
                    fi
                fi
            fi

            # Thử 2: musl.cc static gcc
            if [[ "$_gcc_static_ok" == "0" ]]; then
                echo -e "${B}ℹ${W}  Thử tải musl toolchain từ musl.cc..."
                local _musl_url="https://musl.cc/x86_64-linux-musl-native.tgz"
                if wget -q --timeout=120 --tries=2 "$_musl_url" -O /tmp/musl-gcc.tgz 2>/dev/null; then
                    if tar xzf /tmp/musl-gcc.tgz -C "$_gcc_static_prefix" --strip-components=1 2>/dev/null; then
                        if [[ -x "$_gcc_static_prefix/bin/gcc" ]]; then
                            CC_PLAIN="$_gcc_static_prefix/bin/gcc"
                            CXX_PLAIN="$_gcc_static_prefix/bin/g++"
                            export AR="$_gcc_static_prefix/bin/ar"
                            export RANLIB="$_gcc_static_prefix/bin/ranlib"
                            _gcc_static_ok=1
                            echo -e "${G}✔${W} Static gcc từ musl.cc: $CC_PLAIN"
                        fi
                    fi
                fi
            fi

            # Thử 3: Build gcc từ source (last resort)
            if [[ "$_gcc_static_ok" == "0" ]]; then
                echo -e "${Y}⚠${W}  Không tải được static binary — thử build gcc từ source..."
                echo -e "${Y}⚠${W}  QUÁ TRÌNH NÀY CÓ THỂ MẤT 30-60 PHÚT!"
                local _gcc_src_dir="$BUILD/gcc-src"
                mkdir -p "$_gcc_src_dir" && cd "$_gcc_src_dir"
                local _gcc_ver="13.2.0"
                if wget -q --timeout=120 "https://ftp.gnu.org/gnu/gcc/gcc-${_gcc_ver}/gcc-${_gcc_ver}.tar.xz" -O gcc.tar.xz 2>/dev/null; then
                    echo -e "${B}ℹ${W}  Giải nén gcc source..."
                    tar xJf gcc.tar.xz 2>/dev/null
                    cd "gcc-${_gcc_ver}"
                    ./contrib/download_prerequisites > /tmp/gcc-prereq.log 2>&1 || true
                    mkdir -p build && cd build
                    echo -e "${B}ℹ${W}  Configure gcc (5-10 phút)..."
                    ../configure --prefix="$_gcc_static_prefix"                         --enable-languages=c,c++                         --disable-multilib                         --disable-bootstrap                         --disable-nls                         --disable-libssp                         --disable-libquadmath                         --disable-libgomp                         > /tmp/gcc-configure.log 2>&1 || true
                    echo -e "${B}ℹ${W}  Build gcc (20-50 phút)..."
                    :
( _hb=0; while :; do sleep 30; _hb=$((_hb+1)); printf "[~] GCC build: %d min elapsed...
" "$((_hb/2))"; done ) & _HB_GCC=$!
if make -j"$(nproc 2>/dev/null || echo 2)" > /tmp/gcc-build.log 2>&1; then
  kill "$_HB_GCC" 2>/dev/null; wait "$_HB_GCC" 2>/dev/null || true; :
                        make install > /tmp/gcc-install.log 2>&1
                        if [[ -x "$_gcc_static_prefix/bin/gcc" ]]; then
                            CC_PLAIN="$_gcc_static_prefix/bin/gcc"
                            CXX_PLAIN="$_gcc_static_prefix/bin/g++"
                            _gcc_static_ok=1
                            echo -e "${G}✔${W} GCC ${_gcc_ver} build từ source xong!"
                        fi
                    else
                        echo -e "${R}✘${W}  Build gcc từ source thất bại — xem /tmp/gcc-build.log"
                    fi
                fi
            fi

            if [[ "$_gcc_static_ok" == "0" ]]; then
                echo -e "${R}✘${W}  KHÔNG THỂ CÓ COMPILER — CÁC PHƯƠNG ÁN ĐÃ THỬ:"
                echo -e "   1. conda install gcc_linux-64 (không có conda)"
                echo -e "   2. zig cc (không có zig)"
                echo -e "   3. tcc (download/build thất bại)"
                echo -e "   4. musl.cc static gcc (download thất bại)"
                echo -e "   5. Build gcc từ source (thất bại hoặc quá lâu)"
                echo -e ""
                echo -e "${Y}💡 GIẢI PHÁP:${W}"
                echo -e "   • Cài conda: wget https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh"
                echo -e "   • Hoặc cài gcc qua package manager: sudo apt install build-essential"
                echo -e "   • Hoặc chạy với quyền root để dùng apt"
                exit 1
            fi
        fi
    fi
    export CC_PLAIN CXX_PLAIN
    export CC="$CC_PLAIN" CXX="${CXX_PLAIN:-$CC_PLAIN}"
    _rl_ok "compiler: $CC_PLAIN"

    # ── Detect cross-toolchain AR/RANLIB/NM/STRIP ──────────────────────
    _detect_cross_toolchain
    _qemu_build_tuning

    # ── Detect make — build from source nếu không có (~30-60s) ──
    MAKE="$(command -v make 2>/dev/null || command -v gmake 2>/dev/null || echo "")"
    if [[ -z "$MAKE" ]]; then
        echo -e "${B}ℹ${W}  make không có — build từ source (~30-60s)..."
        mkdir -p "$BUILD"
        ( cd "$BUILD" \
            && wget -q --timeout=60 --tries=2 \
               "https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz" \
               -O make.tar.gz 2>/dev/null \
            && tar xzf make.tar.gz 2>/dev/null \
            && cd make-4.4.1 \
            && CC="$CC_PLAIN" ./configure --prefix="$PREFIX" --disable-dependency-tracking > /tmp/make-build.log 2>&1 \
            && CC="$CC_PLAIN" ./build.sh >> /tmp/make-build.log 2>&1 \
            && mkdir -p "$PREFIX/bin" && cp make "$PREFIX/bin/make" \
        ) && MAKE="$PREFIX/bin/make" \
          && echo -e "${G}✔${W} make built from source: $MAKE" \
          || { echo -e "${R}✘${W} Build make thất bại — xem /tmp/make-build.log"; exit 1; }
        export PATH="$PREFIX/bin:$PATH"
        hash -r 2>/dev/null || true
    fi
    export MAKE
    _rl_ok "make: $MAKE"

    :
    cd "$HOME/certs"
    # UPGRADE 26: Thử nhiều nguồn SSL certs
    if ! wget -q --timeout=30 https://curl.se/ca/cacert.pem -O cacert.pem 2>/dev/null; then
        wget -q --timeout=30 https://mkcert.org/generate/ -O cacert.pem 2>/dev/null || true
    fi
    if [[ -f cacert.pem && -s cacert.pem ]]; then
        export SSL_CERT_FILE="$HOME/certs/cacert.pem"
        export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
        :
    else
        :
    fi

    export PY_PREFIX="$HOME/python-local"
    mkdir -p "$PY_PREFIX"
    export PATH="$HOME/.local/bin:$PREFIX/bin:$PATH"

    :
    PY_VER_SYSTEM=$(python3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$PY_VER_SYSTEM" ]]; then
        echo -e "\r${G}✔${W} Python system $PY_VER_SYSTEM          "
    else
        echo -e "\r${R}✘${W} Không tìm thấy Python 3"; exit 1
    fi

    if ! python3 -c "import ssl" 2>/dev/null; then
        _rl_fail "Python ssl module KHÔNG có"
    elif false; then
        echo -e "${R}✘${W} Python ssl module KHÔNG có"; exit 1
    fi

    echo -ne "${B}◜${W} Bootstrap pip (get-pip vào \$PIP_TARGET)..."
    if ! python3 -m pip --version > /dev/null 2>&1; then
        PY_MINOR=$(python3 -c "import sys; print(sys.version_info.minor)")
        echo -e "\r${B}◜${W} Tải get-pip.py cho Python 3.${PY_MINOR}..."
        if wget -q "https://bootstrap.pypa.io/pip/3.${PY_MINOR}/get-pip.py" -O /tmp/get-pip.py 2>/tmp/pip-bootstrap.log; then
            # Cài pip vào PIP_TARGET, không dùng --user (bị disable trên HPC)
            python3 /tmp/get-pip.py --target="$PIP_TARGET" --no-warn-script-location \
                >> /tmp/pip-bootstrap.log 2>&1 \
                && echo -e "\r${G}✔${W} pip bootstrap xong → $PIP_TARGET          " \
                || { echo -e "${R}✘${W} get-pip.py thất bại:"; cat /tmp/pip-bootstrap.log; exit 1; }
        else
            echo -e "${R}✘${W} Không tải được get-pip.py"; exit 1
        fi
        hash -r
    else
        echo -e "\r${G}✔${W} pip đã có sẵn          "
    fi

    _rl_step 6 "${_RL_T:-10}" "pip/meson/ninja"
    pip_install --upgrade pip > /tmp/pip-meson.log 2>&1
    pip_install 'meson>=1.6.0' ninja tomli >> /tmp/pip-meson.log 2>&1

    # UPGRADE 28: Nếu pip install thất bại, thử download binary trực tiếp
    if [[ ! -x "$PIP_TARGET/bin/meson" ]] && [[ ! -x "$PY_PREFIX/bin/meson" ]]; then
        echo -e "${Y}⚠${W}  pip install meson thất bại — thử download binary..."
        # Thử tải meson từ PyPI wheel
        local _meson_wheel_url="https://files.pythonhosted.org/packages/source/m/meson/meson-1.6.0.tar.gz"
        if wget -q --timeout=60 "$_meson_wheel_url" -O /tmp/meson-src.tar.gz 2>/dev/null; then
            tar xzf /tmp/meson-src.tar.gz -C /tmp/ 2>/dev/null
            if [[ -d /tmp/meson-*/mesonbuild ]]; then
                cp -r /tmp/meson-*/mesonbuild "$PIP_TARGET/" 2>/dev/null
                echo -e "${G}✔${W} meson source copied to $PIP_TARGET"
            fi
        fi
    fi

    # ── Tạo wrapper scripts cho meson/ninja (pip --target không tạo executables) ──
    mkdir -p "$PIP_TARGET/bin"
    local _pip_py3; _pip_py3="$(command -v python3)"
    # meson wrapper — KHÔNG dùng python3 -c "..." vì meson dùng sys.argv[0] để
    # tìm meson binary path → "build/-c: not found" khi generate codegen commands.
    # Tạo Python script thực: sys.argv[0] = path file thực → meson tìm được chính nó.
    if [[ ! -x "$PIP_TARGET/bin/meson" ]]; then
        local _mw="$PIP_TARGET/bin/meson"
        local _mpt="$PIP_TARGET"
        # Tạo Python script thực (không phải shell -c inline)
        cat > "$_mw" <<MESONWRAP
#!${_pip_py3}
import sys, os
sys.path.insert(0, '${_mpt}')
from mesonbuild.mesonmain import main
sys.exit(main())
MESONWRAP
        chmod +x "$_mw"
        echo -e "${G}✔${W} meson wrapper → $_mw"
    fi
    # ninja wrapper
    if [[ ! -x "$PIP_TARGET/bin/ninja" ]]; then
        local _nj_bin
        _nj_bin=$(find "$PIP_TARGET" -name "ninja" -type f \
            ! -name "*.py" ! -name "*.pyc" ! -path "*__pycache__*" 2>/dev/null | head -1 || true)
        if [[ -n "$_nj_bin" && -x "$_nj_bin" ]]; then
            ln -sf "$_nj_bin" "$PIP_TARGET/bin/ninja"
        else
            local _mpt2="$PIP_TARGET"
            printf '#!/bin/sh\nPYTHONPATH="%s${PYTHONPATH:+:$PYTHONPATH}"\nexport PYTHONPATH\nexec "%s" -m ninja "$@"\n' \
                "$_mpt2" "$_pip_py3" > "$PIP_TARGET/bin/ninja"
            chmod +x "$PIP_TARGET/bin/ninja"
        fi
        echo -e "${G}✔${W} ninja wrapper → $PIP_TARGET/bin/ninja"
    fi
    export PATH="$PIP_TARGET/bin:$PATH"
    hash -r 2>/dev/null || true
    echo -e "${G}✔${W} meson/ninja từ pip xong"

    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔨 BUILD LIBRARIES FROM SOURCE${W}"
    echo -e "${C}════════════════════════════════════${W}"

    # UPGRADE 31: Resume support — kiểm tra build trước đó
    if [[ -f "$BUILD/.rootless-resume" ]]; then
        echo -e "${Y}⚠${W}  Phát hiện build trước đó bị gián đoạn"
        echo -e "${B}↩${W}  Resume build..."
        if [[ "$AUTO_MODE" != "1" ]]; then
            read -rp "Xoá build cũ và bắt đầu lại? (y/n): " _resume_choice
            [[ "${_resume_choice:-y}" == "y" ]] && rm -rf "$BUILD"/* || true
        fi
    fi
    echo "zlib" > "$BUILD/.rootless-resume"
    _build_zlib_from_source "$PREFIX" "$BUILD"
    _build_libffi_from_source "$PREFIX" "$BUILD"
    _build_pixman_from_source "$PREFIX" "$BUILD"
    _build_glib_from_source "$PREFIX" "$BUILD" "$PY_PREFIX"

    PIXMAN_INC="$PREFIX/include"
    [[ -z "$PIXMAN_INC" ]] && \
        PIXMAN_INC=$(find "$PREFIX" -name "pixman.h" -type f 2>/dev/null | head -1 | xargs dirname)
    echo -e "${G}✔${W} pixman.h tại: ${PIXMAN_INC}"

    :
    echo -e "${C}   👉 Xem log: tail -f /tmp/pip-rootless.log${W}"
    pip_install --upgrade packaging > /tmp/pip-rootless.log 2>&1
    echo -e "${G}✔${W} pip packages xong"

    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}⬇  Tải QEMU 11.0.0 (khoảng 100MB)${W}"
    echo -e "${C}════════════════════════════════════${W}"
    cd "$BUILD"
    wget -c --progress=bar:force:noscroll \
        https://download.qemu.org/qemu-11.0.0.tar.xz 2>&1
    echo -e "${C}════════════════════════════════════${W}"
    spin_start "Giải nén QEMU (dùng Python lzma)..."
    python3 -c "
import lzma, tarfile
with lzma.open('qemu-11.0.0.tar.xz') as f:
    with tarfile.open(fileobj=f) as t:
        t.extractall('.')
" 2>/dev/null
    spin_stop "Giải nén QEMU xong"

    echo -ne "${B}◜${W} Cài libslirp từ source..."
    SLIRP_OK=0

    if [[ "$SLIRP_OK" == "0" ]]; then
        mkdir -p "$BUILD/qemu-11.0.0/subprojects"
        wget -c -qO- \
            "https://gitlab.freedesktop.org/slirp/libslirp/-/archive/v4.7.0/libslirp-v4.7.0.tar.gz" \
            | tar xz -C "$BUILD/qemu-11.0.0/subprojects/" > /dev/null 2>&1 \
            && mv "$BUILD/qemu-11.0.0/subprojects/libslirp-v4.7.0" \
                  "$BUILD/qemu-11.0.0/subprojects/libslirp" \
            && SLIRP_OK=1 \
            && echo -e "\r${G}✔${W} libslirp tarball xong          "
    fi

    if [[ "$SLIRP_OK" == "0" ]]; then
        git clone -q --depth 1 \
            https://gitlab.freedesktop.org/slirp/libslirp.git \
            "$BUILD/qemu-11.0.0/subprojects/libslirp" > /dev/null 2>&1 \
            && SLIRP_OK=1 \
            && echo -e "\r${G}✔${W} libslirp git xong          " \
            || { echo -e "\r${R}✘${W} libslirp thất bại toàn bộ"; exit 1; }
    fi
    spin_stop "libslirp xong"

    # Fix: PHẢI isolate PKG_CONFIG_PATH khỏi conda trước khi build QEMU.
    # Conda path trong PKG_CONFIG_PATH khiến meson tìm ra glib của conda
    # (ABI/sizeof khác system libc) → lỗi "sizeof(size_t) doesn't match GLIB_SIZEOF_SIZE_T".
    # NGOẠI LỆ: nếu đang dùng conda glib fallback (_GLIB_FROM_CONDA=1) thì PHẢI giữ
    # conda pkgconfig path — vì glib-2.0.pc chỉ có trong conda, không copy vào $PREFIX.
    _SYSTEM_PC_PATHS="/usr/lib/x86_64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig"
    if [[ "${_GLIB_FROM_CONDA:-0}" == "1" ]]; then
        # Conda glib fallback: thêm conda pc paths VÀO ĐẦU để meson tìm được glib-2.0
        _CONDA_PC_PATHS="/opt/conda/lib/pkgconfig:/opt/conda/share/pkgconfig"
        export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$_CONDA_PC_PATHS:$_SYSTEM_PC_PATHS"
        export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$_CONDA_PC_PATHS:$_SYSTEM_PC_PATHS"
        echo -e "${Y}⚠${W}  conda glib fallback: conda pkgconfig paths được include vào PKG_CONFIG_LIBDIR"
    else
        export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$_SYSTEM_PC_PATHS"
        # PKG_CONFIG_LIBDIR override mọi default search path (bao gồm conda)
        export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/lib64/pkgconfig:$_SYSTEM_PC_PATHS"
    fi
    :

    # ── Ensure pkg-config binary actually WORKS (not just exists) ──
    # QUAN TRỌNG: KHÔNG dùng conda's pkg-config (/opt/conda/bin/pkg-config)
    # vì nó có hardcoded PKG_CONFIG_SYSTEM_LIBRARY_PATH bao gồm conda paths,
    # ignore PKG_CONFIG_LIBDIR → meson tìm thấy conda glib thay vì source-built glib.
    # Chỉ dùng $PREFIX/bin/pkg-config (self-built --with-internal-glib).
    _pkgcfg_works() {
        [[ -x "$PREFIX/bin/pkg-config" ]] && \
            "$PREFIX/bin/pkg-config" --version &>/dev/null && \
            { export PKG_CONFIG="$PREFIX/bin/pkg-config"; return 0; }
        return 1
    }

    if ! _pkgcfg_works; then
        _rl_step "${_RL_N:-7}" "${_RL_T:-10}" "pkg-config 0.29.2"
        (cd "$BUILD" \
            && wget -q "https://pkgconfig.freedesktop.org/releases/pkg-config-0.29.2.tar.gz" \
                   -O pkg-config.tar.gz 2>/dev/null \
            && tar xzf pkg-config.tar.gz 2>/dev/null \
            && cd pkg-config-0.29.2 \
            && CC="$CC_PLAIN" ./configure \
                   --prefix="$PREFIX" \
                   --with-internal-glib \
                   --disable-host-tool \
                   --disable-dependency-tracking \
                   > /tmp/pkgconfig-build.log 2>&1 \
            && CC="$CC_PLAIN" ${MAKE:-make} -j"$(nproc)" >> /tmp/pkgconfig-build.log 2>&1 \
            && ${MAKE:-make} install >> /tmp/pkgconfig-build.log 2>&1) \
            && _rl_ok "pkg-config 0.29.2 xong" \
            || _rl_warn "pkg-config build thất bại"
    fi

    if _pkgcfg_works; then
        echo -e "${G}✔${W} pkg-config: $PKG_CONFIG ($("$PKG_CONFIG" --version))"
    else
        echo -e "${Y}⚠${W}  pkg-config tự build thất bại — dùng wrapper script để isolate conda paths"
        # Tạo wrapper script: gọi conda pkg-config nhưng chỉ search PKG_CONFIG_LIBDIR
        cat > "$PREFIX/bin/pkg-config" <<'PKGWRAP'
#!/bin/sh
# Wrapper: enforce PKG_CONFIG_LIBDIR, bỏ qua conda default paths
exec env PKG_CONFIG_SYSTEM_LIBRARY_PATH="" \
     /opt/conda/bin/pkg-config "$@"
PKGWRAP
        chmod +x "$PREFIX/bin/pkg-config"
        export PKG_CONFIG="$PREFIX/bin/pkg-config"
        :
    fi

    SRC_INC="$PREFIX/include"; SRC_LIB="$PREFIX/lib"

    QEMU_EXTRA_CFLAGS="$QEMU_BASE_CFLAGS -I$PREFIX/include -I${PIXMAN_INC:-$SRC_INC/pixman-1} -I$SRC_INC"
    QEMU_EXTRA_CXXFLAGS="$QEMU_BASE_CXXFLAGS -I$PREFIX/include -I${PIXMAN_INC:-$SRC_INC/pixman-1} -I$SRC_INC"
    QEMU_EXTRA_LDFLAGS="$QEMU_BASE_LDFLAGS -L$PREFIX/lib64 -L$PREFIX/lib -L$SRC_LIB -Wl,-rpath,$SRC_LIB"

    # ── KVM flag cho configure rootless ──────────────────────────
    if [[ "$KVM_AVAILABLE" == "1" ]]; then
        QEMU_KVM_FLAG="--enable-kvm"
        echo -e "${G}⚡ Rootless QEMU build: --enable-kvm${W}"
    else
        QEMU_KVM_FLAG="--disable-kvm"
        :
    fi

    _rl_step 9 "${_RL_T:-10}" "QEMU configure"
    cd "$BUILD/qemu-11.0.0"
    rm -rf build

    _pick_qemu_python() {
        local _cands=(
            /usr/local/bin/python3
            /usr/bin/python3
            /opt/conda/bin/python3
            /opt/conda/bin/python
            "$(command -v python3 2>/dev/null || true)"
            "$(command -v python 2>/dev/null || true)"
        )
        local _py
        for _py in "${_cands[@]}"; do
            [[ -n "$_py" && -x "$_py" ]] || continue
            if "$_py" - <<'PY2' >/dev/null 2>&1
import ensurepip
PY2
            then
                echo "$_py"
                return 0
            fi
        done
        command -v python3 2>/dev/null || echo python3
    }

    QEMU_PYTHON_BIN="$(_pick_qemu_python)"
    echo -e "${B}ℹ${W}  Using python for QEMU: $QEMU_PYTHON_BIN ($($QEMU_PYTHON_BIN --version 2>&1))"

    # Đảm bảo tomli/meson tìm thấy được trong pyvenv QEMU tạo ra
    export PYTHONPATH="$PIP_TARGET${PYTHONPATH:+:$PYTHONPATH}"

    # Ensure we use pip-installed meson (>= 0.65.3) not system meson (might be old)
    _MESON_BIN="$(python3 -c "import subprocess,sys; r=subprocess.run([sys.executable,'-m','meson','--version'],capture_output=True,text=True); print(sys.executable+' -m meson' if r.returncode==0 else 'meson')" 2>/dev/null || echo "meson")"
    [[ -x "$PIP_TARGET/bin/meson" ]] && _MESON_BIN="$PIP_TARGET/bin/meson"
    echo -e "${B}ℹ${W}  Using meson: $_MESON_BIN ($("$_MESON_BIN" --version 2>/dev/null || echo "?"))"
    export MESON="$_MESON_BIN"
    # Ưu tiên pkg-config tự build (--with-internal-glib, không phụ thuộc conda glib)
    # Tránh dùng conda's pkg-config vì nó tự động thêm conda paths vào search list
    if [[ -x "$PREFIX/bin/pkg-config" ]] && "$PREFIX/bin/pkg-config" --version &>/dev/null; then
        export PKG_CONFIG="$PREFIX/bin/pkg-config"
        echo -e "${G}✔${W}  Dùng pkg-config tự build: $PKG_CONFIG"
    else
        export PKG_CONFIG="${PKG_CONFIG:-$(command -v pkg-config 2>/dev/null || echo "")}"
    fi
    # PKG_CONFIG_LIBDIR phải được export cho tất cả subprocess của configure (meson, cmake...)
    export PKG_CONFIG_LIBDIR

    # ABI check: đảm bảo glib từ source tương thích với system gcc
    # Skip nếu đang dùng conda glib fallback (_GLIB_FROM_CONDA=1) — conda glib có ABI riêng,
    # nhưng QEMU meson sẽ tự detect và link đúng qua LD_LIBRARY_PATH.
    if [[ "${_GLIB_FROM_CONDA:-0}" != "1" ]]; then
        _GLIB_PC_FOR_CHECK=""
        for _f in "$PREFIX/lib/pkgconfig/glib-2.0.pc" "$PREFIX/lib64/pkgconfig/glib-2.0.pc"; do
            [[ -f "$_f" ]] && { _GLIB_PC_FOR_CHECK="$_f"; break; }
        done
        if [[ -n "${_GLIB_PC_FOR_CHECK:-}" && -n "${CC_PLAIN:-}" && -x "${CC_PLAIN:-/nonexistent}" ]] && \
           [[ -n "${PKG_CONFIG:-}" && -x "${PKG_CONFIG:-/nonexistent}" ]]; then
            _GLIB_INC=$(PKG_CONFIG_LIBDIR="$PKG_CONFIG_LIBDIR" \
                        "$PKG_CONFIG" --cflags glib-2.0 2>/dev/null || echo "")
            if ! echo '#include <glib.h>
char _abi_chk[sizeof(size_t)==GLIB_SIZEOF_SIZE_T?1:-1];' | \
                   "$CC_PLAIN" -x c - $_GLIB_INC -fsyntax-only 2>/tmp/glib-abi.log; then
                echo -e "${R}✘${W}  GLIB_SIZEOF_SIZE_T mismatch — glib ABI không tương thích."
                echo -e "${Y}⚠${W}  Xoá glib cache và build lại:"
                echo -e "${Y}    rm -f $PREFIX/lib*/libglib* $PREFIX/lib*/pkgconfig/glib*.pc${W}"
                echo -e "${Y}    rm -f $PREFIX/lib*/pkgconfig/gobject*.pc $PREFIX/lib*/pkgconfig/gio*.pc${W}"
                rm -f "$PREFIX"/lib*/pkgconfig/glib-2.0.pc \
                      "$PREFIX"/lib*/pkgconfig/gobject-2.0.pc \
                      "$PREFIX"/lib*/pkgconfig/gio-2.0.pc 2>/dev/null || true
                echo -e "${R}✘${W}  Build thất bại. Chạy lại sau khi: rm -rf ~/qemu-static ~/qemu-build"
                exit 1
            fi
            echo -e "${G}✔${W}  glib ABI OK (GLIB_SIZEOF_SIZE_T == sizeof(size_t))"
        fi
    else
        echo -e "${Y}⚠${W}  Dùng conda glib fallback — bỏ qua ABI check, link qua LD_LIBRARY_PATH"
    fi

    # Lưu và tạm reset PIP_TARGET/PYTHONPATH để QEMU configure không bị confused
    _SAVED_PIP_TARGET="${PIP_TARGET:-}"
    _SAVED_PYTHONPATH="${PYTHONPATH:-}"
    export PIP_TARGET=""
    export PYTHONPATH=""
    # Khi dùng conda glib, đảm bảo linker tìm được libglib-2.0.so
    if [[ "${_GLIB_FROM_CONDA:-0}" == "1" ]]; then
        export LD_LIBRARY_PATH="/opt/conda/lib:${LD_LIBRARY_PATH:-}"
        :
    fi
    export CFLAGS="$QEMU_EXTRA_CFLAGS"
    export CXXFLAGS="$QEMU_EXTRA_CXXFLAGS"
    export LDFLAGS="$QEMU_EXTRA_LDFLAGS"

    ./configure \
        --prefix="$PREFIX" \
        --python="$QEMU_PYTHON_BIN" \
        --target-list=x86_64-softmmu \
        --enable-tcg \
        $QEMU_CONFIGURE_LTO_OPT \
        $QEMU_KVM_FLAG \
        --disable-werror \
        --disable-gtk \
        --disable-sdl \
        --disable-docs \
        --disable-plugins \
        --enable-slirp \
        --enable-vnc \
        --disable-libusb \
        --disable-capstone \
        -Dguest_agent=disabled \
        -Dguest_agent_msi=disabled \
        -Dtools=enabled \
        --extra-cflags="$QEMU_EXTRA_CFLAGS" \
        --extra-cxxflags="$QEMU_EXTRA_CXXFLAGS" \
        --extra-ldflags="$QEMU_EXTRA_LDFLAGS" \
        2>&1 | tee /tmp/qemu-configure.log
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo -e "${R}✘${W} Configure QEMU thất bại — xem /tmp/qemu-configure.log"
        exit 1
    fi
    echo -e "\r${G}✔${W} Configure QEMU xong          "
    # Restore PIP_TARGET/PYTHONPATH cho các bước build tiếp theo
    export PIP_TARGET="${_SAVED_PIP_TARGET:-}"
    export PYTHONPATH="${_SAVED_PYTHONPATH:-}"

    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔨 Compile QEMU (mất 10-20 phút)${W}"
    echo -e "${C}════════════════════════════════════${W}"
    # Tính số job an toàn từ cgroup quota (container-safe)
    # cpu_u có thể chưa được set nếu _rootless_build gọi trước auto-detect
    if [[ -z "${cpu_u:-}" || "${cpu_u:-0}" -lt 1 ]]; then
        local _cq _cp
        cpu_u=$(nproc 2>/dev/null || echo 2)
        if [[ -f /sys/fs/cgroup/cpu.max ]]; then
            IFS=" " read -r _cq _cp < /sys/fs/cgroup/cpu.max
            [[ "$_cq" != "max" && -n "$_cp" && "$_cp" -gt 0 ]] && \
                cpu_u=$(awk "BEGIN{printf \"%.0f\",$_cq/$_cp}")
        elif [[ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]]; then
            _cq=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
            _cp=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
            [[ "$_cq" != "-1" && -n "$_cp" && "$_cp" -gt 0 ]] && \
                cpu_u=$(awk "BEGIN{printf \"%.0f\",$_cq/$_cp}")
        fi
        [[ "${cpu_u:-0}" -lt 1 ]] && cpu_u=1
    fi
    _BUILD_JOBS=$(( cpu_u > 0 ? cpu_u : $(nproc 2>/dev/null || echo 2) ))
    [[ "$_BUILD_JOBS" -lt 1 ]] && _BUILD_JOBS=1
    :
    # Lưu exit code của make TRƯỚC khi kiểm tra (grep exit 1 khi không có match sẽ
    # trigger pipefail trước khi PIPESTATUS được đọc — dùng || true để tránh)
    :
( _hb=0; while :; do sleep 60; _hb=$((_hb+1)); printf "[~] QEMU compile: %d min...\n" "$_hb"; done ) &
_HB_QM=$!
${MAKE:-make} -j"$_BUILD_JOBS" 2>&1 | tee /tmp/qemu-make.log | grep --line-buffered -E "^\[|error:|warning:|FAILED" || true
kill "$_HB_QM" 2>/dev/null; wait "$_HB_QM" 2>/dev/null || true
:
    _MAKE_EXIT=${PIPESTATUS[0]}
    if [[ "$_MAKE_EXIT" -ne 0 ]]; then
        echo -e "${R}✘ Compile QEMU thất bại — xem /tmp/qemu-build.log${W}"
        ${MAKE:-make} -j"$_BUILD_JOBS" > /tmp/qemu-build.log 2>&1
        exit 1
    fi
    ${MAKE:-make} install > /dev/null 2>&1 \
        || { echo -e "${R}✘ make install thất bại — QEMU không được cài vào $PREFIX${W}"; exit 1; }
    strip "$PREFIX/bin/qemu-system-x86_64" 2>/dev/null || true
    echo -e "${G}✔ QEMU rootless build xong${W}"

    export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64:$PREFIX/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
    export QEMU_BIN="$PREFIX/bin/qemu-system-x86_64"
    export PATH="$PREFIX/bin:$PATH"

    # UPGRADE 33: Cleanup resume file nếu build thành công
    rm -f "$BUILD/.rootless-resume" 2>/dev/null || true

    echo -e "${G}✔ Rootless build hoàn tất${W}"
    echo -e "   QEMU  : $QEMU_BIN"
    echo -e "   Python: $(python3 --version 2>&1)"
    echo -e "   Accel : ${KVM_MODE^^}"
}

# ════════════════════════════════════════════════════════════════
#  CROSS-TOOLCHAIN DETECTION
#  Detect AR/RANLIB/NM/STRIP from CC_PLAIN prefix
#  Fixes: conda cross-compiler (x86_64-conda-linux-gnu-gcc) needs
#         x86_64-conda-linux-gnu-ar instead of plain `ar`
# ════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════
#  MAIN — detect apt, detect KVM, detect QEMU
# ════════════════════════════════════════════════════════════════
QEMU_BIN="/usr/bin/qemu-system-x86_64"
ROOTLESS_QEMU="$HOME/qemu-static/bin/qemu-system-x86_64"
OPT_QEMU="/opt/qemu-optimized/bin/qemu-system-x86_64"
HOME_QEMU="$HOME/qemu-optimized/bin/qemu-system-x86_64"

_ask_win_image_early() {
    [[ -n "${win_choice:-}" ]] && return        # already set

    if [[ -n "${AUTO_WIN:-}" ]]; then
        win_choice="$AUTO_WIN"
    elif [[ "$AUTO_MODE" == "1" ]]; then
        win_choice="5"
        echo -e "${G}🤖 AUTO MODE — Windows preset: Win10 LTSC (5)${W}"
    else
        echo ""
        echo -e "${C}════════════════════════════════════${W}"
        echo -e "${C}🪟 CHỌN PHIÊN BẢN WINDOWS (trước build)${W}"
        echo -e "${C}════════════════════════════════════${W}"
        echo "1️⃣  Windows Server 2012 R2 x64"
        echo "2️⃣  Windows Server 2022 x64"
        echo "3️⃣  Windows 11 LTSB x64"
        echo "4️⃣  Windows 10 LTSB 2015 x64"
        echo "5️⃣  Windows 10 LTSC 2023 x64"
        if [[ -t 0 ]]; then
            read -rp "👉 Nhập số [1-5]: " win_choice
        else
            win_choice="5"
            echo -e "${Y}⚠${W}  stdin không tương tác — mặc định 5 (LTSC 2023)"
        fi
    fi
    case "${win_choice:-5}" in
        1) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no"  ; RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
        2) WIN_NAME="Windows Server 2022";    WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img";   USE_UEFI="no"  ; RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
        3) WIN_NAME="Windows 11 LTSB";        WIN_URL="https://archive.org/download/win_20260203/win.img";       USE_UEFI="yes" ; RDP_USER="Admin";         RDP_PASS="Tam255Z"         ;;
        4) WIN_NAME="Windows 10 LTSB 2015";   WIN_URL="https://archive.org/download/win_20260208/win.img";       USE_UEFI="no"  ; RDP_USER="Admin";         RDP_PASS="Tam255Z"         ;;
        5|*) WIN_NAME="Windows 10 LTSC 2023"; WIN_URL="https://archive.org/download/win_20260215/win.img";       USE_UEFI="no"  ; RDP_USER="Admin";         RDP_PASS="Tam255Z"         ;;
    esac
    case "${win_choice:-5}" in
        3|4|5) RDP_USER="Admin"; RDP_PASS="Tam255Z" ;;
        *)     RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
    esac
    echo -e "${G}✔${W} Image đã chọn: ${C}${WIN_NAME}${W}"
}

# ── Start background download (parallel với build QEMU) ──────────
IMG_DL_PID=""
_IMG_DOWNLOAD_DONE=0   # set to 1 after parallel download confirms valid image
_img_valid() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    # QCOW2 check — dùng `file` command (đọc magic bytes, không cần network)
    if command -v file &>/dev/null && file "$f" 2>/dev/null | grep -qi "qcow"; then
        return 0
    fi
    # Fallback: od magic bytes
    local _magic
    _magic=$(od -An -N4 -tx1 "$f" 2>/dev/null | tr -d " \n" || echo "")
    [[ "$_magic" == "514649fb" ]] && return 0
    # Raw image: phải >= 2 GiB và header khác zero
    local sz; sz=$(stat -c%s "$f" 2>/dev/null || echo 0)
    [[ "$sz" -lt 2147483648 ]] && return 1
    # Size check only — đủ vì UEFI/Win11 có thể có 512 bytes đầu toàn zero
    return 0
}

_start_parallel_download() {
    [[ "${USE_HTTP_BACKEND:-0}" == "1" ]] && return      # HTTP mode — no download
    [[ "${SAFE_DOWNLOAD:-0}"    == "1" ]] && return      # chunked mode — keep sequential
    [[ -z "${WIN_URL:-}"               ]] && return
    _img_valid "${WIN_IMG_PATH:-win.img}" && {
        echo -e "${G}✔${W} Image đã sẵn sàng — bỏ qua tải nền"; return; }
    echo -e "${B}ℹ${W}  🔄 Tải ${WIN_NAME} nền (song song với build QEMU)..."
    :
    if command -v aria2c &>/dev/null; then
        nohup aria2c "${ARIA2_OPTS[@]}" \
            --summary-interval=30 \
            "$WIN_URL" -d "$(dirname "${WIN_IMG_PATH:-win.img}")" -o "$(basename "${WIN_IMG_PATH:-win.img}")" \
            > /tmp/dl-parallel.log 2>&1 &
    else
        nohup wget --progress=dot:giga --continue             "$WIN_URL" -O "${WIN_IMG_PATH:-win.img}"             > /tmp/dl-parallel.log 2>&1 &
    fi
    IMG_DL_PID=$!
    disown "$IMG_DL_PID" 2>/dev/null || true
    echo -e "${G}✔${W} Download bắt đầu nền (PID: $IMG_DL_PID)"
}

# ── Đợi download nền nếu chưa xong ──────────────────────────────
_wait_parallel_download() {
    [[ -z "${IMG_DL_PID:-}" ]] && return
    if kill -0 "$IMG_DL_PID" 2>/dev/null; then
        echo ""
        echo -e "${B}ℹ${W}  ⏳ Build QEMU xong — đợi download ${WIN_NAME} hoàn tất..."
        :
        local _t=0
        while kill -0 "$IMG_DL_PID" 2>/dev/null; do
            _t=$(( _t + 5 ))
            local _sz; _sz=$(du -sh "${WIN_IMG_PATH:-win.img}" 2>/dev/null | cut -f1 || echo "?")
            printf "\r${B}◜${W} Đang tải... %-6s đã tải (%ss)" "$_sz" "$_t"
            sleep 5
        done
        printf "\r${G}✔${W} Download xong!%30s\n" ""
    fi
    wait "$IMG_DL_PID" 2>/dev/null || true
    IMG_DL_PID=""
    local _wimg="${WIN_IMG_PATH:-win.img}"
    if _img_valid "$_wimg" 2>/dev/null; then
        echo -e "${G}✔${W} ${WIN_NAME:-Windows image} tải thành công"
        _IMG_DOWNLOAD_DONE=1
    elif [[ -f "$_wimg" ]]; then
        SZ_BYTES=$(stat -c%s "$_wimg" 2>/dev/null || echo 0)
        if [[ "$SZ_BYTES" -ge 2147483648 ]]; then
            echo -e "${G}✔${W} ${WIN_NAME:-Windows image} tải thành công (${SZ_BYTES} bytes)"
            _IMG_DOWNLOAD_DONE=1
        else
            echo -e "${Y}⚠${W}  File nhỏ hơn 2GB (${SZ_BYTES} bytes) — có thể chưa xong: /tmp/dl-parallel.log"
        fi
    else
        echo -e "${Y}⚠${W}  Download chưa hoàn tất — kiểm tra /tmp/dl-parallel.log"
    fi
}

ORIGINAL_DIR="$(pwd)"
export ORIGINAL_DIR
# PREFIX fallback: nếu rootless build bị bỏ qua (QEMU đã tồn tại),
# PREFIX chưa được set bởi _rootless_build → đặt fallback $HOME/qemu-static
# để các hàm phụ (qemu-img lookup, aria2 path...) tìm được đúng đường
PREFIX="${PREFIX:-$HOME/qemu-static}"
export PREFIX
_detect_apt
_detect_kvm   # ← chạy KVM detection ngay sau apt detection

# ════════════════════════════════════════════════════════════════
#  ARIA2 — đảm bảo aria2c có sẵn
#  Thứ tự: static binary (~5s) → build from source (~5min) → apt → conda (20+min)
#  conda bị skip nếu env corrupt (broken symlinks / missing meta JSON)
# ════════════════════════════════════════════════════════════════

# Kiểm tra conda env có healthy không (không bị corrupt symlink/meta)
_conda_is_healthy() {
    command -v conda &>/dev/null || return 1
    # conda info --json trả lỗi nếu env hỏng nặng
    conda info --json > /tmp/_conda_health_$$.json 2>/dev/null || return 1
    local _base
    _base="$(python3 -c "import json; d=json.load(open('/tmp/_conda_health_$$.json')); print(d.get('root_prefix',''))" 2>/dev/null)"
    rm -f /tmp/_conda_health_$$.json
    [[ -z "$_base" ]] && return 1
    [[ -d "$_base/pkgs" ]] || return 1
    # Kiểm tra broken symlink trong conda-meta
    local _meta="$_base/conda-meta"
    [[ -d "$_meta" ]] || return 1
    # Nếu có file .json nào không đọc được → corrupt
    local _bad
    _bad=$(find "$_meta" -name "*.json" -maxdepth 1 2>/dev/null | while read -r f; do
        [[ -r "$f" ]] || echo "$f"
    done | wc -l)
    [[ "$_bad" -gt 0 ]] && return 1
    return 0
}

_ensure_aria2() {
    command -v aria2c &>/dev/null && return 0  # đã có rồi

    local _bin_dir="${PREFIX:-$HOME/qemu-static}/bin"
    mkdir -p "$_bin_dir"

    # ── Thử 1: static musl binary (nhanh nhất, ~5s, không cần root) ──
    spin_start "Tải aria2 static binary..."
    local _aria2_url="https://github.com/abcfy2/aria2-static-build/releases/latest/download/aria2-x86_64-linux-musl_static.zip"
    local _tmp_zip="/tmp/aria2-static-$$.zip"
    local _tmp_dir="/tmp/aria2-static-$$"

    if wget -q --no-check-certificate "$_aria2_url" -O "$_tmp_zip" 2>/dev/null \
        || curl -fsSL --insecure "$_aria2_url" -o "$_tmp_zip" 2>/dev/null; then
        mkdir -p "$_tmp_dir"
        if unzip -q "$_tmp_zip" -d "$_tmp_dir" 2>/dev/null; then
            local _aria2c
            _aria2c=$(find "$_tmp_dir" -name "aria2c" -type f | head -1)
            if [[ -n "$_aria2c" ]]; then
                install -m755 "$_aria2c" "$_bin_dir/aria2c"
                export PATH="$_bin_dir:$PATH"
                rm -rf "$_tmp_zip" "$_tmp_dir"
                spin_stop "aria2 static binary: $_bin_dir/aria2c"
                return 0
            fi
        fi
        rm -rf "$_tmp_zip" "$_tmp_dir"
    fi
    spin_fail "static binary thất bại — thử build from source..."

    # ── Thử 2: build from source (rootless, không cần root) ─────
    # Yêu cầu: gcc, make, pkg-config, libssl-dev, libxml2-dev, libsqlite3-dev
    # Trong HPC/conda env thường có đủ compiler nhưng thiếu dev libs → fallback tiếp
    if command -v gcc &>/dev/null && command -v make &>/dev/null; then
        spin_start "Build aria2 from source (~5 phút)..."
        local _src_ver="1.37.0"
        local _src_url="https://github.com/aria2/aria2/releases/download/release-${_src_ver}/aria2-${_src_ver}.tar.gz"
        local _src_dir="/tmp/aria2-src-$$"
        local _src_tar="/tmp/aria2-src-$$.tar.gz"
        mkdir -p "$_src_dir"

        if wget -q --no-check-certificate "$_src_url" -O "$_src_tar" 2>/dev/null \
            || curl -fsSL --insecure "$_src_url" -o "$_src_tar" 2>/dev/null; then
            tar -xf "$_src_tar" -C "$_src_dir" --strip-components=1 2>/dev/null
            rm -f "$_src_tar"

            # Tắt các feature cần lib ngoài để giảm dependency
            local _cfg_flags=(
                "--prefix=$_bin_dir/.."
                "--without-sqlite3"
                "--without-libexpat"
                "--without-libcares"
                "--disable-nls"
                "--disable-bittorrent"
                "--disable-metalink"
                "--with-pic"
            )
            # Dùng pkg-config từ conda nếu có (tránh system path)
            if command -v conda &>/dev/null; then
                local _conda_prefix
                _conda_prefix="$(conda info --base 2>/dev/null)/envs/$(conda info --json 2>/dev/null | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("active_prefix_name","base"))' 2>/dev/null || echo base)"
                [[ -d "$_conda_prefix/lib/pkgconfig" ]] && \
                    export PKG_CONFIG_PATH="$_conda_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
            fi

            if (cd "$_src_dir" && \
                ./configure "${_cfg_flags[@]}" > /tmp/aria2-cfg-$$.log 2>&1 && \
                make -j"$(nproc)" > /tmp/aria2-make-$$.log 2>&1 && \
                make install > /dev/null 2>&1); then
                rm -rf "$_src_dir" /tmp/aria2-cfg-$$.log /tmp/aria2-make-$$.log
                export PATH="$_bin_dir:$PATH"
                if command -v aria2c &>/dev/null; then
                    spin_stop "aria2 build from source xong: $_bin_dir/aria2c"
                    return 0
                fi
            else
                echo -e "\n${Y}  configure log: $(tail -3 /tmp/aria2-cfg-$$.log 2>/dev/null)${W}" >&2
                rm -rf "$_src_dir" /tmp/aria2-cfg-$$.log /tmp/aria2-make-$$.log
            fi
        fi
        rm -rf "$_src_dir" "$_src_tar" 2>/dev/null
        spin_fail "build from source thất bại — thử apt..."
    else
        echo -e "${Y}⚠${W}  Thiếu gcc/make — bỏ qua build from source"
    fi

    # ── Thử 3: apt / apt-get (nếu root hoặc sudo) ───────────────
    local _apt=""
    command -v apt-get &>/dev/null && _apt="apt-get"
    command -v apt     &>/dev/null && _apt="apt"
    if [[ -n "$_apt" ]]; then
        spin_start "Cài aria2 qua $_apt..."
        if [[ "$(id -u)" == "0" ]]; then
            $_apt install -y -qq aria2 > /dev/null 2>&1 \
                && spin_stop "aria2 qua $_apt xong" \
                && return 0
        elif sudo -n true 2>/dev/null; then
            sudo $_apt install -y -qq aria2 > /dev/null 2>&1 \
                && spin_stop "aria2 qua sudo $_apt xong" \
                && return 0
        fi
        spin_fail "apt không cài được aria2 — thử conda (chậm)..."
    fi

    # ── Thử 4: conda (cuối cùng — chậm, 5-20 phút) ─────────────
    if command -v conda &>/dev/null; then
        if ! _conda_is_healthy; then
            echo -e "${Y}⚠${W}  conda env bị corrupt (broken symlinks / missing meta) — bỏ qua conda"
            echo -e "${B}ℹ${W}  Gợi ý: chạy ${C}conda clean --packages --tarballs${W} để thử phục hồi"
        else
            spin_start "Cài aria2 từ conda (chậm, vui lòng chờ)..."
            conda install -y -q -c conda-forge aria2 > /dev/null 2>&1 \
                || conda install -y -q aria2 > /dev/null 2>&1 || true
            if command -v aria2c &>/dev/null; then
                spin_stop "aria2 từ conda-forge xong"
                return 0
            fi
            spin_fail "aria2 conda thất bại"
        fi
    fi

    spin_fail "Không cài được aria2 — sẽ dùng wget/curl thay thế"
    return 1
}

# ════════════════════════════════════════════════════════════════
#  ISO MODE — boot từ Windows ISO (--iso=URL [--virtio=URL])
# ════════════════════════════════════════════════════════════════
_iso_mode_run() {
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}⬡  WINBOX — ISO Boot Mode${W}"
    echo -e "${C}════════════════════════════════════${W}"

    # ── Bước 1: Đảm bảo có QEMU ──────────────────────────────────
    spin_start "Kiểm tra QEMU..."
    AUTO_BUILD="${AUTO_BUILD:-}"
    local _qemu_ok=0
    for _q in "$HOME/qemu-static/bin/qemu-system-x86_64" \
              "$HOME/qemu-optimized/bin/qemu-system-x86_64" \
              "/opt/qemu-optimized/bin/qemu-system-x86_64" \
              "/usr/bin/qemu-system-x86_64" \
              "$(command -v qemu-system-x86_64 2>/dev/null || true)"; do
        [[ -x "$_q" ]] || continue
        if "$_q" --help 2>&1 | grep -q "\-display"; then
            QEMU_BIN="$_q"; _qemu_ok=1; break
        fi
    done
    if [[ "$_qemu_ok" == "0" || "$AUTO_BUILD" == "yes" ]]; then
        spin_stop "QEMU chưa có — tiến hành build..."
        AUTO_BUILD="yes"
        # Luôn kiểm tra ROOTLESS trước để đảm bảo rootless mode hoạt động đúng trong ISO mode
        if [[ "$ROOTLESS" == "1" ]]; then
            spin_start "Build QEMU (rootless — ISO mode)..."
            _rootless_build 2>&1
            spin_stop "Build QEMU xong"
        elif [[ "$(id -u)" == "0" ]] && [[ "$APT_OK" == "1" ]]; then
            spin_start "Build QEMU (apt/root — ISO mode)..."
            _rootless_build 2>&1
            spin_stop "Build QEMU xong"
        else
            spin_start "Build QEMU (rootless fallback — ISO mode)..."
            _rootless_build 2>&1
            spin_stop "Build QEMU xong"
        fi
    else
        spin_stop "QEMU: $QEMU_BIN"
    fi

    # ── Resolve qemu-img ─────────────────────────────────────────
    local _qemu_bin_dir; _qemu_bin_dir="$(dirname "$QEMU_BIN")"
    QEMU_IMG=""
    for _qi in "$_qemu_bin_dir/qemu-img"                "$HOME/qemu-static/bin/qemu-img"                "$HOME/qemu-optimized/bin/qemu-img"                "/opt/qemu-optimized/bin/qemu-img"                "/usr/bin/qemu-img"                "/usr/local/bin/qemu-img"                "$(command -v qemu-img 2>/dev/null || true)"; do
        [[ -x "$_qi" ]] && { QEMU_IMG="$_qi"; break; }
    done
    if [[ -z "$QEMU_IMG" ]]; then
        # qemu-img không có → thử cài qua apt
        if [[ "$(id -u)" == "0" ]] && command -v apt-get &>/dev/null; then
            echo -e "${B}ℹ${W}  qemu-img không có — thử cài qemu-utils..."
            apt-get install -y -qq qemu-utils >/dev/null 2>&1 &&                 QEMU_IMG="$(command -v qemu-img 2>/dev/null || true)"
        elif sudo -n true 2>/dev/null && command -v apt-get &>/dev/null; then
            echo -e "${B}ℹ${W}  qemu-img không có — thử cài qemu-utils (sudo)..."
            sudo apt-get install -y -qq qemu-utils >/dev/null 2>&1 &&                 QEMU_IMG="$(command -v qemu-img 2>/dev/null || true)"
        fi
    fi
    if [[ -z "$QEMU_IMG" ]]; then
        # Fallback cuối: raw disk không cần qemu-img — dùng truncate/dd
        echo -e "${Y}⚠${W}  qemu-img không có — dùng truncate để tạo raw disk (không cần qemu-img)"
        QEMU_IMG="__truncate__"
    else
        echo -e "${G}✔${W}  qemu-img: $QEMU_IMG"
    fi

    # ── Helper: tạo raw disk ────────────────────────────────────
    _create_raw_disk() {
        local _path="$1" _gb="$2"
        if [[ "$QEMU_IMG" != "__truncate__" ]]; then
            "$QEMU_IMG" create -f raw "$_path" "${_gb}G" 2>&1
        else
            truncate -s "${_gb}G" "$_path" 2>&1
        fi
    }

    # ── Bước 2: Đảm bảo aria2c có sẵn ───────────────────────────
    _ensure_aria2 || true  # không fatal — fallback wget/curl trong _iso_download

    # ── Bước 3: Tải ISOs ─────────────────────────────────────────
    local _iso_dir="$HOME/.cache/winbox-iso"
    mkdir -p "$_iso_dir"
    cd "$_iso_dir"

    if [[ -z "$ISO_WIN_URL" ]]; then
        echo ""
        read -rp "$(echo -e "${B}📀${W} Nhập URL Windows ISO: ")" ISO_WIN_URL
        if [[ -z "$ISO_WIN_URL" ]]; then
            echo -e "${R}✘${W}  Cần URL Windows ISO. Dùng: bash winbox.sh --iso=URL"
            exit 1
        fi
    fi

    # ── Helper tải file với aria2 → wget → curl fallback ─────────
    _iso_download() {
        local _url="$1" _out="$2" _label="$3"
        local _full_path="$_iso_dir/$_out"
        spin_start "Kiểm tra ${_label}..."

        if [[ -f "$_full_path" ]]; then
            local _sz
            _sz=$(stat -c%s "$_full_path" 2>/dev/null || echo 0)
            if [[ "$_sz" -lt 104857600 ]]; then
                # < 100MB — rõ ràng incomplete/corrupt
                spin_stop "${Y}⚠${W}  ${_label} có nhưng < 100MB ($_sz bytes) — xóa và tải lại"
                rm -f "$_full_path" "$_full_path".aria2
            else
                spin_stop "${_label} đã có ($_sz bytes)"
                echo ""
                local _yn
                read -rp "$(echo -e "${Y}?${W}  Tải lại ${_label}? [y/N]: ")" _yn
                if [[ "${_yn,,}" == "y" ]]; then
                    rm -f "$_full_path" "$_full_path".aria2
                    echo -e "${B}ℹ${W}  Đã xóa — bắt đầu tải lại..."
                else
                    echo -e "${G}✔${W}  Dùng file cũ"
                    return 0
                fi
            fi
        fi

        # Thử aria2c trước — multi-connection, resume, progress
        if command -v aria2c &>/dev/null; then
            spin_stop "Tải ${_label} bằng aria2c..."
            aria2c "${ARIA2_OPTS[@]}" \
                --out="$_out" \
                --dir="$_iso_dir" \
                "$_url" \
            && { echo -e "${G}✔${W} ${_label} tải xong (aria2c)"; return 0; }
            echo -e "${Y}⚠${W}  aria2c thất bại — thử wget..."
        fi

        # Fallback wget
        if command -v wget &>/dev/null; then
            spin_stop "Tải ${_label} bằng wget..."
            wget --no-check-certificate --show-progress -O "$_iso_dir/$_out" "$_url" \
            && { echo -e "${G}✔${W} ${_label} tải xong (wget)"; return 0; }
            echo -e "${Y}⚠${W}  wget thất bại — thử curl..."
        fi

        # Fallback curl
        spin_stop "Tải ${_label} bằng curl..."
        curl -fL --insecure --progress-bar -o "$_iso_dir/$_out" "$_url" \
        && { echo -e "${G}✔${W} ${_label} tải xong (curl)"; return 0; }

        echo -e "${R}✘${W} Không tải được ${_label} từ: $_url"
        return 1
    }

    _iso_download "$ISO_WIN_URL" "win.iso" "Windows ISO" \
        || exit 1

    if [[ -n "$ISO_VIRTIO_URL" ]]; then
        _iso_download "$ISO_VIRTIO_URL" "virtio.iso" "VirtIO ISO" \
            || exit 1
    fi

    # ── Bước 3: Tạo disk ─────────────────────────────────────────
    local _disk_gb="60"
    local _cpu_cores="2"
    local _ram_gb="4"
    local _host_cores; _host_cores=$(nproc 2>/dev/null || echo 4)
    local _host_ram_gb; _host_ram_gb=$(awk '/MemTotal/{printf "%d", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 8)
    echo ""

    if [[ -f "$_iso_dir/win.img" ]]; then
        local _exist_sz
        if [[ "$QEMU_IMG" != "__truncate__" ]]; then
            _exist_sz=$("$QEMU_IMG" info "$_iso_dir/win.img" 2>/dev/null | awk '/virtual size/{print $3$4}' || echo "?")
        else
            _exist_sz=$(du -sh "$_iso_dir/win.img" 2>/dev/null | cut -f1 || echo "?")
        fi
        read -rp "$(echo -e "${Y}?${W}  win.img đã có (${_exist_sz}) — tạo lại không? [y/N]: ")" _yn
        if [[ "${_yn,,}" == "y" ]]; then
            read -rp "$(echo -e "${B}💾${W} Dung lượng disk mới (GB) [mặc định 60]: ")" _disk_raw
            _disk_raw=$(printf '%s' "${_disk_raw}" | tr -cd '0-9')
            [[ -n "$_disk_raw" ]] && _disk_gb="$_disk_raw"
            rm -f "$_iso_dir/win.img"
            spin_start "Tạo lại win.img raw (${_disk_gb}G)..."
            local _qimg_err2
            local _qimg_err2
            _qimg_err2=$(_create_raw_disk "$_iso_dir/win.img" "$_disk_gb" 2>&1) || {
                spin_stop ""
                echo -e "${R}✘${W}  Tạo disk thất bại: ${_qimg_err2}"
                echo -e "${B}ℹ${W}  Kiểm tra dung lượng trống: df -h ."
                return 1
            }
            spin_stop "Disk ${_disk_gb}G tạo xong"
        else
            echo -e "${G}✔${W}  Dùng disk cũ: $_iso_dir/win.img (${_exist_sz})"
        fi
    else
        read -rp "$(echo -e "${B}💾${W} Dung lượng disk (GB) [mặc định 60]: ")" _disk_raw
        _disk_raw=$(printf '%s' "${_disk_raw}" | tr -cd '0-9')
        [[ -n "$_disk_raw" ]] && _disk_gb="$_disk_raw"
        spin_start "Tạo win.img raw (${_disk_gb}G)..."
        local _qimg_err
        local _qimg_err
        _qimg_err=$(_create_raw_disk "$_iso_dir/win.img" "$_disk_gb" 2>&1) || {
            spin_stop ""
            echo -e "${R}✘${W}  Tạo disk thất bại: ${_qimg_err}"
            echo -e "${B}ℹ${W}  Kiểm tra dung lượng trống: df -h ."
            return 1
        }
        spin_stop "Disk ${_disk_gb}G tạo xong"
    fi

    read -rp "$(echo -e "${B}🖥️${W}  Số CPU cores [mặc định 2, host có ${_host_cores}]: ")" _cores_raw
    _cores_raw=$(printf '%s' "${_cores_raw}" | tr -cd '0-9')
    if [[ -n "$_cores_raw" && "$_cores_raw" -ge 1 ]]; then
        [[ "$_cores_raw" -gt "$_host_cores" ]] && \
            echo -e "${Y}⚠${W}  ${_cores_raw} cores > host (${_host_cores}) — có thể chậm" || true
        _cpu_cores="$_cores_raw"
    fi

    read -rp "$(echo -e "${B}🧠${W}  RAM (GB) [mặc định 4, host có ${_host_ram_gb}GB]: ")" _ram_raw
    _ram_raw=$(printf '%s' "${_ram_raw}" | tr -cd '0-9')
    if [[ -n "$_ram_raw" && "$_ram_raw" -ge 1 ]]; then
        [[ "$_ram_raw" -gt "$_host_ram_gb" ]] && \
            echo -e "${Y}⚠${W}  ${_ram_raw}GB RAM > host (${_host_ram_gb}GB) — có thể gây swap" || true
        _ram_gb="$_ram_raw"
    fi

    # ── Bước 4: Khởi động VM ─────────────────────────────────────
    local _has_virtio_iso=0
    [[ -f "$_iso_dir/virtio.iso" && -n "$ISO_VIRTIO_URL" ]] && _has_virtio_iso=1

    # ── Detect KVM + CPU model (giống normal mode) ───────────────
    local _kvm_ok=0
    local _cpu_val
    local _machine_val="q35,vmport=off"
    local _kvm_accel_args
    local _tcg_tb_mb=4096

    if [[ -r /dev/kvm ]]; then
        _kvm_ok=1
        _kvm_accel_args=(-accel kvm)
        _cpu_val="host"
        _machine_val="q35"
        echo -e "${G}✔${W}  KVM phát hiện — dùng -cpu host -accel kvm"
    else
        echo -e "${Y}⚠${W}  KVM không có — dùng TCG software emulation"

        # ── TCG TB cache ──────────────────────────────────────────
        local _host_ram_iso; _host_ram_iso=$(awk '/MemTotal/{printf "%.0f",$2/1024/1024}' /proc/meminfo 2>/dev/null || echo 4)
        [[ "${_host_ram_iso:-0}" -lt 1 ]] && _host_ram_iso=4
        _tcg_tb_mb=4096
        [[ "$_tcg_tb_mb" -gt 16384 ]] && _tcg_tb_mb=16384
        _kvm_accel_args=(-accel "tcg,thread=multi,split-wx=off,one-insn-per-tb=off,tb-size=${_tcg_tb_mb}")
        echo -e "${G}⚡ TCG TB cache: ${_tcg_tb_mb}MB | multi-thread${W}"

        # ── CPU model-id (giống normal mode) ─────────────────────
        local _raw_cpu_name _cpu_vendor _cpu_name_useful _stripped
        _raw_cpu_name=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | sed 's/^.*: //' || echo "")
        _cpu_vendor=$(grep -m1 "vendor_id"  /proc/cpuinfo 2>/dev/null | awk '{print $NF}' || echo "")
        _cpu_name_useful=0
        _stripped=$(printf '%s' "$_raw_cpu_name" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
        if [[ -n "$_stripped" && "$_stripped" != "unknown" && ${#_stripped} -ge 4 ]]; then
            printf '%s' "$_stripped" | grep -q '[a-z]' && _cpu_name_useful=1
        fi

        local _cpu_host _cpu_model_id _cpu_extra
        if [[ "$_cpu_name_useful" == "1" ]]; then
            _cpu_host="$_raw_cpu_name"
            _cpu_model_id=$(printf '%s' "$_cpu_host"                 | tr ',' ' '                 | tr -d '"\@#$%^&*|<>'                 | sed 's/[[:space:]]\+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//'                 | cut -c1-48)
        else
            case "$_cpu_vendor" in
                GenuineIntel) _cpu_host="Intel Xeon Gold 6254" ;;
                AuthenticAMD) _cpu_host="AMD EPYC 7763" ;;
                HygonGenuine) _cpu_host="Hygon C86 7185" ;;
                CentaurHauls) _cpu_host="VIA Nano" ;;
                *)            _cpu_host="Generic x86_64" ;;
            esac
            _cpu_model_id="${_cpu_host} Processor"
            echo -e "${Y}⚠${W}  CPU name không đọc được — dùng fallback: ${_cpu_model_id}"
        fi
        _cpu_extra=
        grep -q ssse3  /proc/cpuinfo && _cpu_extra="${_cpu_extra},+ssse3"
        grep -q sse4_1 /proc/cpuinfo && _cpu_extra="${_cpu_extra},+sse4.1"
        grep -q sse4_2 /proc/cpuinfo && _cpu_extra="${_cpu_extra},+sse4.2"
        grep -q rdtscp /proc/cpuinfo && _cpu_extra="${_cpu_extra},+rdtscp"
        grep -q ' avx ' /proc/cpuinfo && _cpu_extra="${_cpu_extra},+avx"
        grep -q avx2   /proc/cpuinfo && _cpu_extra="${_cpu_extra},+avx2"
        _cpu_val="qemu64,hypervisor=off,tsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+cx16,+x2apic,+sep,+pat,+pse,+aes,+popcnt${_cpu_extra},model-id=${_cpu_model_id}"
        echo -e "${G}✔${W}  CPU model: ${_cpu_host}  |  flags:${_cpu_extra:-none}"
    fi

    local _launch_cmd=(
        "$QEMU_BIN"
        -machine "${_machine_val}"
        -cpu "${_cpu_val}"
        -smp "${_cpu_cores},sockets=1,cores=${_cpu_cores},threads=1"
        -m "${_ram_gb}G"
        "${_kvm_accel_args[@]}"
        -object iothread,id=io1
        -drive file="$_iso_dir/win.img",if=none,id=disk0,format=raw,cache=unsafe,aio=threads,discard=on
        -device virtio-blk-pci,drive=disk0,iothread=io1,num-queues=1,queue-size=128
        -cdrom "$_iso_dir/win.iso"
    )
    if [[ "$_has_virtio_iso" == "1" ]]; then
        _launch_cmd+=(
            -drive file="$_iso_dir/virtio.iso",media=cdrom,if=none,id=cdvirtio
            -device ide-cd,drive=cdvirtio
        )
    fi

    _launch_cmd+=(
        -device virtio-gpu-pci
        -device qemu-xhci,id=xhci
        -device usb-tablet,bus=xhci.0
        -device usb-kbd,bus=xhci.0
        -netdev user,id=n0,hostfwd=tcp::3389-:3389
        -device virtio-net-pci,netdev=n0
        -display vnc=:0,share=force-shared
        -boot order=c,menu=on
        -daemonize
    )

    spin_start "Khởi động ISO VM..."
    "${_launch_cmd[@]}"
    spin_stop "ISO VM đã khởi động"

    # ── Summary ───────────────────────────────────────────────────
    echo ""
    echo -e "${C}════════════════════════════════════════════${W}"
    echo -e "${C}⬡  WINBOX — ISO Boot${W}"
    echo -e "${C}════════════════════════════════════════════${W}"
    echo -e "📀 ISO Boot   : ${G}VM đang chạy${W}"
    if [[ "$_kvm_ok" == "1" ]]; then
        echo -e "⚡ Accel      : ${G}KVM + -cpu host${W}"
    else
        echo -e "⚡ Accel      : ${Y}TCG | TB: ${_tcg_tb_mb}MB${W}"
        echo -e "🧠 CPU Model  : ${B}${_cpu_host:-qemu64}${W}"
    fi
    echo -e "🖥  VNC        : ${G}localhost:5900${W}"
    echo -e "              → vncviewer localhost:5900"
    echo -e "              → TigerVNC / RealVNC / any VNC client"
    echo -e "🌐 RDP port   : ${G}localhost:3389${W}  (sau khi cài Windows)"
    echo -e "💾 Disk       : ${B}${_iso_dir}/win.img${W}  (${_disk_gb}G, raw)"
    if [[ "$_has_virtio_iso" == "1" ]]; then
        echo -e "📦 VirtIO     : ${B}${_iso_dir}/virtio.iso${W}"
    fi
    echo -e "${C}════════════════════════════════════════════${W}"
}

# ── ISO mode early exit ────────────────────────────────────────
if [[ "$ISO_MODE" == "1" ]]; then
    _iso_mode_run
    exit 0
fi

# ═══════════════════════════════════════════════════════════════
#  MENU CHÍNH — phải hiện trước khi hỏi bất cứ gì
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${C}════════════════════════════════════${W}"
echo -e "${C}⬡  WINBOX${W}"
if [[ "$KVM_AVAILABLE" == "1" ]]; then
    echo -e "${C}⚡ Acceleration: ${G}KVM (hardware)${C}${W}"
else
    echo -e "${C}⚡ Acceleration: ${Y}TCG (software)${C}${W}"
fi
echo -e "${C}════════════════════════════════════${W}"

if [[ "$AUTO_MODE" == "1" ]]; then
    echo -e "${G}🤖 AUTO MODE — bỏ qua menu, tiến hành tạo VM${W}"
    main_choice="1"
else
    echo "1️⃣  Tạo Windows VM"
    echo "2️⃣  Quản Lý Windows VM"
    echo "3️⃣  Xoá VM (xoá tiến trình + img)"
    echo -e "${C}════════════════════════════════════${W}"
    read -rp "👉 Nhập lựa chọn [1-3]: " main_choice
fi
# ── Early exit cho case 2 & 3 (tránh build QEMU / cài aria2 không cần thiết) ──
case "$main_choice" in
2)
    echo ""
    echo -e "${C}🚀 ===== MANAGE RUNNING VM =====${W}"
    if pgrep -f 'qemu-system-x86_64' > /dev/null; then
        while IFS= read -r pid; do
            [[ -n "$pid" ]] || continue
            cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline")
            vcpu=$(sed -n 's/.*-smp \([^ ,]*\).*/\1/p' <<< "$cmd")
            ram=$(sed -n  's/.*-m \([^ ]*\).*/\1/p'    <<< "$cmd")
            cpu=$(ps -p "$pid" -o %cpu= 2>/dev/null || echo "?")
            mem=$(ps -p "$pid" -o %mem= 2>/dev/null || echo "?")
            echo -e "🆔 PID: ${Y}${pid}${W}  |  vCPU: ${B}${vcpu}${W}  |  RAM: ${B}${ram}${W}  |  CPU: ${G}${cpu}%${W}  |  MEM: ${R}${mem}%${W}"
        done < <(pgrep -f 'qemu-system-x86_64')
    else
        echo -e "${R}❌ Không có VM nào đang chạy${W}"
    fi
    echo -e "${C}==================================${W}"
    read -rp "🆔 Nhập PID VM muốn tắt (hoặc Enter để bỏ qua): " kill_pid
    if [[ -n "$kill_pid" && -d "/proc/$kill_pid" ]]; then
        kill "$kill_pid" 2>/dev/null || true
        echo -e "${G}✅ Đã gửi tín hiệu tắt VM PID $kill_pid${W}"
    fi
    exit 0
    ;;

3)
    echo ""
    echo -e "${C}🗑️  ===== XOÁ VM =====${W}"
    BUILD="${BUILD:-/tmp/qemu-build}"
    IMG_LIST=(); IMG_LABEL=()
    for _p in \
        "$BUILD/win.img" "/tmp/qemu-build/win.img" "$HOME/win.img" \
        "/content/win.img" "$(pwd)/win.img" \
        "$BUILD/2012.img" "$BUILD/2022.img" \
        "/tmp/qemu-build/2012.img" "/tmp/qemu-build/2022.img"; do
        if [[ -f "$_p" ]]; then
            SIZE=$(du -sh "$_p" 2>/dev/null | cut -f1 || echo "?")
            IMG_LIST+=("$_p"); IMG_LABEL+=("$_p  [${SIZE}]")
        fi
    done
    RUNNING_PIDS=()
    while IFS= read -r pid; do
        [[ -n "$pid" ]] && RUNNING_PIDS+=("$pid")
    done < <(pgrep -f 'qemu-system-x86_64' 2>/dev/null || true)
    echo -e "${C}── VM đang chạy: ──────────────────────${W}"
    if [[ "${#RUNNING_PIDS[@]}" -gt 0 ]]; then
        for pid in "${RUNNING_PIDS[@]}"; do
            cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || echo "")
            img=$(grep -oE -- '-drive file=[^ ,]+' <<< "$cmd" | cut -d= -f3 | head -1)
            echo -e "  🆔 PID ${Y}${pid}${W}  |  img: ${B}${img:-unknown}${W}"
        done
    else
        echo -e "  ${B}(không có VM nào đang chạy)${W}"
    fi
    echo -e "${C}── Image files tìm thấy: ───────────────${W}"
    if [[ "${#IMG_LIST[@]}" -gt 0 ]]; then
        for i in "${!IMG_LIST[@]}"; do
            echo -e "  $((i+1)). ${IMG_LABEL[$i]}"
        done
    else
        echo -e "  ${B}(không tìm thấy img nào)${W}"
    fi
    echo -e "${C}═══════════════════════════════════════${W}"
    echo -e "${R}⚠️  Xoá VM sẽ:${W}"
    echo -e "   1. Kill tất cả tiến trình qemu-system-x86_64"
    echo -e "   2. Dừng QEMU processes"
    echo -e "   3. Xoá các img file được chọn"
    echo -e "${C}═══════════════════════════════════════${W}"
    read -rp "❓ Bạn có chắc muốn xoá VM không? (yes/n): " confirm_delete
    confirm_delete=$(echo "${confirm_delete:-n}" | tr -cd 'a-zA-Z')
    if [[ "$confirm_delete" != "yes" ]]; then
        echo -e "${Y}⚠️  Huỷ — không xoá gì cả${W}"
        exit 0
    fi
    if [[ "${#RUNNING_PIDS[@]}" -gt 0 ]]; then
        echo -e "${B}ℹ${W}  Kill VM processes..."
        for pid in "${RUNNING_PIDS[@]}"; do
            kill -SIGTERM "$pid" 2>/dev/null || true
        done
        sleep 2
        for pid in "${RUNNING_PIDS[@]}"; do
            kill -0 "$pid" 2>/dev/null && kill -SIGKILL "$pid" 2>/dev/null || true
        done
        echo -e "${G}✔${W} Đã kill tất cả QEMU processes"
    else
        echo -e "${B}ℹ${W}  Không có QEMU process nào"
    fi
    rm -f /tmp/frpc-rdp.* /tmp/frpc-watchdog.pid 2>/dev/null || true
    if [[ "${#IMG_LIST[@]}" -gt 0 ]]; then
        if [[ "${#IMG_LIST[@]}" -eq 1 ]]; then
            del_choice="1"
        else
            echo ""; echo "Chọn img muốn xoá:"
            for i in "${!IMG_LIST[@]}"; do echo "  $((i+1)). ${IMG_LABEL[$i]}"; done
            echo "  a. Xoá tất cả"; echo "  0. Không xoá img nào"
            read -rp "👉 Nhập số (hoặc 'a' cho tất cả): " del_choice
            del_choice=$(echo "${del_choice:-0}" | tr -cd '0-9a')
        fi
        if [[ "$del_choice" == "a" ]]; then
            for p in "${IMG_LIST[@]}"; do rm -f "$p" && echo -e "${G}✔${W} Đã xoá: $p" || echo -e "${R}✘${W} Không xoá được: $p"; done
        elif [[ "$del_choice" =~ ^[0-9]+$ && "$del_choice" -ge 1 && "$del_choice" -le "${#IMG_LIST[@]}" ]]; then
            idx=$(( del_choice - 1 ))
            rm -f "${IMG_LIST[$idx]}" && echo -e "${G}✔${W} Đã xoá: ${IMG_LIST[$idx]}" || echo -e "${R}✘${W} Không xoá được: ${IMG_LIST[$idx]}"
        else
            echo -e "${B}ℹ${W}  Bỏ qua xoá img"
        fi
    fi
    rm -f /tmp/qemu-launch.log /tmp/frpc-rdp.* /tmp/frpc-watchdog.pid 2>/dev/null || true
    echo ""; echo -e "${G}✅ Xoá VM hoàn tất${W}"
    exit 0
    ;;
esac

# Case 1 falls through — tiếp tục build/download
_ask_win_image_early
WIN_IMG_PATH="${ORIGINAL_DIR:-$(pwd)}/win.img"
export WIN_IMG_PATH

_detect_existing_qemu() {
    for q in "$OPT_QEMU" "$HOME_QEMU" "$ROOTLESS_QEMU" "$QEMU_BIN" \
              "$(command -v qemu-system-x86_64 2>/dev/null)"; do
        if [[ -n "$q" && -x "$q" ]]; then
            local qv
            qv=$("$q" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
            echo -e "${G}⚡ Tìm thấy QEMU v${qv} tại: $q${W}"
            export QEMU_BIN="$q"
            export PATH="$(dirname "$q"):$PATH"
            [[ "$q" == "$OPT_QEMU" || "$q" == "$HOME_QEMU" ]] && export QEMU_BUILT_BIN="$q"
            return 0
        fi
    done
    return 1
}

if _detect_existing_qemu; then
    QEMU_VER=$("$QEMU_BIN" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "?")
    if [[ "$AUTO_BUILD" == "yes" ]]; then
        choice="y"
        echo -e "${Y}⚠${W}  --rebuild: build lại QEMU v${QEMU_VER}"
    elif [[ "$AUTO_BUILD" == "no" || "$AUTO_MODE" == "1" ]]; then
        choice="n"
        echo -e "${G}✔${W} QEMU v${QEMU_VER} đã có — bỏ qua build (dùng --rebuild để build lại)"
    else
        echo -e "${G}✔${W} QEMU v${QEMU_VER} đã có — bỏ qua build"
        echo -e "${B}ℹ${W}  Dùng --rebuild nếu muốn build lại"
        choice="n"
    fi
else
    if [[ "$AUTO_BUILD" == "no" ]]; then
        choice="n"
        echo -e "${Y}⚠${W}  --no-build: bỏ qua build (QEMU chưa có, có thể lỗi)"
    elif [[ "$AUTO_MODE" == "1" || "$AUTO_BUILD" == "yes" ]]; then
        choice="y"
        echo -e "${G}🤖 Chưa có QEMU — tiến hành build${W}"
    else
        choice=$(ask "👉 Chưa tìm thấy QEMU. Build ngay không? (y/n): " "y")
    fi
fi

if [[ "$choice" == "y" ]]; then

    if [[ "$ROOTLESS" == "1" ]]; then
        # Cài aria2 TRƯỚC khi tải image — để _start_parallel_download dùng được aria2c
        # (không phải fallback wget). Aria2 cần conda nên cài ngay ở đây.
        _ensure_aria2 || true
        # Bắt đầu tải image nền TRƯỚC khi build để tối đa hoá parallelism
        # (rootless build mất 20-40 phút — đủ thời gian tải xong 10GB image)
        WIN_IMG_PATH="${ORIGINAL_DIR:-$(pwd)}/win.img"
        _start_parallel_download
        [[ -n "$IMG_DL_PID" ]] && echo -e "${B}ℹ${W}  🔀 Tải image song song với toàn bộ rootless build (PID: $IMG_DL_PID)"
        _rootless_build
    elif [[ -x "/opt/qemu-optimized/bin/qemu-system-x86_64" && "$AUTO_BUILD" != "yes" ]]; then
        BUILT_VER=$("/opt/qemu-optimized/bin/qemu-system-x86_64" --version 2>/dev/null \
            | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}⚡ QEMU v${BUILT_VER} đã có tại /opt/qemu-optimized — bỏ qua build${W}"
        echo -e "${B}ℹ${W}  Dùng --rebuild để build lại"
        export QEMU_BIN="/opt/qemu-optimized/bin/qemu-system-x86_64"
        export PATH="/opt/qemu-optimized/bin:$PATH"
        export LD_LIBRARY_PATH="/opt/qemu-optimized/lib:${LD_LIBRARY_PATH:-}"
    elif [[ -x "$HOME/qemu-optimized/bin/qemu-system-x86_64" && "$AUTO_BUILD" != "yes" ]]; then
        BUILT_VER=$("$HOME/qemu-optimized/bin/qemu-system-x86_64" --version 2>/dev/null \
            | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}⚡ QEMU v${BUILT_VER} đã có tại ~/qemu-optimized — bỏ qua build${W}"
        export QEMU_BIN="$HOME/qemu-optimized/bin/qemu-system-x86_64"
        export PATH="$HOME/qemu-optimized/bin:$PATH"
    elif [[ -x "$QEMU_BIN" && "$AUTO_BUILD" != "yes" ]]; then
        BUILT_VER=$("$QEMU_BIN" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
        echo -e "${G}⚡ QEMU v${BUILT_VER} đã tồn tại — bỏ qua build${W}"
        export PATH="/opt/qemu-optimized/bin:$PATH"
    else
        echo ""
        $APT_CMD update -qq > /dev/null 2>&1

        DEPS=(
            "lsb-release|lsb-release|lsb_release"
            "wget|wget|wget"
            "gnupg|gnupg|gpg"
            "build-essential|build-essential|gcc"
            "ninja-build|ninja-build|ninja"
            "git|git|git"
            "python3-venv|python3-venv|python3"
            "python3-pip|python3-pip|pip3"
            "pkg-config|pkg-config|pkg-config"
            "aria2|aria2|aria2c"
            "ovmf|ovmf|"
            "libglib2.0-dev|libglib2.0-dev|"
            "libpixman-1-dev|libpixman-1-dev|"
            "zlib1g-dev|zlib1g-dev|"
            "libslirp-dev|libslirp-dev|"
            "meson|meson|meson"
            "software-properties-common|software-properties-common|"
            "genisoimage|genisoimage|genisoimage"
        )

        TOTAL=${#DEPS[@]}; IDX=0
        for entry in "${DEPS[@]}"; do
            IFS='|' read -r label pkg chk <<< "$entry"
            IDX=$(( IDX + 1 ))
            if [[ -n "$chk" ]] && command -v "$chk" &>/dev/null; then continue; fi
            if dpkg -s "$pkg" &>/dev/null 2>&1; then continue; fi
            _rl_step "$IDX" "$TOTAL"
            apt_install "$pkg" || true
        done
        _rl_ok "apt deps xong"

        export CC="${CC:-gcc}"
        export CXX="${CXX:-g++}"
        LLD_AVAILABLE=0

        GLIB_VER=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "0.0.0")
        if ver_lt "$GLIB_VER" "2.66"; then
            _rl_warn "glib cũ — build 2.76.6"
            :
            silent sudo apt-get install -y libffi-dev gettext
            cd /tmp; silent wget -q https://download.gnome.org/sources/glib/2.76/glib-2.76.6.tar.xz
            :
            :
            if command -v xz &>/dev/null; then
                silent tar -xf /tmp/glib-2.76.6.tar.xz -C /tmp
            else
                python3 -c "
import lzma, tarfile, os
os.chdir('/tmp')
with lzma.open('glib-2.76.6.tar.xz') as f:
    with tarfile.open(fileobj=f) as t:
        t.extractall('.')
" 2>/dev/null
            fi
            :
            :
            cd glib-2.76.6; silent meson setup build --prefix=/usr/local
            silent ninja -C build; silent sudo ninja -C build install
            _rl_ok "glib 2.76.6 xong"
            export PKG_CONFIG_PATH="/usr/local/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
            export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:/usr/local/lib:${LD_LIBRARY_PATH:-}"
        else
            echo -e "${G}✔ glib đủ yêu cầu: $GLIB_VER${W}"
        fi

        PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        :
        # Ưu tiên gói versioned (python3.X-venv) — bắt buộc với Python 3.12+ trên Ubuntu 24.04
        VENV_PKG_VER="python${PY_VER}-venv"
        VENV_PKG_GEN="python3-venv"
        _venv_pkg_ok=0
        dpkg -s "$VENV_PKG_VER" &>/dev/null 2>&1 && _venv_pkg_ok=1
        dpkg -s "$VENV_PKG_GEN" &>/dev/null 2>&1 && _venv_pkg_ok=1
        if [[ "$_venv_pkg_ok" == "0" ]]; then
            echo -ne "${B}◜${W} Cài ${VENV_PKG_VER}..."
            # Dùng $APT_CMD thay vì sudo apt-get (tránh sudo khi đã là root)
            $APT_CMD install -y -qq "$VENV_PKG_VER" > /dev/null 2>&1 \
                || $APT_CMD install -y -qq "$VENV_PKG_GEN" > /dev/null 2>&1 \
                || true   # || true: không để set -e thoát nếu cả hai fail
            echo -e "\r${G}✔${W} python venv packages cài xong          "
        else
            echo -e "${G}✔${W} python venv pkg đã có (${VENV_PKG_VER} hoặc ${VENV_PKG_GEN})"
        fi

        if [[ -d ~/qemu-env ]] && [[ -f ~/qemu-env/bin/activate ]]; then
            echo -e "${G}✔${W} Python venv đã tồn tại — sử dụng lại"
            _USE_VENV=1
        else
            echo -e "${Y}⚠${W} Không tạo venv trong rootless mode — dùng no-venv mode"
            _USE_VENV=0
        fi

        # Fix: PREFIX và PIP_TARGET chỉ được set trong _rootless_build.
        # Trong root/apt mode các biến này chưa khai báo → set -u crash.
        # Đặt fallback an toàn để PATH export không bị lỗi.
        PREFIX="${PREFIX:-$HOME/qemu-static}"
        PIP_TARGET="${PIP_TARGET:-$HOME/.local/lib/python-packages}"

        if [[ "${_USE_VENV:-0}" == "1" ]]; then
            source ~/qemu-env/bin/activate
        else
            export PATH="$PIP_TARGET/bin:$HOME/.local/bin:$PREFIX/bin:$PATH"
            export PYTHONPATH="$PIP_TARGET${PYTHONPATH:+:$PYTHONPATH}"
        fi

        :
        :
        {
            pip_install --upgrade pip tomli packaging
            pip_install meson ninja
            sudo apt-get remove -y meson 2>/dev/null || true
            hash -r
        } > /tmp/pip-install.log 2>&1
        _rl_ok "meson / ninja sẵn sàng"
        _qemu_build_tuning
        EXTRA_CFLAGS="$QEMU_BASE_CFLAGS"
        EXTRA_CXXFLAGS="$QEMU_BASE_CXXFLAGS"
        EXTRA_LDFLAGS="$QEMU_BASE_LDFLAGS"
        export CFLAGS="$EXTRA_CFLAGS"
        export CXXFLAGS="$EXTRA_CXXFLAGS"
        export LDFLAGS="$EXTRA_LDFLAGS"

        if [[ ! -d /tmp/qemu-src ]]; then
            spin_start "Tải source QEMU v11.0.0..."
            silent git clone --depth 1 --branch v11.0.0 \
                https://gitlab.com/qemu-project/qemu.git /tmp/qemu-src
            spin_stop "Tải source QEMU xong"
        else
            echo -e "${G}✔ Source QEMU đã có tại /tmp/qemu-src — bỏ qua clone${W}"
        fi

        rm -rf /tmp/qemu-build
        mkdir -p /tmp/qemu-build
        cd /tmp/qemu-build

        TCG_TB_COMPILE=$(( 256 * 1024 * 1024 ))

        export CFLAGS="$EXTRA_CFLAGS"
        export CXXFLAGS="$EXTRA_CXXFLAGS"
        export LDFLAGS="$EXTRA_LDFLAGS"

        # ── KVM flag cho configure apt-mode ──────────────────────
        if [[ "$KVM_AVAILABLE" == "1" ]]; then
            QEMU_KVM_FLAG="--enable-kvm"
            echo -e "${G}⚡ QEMU apt-build: --enable-kvm${W}"
        else
            QEMU_KVM_FLAG="--disable-kvm"
            echo -e "${B}ℹ${W}  QEMU apt-build: --disable-kvm (TCG mode)"
        fi

        # Bắt đầu tải image SONG SONG từ bước configure để tối đa hoá thời gian chạy song song
        WIN_IMG_PATH="${ORIGINAL_DIR:-$(pwd)}/${WIN_IMG_PATH_BASE:-win.img}"
        _start_parallel_download
        [[ -n "$IMG_DL_PID" ]] && echo -e "${B}ℹ${W}  🔀 Tải image đang chạy nền (PID: $IMG_DL_PID) trong khi configure + compile..."
        _rl_step 1 2 && :

        if ../qemu-src/configure \
            --prefix=/opt/qemu-optimized \
            --target-list=x86_64-softmmu \
            --enable-tcg \
            $QEMU_KVM_FLAG \
            --enable-slirp \
            --enable-coroutine-pool \
            --enable-vnc \
            --disable-mshv \
            --disable-xen \
            --disable-gtk \
            --disable-sdl \
            --disable-spice \
            --disable-plugins \
            --disable-debug-info \
            --disable-docs \
            --disable-werror \
            --disable-fdt \
            --disable-vdi \
            --disable-vvfat \
            --disable-cloop \
            --disable-dmg \
            --disable-pa \
            --disable-alsa \
            --disable-oss \
            --disable-jack \
            --disable-gnutls \
            --disable-smartcard \
            --disable-libusb \
            --disable-seccomp \
            --disable-modules \
            -Dguest_agent=disabled \
            -Dguest_agent_msi=disabled \
            -Dtools=enabled \
            --extra-cflags="$QEMU_BASE_CFLAGS" \
            --extra-cxxflags="$QEMU_BASE_CXXFLAGS" \
            --extra-ldflags="$QEMU_BASE_LDFLAGS" \
            > /tmp/qemu-configure.log 2>&1; then
            spin_stop "Configure xong"
        fi

        ulimit -n 84857 2>/dev/null || true
        NCPU=$(nproc)

        # ── Compile QEMU ─────────────────────────────────────
        spin_start "Compile QEMU với ${NCPU} cores (mất 5-20 phút)..."
        printf "[*] QEMU (system) compile started at %s
" "$(date +%H:%M:%S)"
( _hb=0; while :; do sleep 30; _hb=$((_hb+1)); printf "[~] QEMU compile: %d min...
" "$((_hb/2))"; done ) & _HB_QSYS=$!
if ninja -j"$NCPU" >> /tmp/qemu-build.log 2>&1; then
  kill "$_HB_QSYS" 2>/dev/null; wait "$_HB_QSYS" 2>/dev/null || true; printf "[+] QEMU compile done
"
            spin_stop "Compile QEMU xong"
        else
            spin_fail "Compile QEMU thất bại — xem /tmp/qemu-build.log"
            tail -30 /tmp/qemu-build.log >&2
            exit 1
        fi
        echo -e "${G}🔥 Build hoàn tất: safe fast build${W}"

        echo -e "${B}ℹ${W}  Cài đặt QEMU vào /opt/qemu-optimized..."
        # Kiểm tra sudo trước để không bị treo chờ password
        if [[ $EUID -eq 0 ]]; then
            # Đang là root — cài thẳng
            ninja install > /tmp/qemu-install.log 2>&1 \
                && echo -e "${G}✔${W} Cài đặt QEMU xong (root)" \
                || { echo -e "${R}✘${W} ninja install thất bại:"; tail -20 /tmp/qemu-install.log; exit 1; }
        elif sudo -n true 2>/dev/null; then
            # sudo không cần password
            sudo ninja install > /tmp/qemu-install.log 2>&1 \
                && echo -e "${G}✔${W} Cài đặt QEMU xong (sudo)" \
                || { echo -e "${R}✘${W} ninja install thất bại:"; tail -20 /tmp/qemu-install.log; exit 1; }
        else
            # sudo cần password hoặc không có — cài vào $HOME thay thế
            echo -e "${Y}⚠${W}  sudo không có hoặc cần password — cài vào ~/qemu-optimized thay thế"
            mkdir -p ~/qemu-optimized
            DESTDIR="" ninja install --destdir="" 2>/dev/null \
                || MESON_INSTALL_DESTDIR_PREFIX="$HOME/qemu-optimized" ninja install \
                    > /tmp/qemu-install.log 2>&1 \
                || { echo -e "${R}✘${W} ninja install thất bại:"; tail -20 /tmp/qemu-install.log; exit 1; }
            export PATH="$HOME/qemu-optimized/bin:$PATH"
            export QEMU_BIN="$HOME/qemu-optimized/bin/qemu-system-x86_64"
            echo -e "${G}✔${W} Cài đặt QEMU xong → ~/qemu-optimized"
        fi

        # Cập nhật QEMU_BIN sau khi cài xong (tránh trỏ vào path không tồn tại)
        # Ưu tiên rootless path ($PREFIX, ~/qemu-static) trước opt/usr
        for _qp in \
            "${PREFIX:-}/bin/qemu-system-x86_64" \
            "$HOME/qemu-static/bin/qemu-system-x86_64" \
            "/opt/qemu-optimized/bin/qemu-system-x86_64" \
            "$HOME/qemu-optimized/bin/qemu-system-x86_64" \
            "/usr/bin/qemu-system-x86_64"; do
            [[ -x "$_qp" ]] && { export QEMU_BIN="$_qp"; break; }
        done
        # Thêm bin dir của QEMU_BIN vào PATH (hoạt động đúng cả root lẫn rootless)
        [[ -n "${QEMU_BIN:-}" ]] && export PATH="$(dirname "$QEMU_BIN"):$PATH"
        echo -e "${G}🔥 QEMU build xong! $("$QEMU_BIN" --version 2>/dev/null | head -1 || echo '(ok)')${W}"
        echo -e "   Accel: ${KVM_MODE^^}"
    fi
    # Đợi download nền (nếu đang chạy)
    _wait_parallel_download
else
    echo -e "${Y}⚡ Bỏ qua build QEMU.${W}"
    # Với --no-build, cần đảm bảo image sẵn sàng (download nếu cần)
    _start_parallel_download
    _wait_parallel_download
fi

# Đảm bảo bin dir của QEMU_BIN luôn có trong PATH (đúng cả root lẫn rootless)
[[ -x "${QEMU_BIN:-}" ]] && export PATH="$(dirname "$QEMU_BIN"):$PATH"

# ════════════════════════════════════════════════════════════════
#  CHỌN PHIÊN BẢN WINDOWS
# ════════════════════════════════════════════════════════════════
echo ""
if [[ -n "${win_choice:-}" ]]; then
    echo -e "${G}🤖 Dùng image đã chọn trước: ${WIN_NAME:-Windows image}${W}"
elif [[ "$AUTO_MODE" == "1" && -n "$AUTO_WIN" ]]; then
    win_choice="$AUTO_WIN"
    echo -e "${G}🤖 AUTO MODE — Windows preset: ${AUTO_WIN}${W}"
else
    echo "🪟 Chọn phiên bản Windows muốn tải:"
    echo "1️⃣  Windows Server 2012 R2 x64"
    echo "2️⃣  Windows Server 2022 x64"
    echo "3️⃣  Windows 11 LTSB x64"
    echo "4️⃣  Windows 10 LTSB 2015 x64"
    echo "5️⃣  Windows 10 LTSC 2023 x64"
    if [[ -t 0 ]]; then
        read -rp "👉 Nhập số [1-5]: " win_choice
    else
        win_choice="5"
        echo -e "${Y}⚠${W}  stdin không tương tác — mặc định chọn 5 (LTSC 2023)"
    fi
fi

case "$win_choice" in
1) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no"  ;;
2) WIN_NAME="Windows Server 2022";    WIN_URL="https://archive.org/download/tamnguyen-2022/2022.img";   USE_UEFI="no"  ;;
3) WIN_NAME="Windows 11 LTSB";        WIN_URL="https://archive.org/download/win_20260203/win.img";       USE_UEFI="yes" ;;
4) WIN_NAME="Windows 10 LTSB 2015";   WIN_URL="https://archive.org/download/win_20260208/win.img";       USE_UEFI="no"  ;;
5) WIN_NAME="Windows 10 LTSC 2023";   WIN_URL="https://archive.org/download/win_20260215/win.img";       USE_UEFI="no"  ;;
*) WIN_NAME="Windows Server 2012 R2"; WIN_URL="https://archive.org/download/tamnguyen-2012r2/2012.img"; USE_UEFI="no"  ;;
esac

case "$win_choice" in
3|4|5) RDP_USER="Admin";         RDP_PASS="Tam255Z"         ;;
*)     RDP_USER="administrator"; RDP_PASS="Tamnguyenyt@123" ;;
esac

# Kiểm tra win.img hợp lệ (tồn tại + không phải file rỗng/zero + >= 2GB)

# VNC boot verification - HTTP backend an toàn với VNC
# Không cần tắt HTTP backend, VNC hoạt động độc lập

# ── HTTP backend mode: tạo QCOW2 backing file thay vì tải toàn bộ image ──
if [[ "${USE_HTTP_BACKEND:-0}" == "1" ]]; then
    if [[ ! -f win.img ]] || ! _img_valid win.img; then
        echo -e "${C}════════════════════════════════════${W}"
        echo -e "${C}🌐 HTTP-BACKEND MODE — không tải file${W}"
        echo -e "${C}════════════════════════════════════${W}"
        echo -e "${B}ℹ${W}  Tạo QCOW2 backing → $WIN_URL"
        echo -e "${B}ℹ${W}  QEMU sẽ fetch block on-demand (tiết kiệm disk, cần mạng tốt)"
        # Dùng /usr/bin/qemu-img trực tiếp (tránh wrapper cũ trong /opt)
        _REAL_QEMU_IMG=$(for _q in /usr/bin/qemu-img /usr/local/bin/qemu-img; do
            [[ -x "$_q" ]] && grep -qv "touch" "$_q" 2>/dev/null && echo "$_q" && break
        done)
        [[ -z "$_REAL_QEMU_IMG" ]] && _REAL_QEMU_IMG=$(PATH=/usr/bin:/bin which qemu-img 2>/dev/null || echo "")
        if [[ -n "$_REAL_QEMU_IMG" && -x "$_REAL_QEMU_IMG" ]]; then
            "$_REAL_QEMU_IMG" create -f qcow2 -F raw -b "$WIN_URL" win.img 2>/dev/null                 && { echo -e "${G}✔${W} QCOW2 backing file tạo xong: win.img (HTTP-backed, ~200KB local)"; _HTTP_BACKED=1; }                 || {
                    echo -e "${Y}⚠${W}  qemu-img create failed — fallback tải thường"
                    USE_HTTP_BACKEND=0
                }
        else
            echo -e "${Y}⚠${W}  qemu-img thật không tìm thấy — fallback tải thường"
            USE_HTTP_BACKEND=0
        fi
    else
        echo -e "${G}✔${W} win.img đã tồn tại và hợp lệ — bỏ qua tạo backing"
        _HTTP_BACKED=1
    fi
fi

# Đảm bảo WIN_IMG_PATH tuyệt đối + quay về thư mục gốc
WIN_IMG_PATH="${WIN_IMG_PATH:-${ORIGINAL_DIR:-$(pwd)}/win.img}"
cd "${ORIGINAL_DIR:-$(pwd)}" 2>/dev/null || true

_HTTP_BACKED="${_HTTP_BACKED:-0}"
if [[ "$_HTTP_BACKED" == "1" ]] || [[ "${_IMG_DOWNLOAD_DONE:-0}" == "1" ]] || _img_valid "$WIN_IMG_PATH"; then
    echo -e "${G}✔ win.img sẵn sàng ($(du -sh "$WIN_IMG_PATH" 2>/dev/null | cut -f1 || echo "HTTP-backed")) — bỏ qua tải${W}"
else
    [[ -f "$WIN_IMG_PATH" ]] &&         echo -e "${Y}⚠${W}  win.img tồn tại nhưng không hợp lệ (rỗng/nhỏ quá) — tải lại"
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}⬇  Đang tải: ${Y}$WIN_NAME${W}"
    echo -e "${C}════════════════════════════════════${W}"
    if command -v aria2c &>/dev/null; then
        aria2c "${ARIA2_OPTS[@]}" \
            "$WIN_URL" -d "$(dirname "$WIN_IMG_PATH")" -o "$(basename "$WIN_IMG_PATH")"
    else
        echo -e "${Y}⚠${W}  aria2c không có — dùng wget..."
        wget --progress=bar:force --continue "$WIN_URL" -O "$WIN_IMG_PATH"
    fi
    echo -e "${G}✔ Tải $WIN_NAME xong${W}"
fi

# ── Hỏi đổi password (root mode, interactive) ─────────────────────

# ── Thực thi reset password nếu user đã xác nhận ──────────────────

if [[ "$AUTO_MODE" == "1" ]]; then
    extra_gb=0
    echo -e "${G}🤖 AUTO MODE — disk extend: 0GB (bỏ qua resize)${W}"
else
    extra_gb=""
    read -rp "📦 Mở rộng đĩa thêm bao nhiêu GB (default 20)? " extra_gb
    # Lọc bỏ escape codes/ký tự lạ từ terminal (tmux, SSH)
    extra_gb=$(echo "${extra_gb:-20}" | tr -cd '0-9')
    extra_gb="${extra_gb:-20}"
fi

if [[ "$extra_gb" -gt 0 ]]; then
    spin_start "Resize disk +${extra_gb}GB..."
    # Rootless: dùng qemu-img cùng thư mục với QEMU_BIN thay vì bare command
    _QEMU_IMG_BIN=""
    for _qi in \
        "$(dirname "${QEMU_BIN:-/nonexistent}")/qemu-img" \
        "${PREFIX:-}/bin/qemu-img" \
        "$HOME/qemu-static/bin/qemu-img" \
        "/opt/qemu-optimized/bin/qemu-img" \
        "/usr/bin/qemu-img" \
        "$(command -v qemu-img 2>/dev/null || true)"; do
        [[ -x "$_qi" ]] && { _QEMU_IMG_BIN="$_qi"; break; }
    done
    if [[ -n "$_QEMU_IMG_BIN" ]]; then
        silent "$_QEMU_IMG_BIN" resize "$WIN_IMG_PATH" "+${extra_gb}G"
    else
        echo -e "${Y}⚠${W}  qemu-img không tìm thấy — bỏ qua resize"
    fi
    spin_stop "Resize disk xong"
else
    echo -e "${B}ℹ${W}  Bỏ qua resize disk (extra_gb=0)"
fi

# ════════════════════════════════════════════════════════════════
#  CẤU HÌNH VM
# ════════════════════════════════════════════════════════════════
echo ""
echo -e "${C}════════════════════════════════════${W}"
echo -e "${C}⚙  CHỌN CHẾ ĐỘ CẤU HÌNH VM${W}"
echo -e "${C}════════════════════════════════════${W}"

if [[ "$AUTO_MODE" == "1" ]]; then
    cfg_mode="1"
    echo -e "${G}🤖 AUTO MODE — tự động chọn cấu hình tài nguyên${W}"
else
    echo "1️⃣  Auto cấu hình (khuyên dùng)"
    echo "2️⃣  Tự chọn thủ công"
    echo -e "${C}════════════════════════════════════${W}"
    if [[ -t 0 ]]; then
        read -rp "👉 Nhập lựa chọn [1-2]: " cfg_mode
    else
        cfg_mode="1"
        echo -e "${Y}⚠${W}  stdin không tương tác — mặc định chọn 1 (auto cấu hình)"
    fi
fi

if [[ "$cfg_mode" == "1" ]]; then
    spin_start "Auto detect tài nguyên host..."
    cpu_v=$(nproc 2>/dev/null); cpu_u=$cpu_v

    if [[ -f /sys/fs/cgroup/cpu.max ]]; then
        IFS=" " read -r cq cp < /sys/fs/cgroup/cpu.max
        [[ "$cq" != "max" ]] && cpu_u=$(awk "BEGIN{printf \"%.0f\",$cq/$cp}")
    elif [[ -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]]; then
        cq=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
        cp=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
        [[ "$cq" != "-1" ]] && cpu_u=$(awk "BEGIN{printf \"%.0f\",$cq/$cp}")
    fi
    [[ "$cpu_u" -lt 1 ]] && cpu_u=1

    mem_total_gb=$(awk '/MemTotal/{printf "%.0f",$2/1024/1024}' /proc/meminfo)
    mem_auto_gb=$(awk "BEGIN{printf \"%d\", ($mem_total_gb*0.85)+0.5}")
    [[ "$mem_auto_gb" -lt 2 ]] && mem_auto_gb=2
    max_ram=$(( mem_total_gb - 1 ))
    [[ "$mem_auto_gb" -gt "$max_ram" ]] && mem_auto_gb=$max_ram
    cpu_core=$cpu_u; ram_size=$mem_auto_gb
    spin_stop "Auto detect xong"
    echo "   🖥️  CPU : ${cpu_v} cores (usable: ${cpu_core})"
    echo "   💾 RAM : ${mem_total_gb}GB total → VM ${ram_size}GB"
else
    cpu_core=""; ram_size=""
    read -rp "⚙  CPU core (default 4): " cpu_core
    read -rp "💾 RAM GB   (default 4): " ram_size
    cpu_core=$(echo "${cpu_core:-4}" | tr -cd '0-9'); cpu_core="${cpu_core:-4}"
    ram_size=$(echo "${ram_size:-4}" | tr -cd '0-9'); ram_size="${ram_size:-4}"
    # Đảm bảo cpu_u có giá trị hợp lệ khi manual mode
    cpu_u="${cpu_core}"
fi

# ════════════════════════════════════════════════════════════════
#  TCG PERFORMANCE TUNING
#  _tcg_tune_common  — chạy trên cả root lẫn rootless
#  _tcg_tune_root    — chỉ chạy khi có root (thêm mọi thứ còn lại)
#  _tcg_tune         — dispatcher tự chọn đúng phiên bản
# ════════════════════════════════════════════════════════════════

# ── Shared: detect physical cores, numactl, chrt, env vars ──────
_tcg_tune_common() {
    export MALLOC_ARENA_MAX=4
    export MALLOC_MMAP_THRESHOLD_=131072
    export MALLOC_TRIM_THRESHOLD_=131072
    export JIT_SERIALIZE_OBJECT=1
    echo -e "${G}✔${W} JIT env vars set (MALLOC_ARENA_MAX=4)"

    # detect numactl
    if command -v numactl &>/dev/null \
        && numactl --hardware 2>/dev/null | grep -q 'node 0'; then
        TCG_NUMACTL_PREFIX="numactl --membind=0 --cpunodebind=0"
        echo -e "${G}✔${W} numactl: membind=0 (NUMA node 0)"
    else
        TCG_NUMACTL_PREFIX=""
    fi
    export TCG_NUMACTL_PREFIX

    # detect chrt realtime
    if command -v chrt &>/dev/null && chrt -f 99 true 2>/dev/null; then
        TCG_CHRT_PREFIX="chrt -f 99"
        echo -e "${G}✔${W} chrt -f 99 (FIFO RT)"
    elif command -v chrt &>/dev/null && chrt -r 1 true 2>/dev/null; then
        TCG_CHRT_PREFIX="chrt -r 1"
        echo -e "${G}✔${W} chrt -r 1 (RR RT)"
    else
        TCG_CHRT_PREFIX=""
        echo -e "${Y}⚠${W}  chrt: không có quyền realtime"
    fi
    export TCG_CHRT_PREFIX
    QEMU_HUGEPAGES_DIR=""; export QEMU_HUGEPAGES_DIR
}

# ── Root-only extras ─────────────────────────────────────────────
_tcg_tune_root() {
    echo -e "${B}ℹ${W}  Root TCG tuning..."

    # 1. renice
    renice -n -20 $$ 2>/dev/null \
        && echo -e "${G}✔${W} renice -20" \
        || echo -e "${Y}⚠${W}  renice thất bại"

    # 2. ionice
    ionice -c 1 -n 0 $$ 2>/dev/null \
        && echo -e "${G}✔${W} ionice: RT class" \
        || echo -e "${Y}⚠${W}  ionice thất bại"

    # 3. CPU governor → performance
    for _gf in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        [[ -f "$_gf" ]] && echo performance > "$_gf" 2>/dev/null || true
    done
    local _gov; _gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "n/a")
    echo -e "${G}✔${W} CPU governor: ${_gov}"

    # 4. Hugepages (2MB)
    local _pages_needed=$(( ${ram_size:-2} * 512 ))
    local _hr="/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"
    if [[ -w "$_hr" ]]; then
        echo "$_pages_needed" > "$_hr" 2>/dev/null || true
        local _after; _after=$(cat "$_hr" 2>/dev/null || echo 0)
        if [[ "$_after" -ge "$_pages_needed" ]]; then
            QEMU_HUGEPAGES_DIR="/dev/hugepages"
            export QEMU_HUGEPAGES_DIR
            echo -e "${G}✔${W} Hugepages: ${_after} × 2MB"
        else
            echo -e "${Y}⚠${W}  Hugepages: chỉ có ${_after}/${_pages_needed} — bỏ qua"
        fi
    else
        echo -e "${Y}⚠${W}  Hugepages sysfs: không ghi được — bỏ qua"
    fi

    # 5. Disk scheduler → mq-deadline (skip loop devices, suppress EROFS)
    local _sched_ok=0
    for _sched in /sys/block/*/queue/scheduler; do
        [[ -f "$_sched" ]] || continue
        [[ "$_sched" == */loop* ]] && continue  # skip loop devices
        { echo mq-deadline > "$_sched"; } 2>/dev/null             && _sched_ok=$((_sched_ok+1)) || true
    done
    if [[ $_sched_ok -gt 0 ]]; then
        echo -e "${G}✔${W} Disk scheduler → mq-deadline ($_sched_ok)"
    else
        echo -e "${Y}⚠${W}  Disk scheduler: read-only/no permission — bỏ qua"
    fi
    # dummy-to-keep-indentation for Disk scheduler → mq-deadline"
}

# ── stress-ng warmup — chạy được cả root lẫn rootless ───────────
_stress_warmup() {
    local _ncpu="${1:-$(nproc)}"
    local _dur=8
    if command -v stress-ng &>/dev/null; then
        echo -e "${B}ℹ${W}  stress-ng warmup: ${_ncpu} CPU × ${_dur}s..."
        timeout $(( _dur + 2 )) stress-ng --cpu "$_ncpu" --cpu-method matrixprod \
            -t "${_dur}s" --metrics-brief 2>/dev/null || true
        echo -e "${G}✔${W} Warmup xong — CPU đang ở peak frequency"
    else
        apt_install stress-ng > /dev/null 2>&1 || true
        if command -v stress-ng &>/dev/null; then
            timeout $(( _dur + 2 )) stress-ng --cpu "$_ncpu" -t "${_dur}s" 2>/dev/null || true
            echo -e "${G}✔${W} Warmup xong"
        else
            echo -e "${Y}⚠${W}  stress-ng không có — bỏ qua warmup"
        fi
    fi
}

# ── Dispatcher ───────────────────────────────────────────────────
_tcg_tune() {
    if [[ "${NO_TUNING:-0}" == "1" ]]; then
        echo -e "${Y}⚠${W}  Bỏ qua toàn bộ TCG tuning"
        LAUNCH_PREFIX=""
        TCG_TB_MB=512
        return
    fi
    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔧 TCG PERFORMANCE TUNING${W}"
    echo -e "${C}════════════════════════════════════${W}"
    _tcg_tune_common
    if [[ $EUID -eq 0 ]]; then
        _tcg_tune_root
    fi
    _stress_warmup "${cpu_core:-$(nproc)}"
    LAUNCH_PREFIX="${TCG_NUMACTL_PREFIX:+${TCG_NUMACTL_PREFIX} }${TCG_CHRT_PREFIX:-}"
    LAUNCH_PREFIX="${LAUNCH_PREFIX# }"
    export LAUNCH_PREFIX
    echo -e "${G}🔥 TCG tuning xong — full TCG optimizations on${W}"
    echo ""
}

if [[ "$KVM_AVAILABLE" == "1" ]]; then
    echo -e "${G}⚡ VM sẽ chạy với KVM acceleration + CPU host passthrough${W}"
    ACCEL_OPT="-accel kvm"
    CPU_OPT="-cpu host"
    LAUNCH_PREFIX=""   # KVM không cần numactl/chrt prefix

    # Network
    [[ "$win_choice" == "4" ]] \
        && NET_DEVICE="-device e1000e,netdev=n0" \
        || NET_DEVICE="-device virtio-net-pci,netdev=n0"

    # BIOS/UEFI
    [[ "$USE_UEFI" == "yes" ]] \
        && {
            # Detect OVMF across common paths (rootless may not have apt-installed ovmf)
            _OVMF=""
            for _ovmf in                 /usr/share/qemu/OVMF.fd                 /usr/share/ovmf/OVMF.fd                 /usr/share/ovmf/x64/OVMF.fd                 /usr/share/OVMF/OVMF_CODE.fd                 "${PREFIX:-}/share/qemu/OVMF.fd"                 "$HOME/qemu-static/share/qemu/OVMF.fd"; do
                [[ -f "$_ovmf" ]] && { _OVMF="$_ovmf"; break; }
            done
            if [[ -n "$_OVMF" ]]; then
                OVMF_PATH="$_OVMF"
                echo -e "${G}✔${W} OVMF firmware: $_OVMF"
            else
                echo -e "${Y}⚠${W}  OVMF.fd không tìm thấy — thử tải..."
                _OVMF_TMP="${PREFIX:-$HOME/qemu-static}/share/qemu"
                mkdir -p "$_OVMF_TMP"
                _OVMF_OK=0
                for _ovmf_url in \
                    "https://github.com/nicowillis/ovmf-prebuilt/raw/main/OVMF.fd" \
                    "https://github.com/clearlinux/common/raw/master/OVMF.fd" \
                    "https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd"; do
                    if wget -q --timeout=30 --tries=2 "$_ovmf_url" -O "$_OVMF_TMP/OVMF.fd" 2>/dev/null; then
                        # Sanity check: OVMF.fd should be >= 1MB and start with known magic
                        _sz=$(stat -c%s "$_OVMF_TMP/OVMF.fd" 2>/dev/null || echo 0)
                        if [[ "$_sz" -ge 1048576 ]]; then
                            _OVMF_OK=1; break
                        else
                            echo -e "${Y}⚠${W}  OVMF từ $_ovmf_url quá nhỏ ($_sz bytes) — thử nguồn khác"
                            rm -f "$_OVMF_TMP/OVMF.fd"
                        fi
                    fi
                done
                if [[ "$_OVMF_OK" == "1" ]]; then
                    OVMF_PATH="$_OVMF_TMP/OVMF.fd"
                    echo -e "${G}✔${W} OVMF tải xong → $_OVMF_TMP/OVMF.fd"
                else
                    OVMF_PATH=""
                    echo -e "${R}✘${W}  Không tải được OVMF — dùng SeaBIOS legacy BIOS"
                    echo -e "${Y}   Windows 10/11 có thể báo lỗi 0xc0000225 với SeaBIOS."
                    echo -e "${Y}   Fix: cài gói 'ovmf' (apt install ovmf) hoặc đặt WINBOX_DISK_BUS=ide${W}"
                fi
            fi
        } \
        || OVMF_PATH=""

    QEMU_CMD=(
        ${QEMU_BIN:-qemu-system-x86_64}
        -machine pc,hpet=off
        $CPU_OPT
        -smp "$cpu_core"
        -m "${ram_size}G"
        $ACCEL_OPT
        -rtc base=localtime,clock=host
    )

else
    # ── TCG MODE ─────────────────────────────────────────────────
    echo -e "${Y}⚡ VM sẽ chạy với TCG (software emulation)${W}"

    # Chạy tất cả TCG tuning
    _tcg_tune

    # TCG TB cache — aggressive sizing for slow TCG guests
    _host_ram_gb="${mem_total_gb:-$(awk '/MemTotal/{printf "%.0f",$2/1024/1024}' /proc/meminfo)}"
    [[ "${_host_ram_gb:-0}" -lt 1 ]] && _host_ram_gb=4
    TCG_TB_MB=4096
    [[ "$TCG_TB_MB" -gt 16384 ]] && TCG_TB_MB=16384
    TCG_ACCEL_OPTS="thread=multi,split-wx=off,one-insn-per-tb=off,tb-size=$TCG_TB_MB"
    echo -e "${G}⚡ TCG TB cache: ${TCG_TB_MB}MB${W}"
    echo -e "${G}⚡ TCG accel: multi-thread + split-wx=off + one-insn-per-tb=off${W}"

    # CPU flags
    # model-id = tên CPU hiển thị trong Windows Device Manager (text thuần)
    # KHÔNG ảnh hưởng performance — feature flags bên dưới mới quan trọng
    #
    # Thứ tự ưu tiên lấy tên CPU:
    #   1. model name từ /proc/cpuinfo (nếu không phải "unknown"/rỗng)
    #   2. vendor_id + family/model number → tên hợp lý
    #   3. Hardcode fallback theo vendor
    _raw_cpu_name=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | sed 's/^.*: //' || echo "")
    _cpu_vendor=$(grep -m1 "vendor_id"  /proc/cpuinfo 2>/dev/null | awk '{print $NF}' || echo "")

    # Kiểm tra tên có thực sự hữu ích không
    # Các giá trị vô nghĩa thường gặp trên container/VPS: "unknown", trống, chỉ toàn số/ký tự đặc biệt
    _cpu_name_useful=0
    _stripped=$(printf '%s' "$_raw_cpu_name" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
    if [[ -n "$_stripped" && "$_stripped" != "unknown" && ${#_stripped} -ge 4 ]]; then
        # Phải có ít nhất 1 chữ cái (không phải toàn số/ký hiệu)
        if printf '%s' "$_stripped" | grep -q '[a-z]'; then
            _cpu_name_useful=1
        fi
    fi

    if [[ "$_cpu_name_useful" == "1" ]]; then
        # Dùng tên thật — sanitize để QEMU chấp nhận
        cpu_host="$_raw_cpu_name"
        cpu_model_id=$(printf '%s' "$cpu_host" \
            | tr ',' ' ' \
            | tr -d '"\\@#$%^&*|<>' \
            | sed 's/[[:space:]]\+/ /g; s/^[[:space:]]*//; s/[[:space:]]*$//' \
            | cut -c1-48)
    else
        # Tên không dùng được — fallback theo vendor_id
        case "$_cpu_vendor" in
            GenuineIntel) cpu_host="Intel Xeon Gold 6254" ;;
            AuthenticAMD) cpu_host="AMD EPYC 7763" ;;
            HygonGenuine) cpu_host="Hygon C86 7185" ;;
            CentaurHauls) cpu_host="VIA Nano" ;;
            *)            cpu_host="Generic x86_64" ;;
        esac
        cpu_model_id="${cpu_host} Processor"
        echo -e "${Y}⚠${W}  CPU name không đọc được ('${_raw_cpu_name:-empty}') — dùng fallback: ${cpu_model_id}"
    fi
    CPU_EXTRA=
    grep -q ssse3  /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+ssse3"
    grep -q sse4_1 /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+sse4.1"
    grep -q sse4_2 /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+sse4.2"
    grep -q rdtscp /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+rdtscp"
    grep -q ' avx ' /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+avx"
    grep -q avx2   /proc/cpuinfo && CPU_EXTRA="$CPU_EXTRA,+avx2"
    cpu_model="qemu64,hypervisor=off,tsc=on,pmu=off,l3-cache=on,+cmov,+mmx,+fxsr,+sse2,+cx16,+x2apic,+sep,+pat,+pse,+aes,+popcnt${CPU_EXTRA},model-id=${cpu_model_id}"

    # Network
    [[ "$win_choice" == "4" ]] \
        && NET_DEVICE="-device e1000e,netdev=n0" \
        || NET_DEVICE="-device virtio-net-pci,netdev=n0"

    # BIOS/UEFI
    [[ "$USE_UEFI" == "yes" ]] \
        && {
            # Detect OVMF across common paths (rootless may not have apt-installed ovmf)
            _OVMF=""
            for _ovmf in                 /usr/share/qemu/OVMF.fd                 /usr/share/ovmf/OVMF.fd                 /usr/share/ovmf/x64/OVMF.fd                 /usr/share/OVMF/OVMF_CODE.fd                 "${PREFIX:-}/share/qemu/OVMF.fd"                 "$HOME/qemu-static/share/qemu/OVMF.fd"; do
                [[ -f "$_ovmf" ]] && { _OVMF="$_ovmf"; break; }
            done
            if [[ -n "$_OVMF" ]]; then
                OVMF_PATH="$_OVMF"
                echo -e "${G}✔${W} OVMF firmware: $_OVMF"
            else
                echo -e "${Y}⚠${W}  OVMF.fd không tìm thấy — thử tải..."
                _OVMF_TMP="${PREFIX:-$HOME/qemu-static}/share/qemu"
                mkdir -p "$_OVMF_TMP"
                _OVMF_OK=0
                for _ovmf_url in \
                    "https://github.com/nicowillis/ovmf-prebuilt/raw/main/OVMF.fd" \
                    "https://github.com/clearlinux/common/raw/master/OVMF.fd" \
                    "https://retrage.github.io/edk2-nightly/bin/RELEASEX64_OVMF.fd"; do
                    if wget -q --timeout=30 --tries=2 "$_ovmf_url" -O "$_OVMF_TMP/OVMF.fd" 2>/dev/null; then
                        # Sanity check: OVMF.fd should be >= 1MB and start with known magic
                        _sz=$(stat -c%s "$_OVMF_TMP/OVMF.fd" 2>/dev/null || echo 0)
                        if [[ "$_sz" -ge 1048576 ]]; then
                            _OVMF_OK=1; break
                        else
                            echo -e "${Y}⚠${W}  OVMF từ $_ovmf_url quá nhỏ ($_sz bytes) — thử nguồn khác"
                            rm -f "$_OVMF_TMP/OVMF.fd"
                        fi
                    fi
                done
                if [[ "$_OVMF_OK" == "1" ]]; then
                    OVMF_PATH="$_OVMF_TMP/OVMF.fd"
                    echo -e "${G}✔${W} OVMF tải xong → $_OVMF_TMP/OVMF.fd"
                else
                    OVMF_PATH=""
                    echo -e "${R}✘${W}  Không tải được OVMF — dùng SeaBIOS legacy BIOS"
                    echo -e "${Y}   Windows 10/11 có thể báo lỗi 0xc0000225 với SeaBIOS."
                    echo -e "${Y}   Fix: cài gói 'ovmf' (apt install ovmf) hoặc đặt WINBOX_DISK_BUS=ide${W}"
                fi
            fi
        } \
        || OVMF_PATH=""

    QEMU_CMD=(
        ${QEMU_BIN:-qemu-system-x86_64}
        -machine pc,hpet=off,vmport=off
        -cpu "$cpu_model"
        -smp "$cpu_core,cores=$cpu_core,threads=1,sockets=1"
        -m "${ram_size}G"
        -accel tcg,${TCG_ACCEL_OPTS}
        -rtc base=localtime
        -overcommit cpu-pm=on
        -boot order=c,strict=on
    )

    # Hugepages mem-path nếu detect được
    if [[ -n "${QEMU_HUGEPAGES_DIR:-}" && -d "$QEMU_HUGEPAGES_DIR" ]]; then
        QEMU_CMD+=(-mem-path "$QEMU_HUGEPAGES_DIR" -mem-prealloc)
        echo -e "${G}✔${W} Hugepages: -mem-path $QEMU_HUGEPAGES_DIR -mem-prealloc"
    fi
fi

# ── Thêm BIOS/UEFI ───────────────────────────────────────────
# shellcheck disable=SC2206 — BIOS_OPT is intentionally split into two words (-bios PATH)
[[ -n "${OVMF_PATH:-}" ]] && QEMU_CMD+=(-bios "${OVMF_PATH}")

# ── Disk ─────────────────────────────────────────────────────
WIN_IMG_PATH="${WIN_IMG_PATH:-win.img}"
# Detect image format: HTTP-backed = qcow2, else try file command
_QEMU_IMG_FMT="raw"
if [[ "${_HTTP_BACKED:-0}" == "1" ]]; then
    _QEMU_IMG_FMT="qcow2"
elif command -v qemu-img &>/dev/null; then
    _detected_fmt=$(qemu-img info --output=json "$WIN_IMG_PATH" 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin).get('format','raw'))" 2>/dev/null || echo "raw")
    [[ -n "$_detected_fmt" ]] && _QEMU_IMG_FMT="$_detected_fmt"
elif command -v file &>/dev/null && file "$WIN_IMG_PATH" 2>/dev/null | grep -qi "qcow"; then
    _QEMU_IMG_FMT="qcow2"
fi
# Disk interface: virtio (nhanh nhất, dùng mặc định)
echo -e "${G}✔${W}  Disk bus: ${B}virtio${W} (high performance)"
QEMU_CMD+=(
    -drive file="$WIN_IMG_PATH",if=none,id=disk0,cache=unsafe,aio=native,cache.direct=on,format="$_QEMU_IMG_FMT"
    -device virtio-blk-pci,drive=disk0,iothread=io1,num-queues=4,queue-size=256
    -object iothread,id=io1
)

if [[ "${WINBOX_NET_DEVICE}" == "e1000e" ]]; then
    NET_DEVICE="-device e1000e,netdev=n0"
elif [[ "${WINBOX_NET_DEVICE}" == "virtio" ]]; then
    NET_DEVICE="-device virtio-net-pci,netdev=n0"
fi
QEMU_CMD+=(
    -netdev user,id=n0,hostfwd=tcp::${WINVM_RDP_PORT}-:${WINVM_RDP_PORT}
    $NET_DEVICE
)
if [[ "${WINBOX_VNC:-0}" == "1" ]]; then
    QEMU_CMD+=(-device nec-usb-xhci -device usb-tablet)
fi

# ── Input ────────────────────────────────────────────────────
QEMU_CMD+=(
    -device virtio-mouse-pci
    -device virtio-keyboard-pci
)

# ── Display ──────────────────────────────────────────────────
# VNC luôn bật mặc định (có thể tắt bằng WINBOX_VNC=0)
if [[ "${WINBOX_VNC:-1}" == "1" ]]; then
    QEMU_CMD+=(-vga std -vnc :0,share=force-shared)
    echo -e "${G}✔${W} VNC enabled on :5900 (share=force-shared)"
else
    QEMU_CMD+=(-vga virtio -display none)
fi
QEMU_CMD+=(-nodefaults)
QEMU_CMD+=(-serial none -monitor none)

# ── SMBIOS ───────────────────────────────────────────────────
QEMU_CMD+=(
    -smbios type=1,manufacturer="Dell Inc.",product="PowerEdge R640"
    -no-user-config
)

# ════════════════════════════════════════════════════════════════
#  KHỞI ĐỘNG VM
# ════════════════════════════════════════════════════════════════
echo -e "${B}ℹ${W}  Khởi động VM ${WIN_NAME}..."

QEMU_LOG="/tmp/qemu-launch-$$.log"
rm -f /tmp/qemu-launch.log 2>/dev/null || true
ln -sf "$QEMU_LOG" /tmp/qemu-launch.log 2>/dev/null || true

# ── Validate QEMU_BIN trước khi launch ──────────────────────────
# Resolve lại QEMU_BIN theo thứ tự ưu tiên
_resolve_qemu_bin() {
    for q in \
        "${QEMU_BIN:-}" \
        "$HOME/qemu-static/bin/qemu-system-x86_64" \
        "$HOME/qemu-optimized/bin/qemu-system-x86_64" \
        "/opt/qemu-optimized/bin/qemu-system-x86_64" \
        "$(command -v qemu-system-x86_64 2>/dev/null)"; do
        [[ -n "$q" && -x "$q" ]] && { echo "$q"; return 0; }
    done
    return 1
}

RESOLVED_QEMU=$(_resolve_qemu_bin) || {
    echo -e "${R}✘ Không tìm thấy qemu-system-x86_64!${W}"
    echo -e "${Y}   Đảm bảo đã build QEMU trước khi chạy VM.${W}"
    exit 1
}
export QEMU_BIN="$RESOLVED_QEMU"
QEMU_CMD[0]="$QEMU_BIN"
echo -e "${G}✔${W} QEMU binary: $QEMU_BIN"

# Build extra port forward string
_EXTRA_FWDS_STR=""
for _fwd in "${EXTRA_FWDS[@]+"${EXTRA_FWDS[@]}"}"; do
    [[ -z "$_fwd" ]] && continue
    _h="${_fwd%%:*}"; _g="${_fwd##*:}"
    _EXTRA_FWDS_STR+=",hostfwd=tcp::${_h}-:${_g}"
done
# Add QMP socket to QEMU command
QEMU_CMD+=(-qmp unix:"$WINVM_QMP_SOCK",server,nowait)

echo "QEMU CMD: ${QEMU_CMD[*]}" > "$QEMU_LOG"

# LAUNCH_PREFIX giữ nguyên giá trị từ _tcg_tune()


# Rootless QEMU: đảm bảo LD_LIBRARY_PATH có lib path TRƯỚC khi fork
if [[ "$QEMU_BIN" == *"qemu-static"* ]]; then
    _QEMU_PREFIX="$(dirname "$(dirname "$QEMU_BIN")")"
    export LD_LIBRARY_PATH="$_QEMU_PREFIX/lib:$_QEMU_PREFIX/lib64:$_QEMU_PREFIX/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
    :
fi

if [[ -n "$LAUNCH_PREFIX" ]]; then
    echo -e "${G}🔥 Launch prefix: ${LAUNCH_PREFIX}${W}"
    # Dùng read -ra để split LAUNCH_PREFIX an toàn (không dùng eval)
    read -ra _launch_prefix_arr <<< "$LAUNCH_PREFIX"
    nohup "${_launch_prefix_arr[@]}" "${QEMU_CMD[@]}" >> "$QEMU_LOG" 2>&1 &
else
    nohup "${QEMU_CMD[@]}" >> "$QEMU_LOG" 2>&1 &
fi
QEMU_PID=$!
echo "$QEMU_PID" > "$WINVM_PID_FILE"
# Write state file for --status
python3 -c "
import json,sys
json.dump({\"pid\":int(sys.argv[1]),\"instance\":int(sys.argv[2]),\"rdp_port\":int(sys.argv[3]),\"rdp_user\":sys.argv[4],\"win_name\":sys.argv[5]},
    open(sys.argv[6],\"w\"), indent=2)
" "$QEMU_PID" "$INSTANCE_ID" "$WINVM_RDP_PORT" "$RDP_USER" "$WIN_NAME" "$WINVM_STATE_FILE" 2>/dev/null || true
disown "$QEMU_PID"

sleep 4
if kill -0 "$QEMU_PID" 2>/dev/null; then
    echo -e "${G}✔${W} VM đã khởi động (PID: $QEMU_PID)"
else
    echo -e "${R}✘ VM KHÔNG khởi động được!${W}"
    echo -e "${R}═══ QEMU ERROR LOG ═══${W}"
    cat "$QEMU_LOG"
    echo -e "${R}═══════════════════════${W}"
    echo -e "${Y}Tip: Xem log đầy đủ tại $QEMU_LOG${W}"
    exit 1
fi


PUBLIC=""

# ── SUMMARY ───────────────────────────────────────────────────────
echo ""
echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "${C}🚀 WINBOX DEPLOYED SUCCESSFULLY${W}"
[[ "$AUTO_MODE" == "1" ]] && \
    echo -e "${C}🤖 Launched via: --auto${AUTO_WIN:+ --win$AUTO_WIN}${W}"
echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "🪟 OS           : ${Y}$WIN_NAME${W}"
echo -e "⚙  CPU Cores    : ${B}$cpu_core${W}"
echo -e "💾 RAM          : ${B}${ram_size} GB${W}"
if [[ "$KVM_AVAILABLE" == "1" ]]; then
    echo -e "⚡ Acceleration : ${G}KVM (hardware) + CPU host${W}"
else
    echo -e "⚡ Acceleration : ${Y}TCG (software) | TB cache: ${TCG_TB_MB:-?}MB${W}"
    echo -e "🧠 CPU Model    : ${B}${cpu_host:-unknown}${W}"
fi
echo -e "${C}──────────────────────────────────────────────${W}"
if [[ -n "$PUBLIC" ]]; then
    echo -e "📡 RDP Address  : ${G}${PUBLIC}${W}"

else
    echo -e "📡 RDP (local)  : ${G}localhost:${WINVM_RDP_PORT}${W}"
    [[ "${use_rdp:-n}" == "y" ]] && \
        echo -e "${Y}   ⚠  Tunnel chưa lấy được endpoint — xem log ở trên${W}"
fi
echo -e "👤 Username     : ${Y}$RDP_USER${W}"
echo -e "🔑 Password     : ${Y}$RDP_PASS${W}"
echo -e "${C}══════════════════════════════════════════════${W}"
echo "🖥  VNC Server   : ${G}:5900${W} (share=force-shared)"
echo "   → vncviewer localhost:5900"
echo "   → noVNC: http://localhost:6080 (nếu có websockify)"
echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "${G}🟢 Status       : RUNNING (PID: $QEMU_PID)${W}"
echo    "⏱  GUI Mode     : VNC + RDP"
echo -e "${C}══════════════════════════════════════════════${W}"

