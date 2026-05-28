#!/usr/bin/env bash
set -euo pipefail

# Đảm bảo biến môi trường cơ bản khi chạy qua sudo su (HOME/USER có thể bị unset)
HOME="${HOME:-/root}"
USER="${USER:-$(id -un 2>/dev/null || echo root)}"
LOGNAME="${LOGNAME:-$USER}"
export HOME USER LOGNAME

# ════════════════════════════════════════════════════════════════
#  WINBOX
#  LLVM 16 via apt-get hoặc fallback apt.llvm.org (Debian 12/13, Ubuntu 20-24)
#  Rootless: toàn bộ libs build từ source (zlib/libffi/pixman/glib/libslirp)
#  aria2: cài qua conda nếu có, fallback wget static binary, fallback wget
#  Fix: removed --user from pip install (virtualenv compatibility)
#  KVM: Auto detect /dev/kvm → enable KVM acceleration if available
#  NEW: CLI flags --auto --winXXXX để chạy hoàn toàn không tương tác
#  NEW: Tự động skip build nếu QEMU đã tồn tại (--rebuild để build lại)
#
#  Cách dùng:
#    bash winbox.sh                          # chế độ interactive như cũ
#    bash winbox.sh --auto --win2012         # auto, Windows Server 2012 R2
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
AUTO_RDP=0         # 1 = tự mở tunnel RDP
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
USE_HTTP_BACKEND=0  # --http-img: bật HTTP backend (không tải file)
SAFE_DOWNLOAD=0   # --safe-download: tải theo chunks 900MB (cho môi trường giới hạn)
ISO_MODE=0        # --iso: boot từ ISO thay vì tải Windows image
ISO_WIN_URL=""    # URL Windows ISO
ISO_VIRTIO_URL="" # URL VirtIO ISO (optional)
LLVM_ACCEL="auto"  # auto=tự detect root, 1=bật, 0=tắt
LLVM_THRESHOLD="" # --llvm-threshold=N: hot TB threshold
LLVM_NO=0          # --no-llvm: tắt LLVM

for _arg in "$@"; do
    case "$_arg" in
        --auto)       AUTO_MODE=1    ;;
        --win2012)    AUTO_WIN=1     ;;
        --win2022)    AUTO_WIN=2     ;;
        --win11)      AUTO_WIN=3     ;;
        --win10ltsb)  AUTO_WIN=4     ;;
        --win10ltsc)  AUTO_WIN=5     ;;
        --rdp)        AUTO_RDP=1     ;;
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
        --port-forward=*|--fwd=*)
            _fwd="${_arg#*=}"; EXTRA_FWDS+=("$_fwd") ;;
        --iso=*)       ISO_MODE=1; ISO_WIN_URL="${_arg#--iso=}" ;;
        --iso)         ISO_MODE=1 ;;
        --virtio=*)    ISO_VIRTIO_URL="${_arg#--virtio=}" ;;
        --accel-llvm|--llvm) LLVM_ACCEL=1 ;;
        --no-llvm)     LLVM_NO=1 ;;
        --llvm-threshold=*) LLVM_THRESHOLD="${_arg#--llvm-threshold=}" ;;
        --help|-h)
            echo "Usage: bash winbox.sh [OPTIONS]"
            echo ""
            echo "  --auto          Chạy không tương tác (bắt buộc kết hợp với --winXXXX)"
            echo "  --win2012       Windows Server 2012 R2"
            echo "  --win2022       Windows Server 2022"
            echo "  --win11         Windows 11 LTSB"
            echo "  --win10ltsb     Windows 10 LTSB 2015"
            echo "  --win10ltsc     Windows 10 LTSC 2023"
            echo "  --rdp           Tự động mở tunnel RDP (frpc, cần ZO_CLIENT_IDENTITY_TOKEN)"
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
            echo "  --iso=URL       Boot từ Windows ISO (cần --virtio=URL cho driver)"
            echo "  --iso           Boot từ ISO (hỏi URL interactive)"
            echo "  --virtio=URL    VirtIO driver ISO URL (dùng với --iso)"
            echo "  --accel-llvm    Force bật hybrid LLVM+TCG backend"
            echo "  --no-llvm       Tắt LLVM backend (dùng TCG thuần)"
            echo "  --llvm-threshold=N  Ngưỡng hot TB cho LLVM (mặc định 1000)"
            echo ""
            echo "  LLVM Hybrid mặc định BẬT khi chạy bằng root."
            echo ""
            echo "  Nếu QEMU đã có sẵn, script tự động bỏ qua build."
            echo "  Dùng --rebuild để build lại từ đầu."
            exit 0
            ;;
        *) echo -e "${Y}⚠${W}  Unknown argument: $_arg (bỏ qua)"; ;;
    esac
done

# ── LLVM auto-detect: mặc định BẬT cho tất cả user (root + non-root)
#    Nếu LLVM install thất bại sẽ tự fallback TCG — không ảnh hưởng gì
if [[ "$LLVM_NO" == "1" ]]; then
    LLVM_ACCEL=0
elif [[ "$LLVM_ACCEL" == "auto" ]]; then
    LLVM_ACCEL=1  # Bật cho cả root và non-root; fallback TCG nếu build thất bại
fi
LLVM_BUILD_OK=0  # sẽ set =1 nếu LLVM patch + build thành công

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
            aria2c -x4 -s4 --file-allocation=none \
                --console-log-level=warn --summary-interval=10 \
                "$url" -o "$output"
        else
            wget --progress=dot:giga --continue "$url" -O "$output"
        fi
        return $?
    fi

    local num_chunks=$(( (total_size + chunk_bytes - 1) / chunk_bytes ))
    echo -e "${B}\u2139${W}  Tổng: $(( total_size / 1024 / 1024 ))MB → ${num_chunks} phần × ${chunk_mb}MB"

    truncate -s "$total_size" "$output" 2>/dev/null || \
        dd if=/dev/zero of="$output" bs=1 count=0 seek="$total_size" 2>/dev/null || true

    local _tmp; _tmp=$(mktemp /tmp/win_chunk_XXXXXX)
    local i start end part_num ok seek_blocks
    for i in $(seq 0 $((num_chunks - 1))); do
        start=$(( i * chunk_bytes ))
        end=$(( start + chunk_bytes - 1 ))
        [[ $end -ge $total_size ]] && end=$(( total_size - 1 ))
        part_num=$(( i + 1 ))
        echo -e "${B}\u2139${W}  Phần ${part_num}/${num_chunks} ($(( (end-start+1)/1024/1024 ))MB)..."
        ok=0
        for _try in 1 2 3; do
            if command -v aria2c &>/dev/null; then
                aria2c --header="Range: bytes=${start}-${end}" \
                    -x8 -s8 --file-allocation=none \
                    --console-log-level=warn --summary-interval=5 \
                    --human-readable=true "$url" -o "$_tmp" 2>&1 && ok=1 && break
            else
                curl -fL --range "${start}-${end}" --retry 3 \
                    --progress-bar -o "$_tmp" "$url" && ok=1 && break
            fi
            echo -e "${Y}⚠${W}  Thử lại lần ${_try}..."; sleep 3
        done
        if [[ "$ok" -eq 0 ]]; then
            rm -f "$_tmp"
            echo -e "${R}\u2718${W}  Phần ${part_num} thất bại"; return 1
        fi
        seek_blocks=$(( start / 512 ))
        dd if="$_tmp" of="$output" bs=512 seek="$seek_blocks" conv=notrunc 2>/dev/null
        rm -f "$_tmp"
        echo -e "${G}\u2714${W}  Phần ${part_num}/${num_chunks} xong"
    done
    echo -e "${G}\u2714${W}  Ghép xong: $(( total_size / 1024 / 1024 / 1024 ))GB"
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
    echo -e "${B}ℹ${W}  ${KVM_LS}"

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
#  LLVM HYBRID BACKEND — Embedded Source + Patch Function
#  Extracts all C source files and patches QEMU source tree
#  Called during root-mode QEMU build if LLVM_ACCEL=1
# ════════════════════════════════════════════════════════════════

_llvm_hybrid_install_dev() {
    # Cài LLVM dev packages (cần cho hybrid backend)
    echo -e "${C}⬡  LLVM Hybrid: cài LLVM dev libraries${W}"
    local _llvm_ok=0
    # Thử nhiều phiên bản LLVM (14-18) lấy cái nào có
    for _v in 16 15 14 17 18; do
        if dpkg -s "llvm-${_v}-dev" &>/dev/null 2>&1; then
            echo -e "${G}✔${W} llvm-${_v}-dev đã có"
            _llvm_ok=1; LLVM_VER=$_v; break
        fi
    done
    if [[ "$_llvm_ok" == "0" ]]; then
        for _v in 16 15 14 17 18; do
            if $APT_CMD install -y "llvm-${_v}-dev" > /tmp/llvm-dev-install.log 2>&1; then
                echo -e "${G}✔${W} llvm-${_v}-dev đã cài"
                _llvm_ok=1; LLVM_VER=$_v; break
            fi
        done
    fi
    if [[ "$_llvm_ok" == "0" ]]; then
        # Fallback: cài generic llvm-dev
        if $APT_CMD install -y llvm-dev > /tmp/llvm-dev-install.log 2>&1; then
            echo -e "${G}✔${W} llvm-dev đã cài (generic)"
            LLVM_VER=$(llvm-config --version 2>/dev/null | cut -d. -f1 || echo "14")
            _llvm_ok=1
        fi
    fi
    if [[ "$_llvm_ok" == "0" ]]; then
        echo -e "${B}ℹ${W}  Thử thêm repo apt.llvm.org (hỗ trợ Debian Trixie / Ubuntu 24.04)..."
        local _codename
        _codename=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}" \
            || lsb_release -sc 2>/dev/null || echo "")
        if [[ -n "$_codename" ]] && _http_get https://apt.llvm.org/llvm.sh /tmp/llvm-install.sh 2>/dev/null; then
            chmod +x /tmp/llvm-install.sh
            if bash /tmp/llvm-install.sh 16 > /tmp/llvm-repo.log 2>&1; then
                echo -e "${G}✔${W} Repo llvm.org thêm thành công"
            else
                echo -e "${Y}⚠${W}  llvm.sh thất bại — thêm repo thủ công..."
                _http_get https://apt.llvm.org/llvm-snapshot.gpg.key \
                    | (command -v sudo &>/dev/null \
                       && sudo tee /etc/apt/trusted.gpg.d/llvm.asc > /dev/null 2>&1 \
                       || tee /etc/apt/trusted.gpg.d/llvm.asc > /dev/null 2>&1) || true
                printf 'deb http://apt.llvm.org/%s/ llvm-toolchain-%s-16 main\ndeb-src http://apt.llvm.org/%s/ llvm-toolchain-%s-16 main\n' \
                    "$_codename" "$_codename" "$_codename" "$_codename" \
                    | (command -v sudo &>/dev/null \
                       && sudo tee /etc/apt/sources.list.d/llvm-16.list > /dev/null \
                       || tee /etc/apt/sources.list.d/llvm-16.list > /dev/null) || true
            fi
            if [[ -n "${APT_CMD:-}" ]]; then
                $APT_CMD update -qq > /dev/null 2>&1 || true
                for _v in 16 15 14 17 18 19; do
                    if $APT_CMD install -y "llvm-${_v}-dev" > /tmp/llvm-dev-install.log 2>&1; then
                        echo -e "${G}✔${W} llvm-${_v}-dev đã cài (từ apt.llvm.org)"
                        _llvm_ok=1; LLVM_VER=$_v; break
                    fi
                done
            fi
        else
            echo -e "${Y}⚠${W}  Không tải được llvm.sh — kiểm tra mạng"
        fi
    fi
    if [[ "$_llvm_ok" == "0" ]]; then
        echo -e "${Y}⚠${W}  LLVM dev không cài được — fallback TCG"
        return 1
    fi
    # Verify llvm-config works
    local _llvm_config=""
    for _c in "llvm-config-${LLVM_VER}" "llvm-config"; do
        if command -v "$_c" &>/dev/null; then _llvm_config="$_c"; break; fi
    done
    if [[ -z "$_llvm_config" ]]; then
        echo -e "${Y}⚠${W}  llvm-config không tìm thấy — fallback TCG"
        return 1
    fi
    echo -e "${G}✔${W} LLVM $(${_llvm_config} --version) dev sẵn sàng"
    export LLVM_CONFIG="$_llvm_config"
    # Ensure unversioned llvm-config points to our version
    if [[ "$_llvm_config" != "llvm-config" ]] && [[ "$(id -u)" == "0" ]]; then
        sudo update-alternatives --install /usr/bin/llvm-config llvm-config "$_llvm_config" 100 2>/dev/null || \
            ln -sf "$(command -v "$_llvm_config")" /usr/local/bin/llvm-config 2>/dev/null || true
        echo -e "${G}✔${W} llvm-config → $_llvm_config"
    fi
    return 0
}

_llvm_hybrid_extract_and_patch() {
    # $1 = QEMU source directory (e.g. /tmp/qemu-src)
    local QEMU_DIR="$1"
    if [[ ! -d "$QEMU_DIR/tcg" ]]; then
        echo -e "${Y}⚠${W}  QEMU source dir invalid — skip LLVM patch"
        return 1
    fi

    echo -e "${C}⬡  LLVM Hybrid: extracting + patching QEMU${W}"
    local LLVM_DIR="$QEMU_DIR/tcg/llvm"
    mkdir -p "$LLVM_DIR"

    # ── llvm-jit.h ─────────────────────────────────────────────
    cat > "$LLVM_DIR/llvm-jit.h" << 'LLVM_JIT_H_EOF'
/*
 * QEMU Hybrid LLVM+TCG — LLVM JIT Engine
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef QEMU_LLVM_JIT_H
#define QEMU_LLVM_JIT_H
#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <llvm-c/Core.h>
#include <llvm-c/ExecutionEngine.h>
#include <llvm-c/Target.h>
#include <llvm-c/Analysis.h>
#include <llvm-c/Transforms/PassBuilder.h>
#if LLVM_VERSION_MAJOR < 15
#define LLVMPointerTypeInContext(ctx, as) \
    LLVMPointerType(LLVMInt8TypeInContext(ctx), as)
#endif
typedef struct LLVMCompiledTB {
    void     *code_ptr;
    size_t    code_size;
    uint64_t  tb_pc;
    uint64_t  compile_time_ns;
} LLVMCompiledTB;
typedef struct LLVMJITState {
    LLVMContextRef         ctx;
    LLVMExecutionEngineRef engine;
    LLVMTargetMachineRef   target_machine;
    LLVMPassBuilderOptionsRef pbo;
    volatile uint64_t total_compiled;
    volatile uint64_t total_failed;
    volatile uint64_t total_compile_time_ns;
    bool initialized;
} LLVMJITState;
typedef struct LLVMJITWorker {
    LLVMJITState state;
    int worker_id;
} LLVMJITWorker;
int llvm_jit_init(LLVMJITState *state);
int llvm_jit_compile(LLVMJITState *state, LLVMModuleRef module,
                     uint64_t tb_pc, LLVMCompiledTB *out);
void llvm_jit_optimize(LLVMJITState *state, LLVMModuleRef module);
void llvm_jit_dump_stats(const LLVMJITState *state);
void llvm_jit_destroy(LLVMJITState *state);
int llvm_jit_worker_init(LLVMJITWorker *w, int id);
void llvm_jit_worker_destroy(LLVMJITWorker *w);
#endif
LLVM_JIT_H_EOF

    # ── llvm-jit.c ─────────────────────────────────────────────
    cat > "$LLVM_DIR/llvm-jit.c" << 'LLVM_JIT_C_EOF'
/*
 * QEMU Hybrid LLVM+TCG — LLVM JIT Engine Implementation
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "llvm-jit.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static uint64_t get_time_ns(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + ts.tv_nsec;
}
int llvm_jit_init(LLVMJITState *state) {
    char *error = NULL;
    memset(state, 0, sizeof(*state));
    LLVMInitializeNativeTarget();
    LLVMInitializeNativeAsmPrinter();
    LLVMInitializeNativeAsmParser();
    state->ctx = LLVMContextCreate();
    if (!state->ctx) { fprintf(stderr, "[llvm-jit] Failed to create LLVM context\n"); return -1; }
    char *triple = LLVMGetDefaultTargetTriple();
    LLVMTargetRef target;
    if (LLVMGetTargetFromTriple(triple, &target, &error)) {
        fprintf(stderr, "[llvm-jit] Failed to get target: %s\n", error);
        LLVMDisposeMessage(error); LLVMDisposeMessage(triple); return -1;
    }
    state->target_machine = LLVMCreateTargetMachine(target, triple, "generic", "",
        LLVMCodeGenLevelAggressive, LLVMRelocPIC, LLVMCodeModelJITDefault);
    LLVMDisposeMessage(triple);
    if (!state->target_machine) { fprintf(stderr, "[llvm-jit] Failed to create target machine\n"); return -1; }
    state->pbo = LLVMCreatePassBuilderOptions();
    if (state->pbo) {
        LLVMPassBuilderOptionsSetLoopUnrolling(state->pbo, 1);
        LLVMPassBuilderOptionsSetLoopVectorization(state->pbo, 1);
        LLVMPassBuilderOptionsSetMergeFunctions(state->pbo, 1);
    }
    state->initialized = true;
    return 0;
}
void llvm_jit_optimize(LLVMJITState *state, LLVMModuleRef module) {
    if (!state->pbo || !state->target_machine) return;
    LLVMRunPasses(module, "default<O2>", state->target_machine, state->pbo);
}
int llvm_jit_compile(LLVMJITState *state, LLVMModuleRef module,
                     uint64_t tb_pc, LLVMCompiledTB *out) {
    char *error = NULL; char func_name[64]; uint64_t t_start, t_end;
    if (!state->initialized) { LLVMDisposeModule(module); return -1; }
    if (LLVMVerifyModule(module, LLVMReturnStatusAction, &error)) {
        fprintf(stderr, "[llvm-jit] Verify failed TB 0x%lx: %s\n", (unsigned long)tb_pc, error);
        LLVMDisposeMessage(error); LLVMDisposeModule(module); __atomic_add_fetch(&state->total_failed,1,__ATOMIC_RELAXED); return -1;
    }
    if (error) { LLVMDisposeMessage(error); error = NULL; }
    t_start = get_time_ns();
    llvm_jit_optimize(state, module);
    LLVMExecutionEngineRef ee;
    struct LLVMMCJITCompilerOptions options;
    LLVMInitializeMCJITCompilerOptions(&options, sizeof(options));
    options.OptLevel = 2;
    if (LLVMCreateMCJITCompilerForModule(&ee, module, &options, sizeof(options), &error)) {
        fprintf(stderr, "[llvm-jit] MCJIT fail TB 0x%lx: %s\n", (unsigned long)tb_pc, error);
        LLVMDisposeMessage(error); __atomic_add_fetch(&state->total_failed,1,__ATOMIC_RELAXED); return -1;
    }
    snprintf(func_name, sizeof(func_name), "tb_%lx", (unsigned long)tb_pc);
    uint64_t func_addr = LLVMGetFunctionAddress(ee, func_name);
    t_end = get_time_ns();
    if (!func_addr) { LLVMDisposeExecutionEngine(ee); __atomic_add_fetch(&state->total_failed,1,__ATOMIC_RELAXED); return -1; }
    out->code_ptr = (void *)func_addr; out->code_size = 0;
    out->tb_pc = tb_pc; out->compile_time_ns = t_end - t_start;
    __atomic_add_fetch(&state->total_compiled, 1, __ATOMIC_RELAXED);
    __atomic_add_fetch(&state->total_compile_time_ns, out->compile_time_ns, __ATOMIC_RELAXED);
    if (!state->engine) state->engine = ee;
    return 0;
}
int llvm_jit_worker_init(LLVMJITWorker *w, int id) {
    memset(w, 0, sizeof(*w));
    w->worker_id = id;
    return llvm_jit_init(&w->state);
}
void llvm_jit_worker_destroy(LLVMJITWorker *w) {
    llvm_jit_destroy(&w->state);
}
void llvm_jit_dump_stats(const LLVMJITState *state) {
    if (!state->initialized) return;
    fprintf(stderr, "\n[llvm-jit] === LLVM Hybrid JIT Statistics ===\n");
    fprintf(stderr, "[llvm-jit]   TBs compiled by LLVM : %lu\n", (unsigned long)state->total_compiled);
    fprintf(stderr, "[llvm-jit]   TBs failed (fallback) : %lu\n", (unsigned long)state->total_failed);
    if (state->total_compiled > 0)
        fprintf(stderr, "[llvm-jit]   Avg compile time     : %.2f ms\n",
            (double)state->total_compile_time_ns / (double)state->total_compiled / 1e6);
    fprintf(stderr, "[llvm-jit] ================================\n\n");
}
void llvm_jit_destroy(LLVMJITState *state) {
    if (!state->initialized) return;
    llvm_jit_dump_stats(state);
    if (state->engine) { LLVMDisposeExecutionEngine(state->engine); state->engine = NULL; }
    if (state->pbo) { LLVMDisposePassBuilderOptions(state->pbo); state->pbo = NULL; }
    if (state->target_machine) { LLVMDisposeTargetMachine(state->target_machine); state->target_machine = NULL; }
    if (state->ctx) { LLVMContextDispose(state->ctx); state->ctx = NULL; }
    state->initialized = false;
}
LLVM_JIT_C_EOF

    # ── tb-profiler.h ──────────────────────────────────────────
    cat > "$LLVM_DIR/tb-profiler.h" << 'TB_PROF_H_EOF'
/*
 * QEMU Hybrid LLVM+TCG — Translation Block Profiler
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef QEMU_TB_PROFILER_H
#define QEMU_TB_PROFILER_H
#include <stdint.h>
#include <stdbool.h>
#include <pthread.h>
#define LLVM_HOT_THRESHOLD 1000
#define TB_PROFILE_HT_SIZE  (1 << 16)
#define TB_PROFILE_HT_MASK  (TB_PROFILE_HT_SIZE - 1)
#define TB_PROFILER_STRIPE  64
typedef struct TBProfileEntry {
    uint64_t pc; volatile uint32_t exec_count;
    volatile uint8_t llvm_state; uint8_t _pad[3];
    struct TBProfileEntry *next;
} TBProfileEntry;
typedef struct TBProfiler {
    TBProfileEntry *buckets[TB_PROFILE_HT_SIZE];
    pthread_spinlock_t stripe_locks[TB_PROFILER_STRIPE];
    uint32_t hot_threshold; volatile uint64_t total_entries;
    volatile uint64_t total_hot; bool initialized;
} TBProfiler;
enum { TB_LLVM_PENDING=0, TB_LLVM_QUEUED=1, TB_LLVM_COMPILED=2, TB_LLVM_FAILED=3 };
void tb_profiler_init(TBProfiler *prof, uint32_t threshold);
TBProfileEntry *tb_profiler_record(TBProfiler *prof, uint64_t pc);
bool tb_profiler_is_hot(TBProfiler *prof, uint64_t pc);
TBProfileEntry *tb_profiler_lookup(TBProfiler *prof, uint64_t pc);
void tb_profiler_set_state(TBProfiler *prof, uint64_t pc, uint8_t state);
void tb_profiler_dump_stats(const TBProfiler *prof);
void tb_profiler_destroy(TBProfiler *prof);
#endif
TB_PROF_H_EOF

    # ── tb-profiler.c ──────────────────────────────────────────
    cat > "$LLVM_DIR/tb-profiler.c" << 'TB_PROF_C_EOF'
/*
 * QEMU Hybrid LLVM+TCG — TB Profiler Implementation
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "tb-profiler.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static inline uint32_t hash_pc(uint64_t pc) {
    pc ^= pc >> 16; pc *= 0x45d9f3b; pc ^= pc >> 16;
    return (uint32_t)(pc & TB_PROFILE_HT_MASK);
}
static inline uint32_t stripe_idx(uint32_t bucket) {
    return bucket % TB_PROFILER_STRIPE;
}
void tb_profiler_init(TBProfiler *prof, uint32_t threshold) {
    memset(prof, 0, sizeof(*prof));
    prof->hot_threshold = threshold ? threshold : LLVM_HOT_THRESHOLD;
    for (int i = 0; i < TB_PROFILER_STRIPE; i++)
        pthread_spin_init(&prof->stripe_locks[i], PTHREAD_PROCESS_PRIVATE);
    prof->initialized = true;
}
TBProfileEntry *tb_profiler_record(TBProfiler *prof, uint64_t pc) {
    uint32_t idx = hash_pc(pc);
    uint32_t si = stripe_idx(idx);
    pthread_spin_lock(&prof->stripe_locks[si]);
    TBProfileEntry *e = prof->buckets[idx];
    while (e) { if (e->pc == pc) {
        __atomic_add_fetch(&e->exec_count, 1, __ATOMIC_RELAXED);
        if (e->exec_count == prof->hot_threshold && e->llvm_state == TB_LLVM_PENDING)
            __atomic_add_fetch(&prof->total_hot, 1, __ATOMIC_RELAXED);
        pthread_spin_unlock(&prof->stripe_locks[si]);
        return e; } e = e->next; }
    e = calloc(1, sizeof(*e));
    if (!e) { pthread_spin_unlock(&prof->stripe_locks[si]); return NULL; }
    e->pc = pc; e->exec_count = 1; e->llvm_state = TB_LLVM_PENDING;
    e->next = prof->buckets[idx]; prof->buckets[idx] = e;
    __atomic_add_fetch(&prof->total_entries, 1, __ATOMIC_RELAXED);
    pthread_spin_unlock(&prof->stripe_locks[si]);
    return e;
}
bool tb_profiler_is_hot(TBProfiler *prof, uint64_t pc) {
    TBProfileEntry *e = tb_profiler_lookup(prof, pc);
    if (!e) return false;
    return (__atomic_load_n(&e->exec_count, __ATOMIC_RELAXED) >= prof->hot_threshold
            && __atomic_load_n(&e->llvm_state, __ATOMIC_RELAXED) == TB_LLVM_PENDING);
}
TBProfileEntry *tb_profiler_lookup(TBProfiler *prof, uint64_t pc) {
    uint32_t idx = hash_pc(pc);
    uint32_t si = stripe_idx(idx);
    pthread_spin_lock(&prof->stripe_locks[si]);
    TBProfileEntry *e = prof->buckets[idx];
    while (e) { if (e->pc == pc) { pthread_spin_unlock(&prof->stripe_locks[si]); return e; } e = e->next; }
    pthread_spin_unlock(&prof->stripe_locks[si]);
    return NULL;
}
void tb_profiler_set_state(TBProfiler *prof, uint64_t pc, uint8_t state) {
    TBProfileEntry *e = tb_profiler_lookup(prof, pc);
    if (e) __atomic_store_n(&e->llvm_state, state, __ATOMIC_RELEASE);
}
void tb_profiler_dump_stats(const TBProfiler *prof) {
    if (!prof->initialized) return;
    uint64_t compiled=0, failed=0, max_count=0; uint64_t top_pc=0;
    for (uint32_t i = 0; i < TB_PROFILE_HT_SIZE; i++) {
        TBProfileEntry *e = prof->buckets[i];
        while (e) { if (e->llvm_state==TB_LLVM_COMPILED) compiled++;
            if (e->llvm_state==TB_LLVM_FAILED) failed++;
            if (e->exec_count > max_count) { max_count = e->exec_count; top_pc = e->pc; }
            e = e->next; } }
    fprintf(stderr, "\n[tb-profiler] Total TBs: %lu | Hot: %lu | LLVM compiled: %lu | Failed: %lu\n",
        (unsigned long)prof->total_entries, (unsigned long)prof->total_hot,
        (unsigned long)compiled, (unsigned long)failed);
    if (max_count > 0) fprintf(stderr, "[tb-profiler] Hottest: 0x%lx (%lu exec)\n",
        (unsigned long)top_pc, (unsigned long)max_count);
}
void tb_profiler_destroy(TBProfiler *prof) {
    if (!prof->initialized) return; tb_profiler_dump_stats(prof);
    for (uint32_t i = 0; i < TB_PROFILE_HT_SIZE; i++) {
        TBProfileEntry *e = prof->buckets[i];
        while (e) { TBProfileEntry *n = e->next; free(e); e = n; }
        prof->buckets[i] = NULL; }
    for (int i = 0; i < TB_PROFILER_STRIPE; i++)
        pthread_spin_destroy(&prof->stripe_locks[i]);
    prof->initialized = false;
}
TB_PROF_C_EOF

    # ── tcg-to-llvm.h ─────────────────────────────────────────
    cat > "$LLVM_DIR/tcg-to-llvm.h" << 'TCG_LLVM_H_EOF'
/*
 * QEMU Hybrid LLVM+TCG — TCG IR to LLVM IR Translator
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef QEMU_TCG_TO_LLVM_H
#define QEMU_TCG_TO_LLVM_H
#include <llvm-c/Core.h>
#include <stdint.h>
#if LLVM_VERSION_MAJOR < 15
#define LLVMPointerTypeInContext(ctx, as) \
    LLVMPointerType(LLVMInt8TypeInContext(ctx), as)
#endif
#include <stdbool.h>
struct TCGContext; struct TCGOp; struct TranslationBlock;
#define MAX_LLVM_TEMPS 512
typedef struct TCGToLLVMCtx {
    LLVMContextRef llvm_ctx; LLVMModuleRef module;
    LLVMBuilderRef builder; LLVMValueRef function; LLVMValueRef env_ptr;
    LLVMValueRef temps[MAX_LLVM_TEMPS]; LLVMTypeRef temp_types[MAX_LLVM_TEMPS];
    LLVMBasicBlockRef *labels; int num_labels; LLVMBasicBlockRef current_bb;
    uint64_t tb_pc; bool has_unsupported_op; int unsupported_opcode;
    int total_ops_translated; int total_ops_skipped;
    LLVMTypeRef i1_type, i8_type, i16_type, i32_type, i64_type, ptr_type, void_type;
} TCGToLLVMCtx;
int tcg_to_llvm_init(TCGToLLVMCtx *ctx, LLVMContextRef llvm_ctx, uint64_t tb_pc);
int tcg_to_llvm_translate(TCGToLLVMCtx *ctx, struct TCGContext *tcg_ctx);
LLVMModuleRef tcg_to_llvm_finalize(TCGToLLVMCtx *ctx);
void tcg_to_llvm_cleanup(TCGToLLVMCtx *ctx);
int tcg_to_llvm_translate_op(TCGToLLVMCtx *ctx, struct TCGOp *op);
#endif
TCG_LLVM_H_EOF

    # ── tcg-to-llvm.c ─────────────────────────────────────────
    # This is the largest file (~1200 lines). Using cat with heredoc.
    cp /dev/null "$LLVM_DIR/tcg-to-llvm.c"
    cat > "$LLVM_DIR/tcg-to-llvm.c" << 'TCG_LLVM_C_EOF'
/*
 * QEMU Hybrid LLVM+TCG — TCG IR to LLVM IR Translator
 * Translates TCG ops -> LLVM IR. Unsupported ops -> fallback TCG.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "tcg-to-llvm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "tcg/tcg.h"
#include "tcg/tcg-op-common.h"
#include "exec/translation-block.h"

static LLVMValueRef get_temp(TCGToLLVMCtx *ctx, TCGArg arg) {
    if (arg >= MAX_LLVM_TEMPS) { ctx->has_unsupported_op = true; return LLVMConstInt(ctx->i64_type, 0, 0); }
    if (!ctx->temps[arg]) ctx->temps[arg] = LLVMConstInt(ctx->i64_type, 0, 0);
    return ctx->temps[arg];
}
static void set_temp(TCGToLLVMCtx *ctx, TCGArg arg, LLVMValueRef val) {
    if (arg < MAX_LLVM_TEMPS) ctx->temps[arg] = val;
}
static LLVMValueRef ensure_type(TCGToLLVMCtx *ctx, LLVMValueRef val, LLVMTypeRef target_type) {
    LLVMTypeRef vt = LLVMTypeOf(val); if (vt == target_type) return val;
    unsigned vb = LLVMGetIntTypeWidth(vt), tb = LLVMGetIntTypeWidth(target_type);
    if (vb < tb) return LLVMBuildZExt(ctx->builder, val, target_type, "zext");
    if (vb > tb) return LLVMBuildTrunc(ctx->builder, val, target_type, "trunc");
    return val;
}
static LLVMIntPredicate tcg_cond_to_llvm(int c) {
    switch(c) { case 0:return LLVMIntEQ; case 1:return LLVMIntNE;
    case 2:return LLVMIntSLT; case 3:return LLVMIntSGE; case 4:return LLVMIntSLE;
    case 5:return LLVMIntSGT; case 6:return LLVMIntULT; case 7:return LLVMIntUGE;
    case 8:return LLVMIntULE; case 9:return LLVMIntUGT; default:return LLVMIntEQ; }
}
static LLVMValueRef load_env_field(TCGToLLVMCtx *ctx, int offset, LLVMTypeRef type, const char *name) {
    LLVMValueRef idx = LLVMConstInt(ctx->i32_type, offset, 0);
    LLVMValueRef ptr = LLVMBuildGEP2(ctx->builder, ctx->i8_type, ctx->env_ptr, &idx, 1, "env_gep");
    LLVMValueRef tp = LLVMBuildBitCast(ctx->builder, ptr, LLVMPointerType(type, 0), "env_cast");
    return LLVMBuildLoad2(ctx->builder, type, tp, name);
}
static void store_env_field(TCGToLLVMCtx *ctx, int offset, LLVMValueRef val) {
    LLVMTypeRef type = LLVMTypeOf(val);
    LLVMValueRef idx = LLVMConstInt(ctx->i32_type, offset, 0);
    LLVMValueRef ptr = LLVMBuildGEP2(ctx->builder, ctx->i8_type, ctx->env_ptr, &idx, 1, "env_st_gep");
    LLVMValueRef tp = LLVMBuildBitCast(ctx->builder, ptr, LLVMPointerType(type, 0), "env_st_cast");
    LLVMBuildStore(ctx->builder, val, tp);
}

int tcg_to_llvm_init(TCGToLLVMCtx *ctx, LLVMContextRef llvm_ctx, uint64_t tb_pc) {
    memset(ctx, 0, sizeof(*ctx)); ctx->llvm_ctx = llvm_ctx; ctx->tb_pc = tb_pc;
    ctx->i1_type = LLVMInt1TypeInContext(llvm_ctx); ctx->i8_type = LLVMInt8TypeInContext(llvm_ctx);
    ctx->i16_type = LLVMInt16TypeInContext(llvm_ctx); ctx->i32_type = LLVMInt32TypeInContext(llvm_ctx);
    ctx->i64_type = LLVMInt64TypeInContext(llvm_ctx);
    ctx->ptr_type = LLVMPointerTypeInContext(llvm_ctx, 0);
    ctx->void_type = LLVMVoidTypeInContext(llvm_ctx);
    char mn[64]; snprintf(mn, sizeof(mn), "tb_0x%lx", (unsigned long)tb_pc);
    ctx->module = LLVMModuleCreateWithNameInContext(mn, llvm_ctx);
    char fn[64]; snprintf(fn, sizeof(fn), "tb_%lx", (unsigned long)tb_pc);
    LLVMTypeRef pt[] = { ctx->ptr_type };
    LLVMTypeRef ft = LLVMFunctionType(ctx->i64_type, pt, 1, 0);
    ctx->function = LLVMAddFunction(ctx->module, fn, ft);
    ctx->current_bb = LLVMAppendBasicBlockInContext(llvm_ctx, ctx->function, "entry");
    ctx->builder = LLVMCreateBuilderInContext(llvm_ctx);
    LLVMPositionBuilderAtEnd(ctx->builder, ctx->current_bb);
    ctx->env_ptr = LLVMGetParam(ctx->function, 0);
    return 0;
}

/* Helper: get LLVM type for TCG op based on type info in param1 */
static LLVMTypeRef get_op_type(TCGToLLVMCtx *ctx, unsigned type_param) {
    return (type_param == TCG_TYPE_I32) ? ctx->i32_type : ctx->i64_type;
}
static unsigned get_op_bits(unsigned type_param) {
    return (type_param == TCG_TYPE_I32) ? 32 : 64;
}

int tcg_to_llvm_translate_op(TCGToLLVMCtx *ctx, struct TCGOp *op) {
    TCGOpcode opc = op->opc; const TCGArg *args = op->args;
    LLVMValueRef a, b, result;
    LLVMTypeRef ty;
    unsigned bits;
    switch (opc) {
    case INDEX_op_insn_start: case INDEX_op_discard:
        ctx->total_ops_translated++; return 0;
    case INDEX_op_mov:
        ty = get_op_type(ctx, op->param1);
        set_temp(ctx, args[0], ensure_type(ctx, get_temp(ctx, args[1]), ty));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_add:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildAdd(ctx->builder, a, b, "add"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_sub:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildSub(ctx->builder, a, b, "sub"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_mul:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildMul(ctx->builder, a, b, "mul"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_divs:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildSDiv(ctx->builder, a, b, "divs"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_divu:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildUDiv(ctx->builder, a, b, "divu"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_rems:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildSRem(ctx->builder, a, b, "rems"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_remu:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildURem(ctx->builder, a, b, "remu"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_and:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildAnd(ctx->builder, a, b, "and"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_or:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildOr(ctx->builder, a, b, "or"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_xor:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildXor(ctx->builder, a, b, "xor"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_neg:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        set_temp(ctx, args[0], LLVMBuildNeg(ctx->builder, a, "neg"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_not:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        set_temp(ctx, args[0], LLVMBuildNot(ctx->builder, a, "not"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_shl:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildShl(ctx->builder, a, b, "shl"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_shr:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildLShr(ctx->builder, a, b, "shr"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_sar:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildAShr(ctx->builder, a, b, "sar"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_rotl:
        ty = get_op_type(ctx, op->param1); bits = get_op_bits(op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty); {
        LLVMValueRef bv = LLVMConstInt(ty, bits, 0);
        result = LLVMBuildOr(ctx->builder, LLVMBuildShl(ctx->builder, a, b, ""),
            LLVMBuildLShr(ctx->builder, a, LLVMBuildSub(ctx->builder, bv, b, ""), ""), "rotl");
        set_temp(ctx, args[0], result); ctx->total_ops_translated++; return 0; }
    case INDEX_op_rotr:
        ty = get_op_type(ctx, op->param1); bits = get_op_bits(op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty); {
        LLVMValueRef bv = LLVMConstInt(ty, bits, 0);
        result = LLVMBuildOr(ctx->builder, LLVMBuildLShr(ctx->builder, a, b, ""),
            LLVMBuildShl(ctx->builder, a, LLVMBuildSub(ctx->builder, bv, b, ""), ""), "rotr");
        set_temp(ctx, args[0], result); ctx->total_ops_translated++; return 0; }
    case INDEX_op_andc:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildAnd(ctx->builder, a, LLVMBuildNot(ctx->builder, b, ""), "andc"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_orc:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildOr(ctx->builder, a, LLVMBuildNot(ctx->builder, b, ""), "orc"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_eqv:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildNot(ctx->builder, LLVMBuildXor(ctx->builder, a, b, ""), "eqv"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_nand:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildNot(ctx->builder, LLVMBuildAnd(ctx->builder, a, b, ""), "nand"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_nor:
        ty = get_op_type(ctx, op->param1);
        a = ensure_type(ctx, get_temp(ctx, args[1]), ty);
        b = ensure_type(ctx, get_temp(ctx, args[2]), ty);
        set_temp(ctx, args[0], LLVMBuildNot(ctx->builder, LLVMBuildOr(ctx->builder, a, b, ""), "nor"));
        ctx->total_ops_translated++; return 0;
    /* Extensions (QEMU v11 unified) */
    case INDEX_op_ext_i32_i64: a=ensure_type(ctx,get_temp(ctx,args[1]),ctx->i32_type);
        set_temp(ctx,args[0],LLVMBuildSExt(ctx->builder,a,ctx->i64_type,"ext32_64"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_extu_i32_i64: a=ensure_type(ctx,get_temp(ctx,args[1]),ctx->i32_type);
        set_temp(ctx,args[0],LLVMBuildZExt(ctx->builder,a,ctx->i64_type,"extu32_64"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_extrl_i64_i32: a=ensure_type(ctx,get_temp(ctx,args[1]),ctx->i64_type);
        set_temp(ctx,args[0],LLVMBuildTrunc(ctx->builder,a,ctx->i32_type,"extrl64_32"));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_extrh_i64_i32: a=ensure_type(ctx,get_temp(ctx,args[1]),ctx->i64_type);
        a=LLVMBuildLShr(ctx->builder,a,LLVMConstInt(ctx->i64_type,32,0),"");
        set_temp(ctx,args[0],LLVMBuildTrunc(ctx->builder,a,ctx->i32_type,"extrh64_32"));
        ctx->total_ops_translated++; return 0;
    /* Setcond (unified) */
    case INDEX_op_setcond: {
        ty = get_op_type(ctx, op->param1);
        a=ensure_type(ctx,get_temp(ctx,args[1]),ty);
        b=ensure_type(ctx,get_temp(ctx,args[2]),ty);
        LLVMValueRef cmp=LLVMBuildICmp(ctx->builder,tcg_cond_to_llvm(args[3]),a,b,"");
        set_temp(ctx,args[0],LLVMBuildZExt(ctx->builder,cmp,ty,"setcond"));
        ctx->total_ops_translated++; return 0; }
    /* Movcond (unified) */
    case INDEX_op_movcond: {
        ty = get_op_type(ctx, op->param1);
        LLVMValueRef c1=ensure_type(ctx,get_temp(ctx,args[1]),ty);
        LLVMValueRef c2=ensure_type(ctx,get_temp(ctx,args[2]),ty);
        LLVMValueRef vt=ensure_type(ctx,get_temp(ctx,args[3]),ty);
        LLVMValueRef vf=ensure_type(ctx,get_temp(ctx,args[4]),ty);
        LLVMValueRef cmp=LLVMBuildICmp(ctx->builder,tcg_cond_to_llvm(args[5]),c1,c2,"");
        set_temp(ctx,args[0],LLVMBuildSelect(ctx->builder,cmp,vt,vf,"movcond"));
        ctx->total_ops_translated++; return 0; }
    /* Env loads (unified) */
    case INDEX_op_ld8u: { ty = get_op_type(ctx, op->param1);
        result=load_env_field(ctx,(int)args[2],ctx->i8_type,"ld8u");
        set_temp(ctx,args[0],LLVMBuildZExt(ctx->builder,result,ty,""));
        ctx->total_ops_translated++; return 0; }
    case INDEX_op_ld8s: { ty = get_op_type(ctx, op->param1);
        result=load_env_field(ctx,(int)args[2],ctx->i8_type,"ld8s");
        set_temp(ctx,args[0],LLVMBuildSExt(ctx->builder,result,ty,""));
        ctx->total_ops_translated++; return 0; }
    case INDEX_op_ld16u: { ty = get_op_type(ctx, op->param1);
        result=load_env_field(ctx,(int)args[2],ctx->i16_type,"ld16u");
        set_temp(ctx,args[0],LLVMBuildZExt(ctx->builder,result,ty,""));
        ctx->total_ops_translated++; return 0; }
    case INDEX_op_ld16s: { ty = get_op_type(ctx, op->param1);
        result=load_env_field(ctx,(int)args[2],ctx->i16_type,"ld16s");
        set_temp(ctx,args[0],LLVMBuildSExt(ctx->builder,result,ty,""));
        ctx->total_ops_translated++; return 0; }
    case INDEX_op_ld32u: { result=load_env_field(ctx,(int)args[2],ctx->i32_type,"ld32u");
        set_temp(ctx,args[0],LLVMBuildZExt(ctx->builder,result,ctx->i64_type,""));
        ctx->total_ops_translated++; return 0; }
    case INDEX_op_ld32s: { result=load_env_field(ctx,(int)args[2],ctx->i32_type,"ld32s");
        set_temp(ctx,args[0],LLVMBuildSExt(ctx->builder,result,ctx->i64_type,""));
        ctx->total_ops_translated++; return 0; }
    case INDEX_op_ld: { ty = get_op_type(ctx, op->param1);
        set_temp(ctx,args[0],load_env_field(ctx,(int)args[2],ty,"ld"));
        ctx->total_ops_translated++; return 0; }
    /* Env stores (unified) */
    case INDEX_op_st8: a=get_temp(ctx,args[0]);
        store_env_field(ctx,(int)args[2],LLVMBuildTrunc(ctx->builder,
            ensure_type(ctx,a,ctx->i32_type),ctx->i8_type,""));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_st16: a=get_temp(ctx,args[0]);
        store_env_field(ctx,(int)args[2],LLVMBuildTrunc(ctx->builder,
            ensure_type(ctx,a,ctx->i32_type),ctx->i16_type,""));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_st32: a=get_temp(ctx,args[0]);
        store_env_field(ctx,(int)args[2],LLVMBuildTrunc(ctx->builder,
            ensure_type(ctx,a,ctx->i64_type),ctx->i32_type,""));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_st: { ty = get_op_type(ctx, op->param1);
        store_env_field(ctx,(int)args[2],ensure_type(ctx,get_temp(ctx,args[0]),ty));
        ctx->total_ops_translated++; return 0; }
    /* Control flow */
    case INDEX_op_set_label: {
        int lid=(int)args[0]; char bn[32]; snprintf(bn,sizeof(bn),"L%d",lid);
        if (lid >= ctx->num_labels) { int ns=lid+16;
            ctx->labels=realloc(ctx->labels,ns*sizeof(LLVMBasicBlockRef));
            for(int i=ctx->num_labels;i<ns;i++) ctx->labels[i]=NULL; ctx->num_labels=ns; }
        LLVMBasicBlockRef bb=LLVMAppendBasicBlockInContext(ctx->llvm_ctx,ctx->function,bn);
        ctx->labels[lid]=bb;
        if(!LLVMGetBasicBlockTerminator(ctx->current_bb)) LLVMBuildBr(ctx->builder,bb);
        ctx->current_bb=bb; LLVMPositionBuilderAtEnd(ctx->builder,bb);
        ctx->total_ops_translated++; return 0; }
    case INDEX_op_br: { int lid=(int)args[0];
        if(lid>=ctx->num_labels){int ns=lid+16;ctx->labels=realloc(ctx->labels,ns*sizeof(LLVMBasicBlockRef));
        for(int i=ctx->num_labels;i<ns;i++)ctx->labels[i]=NULL;ctx->num_labels=ns;}
        if(!ctx->labels[lid]) ctx->labels[lid]=LLVMAppendBasicBlockInContext(ctx->llvm_ctx,ctx->function,"br_fwd");
        LLVMBuildBr(ctx->builder,ctx->labels[lid]); ctx->total_ops_translated++; return 0; }
    case INDEX_op_brcond: {
        ty = get_op_type(ctx, op->param1);
        a=ensure_type(ctx,get_temp(ctx,args[0]),ty);
        b=ensure_type(ctx,get_temp(ctx,args[1]),ty);
        int lid=(int)args[3];
        if(lid>=ctx->num_labels){int ns=lid+16;ctx->labels=realloc(ctx->labels,ns*sizeof(LLVMBasicBlockRef));
        for(int i=ctx->num_labels;i<ns;i++)ctx->labels[i]=NULL;ctx->num_labels=ns;}
        if(!ctx->labels[lid]) ctx->labels[lid]=LLVMAppendBasicBlockInContext(ctx->llvm_ctx,ctx->function,"brc_tgt");
        LLVMBasicBlockRef ft=LLVMAppendBasicBlockInContext(ctx->llvm_ctx,ctx->function,"brc_ft");
        LLVMBuildCondBr(ctx->builder,LLVMBuildICmp(ctx->builder,tcg_cond_to_llvm(args[2]),a,b,""),
            ctx->labels[lid],ft);
        ctx->current_bb=ft; LLVMPositionBuilderAtEnd(ctx->builder,ft);
        ctx->total_ops_translated++; return 0; }
    case INDEX_op_exit_tb: LLVMBuildRet(ctx->builder,LLVMConstInt(ctx->i64_type,args[0],0));
        ctx->total_ops_translated++; return 0;
    case INDEX_op_goto_tb: set_temp(ctx,args[0],LLVMConstInt(ctx->i64_type,args[0],0));
        ctx->total_ops_translated++; return 0;
    /* Deposit/Extract (unified) */
    case INDEX_op_deposit: { ty = get_op_type(ctx, op->param1);
        a=ensure_type(ctx,get_temp(ctx,args[1]),ty);
        b=ensure_type(ctx,get_temp(ctx,args[2]),ty);
        uint64_t pos=(uint64_t)args[3],len=(uint64_t)args[4],mask=((1ULL<<len)-1)<<pos;
        LLVMValueRef sh=LLVMBuildShl(ctx->builder,b,LLVMConstInt(ty,pos,0),"");
        LLVMValueRef m=LLVMBuildAnd(ctx->builder,sh,LLVMConstInt(ty,mask,0),"");
        LLVMValueRef cl=LLVMBuildAnd(ctx->builder,a,LLVMConstInt(ty,~mask,0),"");
        set_temp(ctx,args[0],LLVMBuildOr(ctx->builder,cl,m,"deposit"));
        ctx->total_ops_translated++; return 0; }
    case INDEX_op_extract: { ty = get_op_type(ctx, op->param1);
        a=ensure_type(ctx,get_temp(ctx,args[1]),ty);
        uint64_t pos=(uint64_t)args[2],len=(uint64_t)args[3],mask=(1ULL<<len)-1;
        LLVMValueRef sh=LLVMBuildLShr(ctx->builder,a,LLVMConstInt(ty,pos,0),"");
        set_temp(ctx,args[0],LLVMBuildAnd(ctx->builder,sh,LLVMConstInt(ty,mask,0),"extract"));
        ctx->total_ops_translated++; return 0; }
    case INDEX_op_sextract: { ty = get_op_type(ctx, op->param1);
        a=ensure_type(ctx,get_temp(ctx,args[1]),ty);
        bits = get_op_bits(op->param1);
        uint64_t pos2=(uint64_t)args[2],len2=(uint64_t)args[3];
        uint64_t su=bits-pos2-len2, sd=bits-len2;
        LLVMValueRef sh=LLVMBuildShl(ctx->builder,a,LLVMConstInt(ty,su,0),"");
        set_temp(ctx,args[0],LLVMBuildAShr(ctx->builder,sh,LLVMConstInt(ty,sd,0),"sextract"));
        ctx->total_ops_translated++; return 0; }
    /* Wide multiply (unified) */
    case INDEX_op_mulu2: { ty = get_op_type(ctx, op->param1);
        if (op->param1 == TCG_TYPE_I32) {
            a=ensure_type(ctx,get_temp(ctx,args[2]),ctx->i32_type);
            b=ensure_type(ctx,get_temp(ctx,args[3]),ctx->i32_type);
            LLVMValueRef a64=LLVMBuildZExt(ctx->builder,a,ctx->i64_type,"");
            LLVMValueRef b64=LLVMBuildZExt(ctx->builder,b,ctx->i64_type,"");
            LLVMValueRef prod=LLVMBuildMul(ctx->builder,a64,b64,"mulu2");
            set_temp(ctx,args[0],LLVMBuildTrunc(ctx->builder,prod,ctx->i32_type,"lo"));
            set_temp(ctx,args[1],LLVMBuildTrunc(ctx->builder,
                LLVMBuildLShr(ctx->builder,prod,LLVMConstInt(ctx->i64_type,32,0),""),ctx->i32_type,"hi"));
        } else { ctx->has_unsupported_op=true; ctx->total_ops_skipped++; return -1; }
        ctx->total_ops_translated++; return 0; }
    case INDEX_op_muls2: { ty = get_op_type(ctx, op->param1);
        if (op->param1 == TCG_TYPE_I32) {
            a=ensure_type(ctx,get_temp(ctx,args[2]),ctx->i32_type);
            b=ensure_type(ctx,get_temp(ctx,args[3]),ctx->i32_type);
            LLVMValueRef a64=LLVMBuildSExt(ctx->builder,a,ctx->i64_type,"");
            LLVMValueRef b64=LLVMBuildSExt(ctx->builder,b,ctx->i64_type,"");
            LLVMValueRef prod=LLVMBuildMul(ctx->builder,a64,b64,"muls2");
            set_temp(ctx,args[0],LLVMBuildTrunc(ctx->builder,prod,ctx->i32_type,"lo"));
            set_temp(ctx,args[1],LLVMBuildTrunc(ctx->builder,
                LLVMBuildAShr(ctx->builder,prod,LLVMConstInt(ctx->i64_type,32,0),""),ctx->i32_type,"hi"));
        } else { ctx->has_unsupported_op=true; ctx->total_ops_skipped++; return -1; }
        ctx->total_ops_translated++; return 0; }
    /* Byte swap */
    case INDEX_op_bswap16: case INDEX_op_bswap32: case INDEX_op_bswap64:
    /* Count leading/trailing zeros */
    case INDEX_op_clz: case INDEX_op_ctz: case INDEX_op_ctpop:
    /* Guest memory + calls -> fallback TCG */
    case INDEX_op_qemu_ld: case INDEX_op_qemu_st:
    case INDEX_op_qemu_ld2: case INDEX_op_qemu_st2:
    case INDEX_op_call:
        ctx->has_unsupported_op = true; ctx->unsupported_opcode = opc;
        ctx->total_ops_skipped++; return -1;
    default: ctx->has_unsupported_op=true; ctx->unsupported_opcode=opc;
        ctx->total_ops_skipped++; return -1;
    }
}

int tcg_to_llvm_translate(TCGToLLVMCtx *ctx, struct TCGContext *tcg_ctx) {
    TCGOp *op;
    QTAILQ_FOREACH(op, &tcg_ctx->ops, link) {
        if (op->opc == INDEX_op_set_label) { int lid=(int)op->args[0];
            if(lid>=ctx->num_labels){int ns=lid+16;
            ctx->labels=realloc(ctx->labels,ns*sizeof(LLVMBasicBlockRef));
            for(int i=ctx->num_labels;i<ns;i++)ctx->labels[i]=NULL;ctx->num_labels=ns;} } }
    QTAILQ_FOREACH(op, &tcg_ctx->ops, link) {
        if (tcg_to_llvm_translate_op(ctx, op) != 0 && ctx->has_unsupported_op) {
            fprintf(stderr, "[tcg-to-llvm] TB 0x%lx: unsupported op %d, fallback TCG (%d translated, %d skipped)\n",
                (unsigned long)ctx->tb_pc, ctx->unsupported_opcode,
                ctx->total_ops_translated, ctx->total_ops_skipped);
            return -1; } }
    if (!LLVMGetBasicBlockTerminator(ctx->current_bb))
        LLVMBuildRet(ctx->builder, LLVMConstInt(ctx->i64_type, 0, 0));
    return 0;
}
LLVMModuleRef tcg_to_llvm_finalize(TCGToLLVMCtx *ctx) {
    LLVMModuleRef module = ctx->module; ctx->module = NULL;
    if (ctx->builder) { LLVMDisposeBuilder(ctx->builder); ctx->builder = NULL; }
    if (ctx->labels) { free(ctx->labels); ctx->labels = NULL; }
    return module;
}
void tcg_to_llvm_cleanup(TCGToLLVMCtx *ctx) {
    if (ctx->builder) { LLVMDisposeBuilder(ctx->builder); ctx->builder = NULL; }
    if (ctx->module) { LLVMDisposeModule(ctx->module); ctx->module = NULL; }
    if (ctx->labels) { free(ctx->labels); ctx->labels = NULL; }
}
TCG_LLVM_C_EOF

    # ── llvm-accel.h ───────────────────────────────────────────
    cat > "$LLVM_DIR/llvm-accel.h" << 'LLVM_ACCEL_H_EOF'
/*
 * QEMU Hybrid LLVM+TCG — Accelerator Interface
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#ifndef QEMU_LLVM_ACCEL_H
#define QEMU_LLVM_ACCEL_H
#include "llvm-jit.h"
#include "tb-profiler.h"
#include "tcg-to-llvm.h"
#include <stdbool.h>
#include <pthread.h>
typedef struct LLVMHybridConfig {
    uint32_t hot_threshold; bool async_compile; bool verbose;
    int opt_level; bool enabled; int num_threads;
} LLVMHybridConfig;
#define COMPILE_QUEUE_SIZE 1024
#define LLVM_MAX_WORKERS 16
typedef struct LLVMHybridState {
    LLVMJITState jit; TBProfiler profiler; LLVMHybridConfig config;
    pthread_t compile_threads[LLVM_MAX_WORKERS];
    LLVMJITWorker workers[LLVM_MAX_WORKERS];
    int num_workers;
    pthread_mutex_t compile_mutex;
    pthread_cond_t compile_cond; volatile bool compile_thread_running;
    struct { uint64_t pc; void *tcg_ctx_snapshot; size_t snapshot_size; } compile_queue[COMPILE_QUEUE_SIZE];
    volatile int queue_head; volatile int queue_tail;
    volatile uint64_t queue_total_enqueued;
    volatile uint64_t queue_total_dropped;
    bool initialized;
} LLVMHybridState;
extern LLVMHybridState llvm_hybrid_state;
int llvm_hybrid_init(const LLVMHybridConfig *config);
void llvm_hybrid_on_tb_exec(uint64_t tb_pc, void *tcg_ctx);
void *llvm_hybrid_get_code(uint64_t tb_pc);
int llvm_hybrid_compile_now(uint64_t tb_pc, void *tcg_ctx);
void llvm_hybrid_dump_stats(void);
void llvm_hybrid_destroy(void);
void llvm_hybrid_parse_env(LLVMHybridConfig *config);
#endif
LLVM_ACCEL_H_EOF

    # ── llvm-accel.c ───────────────────────────────────────────
    cat > "$LLVM_DIR/llvm-accel.c" << 'LLVM_ACCEL_C_EOF'
/*
 * QEMU Hybrid LLVM+TCG — Accelerator Implementation
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#include "qemu/osdep.h"
#include "llvm-accel.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
LLVMHybridState llvm_hybrid_state;
#define CODE_CACHE_SIZE (1 << 16)
#define CODE_CACHE_MASK (CODE_CACHE_SIZE - 1)
typedef struct CodeCacheEntry { uint64_t pc; void *code_ptr; struct CodeCacheEntry *next; } CodeCacheEntry;
static CodeCacheEntry *code_cache[CODE_CACHE_SIZE];
static pthread_rwlock_t code_cache_lock = PTHREAD_RWLOCK_INITIALIZER;
static void code_cache_insert(uint64_t pc, void *code) {
    uint32_t idx=(uint32_t)((pc^(pc>>16))&CODE_CACHE_MASK);
    CodeCacheEntry *e=malloc(sizeof(*e)); if(!e)return;
    e->pc=pc; e->code_ptr=code;
    pthread_rwlock_wrlock(&code_cache_lock); e->next=code_cache[idx]; code_cache[idx]=e;
    pthread_rwlock_unlock(&code_cache_lock);
}
static void *code_cache_lookup(uint64_t pc) {
    uint32_t idx=(uint32_t)((pc^(pc>>16))&CODE_CACHE_MASK);
    pthread_rwlock_rdlock(&code_cache_lock); CodeCacheEntry *e=code_cache[idx];
    while(e){if(e->pc==pc){void*c=e->code_ptr;pthread_rwlock_unlock(&code_cache_lock);return c;}e=e->next;}
    pthread_rwlock_unlock(&code_cache_lock); return NULL;
}
static int detect_num_cpus(void) {
    /* Prefer cgroup quota (container-safe) over sysconf which reports
     * the host's physical CPU count on shared/container environments. */
    int quota_cpus = 0;

    /* cgroup v2: /sys/fs/cgroup/cpu.max → "QUOTA PERIOD" or "max PERIOD" */
    FILE *f2 = fopen("/sys/fs/cgroup/cpu.max", "r");
    if (f2) {
        long long quota = 0, period = 0;
        char quota_str[32] = {0};
        if (fscanf(f2, "%31s %lld", quota_str, &period) == 2 && period > 0) {
            if (strcmp(quota_str, "max") != 0) {
                quota = atoll(quota_str);
                if (quota > 0)
                    quota_cpus = (int)((quota + period - 1) / period);
            }
        }
        fclose(f2);
    }

    /* cgroup v1: /sys/fs/cgroup/cpu/cpu.cfs_quota_us */
    if (quota_cpus <= 0) {
        FILE *fq = fopen("/sys/fs/cgroup/cpu/cpu.cfs_quota_us", "r");
        FILE *fp = fopen("/sys/fs/cgroup/cpu/cpu.cfs_period_us", "r");
        if (fq && fp) {
            long long q = 0, p = 0;
            if (fscanf(fq, "%lld", &q) == 1 && fscanf(fp, "%lld", &p) == 1
                    && q > 0 && p > 0)
                quota_cpus = (int)((q + p - 1) / p);
        }
        if (fq) fclose(fq);
        if (fp) fclose(fp);
    }

    /* Fallback to sysconf only when no cgroup quota is set */
    long n = (quota_cpus > 0) ? (long)quota_cpus : sysconf(_SC_NPROCESSORS_ONLN);
    if (n < 1) n = 1;
    /* Reserve at least 1 logical CPU for the VM execution path */
    if (n > 1) n = n - 1;
    if (n > LLVM_MAX_WORKERS) n = LLVM_MAX_WORKERS;
    return (int)n;
}
typedef struct WorkerArg {
    LLVMHybridState *state;
    int worker_id;
} WorkerArg;
static void *compile_thread_func(void *arg) {
    WorkerArg *wa = (WorkerArg *)arg;
    LLVMHybridState *s = wa->state;
    int wid = wa->worker_id;
    LLVMJITWorker *wk = &s->workers[wid];
    free(wa);
    char tname[32]; snprintf(tname, sizeof(tname), "llvm-jit-%d", wid);
#ifdef __linux__
    pthread_setname_np(pthread_self(), tname);
#endif
    if (s->config.verbose)
        fprintf(stderr, "[llvm-hybrid] Worker %d started (tid=%ld)\n", wid, (long)pthread_self());
    while (__atomic_load_n(&s->compile_thread_running, __ATOMIC_ACQUIRE)) {
        pthread_mutex_lock(&s->compile_mutex);
        while (s->queue_head == s->queue_tail && s->compile_thread_running)
            pthread_cond_wait(&s->compile_cond, &s->compile_mutex);
        if (!s->compile_thread_running) { pthread_mutex_unlock(&s->compile_mutex); break; }
        int idx = s->queue_tail;
        uint64_t pc = s->compile_queue[idx].pc;
        void *snap = s->compile_queue[idx].tcg_ctx_snapshot;
        s->queue_tail = (s->queue_tail + 1) % COMPILE_QUEUE_SIZE;
        pthread_mutex_unlock(&s->compile_mutex);
        if (snap) {
            LLVMHybridState *ss = &llvm_hybrid_state;
            struct TCGContext *tc = (struct TCGContext *)snap;
            TCGToLLVMCtx tr;
            if (tcg_to_llvm_init(&tr, wk->state.ctx, pc) == 0 &&
                tcg_to_llvm_translate(&tr, tc) == 0) {
                LLVMModuleRef mod = tcg_to_llvm_finalize(&tr);
                if (mod) {
                    LLVMCompiledTB comp;
                    if (llvm_jit_compile(&wk->state, mod, pc, &comp) == 0) {
                        code_cache_insert(pc, comp.code_ptr);
                        tb_profiler_set_state(&ss->profiler, pc, TB_LLVM_COMPILED);
                    } else {
                        tb_profiler_set_state(&ss->profiler, pc, TB_LLVM_FAILED);
                    }
                } else {
                    tcg_to_llvm_cleanup(&tr);
                    tb_profiler_set_state(&ss->profiler, pc, TB_LLVM_FAILED);
                }
            } else {
                tcg_to_llvm_cleanup(&tr);
                tb_profiler_set_state(&ss->profiler, pc, TB_LLVM_FAILED);
            }
            free(snap);
        }
    }
    if (s->config.verbose)
        fprintf(stderr, "[llvm-hybrid] Worker %d exiting\n", wid);
    return NULL;
}
void llvm_hybrid_parse_env(LLVMHybridConfig *config) {
    const char *v; config->hot_threshold=LLVM_HOT_THRESHOLD;
    config->async_compile=true; config->verbose=false; config->opt_level=2;
    config->enabled=true; config->num_threads=0;
    v=getenv("QEMU_LLVM_THRESHOLD"); if(v) config->hot_threshold=(uint32_t)atoi(v);
    v=getenv("QEMU_LLVM_ASYNC"); if(v) config->async_compile=atoi(v)!=0;
    v=getenv("QEMU_LLVM_VERBOSE"); if(v) config->verbose=atoi(v)!=0;
    v=getenv("QEMU_LLVM_OPT"); if(v) config->opt_level=atoi(v);
    v=getenv("QEMU_LLVM_THREADS"); if(v) config->num_threads=atoi(v);
}
int llvm_hybrid_init(const LLVMHybridConfig *config) {
    LLVMHybridState *s=&llvm_hybrid_state; memset(s,0,sizeof(*s));
    if(config) s->config=*config; else llvm_hybrid_parse_env(&s->config);
    if(!s->config.enabled){fprintf(stderr,"[llvm-hybrid] disabled\n");return 0;}
    int nthreads = s->config.num_threads > 0 ? s->config.num_threads : detect_num_cpus();
    if (nthreads < 1) nthreads = 1;
    if (nthreads > LLVM_MAX_WORKERS) nthreads = LLVM_MAX_WORKERS;
    fprintf(stderr,"[llvm-hybrid] Init hybrid LLVM+TCG | threshold=%u async=%s O%d threads=%d\n",
        s->config.hot_threshold, s->config.async_compile?"yes":"no",
        s->config.opt_level, nthreads);
    if(llvm_jit_init(&s->jit)!=0){fprintf(stderr,"[llvm-hybrid] JIT init failed\n");return -1;}
    tb_profiler_init(&s->profiler,s->config.hot_threshold);
    memset(code_cache,0,sizeof(code_cache));
    s->num_workers = 0;
    if(s->config.async_compile){
        pthread_mutex_init(&s->compile_mutex,NULL); pthread_cond_init(&s->compile_cond,NULL);
        s->compile_thread_running=true;
        for (int i = 0; i < nthreads; i++) {
            if (llvm_jit_worker_init(&s->workers[i], i) != 0) {
                fprintf(stderr, "[llvm-hybrid] Worker %d JIT init failed, skipping\n", i);
                continue;
            }
            WorkerArg *wa = malloc(sizeof(WorkerArg));
            if (!wa) { llvm_jit_worker_destroy(&s->workers[i]); continue; }
            wa->state = s; wa->worker_id = i;
            if (pthread_create(&s->compile_threads[i], NULL, compile_thread_func, wa) != 0) {
                fprintf(stderr, "[llvm-hybrid] Failed to create worker thread %d\n", i);
                free(wa); llvm_jit_worker_destroy(&s->workers[i]); continue;
            }
            s->num_workers++;
        }
        if (s->num_workers == 0) {
            fprintf(stderr, "[llvm-hybrid] No workers created, falling back to sync\n");
            s->config.async_compile = false;
        } else {
            fprintf(stderr, "[llvm-hybrid] Thread pool: %d workers started\n", s->num_workers);
        }
    }
    s->initialized=true; fprintf(stderr,"[llvm-hybrid] Ready\n"); return 0;
}
void llvm_hybrid_on_tb_exec(uint64_t tb_pc, void *tcg_ctx) {
    LLVMHybridState *s=&llvm_hybrid_state;
    if(!s->initialized||!s->config.enabled) return;
    TBProfileEntry *e=tb_profiler_record(&s->profiler,tb_pc); if(!e) return;
    uint32_t cnt = __atomic_load_n(&e->exec_count, __ATOMIC_RELAXED);
    uint8_t st = __atomic_load_n(&e->llvm_state, __ATOMIC_RELAXED);
    if(cnt==s->config.hot_threshold && st==TB_LLVM_PENDING){
        __atomic_store_n(&e->llvm_state, TB_LLVM_QUEUED, __ATOMIC_RELEASE);
        if(s->config.async_compile){
            pthread_mutex_lock(&s->compile_mutex);
            int nh=(s->queue_head+1)%COMPILE_QUEUE_SIZE;
            if(nh!=s->queue_tail){
                s->compile_queue[s->queue_head].pc=tb_pc;
                s->compile_queue[s->queue_head].tcg_ctx_snapshot=tcg_ctx;
                s->queue_head=nh;
                __atomic_add_fetch(&s->queue_total_enqueued, 1, __ATOMIC_RELAXED);
                pthread_cond_signal(&s->compile_cond);
            } else {
                __atomic_add_fetch(&s->queue_total_dropped, 1, __ATOMIC_RELAXED);
            }
            pthread_mutex_unlock(&s->compile_mutex);
        } else llvm_hybrid_compile_now(tb_pc,tcg_ctx);
    }
}
void *llvm_hybrid_get_code(uint64_t tb_pc) {
    if(!llvm_hybrid_state.initialized) return NULL; return code_cache_lookup(tb_pc);
}
int llvm_hybrid_compile_now(uint64_t tb_pc, void *tcg_ctx_ptr) {
    LLVMHybridState *s=&llvm_hybrid_state;
    struct TCGContext *tc=(struct TCGContext*)tcg_ctx_ptr;
    TCGToLLVMCtx tr; if(tcg_to_llvm_init(&tr,s->jit.ctx,tb_pc)!=0)
        {tb_profiler_set_state(&s->profiler,tb_pc,TB_LLVM_FAILED);return -1;}
    if(tcg_to_llvm_translate(&tr,tc)!=0){tcg_to_llvm_cleanup(&tr);
        tb_profiler_set_state(&s->profiler,tb_pc,TB_LLVM_FAILED);return -1;}
    LLVMModuleRef mod=tcg_to_llvm_finalize(&tr);
    if(!mod){tcg_to_llvm_cleanup(&tr);tb_profiler_set_state(&s->profiler,tb_pc,TB_LLVM_FAILED);return -1;}
    LLVMCompiledTB comp;
    if(llvm_jit_compile(&s->jit,mod,tb_pc,&comp)!=0)
        {tb_profiler_set_state(&s->profiler,tb_pc,TB_LLVM_FAILED);return -1;}
    code_cache_insert(tb_pc,comp.code_ptr);
    tb_profiler_set_state(&s->profiler,tb_pc,TB_LLVM_COMPILED); return 0;
}
void llvm_hybrid_dump_stats(void) {
    LLVMHybridState *s=&llvm_hybrid_state; if(!s->initialized) return;
    fprintf(stderr,"\n[llvm-hybrid] === Statistics ===\n");
    fprintf(stderr,"[llvm-hybrid] Thread pool: %d workers\n", s->num_workers);
    fprintf(stderr,"[llvm-hybrid] Queue: enqueued=%lu dropped=%lu\n",
        (unsigned long)s->queue_total_enqueued, (unsigned long)s->queue_total_dropped);
    tb_profiler_dump_stats(&s->profiler);
    for (int i = 0; i < s->num_workers; i++) {
        fprintf(stderr,"[llvm-hybrid] Worker %d: compiled=%lu failed=%lu\n", i,
            (unsigned long)s->workers[i].state.total_compiled,
            (unsigned long)s->workers[i].state.total_failed);
    }
    llvm_jit_dump_stats(&s->jit);
}
void llvm_hybrid_destroy(void) {
    LLVMHybridState *s=&llvm_hybrid_state; if(!s->initialized) return;
    if(s->config.async_compile && s->compile_thread_running){
        pthread_mutex_lock(&s->compile_mutex);
        __atomic_store_n(&s->compile_thread_running, false, __ATOMIC_RELEASE);
        pthread_cond_broadcast(&s->compile_cond);
        pthread_mutex_unlock(&s->compile_mutex);
        for (int i = 0; i < s->num_workers; i++)
            pthread_join(s->compile_threads[i], NULL);
        for (int i = 0; i < s->num_workers; i++)
            llvm_jit_worker_destroy(&s->workers[i]);
        pthread_mutex_destroy(&s->compile_mutex); pthread_cond_destroy(&s->compile_cond);
    }
    llvm_hybrid_dump_stats(); tb_profiler_destroy(&s->profiler); llvm_jit_destroy(&s->jit);
    for(int i=0;i<CODE_CACHE_SIZE;i++){CodeCacheEntry*e=code_cache[i];
    while(e){CodeCacheEntry*n=e->next;free(e);e=n;}code_cache[i]=NULL;}
    s->initialized=false;
}
LLVM_ACCEL_C_EOF

    # ── llvm-init.c (startup hooks with constructor/destructor) ──
    cat > "$LLVM_DIR/llvm-init.c" << 'LLVM_INIT_C_EOF'
#include "qemu/osdep.h"
#include "llvm-accel.h"
#include <stdio.h>
#include <stdlib.h>
/* Called automatically when QEMU binary loads (before main) */
__attribute__((constructor(101)))
static void _llvm_hybrid_auto_init(void) {
    const char *en = getenv("QEMU_LLVM_HYBRID");
    if (!en || atoi(en) == 0) return;
    LLVMHybridConfig config;
    llvm_hybrid_parse_env(&config);
    if (llvm_hybrid_init(&config) == 0) {
        fprintf(stderr, "[llvm-hybrid] Initialized: threshold=%u async=%d opt=O%d threads=%d\n",
                config.hot_threshold, config.async_compile, config.opt_level,
                llvm_hybrid_state.num_workers);
    } else {
        fprintf(stderr, "[llvm-hybrid] WARNING: init failed, continuing with pure TCG\n");
    }
}
/* Called automatically when QEMU binary exits */
__attribute__((destructor(101)))
static void _llvm_hybrid_auto_cleanup(void) {
    llvm_hybrid_destroy();
}
/* Keep explicit API for callers who want manual control */
void qemu_llvm_hybrid_init(void) { _llvm_hybrid_auto_init(); }
void qemu_llvm_hybrid_cleanup(void) { _llvm_hybrid_auto_cleanup(); }
LLVM_INIT_C_EOF

    # ── meson.build ────────────────────────────────────────────
    # Detect llvm-config path for meson
    local _llvm_cfg_path=""
    for _c in "llvm-config-${LLVM_VER}" "llvm-config"; do
        _llvm_cfg_path="$(command -v "$_c" 2>/dev/null || true)"
        [[ -n "$_llvm_cfg_path" ]] && break
    done
    local _llvm_prefix=""
    [[ -n "$_llvm_cfg_path" ]] && _llvm_prefix="$("$_llvm_cfg_path" --prefix 2>/dev/null || true)"

    cat > "$LLVM_DIR/meson.build" << 'MESON_BUILD_EOF'
if get_option('llvm_hybrid')
  add_languages('cpp', required: false, native: false)
  llvm_dep = dependency('llvm', version: '>=14',
                        method: 'config-tool',
                        required: false)
  if not llvm_dep.found()
    llvm_dep = dependency('llvm', version: '>=14',
                          method: 'cmake',
                          required: false)
  endif
  if not llvm_dep.found()
    llvm_dep = dependency('llvm', version: '>=14', required: false)
  endif
  if llvm_dep.found()
    llvm_files = files(
      'llvm-jit.c',
      'tb-profiler.c',
      'tcg-to-llvm.c',
      'llvm-accel.c',
      'llvm-init.c',
    )
    thread_dep = dependency('threads')
    system_ss.add(llvm_dep)
    system_ss.add(thread_dep)
    system_ss.add(llvm_files)
    llvm_hybrid_define = declare_dependency(
      compile_args: ['-DCONFIG_LLVM_HYBRID=1']
    )
    system_ss.add(llvm_hybrid_define)
    message('LLVM Hybrid backend: ENABLED (LLVM ' + llvm_dep.version() + ')')
  else
    message('LLVM Hybrid backend: LLVM not found, disabled')
  endif
else
  message('LLVM Hybrid backend: disabled by option')
endif
MESON_BUILD_EOF

    # ── Patch tcg/meson.build ──────────────────────────────────
    local TCG_MESON="$QEMU_DIR/tcg/meson.build"
    if ! grep -q "llvm" "$TCG_MESON" 2>/dev/null; then
        echo "" >> "$TCG_MESON"
        echo "subdir('llvm')" >> "$TCG_MESON"
    fi

    # ── Add meson option ───────────────────────────────────────
    for _mf in "$QEMU_DIR/meson_options.txt" "$QEMU_DIR/meson.options"; do
        if [[ -f "$_mf" ]] && ! grep -q "llvm_hybrid" "$_mf" 2>/dev/null; then
            echo "" >> "$_mf"
            echo "option('llvm_hybrid', type: 'boolean', value: false," >> "$_mf"
            echo "       description: 'Enable LLVM hybrid JIT backend')" >> "$_mf"
            break
        fi
    done

    # ── Patch cpu-exec.c: add LLVM hybrid profiling hook ──────
    local CPU_EXEC="$QEMU_DIR/accel/tcg/cpu-exec.c"
    if [[ -f "$CPU_EXEC" ]] && ! grep -q "llvm_hybrid_on_tb_exec" "$CPU_EXEC" 2>/dev/null; then
        # Add include after the last #include block
        sed -i '/#include "qemu\/osdep.h"/a\
#ifdef CONFIG_LLVM_HYBRID\
#include "tcg\/llvm\/llvm-accel.h"\
#endif' "$CPU_EXEC" 2>/dev/null || true

        # Hook into cpu_loop_exec_tb — add profiling AFTER cpu_tb_exec returns
        sed -i '/trace_exec_tb(tb, pc);/{n;s|tb = cpu_tb_exec(cpu, tb, tb_exit);|tb = cpu_tb_exec(cpu, tb, tb_exit);\n#ifdef CONFIG_LLVM_HYBRID\n    if (llvm_hybrid_state.initialized) {\n        llvm_hybrid_on_tb_exec(pc, tcg_ctx);\n    }\n#endif|}' "$CPU_EXEC" 2>/dev/null || true
        echo -e "${G}✔${W} Patched cpu-exec.c with LLVM hybrid profiling hook"
    fi

    # ── No need to patch main.c — llvm-init.c uses __attribute__((constructor)) ──
    echo -e "${B}ℹ${W}  LLVM init via __attribute__((constructor)) — no main.c patch needed"

    echo -e "${G}✔${W} LLVM Hybrid: ${B}$(ls "$LLVM_DIR"/*.c "$LLVM_DIR"/*.h 2>/dev/null | wc -l)${W} files extracted + QEMU patched"
    return 0
}

# ════════════════════════════════════════════════════════════════
#  PACKAGE MANAGER — root → sudo apt → rootless build từ source
# ════════════════════════════════════════════════════════════════

APT_CMD=""
APT_OK=0
ROOTLESS=0

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
    echo -e "${B}ℹ${W}  Build zlib 1.3.1 từ source..."
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
print("zlib configure patched OK")
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
        echo -e "${B}ℹ${W}  zlib: shared build"
    else
        echo -e "${Y}⚠${W}  zlib shared không hỗ trợ — dùng static"
        env CC="$_cc" CXX="$_cxx" AR="$_ar" RANLIB="$_ranlib" \
            CFLAGS="-w -O2" CXXFLAGS="-w -O2" LDFLAGS="" \
            ./configure --prefix="$prefix" > /tmp/zlib-build.log 2>&1 \
            || { echo -e "${R}✘${W} Configure zlib thất bại — xem /tmp/zlib-build.log"; exit 1; }
    fi
    ${MAKE:-make} -j"$(nproc)" AR="$_ar" RANLIB="$_ranlib" >> /tmp/zlib-build.log 2>&1 \
        || { echo -e "${R}✘${W} Build zlib thất bại — xem /tmp/zlib-build.log"; exit 1; }
    ${MAKE:-make} install AR="$_ar" RANLIB="$_ranlib" >> /tmp/zlib-build.log 2>&1 \
        || { echo -e "${R}✘${W} Install zlib thất bại — xem /tmp/zlib-build.log"; exit 1; }
    echo -e "${G}✔${W} zlib 1.3.1 xong"
}

_build_libffi_from_source() {
    local prefix="$1"; local build_dir="$2"
    echo -e "${B}ℹ${W}  Build libffi 3.4.6 từ source..."
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
    echo -e "${G}✔${W} libffi 3.4.6 xong"
}

_build_pixman_from_source() {
    local prefix="$1"; local build_dir="$2"
    echo -e "${B}ℹ${W}  Build pixman 0.42.2 từ source..."
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
    echo -e "${G}✔${W} pixman 0.42.2 xong"
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
            export PKG_CONFIG_PATH="$_conda_pc:${PKG_CONFIG_PATH:-}"
            # Nếu conda glib ở path khác prefix, tạo symlink pc vào prefix để QEMU configure thấy
            local _dest_pc="$prefix/lib/pkgconfig"
            mkdir -p "$_dest_pc"
            for _pc in "$_conda_pc"/glib-2.0.pc "$_conda_pc"/gobject-2.0.pc \
                       "$_conda_pc"/gmodule-2.0.pc "$_conda_pc"/gio-2.0.pc; do
                [[ -f "$_pc" ]] && cp -f "$_pc" "$_dest_pc/" 2>/dev/null || true
            done
            # Patch prefix trong .pc nếu cần
            for _f in "$_dest_pc"/glib-2.0.pc "$_dest_pc"/gobject-2.0.pc \
                      "$_dest_pc"/gmodule-2.0.pc "$_dest_pc"/gio-2.0.pc; do
                [[ -f "$_f" ]] && sed -i "s|^prefix=.*|prefix=/opt/conda|g" "$_f" 2>/dev/null || true
            done
            # Export LD path
            [[ -n "$_glib_so" ]] && export LD_LIBRARY_PATH="$_glib_so:${LD_LIBRARY_PATH:-}"
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

    # ── Ưu tiên 1: dùng glib từ conda (nhanh hơn rất nhiều) ─────
    if _try_glib_from_conda "$prefix"; then
        return 0
    fi

    # ── Helper: build pcre2 từ source nếu chưa có ───────────────
    _ensure_pcre2() {
        local _ppc="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"
        PKG_CONFIG_PATH="$_ppc" pkg-config --exists libpcre2-8 2>/dev/null && return 0
        echo -e "${B}ℹ${W}  Build pcre2 10.42 từ source (glib cần)..."
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
        echo -e "${G}✔${W} pcre2 10.42 xong"
    }

    # ── Ưu tiên 2: build glib 2.74.7 từ source ──────────────────
    local GLIB_VER="2.74.7"
    local GLIB_MAJ="2.74"
    echo -e "${B}ℹ${W}  Build glib ${GLIB_VER} từ source..."

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
    [[ "$_glib_ok" == "0" ]] && { echo -e "${R}✘${W} Không tải được glib ${GLIB_VER}"; exit 1; }
    echo -e "${B}ℹ${W}  Giải nén glib ${GLIB_VER} (Python lzma)..."
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
        { echo "#!/bin/sh"
          echo "exec python3 -c \"from mesonbuild.mesonmain import main; import sys; sys.exit(main())\" \"\$@\""
        } > /tmp/_meson_wrap.sh
        chmod +x /tmp/_meson_wrap.sh
        meson_cmd="/tmp/_meson_wrap.sh"
    else
        echo -e "${R}✘${W} meson không tìm thấy — không thể build glib"; exit 1
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

    echo -e "${B}ℹ${W}  meson setup glib ${GLIB_VER}... (timeout 3600s)"
    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"

    # Đảm bảo $prefix/bin trong PATH và libs tìm được
    export PATH="$prefix/bin:${PATH}"
    export LD_LIBRARY_PATH="${CONDA_ROOT:-/opt/conda}/lib:$prefix/lib:${LD_LIBRARY_PATH:-}"

    # Tìm pkg-config thực sự chạy được (built binary có thể fail do missing lib deps)
    local _pc_bin=""
    for _pc_try in \
        "$prefix/bin/pkg-config" \
        "${CONDA_ROOT:-/opt/conda}/bin/pkg-config" \
        "$(command -v pkg-config 2>/dev/null || true)" \
        "$(command -v pkgconf 2>/dev/null || true)"; do
        [[ -z "$_pc_try" || ! -x "$_pc_try" ]] && continue
        if "$_pc_try" --version &>/dev/null; then
            _pc_bin="$_pc_try"; break
        fi
    done
    if [[ -n "$_pc_bin" ]]; then
        export PKG_CONFIG="$_pc_bin"
        echo -e "${G}✔${W}  pkg-config: $_pc_bin ($(${_pc_bin} --version))"
    else
        echo -e "${Y}⚠${W}  Không tìm được pkg-config hoạt động — meson sẽ thử cmake fallback"
        export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig:${PKG_CONFIG_LIBDIR:-}"
    fi

    # Helper: chỉ add option nếu glib version này có khai báo trong meson_options.txt
    _has_opt() { grep -qE "option\s*\(\s*'$1'" ../meson_options.txt 2>/dev/null; }

    # Flags luôn hợp lệ cho mọi glib version
    local _meson_flags=(
        --prefix="$prefix"
        --buildtype=plain
        -Dauto_features=disabled
        -Dlibdir="lib"
        --wrap-mode=nodownload
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
    # pcre2: KHÔNG pass -Dpcre2=internal — pcre2 đã được build từ source ở trên (_ensure_pcre2)
    # glib tự detect qua PKG_CONFIG_PATH

    local _meson_exit=0
    timeout 3600 "$meson_cmd" setup . .. "${_meson_flags[@]}" \
        > /tmp/glib-meson.log 2>&1 || _meson_exit=$?
    if [[ $_meson_exit -eq 124 ]]; then
        echo -e "${R}✘${W} meson setup glib TIMEOUT (>3600s) — xem /tmp/glib-meson.log"
        tail -30 /tmp/glib-meson.log; exit 1
    elif [[ $_meson_exit -ne 0 ]]; then
        echo -e "${R}✘${W} meson glib thất bại (exit $_meson_exit) — xem /tmp/glib-meson.log"
        tail -30 /tmp/glib-meson.log; exit 1
    fi
    echo -e "${G}✔${W} meson setup glib xong"
    echo -e "${B}ℹ${W}  ninja build glib... (timeout 900s, log: /tmp/glib-build.log)"
    echo -e "${B}ℹ${W}  Theo dõi: tail -f /tmp/glib-build.log"
    local _ninja_exit=0
    timeout 900 "$ninja_cmd" -j"$(nproc)" > /tmp/glib-build.log 2>&1 || _ninja_exit=$?
    if [[ $_ninja_exit -eq 124 ]]; then
        echo -e "${R}✘${W} ninja glib TIMEOUT (>900s)"; tail -20 /tmp/glib-build.log; exit 1
    elif [[ $_ninja_exit -ne 0 ]]; then
        echo -e "${R}✘${W} ninja glib thất bại — xem /tmp/glib-build.log"
        tail -20 /tmp/glib-build.log; exit 1
    fi
    timeout 120 "$ninja_cmd" install >> /tmp/glib-build.log 2>&1 \
        || { echo -e "${R}✘${W} ninja glib install thất bại"; exit 1; }
    echo -e "${G}✔${W} glib ${GLIB_VER} xong"
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

    echo -e "${B}ℹ${W}  Toolchain: CC=${_cc}  AR=${AR:-ar}  RANLIB=${RANLIB:-ranlib}"
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

    rm -rf "$HOME/python-local" "$HOME/qemu-static" "$HOME/qemu-build" "$HOME/certs"
    export PREFIX="$HOME/qemu-static"
    export BUILD="$HOME/qemu-build"
    mkdir -p "$PREFIX" "$BUILD" "$HOME/certs"

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
            echo -e "${R}✘${W} Không có gcc và không có conda — không thể build"; exit 1
        fi
    fi
    export CC_PLAIN CXX_PLAIN
    export CC="$CC_PLAIN" CXX="${CXX_PLAIN:-$CC_PLAIN}"
    echo -e "${G}✔${W} compiler: $CC_PLAIN"

    # ── Detect cross-toolchain AR/RANLIB/NM/STRIP ──────────────────────
    _detect_cross_toolchain

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
    echo -e "${G}✔${W} make: $MAKE"

    echo -e "${B}ℹ${W}  Tải SSL certs..."
    cd "$HOME/certs"
    wget -q https://curl.se/ca/cacert.pem -O cacert.pem 2>/dev/null || true
    if [[ -f cacert.pem ]]; then
        export SSL_CERT_FILE="$HOME/certs/cacert.pem"
        export REQUESTS_CA_BUNDLE="$SSL_CERT_FILE"
        echo -e "${G}✔${W} SSL certs xong"
    else
        echo -e "${Y}⚠${W}  Không tải được SSL cert — bỏ qua (dùng cert hệ thống)"
    fi

    export PY_PREFIX="$HOME/python-local"
    mkdir -p "$PY_PREFIX"
    export PATH="$HOME/.local/bin:$PREFIX/bin:$PATH"

    echo -ne "${B}◜${W} Kiểm tra Python system..."
    PY_VER_SYSTEM=$(python3 --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$PY_VER_SYSTEM" ]]; then
        echo -e "\r${G}✔${W} Python system $PY_VER_SYSTEM          "
    else
        echo -e "\r${R}✘${W} Không tìm thấy Python 3"; exit 1
    fi

    if python3 -c "import ssl; print('SSL OK:', ssl.OPENSSL_VERSION)" 2>/dev/null; then
        echo -e "${G}✔${W} Python ssl module OK"
    else
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

    echo -e "${B}ℹ${W}  Cài pip packages (meson/ninja/tomli)... (log: /tmp/pip-meson.log)"
    pip_install --upgrade pip > /tmp/pip-meson.log 2>&1
    pip_install 'meson>=1.6.0' ninja tomli >> /tmp/pip-meson.log 2>&1

    # ── Tạo wrapper scripts cho meson/ninja (pip --target không tạo executables) ──
    mkdir -p "$PIP_TARGET/bin"
    local _pip_py3; _pip_py3="$(command -v python3)"
    # meson wrapper
    if [[ ! -x "$PIP_TARGET/bin/meson" ]]; then
        local _mw="$PIP_TARGET/bin/meson"
        local _mpt="$PIP_TARGET"
        printf '#!/bin/sh\nPYTHONPATH="%s${PYTHONPATH:+:$PYTHONPATH}"\nexport PYTHONPATH\nexec "%s" -c "from mesonbuild.mesonmain import main; import sys; sys.exit(main())" "$@"\n' \
            "$_mpt" "$_pip_py3" > "$_mw"
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
    _build_zlib_from_source "$PREFIX" "$BUILD"
    _build_libffi_from_source "$PREFIX" "$BUILD"
    _build_pixman_from_source "$PREFIX" "$BUILD"
    _build_glib_from_source "$PREFIX" "$BUILD" "$PY_PREFIX"

    PIXMAN_INC="$PREFIX/include"
    [[ -z "$PIXMAN_INC" ]] && \
        PIXMAN_INC=$(find "$PREFIX" -name "pixman.h" -type f 2>/dev/null | head -1 | xargs dirname)
    echo -e "${G}✔${W} pixman.h tại: ${PIXMAN_INC}"

    echo -e "${B}◜${W} Cài pip packages (packaging)... (log: /tmp/pip-rootless.log)"
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

    for d in "$PREFIX/lib/pkgconfig" "$PREFIX/lib64/pkgconfig"; do
        [[ -d "$d" ]] && export PKG_CONFIG_PATH="$d:${PKG_CONFIG_PATH:-}"
    done
    export PKG_CONFIG_PATH="${PKG_CONFIG_PATH%:}"
    echo -e "${B}ℹ${W}  PKG_CONFIG_PATH=$PKG_CONFIG_PATH"

    # ── Ensure pkg-config binary actually WORKS (not just exists) ──
    _pkgcfg_works() {
        local _pc
        for _pc in \
            "${PKG_CONFIG:-}" \
            "$PREFIX/bin/pkg-config" \
            "$(command -v pkg-config 2>/dev/null || true)" \
            "$(command -v pkgconf 2>/dev/null || true)"; do
            [[ -z "$_pc" || ! -x "$_pc" ]] && continue
            if "$_pc" --version &>/dev/null; then
                export PKG_CONFIG="$_pc"
                return 0
            fi
        done
        return 1
    }

    if ! _pkgcfg_works; then
        echo -e "${Y}⚠${W}  pkg-config không có hoặc không chạy được — build từ source..."
        # 1. Conda (thường có trong JupyterHub)
        if command -v conda &>/dev/null; then
            conda install -y -q -c conda-forge pkg-config > /tmp/pkgconfig-conda.log 2>&1 \
                && echo -e "${G}✔${W} pkg-config từ conda-forge" \
                || echo -e "${Y}⚠${W}  conda install pkg-config thất bại"
        fi
        # 2. Build pkg-config 0.29.2 --with-internal-glib (self-contained, zero deps)
        if ! _pkgcfg_works; then
            echo -e "${B}ℹ${W}  Build pkg-config 0.29.2 từ source (self-contained)..."
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
                && echo -e "${G}✔${W} pkg-config 0.29.2 (--with-internal-glib) → $PREFIX/bin" \
                || echo -e "${Y}⚠${W}  Build pkg-config thất bại — xem /tmp/pkgconfig-build.log"
        fi
    fi

    if _pkgcfg_works; then
        echo -e "${G}✔${W} pkg-config: $PKG_CONFIG ($("$PKG_CONFIG" --version))"
    else
        echo -e "${Y}⚠${W}  pkg-config vẫn không chạy được — QEMU configure có thể thất bại"
        export PKG_CONFIG=""
    fi

    SRC_INC="$PREFIX/include"; SRC_LIB="$PREFIX/lib"

    QEMU_EXTRA_CFLAGS="-I$PREFIX/include -I${PIXMAN_INC:-$SRC_INC/pixman-1} -I$SRC_INC"
    QEMU_EXTRA_LDFLAGS="-L$PREFIX/lib64 -L$PREFIX/lib -L$SRC_LIB -Wl,-rpath,$SRC_LIB"

    # ── KVM flag cho configure rootless ──────────────────────────
    if [[ "$KVM_AVAILABLE" == "1" ]]; then
        QEMU_KVM_FLAG="--enable-kvm"
        echo -e "${G}⚡ Rootless QEMU build: --enable-kvm${W}"
    else
        QEMU_KVM_FLAG="--disable-kvm"
        echo -e "${B}ℹ${W}  Rootless QEMU build: --disable-kvm (TCG mode)"
    fi

    echo -e "${B}ℹ${W}  Configure QEMU rootless..."
    cd "$BUILD/qemu-11.0.0"
    rm -rf build

    # Đảm bảo tomli/meson tìm thấy được trong pyvenv QEMU tạo ra
    export PYTHONPATH="$PIP_TARGET${PYTHONPATH:+:$PYTHONPATH}"

    # Ensure we use pip-installed meson (>= 0.65.3) not system meson (might be old)
    _MESON_BIN="$(python3 -c "import subprocess,sys; r=subprocess.run([sys.executable,'-m','meson','--version'],capture_output=True,text=True); print(sys.executable+' -m meson' if r.returncode==0 else 'meson')" 2>/dev/null || echo "meson")"
    [[ -x "$PIP_TARGET/bin/meson" ]] && _MESON_BIN="$PIP_TARGET/bin/meson"
    echo -e "${B}ℹ${W}  Using meson: $_MESON_BIN ($("$_MESON_BIN" --version 2>/dev/null || echo "?"))"
    export MESON="$_MESON_BIN"
    # Export env vars cho configure (phải export, không dùng inline prefix vì configure
    # rootless là một lệnh riêng nằm dưới, không phải inline prefix)
    export PKG_CONFIG="${PKG_CONFIG:-$(command -v pkg-config 2>/dev/null || echo "")}"
    # Lưu và tạm reset PIP_TARGET/PYTHONPATH để QEMU configure không bị confused
    _SAVED_PIP_TARGET="${PIP_TARGET:-}"
    _SAVED_PYTHONPATH="${PYTHONPATH:-}"
    export PIP_TARGET=""
    export PYTHONPATH=""

    # ── LLVM Hybrid: cài LLVM dev + extract embedded source + patch ──
    LLVM_CONFIGURE_FLAGS=""
    if [[ "$LLVM_ACCEL" == "1" ]]; then
        echo -e "${C}⬡  LLVM Hybrid Backend — auto setup (rootless)${W}"
        if _llvm_hybrid_install_dev 2>/dev/null; then
            if _llvm_hybrid_extract_and_patch "$BUILD/qemu-11.0.0"; then
                LLVM_CONFIGURE_FLAGS="-Dllvm_hybrid=true"
                LLVM_BUILD_OK=1
                echo -e "${G}⚡ LLVM Hybrid: enabled — sẽ build cùng QEMU${W}"
            else
                echo -e "${Y}⚠${W}  LLVM patch thất bại — fallback TCG"
            fi
        else
            echo -e "${Y}⚠${W}  LLVM dev install thất bại — fallback TCG"
        fi
    fi

    ./configure \
        --prefix="$PREFIX" \
        --python="$(command -v python3)" \
        --target-list=x86_64-softmmu \
        --enable-tcg \
        $QEMU_KVM_FLAG \
        --disable-werror \
        --disable-gtk \
        --disable-sdl \
        --enable-slirp \
        --enable-vnc \
        --disable-libusb \
        --disable-capstone \
        --extra-cflags="$QEMU_EXTRA_CFLAGS" \
        --extra-ldflags="$QEMU_EXTRA_LDFLAGS" \
        $LLVM_CONFIGURE_FLAGS \
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
    _BUILD_JOBS=$(( cpu_u > 0 ? cpu_u : $(nproc 2>/dev/null || echo 2) ))
    [[ "$_BUILD_JOBS" -lt 1 ]] && _BUILD_JOBS=1
    echo -e "${B}ℹ${W}  Build jobs: ${_BUILD_JOBS} (cgroup-aware)"
    ${MAKE:-make} -j"$_BUILD_JOBS" 2>&1 | grep --line-buffered -E "^\[|error:|warning:|FAILED"
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo -e "${R}✘ Compile QEMU thất bại — xem /tmp/qemu-build.log${W}"
        ${MAKE:-make} -j"$_BUILD_JOBS" > /tmp/qemu-build.log 2>&1
        exit 1
    fi
    ${MAKE:-make} install > /dev/null 2>&1
    strip "$PREFIX/bin/qemu-system-x86_64" 2>/dev/null || true
    echo -e "${G}✔ QEMU rootless build xong${W}"

    export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib64:$PREFIX/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
    export QEMU_BIN="$PREFIX/bin/qemu-system-x86_64"
    export PATH="$PREFIX/bin:$PATH"

    if command -v conda &>/dev/null; then
        spin_start "Cài aria2 từ conda..."
        conda install -y -q aria2 > /dev/null 2>&1 \
            && spin_stop "aria2 từ conda xong" \
            || { spin_fail "aria2 conda thất bại — dùng wget thay thế"
                 echo -e "${B}ℹ${W}  aria2 không có — sẽ dùng wget để tải Windows image"; }
    else
        echo -e "${B}ℹ${W}  Không có conda — cài aria2 qua wget binary..."
        spin_start "Tải aria2 static binary..."
        ARIA2_URL="https://github.com/abcfy2/aria2-static-build/releases/latest/download/aria2-x86_64-linux-musl_static.zip"
        if wget -q "$ARIA2_URL" -O /tmp/aria2-static.zip \
            && unzip -q /tmp/aria2-static.zip -d /tmp/aria2-static/ 2>/dev/null \
            && install -m755 /tmp/aria2-static/aria2c "$PREFIX/bin/aria2c" 2>/dev/null; then
            spin_stop "aria2 static binary xong"
        else
            spin_fail "aria2 binary thất bại — sẽ dùng wget để tải"
        fi
    fi

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
    echo -e "${B}ℹ${W}  📊 Tiến độ: tail -f /tmp/dl-parallel.log"
    if command -v aria2c &>/dev/null; then
        nohup aria2c -x16 -s16 -j16 --continue=true --file-allocation=none             --console-log-level=warn --summary-interval=30             --human-readable=true --download-result=full             "$WIN_URL" -d "$(dirname "${WIN_IMG_PATH:-win.img}")" -o "$(basename "${WIN_IMG_PATH:-win.img}")"             > /tmp/dl-parallel.log 2>&1 &
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
        echo -e "${B}ℹ${W}  📊 Log: /tmp/dl-parallel.log"
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
_detect_apt
_detect_kvm   # ← chạy KVM detection ngay sau apt detection

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
        if [[ "$(id -u)" == "0" ]] && [[ "$APT_OK" == "1" ]]; then
            # root + apt available: dùng apt build path
            spin_start "Build QEMU (apt)..."
            # Trigger the same build logic as main flow
            if [[ "$ROOTLESS" == "1" ]]; then
                _rootless_build 2>&1
            else
                # For root with apt, build from source
                _rootless_build 2>&1
            fi
            spin_stop "Build QEMU xong"
        else
            spin_start "Build QEMU (rootless)..."
            _rootless_build 2>&1
            spin_stop "Build QEMU xong"
        fi
    else
        spin_stop "QEMU: $QEMU_BIN"
    fi

    # ── Bước 2: Tải ISOs ─────────────────────────────────────────
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

    spin_start "Tải Windows ISO..."
    if [[ ! -f win.iso ]]; then
        wget -q --no-check-certificate -O win.iso "$ISO_WIN_URL" \
            || curl -fsSL -o win.iso "$ISO_WIN_URL" \
            || { spin_fail "Không tải được Windows ISO"; exit 1; }
        spin_stop "Windows ISO tải xong"
    else
        spin_stop "Windows ISO đã có (skip)"
    fi

    if [[ -n "$ISO_VIRTIO_URL" ]]; then
        spin_start "Tải VirtIO ISO..."
        if [[ ! -f virtio.iso ]]; then
            wget -q --no-check-certificate -O virtio.iso "$ISO_VIRTIO_URL" \
                || curl -fsSL -o virtio.iso "$ISO_VIRTIO_URL" \
                || { spin_fail "Không tải được VirtIO ISO"; exit 1; }
            spin_stop "VirtIO ISO tải xong"
        else
            spin_stop "VirtIO ISO đã có (skip)"
        fi
    fi

    # ── Bước 3: Tạo disk ─────────────────────────────────────────
    local _disk_gb="60"
    echo ""
    read -rp "$(echo -e "${B}💾${W} Dung lượng disk (GB) [mặc định 60]: ")" _disk_raw
    _disk_raw=$(printf '%s' "${_disk_raw}" | tr -cd '0-9')
    [[ -n "$_disk_raw" ]] && _disk_gb="$_disk_raw"

    spin_start "Tạo disk.qcow2 (${_disk_gb}G)..."
    qemu-img create -f qcow2 "$_iso_dir/disk.qcow2" "${_disk_gb}G" >/dev/null 2>&1
    spin_stop "Disk ${_disk_gb}G tạo xong"

    # ── Bước 4: Khởi động VM ─────────────────────────────────────
    local _has_virtio_iso=0
    [[ -f "$_iso_dir/virtio.iso" && -n "$ISO_VIRTIO_URL" ]] && _has_virtio_iso=1

    local _launch_cmd=(
        "$QEMU_BIN"
        -machine type=q35
        -cpu qemu64
        -smp 2,sockets=1,cores=2,threads=1
        -m 4G
        -accel tcg,thread=multi,tb-size=3097152
        -object iothread,id=io1
        -drive file="$_iso_dir/disk.qcow2",if=none,id=disk0,format=qcow2,cache=unsafe,aio=threads,discard=on
        -device virtio-blk-pci,drive=disk0,iothread=io1,num-queues=1,queue-size=128
        -cdrom "$_iso_dir/win.iso"
    )
    if [[ "$_has_virtio_iso" == "1" ]]; then
        _launch_cmd+=(
            -drive file="$_iso_dir/virtio.iso",media=cdrom,if=none,id=cdvirtio
            -device ide-cd,drive=cdvirtio
        )
    fi

    # KVM nếu có
    if [[ "$KVM_AVAILABLE" == "1" ]]; then
        _launch_cmd=("${_launch_cmd[@]//-cpu qemu64/-cpu host}")
        _launch_cmd=("${_launch_cmd[@]//-accel tcg*/-accel kvm}")
    fi

    _launch_cmd+=(
        -device virtio-gpu-pci
        -device qemu-xhci,id=xhci
        -device usb-tablet,bus=xhci.0
        -device usb-kbd,bus=xhci.0
        -netdev user,id=n0,hostfwd=tcp::3389-:3389
        -device virtio-net-pci,netdev=n0
        -display vnc=:0
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
    echo -e "🖥  VNC        : ${G}localhost:5900${W}"
    echo -e "              → vncviewer localhost:5900"
    echo -e "              → TigerVNC / RealVNC / any VNC client"
    echo -e "🌐 RDP port   : ${G}localhost:3389${W}  (sau khi cài Windows)"
    echo -e "💾 Disk       : ${B}${_iso_dir}/disk.qcow2${W}  (${_disk_gb}G)"
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
# Handle cases 2 and 3 immediately (case 1 falls through)
_MAIN_CHOICE_HANDLED=0

# Ask win image and start parallel download ONLY for case 1 (create VM)
if [[ "${main_choice:-1}" == "1" ]]; then
    _ask_win_image_early
    # Luôn dùng absolute path để tránh lỗi khi CWD thay đổi sau build
    WIN_IMG_PATH="${ORIGINAL_DIR:-$(pwd)}/win.img"
    export WIN_IMG_PATH
fi

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
        spin_start "Cập nhật apt cache..."
        $APT_CMD update -qq > /dev/null 2>&1
        spin_stop "apt cache đã cập nhật"

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
            PREFIX_LABEL="[${IDX}/${TOTAL}]"
            if [[ -n "$chk" ]] && command -v "$chk" &>/dev/null; then
                echo -e "${G}✔${W} ${PREFIX_LABEL} ${label} ${B}(đã có)${W}"; continue
            fi
            if dpkg -s "$pkg" &>/dev/null 2>&1; then
                echo -e "${G}✔${W} ${PREFIX_LABEL} ${label} ${B}(đã cài)${W}"; continue
            fi
            spin_start "Đang cài $label..."
            if apt_install "$pkg"; then spin_stop "$PREFIX_LABEL $label"
            else spin_fail "$PREFIX_LABEL $label thất bại — bỏ qua"; fi
        done
        echo -e "${G}✔ Tất cả dependencies đã sẵn sàng${W}"

        # ── LLVM: thử nhiều version (18 → 17 → 16 → 15 → 14), ưu tiên có sẵn ──
        export DEBIAN_FRONTEND=noninteractive
        LLVM_VER_ROOT=""
        # Bước 1: check version nào đã có sẵn
        for _v in 18 19 17 16 15 14; do
            if command -v "clang-${_v}" &>/dev/null && command -v "llvm-config-${_v}" &>/dev/null; then
                LLVM_VER_ROOT=$_v
                echo -e "${G}✔${W} LLVM ${_v} đã có sẵn (từ hệ thống)"
                break
            fi
        done
        # Bước 2: thử apt install theo thứ tự ưu tiên
        if [[ -z "$LLVM_VER_ROOT" ]]; then
            spin_start "Cài LLVM (thử 18→17→16→15→14)..."
            for _v in 18 19 17 16 15 14; do
                if silent $APT_CMD install -y "clang-${_v}" "lld-${_v}" "llvm-${_v}" "llvm-${_v}-dev"; then
                    LLVM_VER_ROOT=$_v
                    spin_stop "LLVM ${_v} đã cài (từ repo OS)"
                    break
                fi
            done
        fi
        # Bước 3: nếu tất cả fail → thêm apt.llvm.org và thử lại
        if [[ -z "$LLVM_VER_ROOT" ]]; then
            spin_fail "LLVM không có trong repo OS — thêm repo llvm.org..."
            DISTRO_CODENAME=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}" \
                || lsb_release -sc 2>/dev/null || echo "")
            if [[ -n "$DISTRO_CODENAME" ]] && _http_get https://apt.llvm.org/llvm.sh /tmp/llvm.sh; then
                chmod +x /tmp/llvm.sh
                echo -e "${B}ℹ${W}  Chạy llvm.sh 16..."
                bash /tmp/llvm.sh 16 > /tmp/llvm-repo.log 2>&1 || true
                # GPG + sources thủ công nếu llvm.sh thất bại
                if [[ -n "$DISTRO_CODENAME" ]]; then
                    _http_get https://apt.llvm.org/llvm-snapshot.gpg.key \
                        | (command -v sudo &>/dev/null \
                           && sudo tee /etc/apt/trusted.gpg.d/llvm.asc >/dev/null 2>&1 \
                           || tee /etc/apt/trusted.gpg.d/llvm.asc >/dev/null 2>&1) || true
                fi
                $APT_CMD update -qq > /dev/null 2>&1 || true
                for _v in 16 18 17 15 14; do
                    if silent $APT_CMD install -y "clang-${_v}" "lld-${_v}" "llvm-${_v}" "llvm-${_v}-dev"; then
                        LLVM_VER_ROOT=$_v
                        echo -e "${G}✔${W} LLVM ${_v} đã cài (từ apt.llvm.org)"
                        break
                    fi
                done
            fi
        fi
        # Kết quả
        if [[ -n "$LLVM_VER_ROOT" ]]; then
            export PATH="/usr/lib/llvm-${LLVM_VER_ROOT}/bin:$PATH"
            export CC="clang-${LLVM_VER_ROOT}"
            export CXX="clang++-${LLVM_VER_ROOT}"
            export LD="lld-${LLVM_VER_ROOT}"
            echo -e "${G}✔${W} LLVM ${LLVM_VER_ROOT} sẵn sàng — CC=${CC} CXX=${CXX}"
        else
            echo -e "${Y}⚠${W}  Không cài được LLVM — dùng gcc/ld mặc định (LLVM accel tắt)"
            export CC="gcc"; export CXX="g++"; unset LD 2>/dev/null || true
            LLVM_ACCEL=0; LLVM_BUILD_OK=0
        fi

        LLD_AVAILABLE=0
        [[ -n "$LLVM_VER_ROOT" ]] && command -v "lld-${LLVM_VER_ROOT}" &>/dev/null \
            && { LLD_AVAILABLE=1; echo -e "${G}✔ lld-${LLVM_VER_ROOT} tìm thấy${W}"; } \
            || echo -e "${Y}⚠️  lld không tìm thấy, fallback sang ld mặc định${W}"

        GLIB_VER=$(pkg-config --modversion glib-2.0 2>/dev/null || echo "0.0.0")
        if ver_lt "$GLIB_VER" "2.66"; then
            echo -e "${Y}⚠️  glib hiện tại: $GLIB_VER — quá cũ, build glib 2.76.6${W}"
            spin_start "Tải source glib 2.76.6..."
            silent sudo apt-get install -y libffi-dev gettext
            cd /tmp; silent wget -q https://download.gnome.org/sources/glib/2.76/glib-2.76.6.tar.xz
            spin_stop "Tải glib xong"
            spin_start "Giải nén glib..."
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
            spin_stop "Giải nén xong"
            spin_start "Build & install glib 2.76.6..."
            cd glib-2.76.6; silent meson setup build --prefix=/usr/local
            silent ninja -C build; silent sudo ninja -C build install
            spin_stop "glib 2.76.6 đã cài"
            export PKG_CONFIG_PATH="/usr/local/lib/x86_64-linux-gnu/pkgconfig:/usr/local/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
            export LD_LIBRARY_PATH="/usr/local/lib/x86_64-linux-gnu:/usr/local/lib:${LD_LIBRARY_PATH:-}"
        else
            echo -e "${G}✔ glib đủ yêu cầu: $GLIB_VER${W}"
        fi

        PY_VER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        echo -e "${B}ℹ${W} Python version: ${PY_VER}"
        VENV_PKG="python3-venv"
        if ! dpkg -s "$VENV_PKG" &>/dev/null 2>&1; then
            echo -ne "${B}◜${W} Cài ${VENV_PKG}..."
            sudo apt-get install -y -qq "$VENV_PKG" > /dev/null 2>&1
            echo -e "\r${G}✔${W} ${VENV_PKG} đã cài          "
        else
            echo -e "${G}✔${W} ${VENV_PKG} đã có"
        fi

        if [[ -d ~/qemu-env ]] && [[ ! -f ~/qemu-env/bin/activate ]]; then
            echo -e "${Y}⚠${W} venv cũ bị broken — xóa và tạo lại"
            rm -rf ~/qemu-env
        fi

        if [[ ! -f ~/qemu-env/bin/activate ]]; then
            if command -v python3 >/dev/null 2>&1; then
                echo -ne "${B}◜${W} Tạo Python venv..."
                python3 -m venv ~/qemu-env > /tmp/venv-create.log 2>&1
                if [[ $? -eq 0 ]]; then echo -e "\r${G}✔${W} Python venv đã tạo          "
                else echo -e "\r${R}✘${W} Tạo venv thất bại:"; cat /tmp/venv-create.log; exit 1; fi
            else
                echo -e "${R}✘${W} python3 không có — không tạo được venv"; exit 1
            fi
        else
            echo -e "${G}✔${W} Python venv đã tồn tại — bỏ qua"
        fi

        source ~/qemu-env/bin/activate

        echo -e "${B}◜${W} Cài meson / ninja trong venv... (log: /tmp/pip-install.log)"
        echo -e "${C}   👉 Xem log: tail -f /tmp/pip-install.log${W}"
        {
            pip install --upgrade pip tomli packaging
            pip install meson ninja
            sudo apt-get remove -y meson 2>/dev/null || true
            hash -r
        } > /tmp/pip-install.log 2>&1
        echo -e "${G}✔${W} meson / ninja sẵn sàng"
        EXTRA_CFLAGS="-O3 -march=native -mtune=native -pipe -fno-plt -fno-semantic-interposition -fomit-frame-pointer -fno-stack-protector -ffunction-sections -fdata-sections -DNDEBUG"
        LDFLAGS="-Wl,--as-needed"

        if [[ ! -d /tmp/qemu-src ]]; then
            spin_start "Tải source QEMU v11.0.0..."
            silent git clone --depth 1 --branch v11.0.0 \
                https://gitlab.com/qemu-project/qemu.git /tmp/qemu-src
            spin_stop "Tải source QEMU xong"
        else
            echo -e "${G}✔ Source QEMU đã có tại /tmp/qemu-src — bỏ qua clone${W}"
        fi

        # ── LLVM Hybrid: install dev + extract + patch ──────────
        LLVM_CONFIGURE_FLAG=""
        if [[ "$LLVM_ACCEL" == "1" ]]; then
            echo -e "${C}⬡  LLVM Hybrid Backend — auto setup${W}"
            if _llvm_hybrid_install_dev; then
                if _llvm_hybrid_extract_and_patch /tmp/qemu-src; then
                    LLVM_CONFIGURE_FLAG="-Dllvm_hybrid=true"
                    LLVM_BUILD_OK=1
                    echo -e "${G}⚡ LLVM Hybrid: enabled — sẽ build cùng QEMU${W}"
                else
                    echo -e "${Y}⚠${W}  LLVM patch thất bại — fallback TCG"
                    LLVM_BUILD_OK=0
                fi
            else
                echo -e "${Y}⚠${W}  LLVM dev install thất bại — fallback TCG"
                LLVM_BUILD_OK=0
            fi
        fi

        rm -rf /tmp/qemu-build
        mkdir -p /tmp/qemu-build
        cd /tmp/qemu-build

        TCG_TB_COMPILE=$(( 256 * 1024 * 1024 ))

        EXTRA_CFLAGS="-O3 -march=native -mtune=native -pipe -fno-plt -fno-semantic-interposition -fomit-frame-pointer -fno-stack-protector -ffunction-sections -fdata-sections -DNDEBUG"
        [[ "$LLVM_BUILD_OK" == "1" ]] && EXTRA_CFLAGS="$EXTRA_CFLAGS -DCONFIG_LLVM_HYBRID=1"
        LDFLAGS="-Wl,--as-needed"

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
        spin_start "Configure QEMU..."

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
            $LLVM_CONFIGURE_FLAG \
            CC="$CC" CXX="$CXX" LD="$LD" \
            CFLAGS="$EXTRA_CFLAGS" CXXFLAGS="$EXTRA_CFLAGS" LDFLAGS="$LDFLAGS" \
            > /tmp/qemu-configure.log 2>&1; then
            spin_stop "Configure xong"
        else
            # If LLVM flag caused failure, retry without it
            if [[ -n "$LLVM_CONFIGURE_FLAG" ]]; then
                echo -e "${Y}⚠${W}  Configure with LLVM failed — retrying without LLVM..."
                LLVM_BUILD_OK=0; LLVM_CONFIGURE_FLAG=""
                if ../qemu-src/configure \
                    --prefix=/opt/qemu-optimized \
                    --target-list=x86_64-softmmu \
                    --enable-tcg \
                    $QEMU_KVM_FLAG \
                    --enable-slirp \
                    --enable-coroutine-pool \
                    --enable-vnc \
                    --disable-mshv \
                    --disable-xen --disable-gtk --disable-sdl --disable-spice \
                    --disable-plugins --disable-debug-info --disable-docs \
                    --disable-werror --disable-fdt --disable-vdi --disable-vvfat \
                    --disable-cloop --disable-dmg --disable-pa --disable-alsa \
                    --disable-oss --disable-jack --disable-gnutls --disable-smartcard \
                    --disable-libusb --disable-seccomp --disable-modules \
                    CC="$CC" CXX="$CXX" LD="$LD" \
                    CFLAGS="$EXTRA_CFLAGS" CXXFLAGS="$EXTRA_CFLAGS" LDFLAGS="$LDFLAGS" \
                    > /tmp/qemu-configure.log 2>&1; then
                    spin_stop "Configure xong (without LLVM)"
                else
                    spin_fail "Configure QEMU thất bại"
                    echo -e "${R}═══ LỖI CONFIGURE — /tmp/qemu-configure.log (30 dòng cuối) ═══${W}" >&2
                    tail -30 /tmp/qemu-configure.log >&2
                    exit 1
                fi
            else
                spin_fail "Configure QEMU thất bại"
                echo -e "${R}═══ LỖI CONFIGURE — /tmp/qemu-configure.log (30 dòng cuối) ═══${W}" >&2
                tail -30 /tmp/qemu-configure.log >&2
                echo -e "${R}══════════════════════════════════════════════════════════════${W}" >&2
                exit 1
            fi
        fi

        ulimit -n 84857 2>/dev/null || true
        NCPU=$(nproc)

        # ── Compile QEMU ─────────────────────────────────────
        spin_start "Compile QEMU với ${NCPU} cores (mất 5-20 phút)..."
        if ninja -j"$NCPU" >> /tmp/qemu-build.log 2>&1; then
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
        for _qp in "/opt/qemu-optimized/bin/qemu-system-x86_64"                    "$HOME/qemu-optimized/bin/qemu-system-x86_64"                    "/usr/bin/qemu-system-x86_64"; do
            [[ -x "$_qp" ]] && { export QEMU_BIN="$_qp"; break; }
        done
        export PATH="/opt/qemu-optimized/bin:$PATH"
        echo -e "${G}🔥 QEMU build xong! $("$QEMU_BIN" --version 2>/dev/null | head -1 || echo '(ok)')${W}"
        if [[ "$LLVM_BUILD_OK" == "1" ]]; then
            echo -e "   Accel: ${KVM_MODE^^} + ${C}LLVM Hybrid${W}"
        else
            echo -e "   Accel: ${KVM_MODE^^}"
        fi
    fi
    # Đợi download nền (nếu đang chạy)
    _wait_parallel_download
else
    echo -e "${Y}⚡ Bỏ qua build QEMU.${W}"
    # Với --no-build, cần đảm bảo image sẵn sàng (download nếu cần)
    _start_parallel_download
    _wait_parallel_download
fi

[[ -x "$QEMU_BIN" ]] && export PATH="/opt/qemu-optimized/bin:$PATH"

# (main menu already shown above — case 1 falls through here)
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

    # Đảm bảo các biến path có giá trị mặc định
    BUILD="${BUILD:-/tmp/qemu-build}"
    IMG_LIST=()
    IMG_LABEL=()
    for _p in \
        "$BUILD/win.img" \
        "/tmp/qemu-build/win.img" \
        "$HOME/win.img" \
        "/content/win.img" \
        "$(pwd)/win.img" \
        "$BUILD/2012.img" \
        "$BUILD/2022.img" \
        "/tmp/qemu-build/2012.img" \
        "/tmp/qemu-build/2022.img"; do
        if [[ -f "$_p" ]]; then
            SIZE=$(du -sh "$_p" 2>/dev/null | cut -f1 || echo "?")
            IMG_LIST+=("$_p")
            IMG_LABEL+=("$_p  [${SIZE}]")
        fi
    done

    # ── Tìm VM đang chạy ─────────────────────────────────────
    RUNNING_PIDS=()
    while IFS= read -r pid; do
        [[ -n "$pid" ]] && RUNNING_PIDS+=("$pid")
    done < <(pgrep -f 'qemu-system-x86_64' 2>/dev/null || true)

    # ── Hiện trạng thái ──────────────────────────────────────
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
    echo -e "   2. Xoá frpc tunnel nếu đang chạy"
    echo -e "   3. Xoá các img file được chọn"
    echo -e "${C}═══════════════════════════════════════${W}"

    # ── Hỏi xác nhận ─────────────────────────────────────────
    read -rp "❓ Bạn có chắc muốn xoá VM không? (yes/n): " confirm_delete
    confirm_delete=$(echo "${confirm_delete:-n}" | tr -cd 'a-zA-Z')
    if [[ "$confirm_delete" != "yes" ]]; then
        echo -e "${Y}⚠️  Huỷ — không xoá gì cả${W}"
        exit 0
    fi

    # ── Kill tất cả QEMU ─────────────────────────────────────
    if [[ "${#RUNNING_PIDS[@]}" -gt 0 ]]; then
        echo -e "${B}ℹ${W}  Kill VM processes..."
        for pid in "${RUNNING_PIDS[@]}"; do
            kill -SIGTERM "$pid" 2>/dev/null || true
        done
        sleep 2
        # Force kill nếu vẫn còn
        for pid in "${RUNNING_PIDS[@]}"; do
            kill -0 "$pid" 2>/dev/null && kill -SIGKILL "$pid" 2>/dev/null || true
        done
        echo -e "${G}✔${W} Đã kill tất cả QEMU processes"
    else
        echo -e "${B}ℹ${W}  Không có QEMU process nào"
    fi

    # ── Kill frpc tunnel + watchdog nếu đang chạy ────────────────
    [[ -f /tmp/frpc-rdp.pid ]] && {
        kill "$(cat /tmp/frpc-rdp.pid)" 2>/dev/null || true
        rm -f /tmp/frpc-rdp.pid /tmp/frpc-rdp.url /tmp/frpc-rdp.log /tmp/frpc-rdp.toml
    }
    [[ -f /tmp/frpc-watchdog.pid ]] && {
        kill "$(cat /tmp/frpc-watchdog.pid)" 2>/dev/null || true
        rm -f /tmp/frpc-watchdog.pid
    }
    echo -e "${G}✔${W} frpc tunnel + watchdog đã dọn"

    # ── Xoá img ──────────────────────────────────────────────
    if [[ "${#IMG_LIST[@]}" -gt 0 ]]; then
        if [[ "${#IMG_LIST[@]}" -eq 1 ]]; then
            del_choice="1"
        else
            echo ""
            echo -e "Chọn img muốn xoá:"
            for i in "${!IMG_LIST[@]}"; do
                echo "  $((i+1)). ${IMG_LABEL[$i]}"
            done
            echo "  a. Xoá tất cả"
            echo "  0. Không xoá img nào"
            read -rp "👉 Nhập số (hoặc 'a' cho tất cả): " del_choice
            del_choice=$(echo "${del_choice:-0}" | tr -cd '0-9a')
        fi

        if [[ "$del_choice" == "a" ]]; then
            for p in "${IMG_LIST[@]}"; do
                rm -f "$p" && echo -e "${G}✔${W} Đã xoá: $p" \
                           || echo -e "${R}✘${W} Không xoá được: $p"
            done
        elif [[ "$del_choice" =~ ^[0-9]+$ && "$del_choice" -ge 1 && "$del_choice" -le "${#IMG_LIST[@]}" ]]; then
            idx=$(( del_choice - 1 ))
            rm -f "${IMG_LIST[$idx]}" \
                && echo -e "${G}✔${W} Đã xoá: ${IMG_LIST[$idx]}" \
                || echo -e "${R}✘${W} Không xoá được: ${IMG_LIST[$idx]}"
        else
            echo -e "${B}ℹ${W}  Bỏ qua xoá img"
        fi
    fi

    # ── Dọn thêm tmp files ───────────────────────────────────
    echo -e "${B}ℹ${W}  Dọn temp files..."
    rm -f /tmp/qemu-launch.log /tmp/frpc-rdp.* 2>/dev/null || true

    echo ""
    echo -e "${G}✅ Xoá VM hoàn tất${W}"
    exit 0
    ;;
esac

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
        aria2c -x16 -s16 -j16 --continue=true --file-allocation=none             --console-log-level=notice --summary-interval=3             --human-readable=true --download-result=full "$WIN_URL" -d "$(dirname "$WIN_IMG_PATH")" -o "$(basename "$WIN_IMG_PATH")"
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
    silent qemu-img resize win.img "+${extra_gb}G"
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
    echo -e "${G}🔥 TCG tuning xong${W}"
    echo ""
}

if [[ "$KVM_AVAILABLE" == "1" ]]; then
    echo -e "${G}⚡ VM sẽ chạy với KVM acceleration + CPU host passthrough${W}"
    ACCEL_OPT="-accel kvm"
    CPU_OPT="-cpu host"

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
                BIOS_OPT="-bios $_OVMF"
                echo -e "${G}✔${W} OVMF firmware: $_OVMF"
            else
                echo -e "${Y}⚠${W}  OVMF.fd không tìm thấy — thử tải..."
                _OVMF_TMP="${PREFIX:-$HOME/qemu-static}/share/qemu"
                mkdir -p "$_OVMF_TMP"
                if wget -q "https://github.com/nicowillis/ovmf-prebuilt/raw/main/OVMF.fd"                         -O "$_OVMF_TMP/OVMF.fd" 2>/dev/null                     || wget -q "https://github.com/clearlinux/common/raw/master/OVMF.fd"                         -O "$_OVMF_TMP/OVMF.fd" 2>/dev/null; then
                    BIOS_OPT="-bios $_OVMF_TMP/OVMF.fd"
                    echo -e "${G}✔${W} OVMF tải xong → $_OVMF_TMP/OVMF.fd"
                else
                    BIOS_OPT=""
                    echo -e "${Y}⚠${W}  Không tải được OVMF — dùng SeaBIOS (boot có thể không vào được Windows 11)"
                fi
            fi
        } \
        || BIOS_OPT=""

    QEMU_CMD=(
        ${QEMU_BIN:-qemu-system-x86_64}
        -machine q35,hpet=off
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

    # TCG TB cache — tăng mạnh hơn cho host nhiều RAM
    TCG_TB_MB=$(( ram_size * 256 ))
    [[ "$TCG_TB_MB" -lt 512 ]] && TCG_TB_MB=512
    [[ "$TCG_TB_MB" -gt 2048 ]] && TCG_TB_MB=2048
    echo -e "${G}⚡ TCG TB cache: ${TCG_TB_MB}MB${W}"

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
        cpu_host="$_raw_cpu_name"  # giữ để hiện ở summary
        case "$_cpu_vendor" in
            GenuineIntel) cpu_model_id="Intel Xeon Gold 6254 Processor"   ;;
            AuthenticAMD) cpu_model_id="AMD EPYC 7763 64-Core Processor"  ;;
            HygonGenuine) cpu_model_id="Hygon C86 7185 32-core Processor" ;;
            CentaurHauls) cpu_model_id="VIA Nano Processor"               ;;
            *)            cpu_model_id="Generic x86_64 Processor"         ;;
        esac
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
                BIOS_OPT="-bios $_OVMF"
                echo -e "${G}✔${W} OVMF firmware: $_OVMF"
            else
                echo -e "${Y}⚠${W}  OVMF.fd không tìm thấy — thử tải..."
                _OVMF_TMP="${PREFIX:-$HOME/qemu-static}/share/qemu"
                mkdir -p "$_OVMF_TMP"
                if wget -q "https://github.com/nicowillis/ovmf-prebuilt/raw/main/OVMF.fd"                         -O "$_OVMF_TMP/OVMF.fd" 2>/dev/null                     || wget -q "https://github.com/clearlinux/common/raw/master/OVMF.fd"                         -O "$_OVMF_TMP/OVMF.fd" 2>/dev/null; then
                    BIOS_OPT="-bios $_OVMF_TMP/OVMF.fd"
                    echo -e "${G}✔${W} OVMF tải xong → $_OVMF_TMP/OVMF.fd"
                else
                    BIOS_OPT=""
                    echo -e "${Y}⚠${W}  Không tải được OVMF — dùng SeaBIOS (boot có thể không vào được Windows 11)"
                fi
            fi
        } \
        || BIOS_OPT=""

    QEMU_CMD=(
        ${QEMU_BIN:-qemu-system-x86_64}
        -machine q35,hpet=off
        -cpu "$cpu_model"
        -smp "$cpu_core,cores=$cpu_core,threads=1,sockets=1"
        -m "${ram_size}G"
        -accel tcg,thread=multi,tb-size=$TCG_TB_MB
        -rtc base=localtime
        -overcommit cpu-pm=on
    )

    # Hugepages mem-path nếu detect được
    if [[ -n "${QEMU_HUGEPAGES_DIR:-}" && -d "$QEMU_HUGEPAGES_DIR" ]]; then
        QEMU_CMD+=(-mem-path "$QEMU_HUGEPAGES_DIR" -mem-prealloc)
        echo -e "${G}✔${W} Hugepages: -mem-path $QEMU_HUGEPAGES_DIR -mem-prealloc"
    fi
fi

# ── Thêm BIOS/UEFI ───────────────────────────────────────────
[[ -n "$BIOS_OPT" ]] && QEMU_CMD+=($BIOS_OPT)

# ── Disk ─────────────────────────────────────────────────────
WIN_IMG_PATH="${WIN_IMG_PATH:-win.img}"
# Detect image format: HTTP-backed = qcow2, else try file command
_QEMU_IMG_FMT="raw"
if [[ "${_HTTP_BACKED:-0}" == "1" ]]; then
    _QEMU_IMG_FMT="qcow2"
elif command -v file &>/dev/null && file "$WIN_IMG_PATH" 2>/dev/null | grep -qi "qcow"; then
    _QEMU_IMG_FMT="qcow2"
fi
QEMU_CMD+=(
    -drive file="$WIN_IMG_PATH",if=virtio,cache=unsafe,aio=threads,format="$_QEMU_IMG_FMT"
)

QEMU_CMD+=(
    -netdev user,id=n0,hostfwd=tcp::${WINVM_RDP_PORT}-:3389
    $NET_DEVICE
)

# ── Input ────────────────────────────────────────────────────
QEMU_CMD+=(
    -device virtio-mouse-pci
    -device virtio-keyboard-pci
)

# ── Display ──────────────────────────────────────────────────
QEMU_CMD+=(-vga virtio -display none)
QEMU_CMD+=(-nodefaults)
QEMU_CMD+=(-serial none -monitor none)

# ── SMBIOS ───────────────────────────────────────────────────
QEMU_CMD+=(
    -global ICH9-LPC.disable_s3=1
    -global ICH9-LPC.disable_s4=1
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
if [[ -x /usr/bin/qemu-system-x86_64 ]]; then
    RESOLVED_QEMU="/usr/bin/qemu-system-x86_64"
fi
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

# Tuning disabled — launch QEMU plain
LAUNCH_PREFIX=""

# ── LLVM Hybrid: probe QEMU binary rồi set env vars ─────────
# LLVM_BUILD_OK chỉ được set trong build path — nếu skip build (QEMU đã có)
# thì cần probe lại: thử set QEMU_LLVM_HYBRID=1 + chạy --help để xem có crash không
if [[ "$LLVM_ACCEL" == "1" && "$LLVM_BUILD_OK" != "1" && -x "$QEMU_BIN" ]]; then
    # Probe: nếu binary support LLVM hybrid thì QEMU_LLVM_HYBRID=1 không làm crash --help
    _llvm_probe_ok=0
    if QEMU_LLVM_HYBRID=1 "$QEMU_BIN" --help > /dev/null 2>&1; then
        # Kiểm tra thêm: binary có symbol llvm_hybrid_init không (nếu nm có)
        if command -v nm &>/dev/null; then
            if nm -D "$QEMU_BIN" 2>/dev/null | grep -q "llvm_hybrid_init"; then
                _llvm_probe_ok=1
                echo -e "${G}✔${W} LLVM Hybrid symbols detected in QEMU binary"
            else
                echo -e "${Y}⚠${W}  QEMU binary không có LLVM Hybrid symbols — TCG thuần"
            fi
        else
            # Không có nm: thử strings fallback
            if strings "$QEMU_BIN" 2>/dev/null | grep -q "llvm.hybrid\|QEMU_LLVM_HYBRID"; then
                _llvm_probe_ok=1
                echo -e "${G}✔${W} LLVM Hybrid string markers found in QEMU binary"
            else
                echo -e "${Y}⚠${W}  Không xác định được LLVM Hybrid support — thử bật, nếu lỗi dùng TCG"
                # Optimistic: thử bật, QEMU tự disable nếu không support
                _llvm_probe_ok=1
            fi
        fi
    fi
    [[ "$_llvm_probe_ok" == "1" ]] && LLVM_BUILD_OK=1
fi

if [[ "$LLVM_BUILD_OK" == "1" ]]; then
    export QEMU_LLVM_HYBRID=1
    [[ -n "$LLVM_THRESHOLD" ]] && export QEMU_LLVM_THRESHOLD="$LLVM_THRESHOLD"
    echo -e "${C}⬡  LLVM Hybrid Backend: ENABLED${W}"
    # Số thread hiển thị: đọc từ cgroup quota (container-safe), không dùng nproc thô
    _llvm_cgroup_cpus=""
    if [[ -f /sys/fs/cgroup/cpu.max ]]; then
        _cq=$(awk '{print $1}' /sys/fs/cgroup/cpu.max 2>/dev/null)
        _cp=$(awk '{print $2}' /sys/fs/cgroup/cpu.max 2>/dev/null)
        [[ "$_cq" != "max" && -n "$_cq" && -n "$_cp" && "$_cp" -gt 0 ]] && \
            _llvm_cgroup_cpus=$(( (_cq + _cp - 1) / _cp ))
    fi
    if [[ -z "$_llvm_cgroup_cpus" && -f /sys/fs/cgroup/cpu/cpu.cfs_quota_us ]]; then
        _cq2=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null)
        _cp2=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us 2>/dev/null)
        [[ -n "$_cq2" && "$_cq2" != "-1" && -n "$_cp2" && "$_cp2" -gt 0 ]] && \
            _llvm_cgroup_cpus=$(( (_cq2 + _cp2 - 1) / _cp2 ))
    fi
    [[ -z "$_llvm_cgroup_cpus" ]] && _llvm_cgroup_cpus=$(nproc 2>/dev/null || echo 2)
    [[ "$_llvm_cgroup_cpus" -gt 1 ]] && _llvm_cgroup_cpus=$(( _llvm_cgroup_cpus - 1 ))
    _llvm_nthreads=${QEMU_LLVM_THREADS:-$_llvm_cgroup_cpus}
    echo -e "   Threshold: ${LLVM_THRESHOLD:-1000} | Async: on | Opt: O2 | Threads: ${_llvm_nthreads}"
elif [[ "$LLVM_ACCEL" == "1" ]]; then
    echo -e "${Y}⚠${W}  LLVM Hybrid: không detect được trong binary — dùng TCG thuần"
    echo -e "${Y}   Tip: build lại QEMU với --rebuild để patch LLVM vào binary${W}"
fi

# Rootless QEMU: đảm bảo LD_LIBRARY_PATH có lib path TRƯỚC khi fork
if [[ "$QEMU_BIN" == *"qemu-static"* ]]; then
    _QEMU_PREFIX="$(dirname "$(dirname "$QEMU_BIN")")"
    export LD_LIBRARY_PATH="$_QEMU_PREFIX/lib:$_QEMU_PREFIX/lib64:$_QEMU_PREFIX/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
    echo -e "${G}✔${W} LD_LIBRARY_PATH for rootless QEMU: $_QEMU_PREFIX/lib"
fi

if [[ -n "$LAUNCH_PREFIX" ]]; then
    echo -e "${G}🔥 Launch prefix: ${LAUNCH_PREFIX}${W}"
    nohup $LAUNCH_PREFIX "${QEMU_CMD[@]}" >> "$QEMU_LOG" 2>&1 &
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


# ════════════════════════════════════════════════════════════════
#  TUNNEL RDP (frpc only — bore removed)
# ════════════════════════════════════════════════════════════════
if [[ "$AUTO_RDP" == "1" ]]; then
    use_rdp="y"
    echo -e "${G}🤖 AUTO MODE — tự động mở tunnel RDP${W}"
else
    use_rdp=$(ask "🛰️  Mở port tunnel để kết nối RDP? (y/n): " "n")
fi

PUBLIC=""
TUNNEL_BACKEND_SELECTED=""

if [[ "$use_rdp" == "y" ]]; then

    if [[ "${TUNNEL_BACKEND:-auto}" == "frpc" || "${TUNNEL_BACKEND:-auto}" == "auto" ]]; then
        if command -v frpc &>/dev/null && [[ -n "${ZO_CLIENT_IDENTITY_TOKEN:-}" ]]; then
            TUNNEL_BACKEND_SELECTED="frpc"
            FRPC_BIN="$(command -v frpc)"
            FRPC_LOG="/tmp/frpc-rdp.log"
            FRPC_PID_FILE="/tmp/frpc-rdp.pid"
            FRPC_URL_FILE="/tmp/frpc-rdp.url"
            FRPC_CONF_FILE="/tmp/frpc-rdp.toml"
            FRPC_SERVER_ADDR="${FRPC_SERVER_ADDR:-ts4.zocomputer.io}"
            FRPC_SERVER_PORT="${FRPC_SERVER_PORT:-7000}"
            FRPC_REMOTE_PORT="${FRPC_REMOTE_PORT:-0}"
            mkdir -p /tmp

            if [[ -f "$FRPC_PID_FILE" ]]; then
                OLD_PID=$(cat "$FRPC_PID_FILE" 2>/dev/null || true)
                [[ -n "$OLD_PID" ]] && kill "$OLD_PID" 2>/dev/null || true
            fi
            if [[ -f "$FRPC_URL_FILE" ]]; then
                rm -f "$FRPC_URL_FILE"
            fi
            pkill -f "frpc tcp .*ts4.zocomputer.io.*3389" 2>/dev/null || true

            cat > "$FRPC_CONF_FILE" <<EOF
serverAddr = "$FRPC_SERVER_ADDR"
serverPort = $FRPC_SERVER_PORT

transport.tls.enable = true
metadatas.identity_token = "${ZO_CLIENT_IDENTITY_TOKEN}"

[[proxies]]
name = "winbox-rdp"
type = "tcp"
localIP = "127.0.0.1"
localPort = ${WINVM_RDP_PORT}
remotePort = $FRPC_REMOTE_PORT
EOF

            _frpc_start_once() {
                : > "$FRPC_LOG"
                nohup "$FRPC_BIN" -c "$FRPC_CONF_FILE" > "$FRPC_LOG" 2>&1 &
                local pid=$!
                disown "$pid"
                echo "$pid" > "$FRPC_PID_FILE"
            }

            echo -e "${B}ℹ${W}  Khởi động frpc tunnel → ${FRPC_SERVER_ADDR}:${FRPC_SERVER_PORT}..."
            _frpc_start_once

            echo -ne "${B}◜${W} Chờ frpc endpoint"
            for i in $(seq 1 30); do
                ENDPOINT=$(grep -m1 -oE 'remote_addr[^0-9]*[0-9]+(\.[0-9]+)*:[0-9]+' "$FRPC_LOG" 2>/dev/null | grep -oE '[0-9]+$' | tail -1 || true)
                if [[ -z "$ENDPOINT" ]]; then
                    ENDPOINT=$(grep -m1 -oE 'tcp proxy listen port \[[0-9]+\]|listen port \[[0-9]+\]|assigned port \[[0-9]+\]' "$FRPC_LOG" 2>/dev/null | grep -oE '[0-9]+' | tail -1 || true)
                fi
                if [[ -n "$ENDPOINT" ]]; then
                    PUBLIC="${FRPC_SERVER_ADDR}:${ENDPOINT}"
                    echo "$PUBLIC" > "$FRPC_URL_FILE"
                    echo -e "
${G}✔${W} frpc tunnel: ${G}${PUBLIC}${W}          "
                    break
                fi
                echo -ne "."
                sleep 1
            done
            [[ -z "$PUBLIC" ]] && echo -e "
${Y}⚠${W}  Không lấy được endpoint frpc — xem $FRPC_LOG"

            (
                WATCH_INTERVAL=120
                WATCH_FRPC_BIN="$FRPC_BIN"
                WATCH_LOG="$FRPC_LOG"
                WATCH_PID_FILE="$FRPC_PID_FILE"
                WATCH_URL_FILE="$FRPC_URL_FILE"
                WATCH_CONF_FILE="$FRPC_CONF_FILE"
                LAST_ENDPOINT="$PUBLIC"
                RECONNECT_COUNT=0

                while true; do
                    sleep "$WATCH_INTERVAL"
                    CUR_PID=$(cat "$WATCH_PID_FILE" 2>/dev/null || echo "")
                    FRPC_ALIVE=0
                    [[ -n "$CUR_PID" ]] && kill -0 "$CUR_PID" 2>/dev/null && FRPC_ALIVE=1

                    if [[ "$FRPC_ALIVE" -eq 0 ]]; then
                        RECONNECT_COUNT=$(( RECONNECT_COUNT + 1 ))
                        echo -e "\n${Y}⚠  [frpc watchdog] Tunnel mất kết nối (lần ${RECONNECT_COUNT}) — đang reconnect...${W}" >&2
                        sleep 2
                        : > "$WATCH_LOG"
                        nohup "$WATCH_FRPC_BIN" -c "$WATCH_CONF_FILE" > "$WATCH_LOG" 2>&1 &
                        NEW_PID=$!
                        disown "$NEW_PID"
                        echo "$NEW_PID" > "$WATCH_PID_FILE"

                        NEW_ENDPOINT=""
                        for _ in $(seq 1 30); do
                            NEW_ENDPOINT=$(grep -m1 -oE 'tcp proxy listen port \[[0-9]+\]|listen port \[[0-9]+\]|assigned port \[[0-9]+\]' \
                                "$WATCH_LOG" 2>/dev/null | grep -oE '[0-9]+' | tail -1 || true)
                            [[ -n "$NEW_ENDPOINT" ]] && break
                            sleep 1
                        done

                        if [[ -n "$NEW_ENDPOINT" ]]; then
                            NEW_PUBLIC="${FRPC_SERVER_ADDR}:${NEW_ENDPOINT}"
                            echo "$NEW_PUBLIC" > "$WATCH_URL_FILE"
                            if [[ "$NEW_PUBLIC" != "$LAST_ENDPOINT" ]]; then
                                echo -e "\n${G}✔  [frpc watchdog] Reconnected! RDP address đã thay đổi:${W}" >&2
                                echo -e "   ${R}Cũ:${W} ${LAST_ENDPOINT}" >&2
                                echo -e "   ${G}Mới:${W} ${NEW_PUBLIC}" >&2
                                LAST_ENDPOINT="$NEW_PUBLIC"
                            else
                                echo -e "\n${G}✔  [frpc watchdog] Reconnected! RDP address: ${NEW_PUBLIC}${W}" >&2
                            fi
                        else
                            echo -e "\n${R}✘  [frpc watchdog] Reconnect thất bại — sẽ thử lại sau ${WATCH_INTERVAL}s${W}" >&2
                        fi
                    fi

                    SHOWN_ADDR=$(cat "$WATCH_URL_FILE" 2>/dev/null || echo "unknown")
                    echo -e "\n${C}[frpc watchdog $(date '+%H:%M:%S')] RDP: ${G}${SHOWN_ADDR}${W}  |  reconnects: ${RECONNECT_COUNT}${W}" >&2
                done
            ) &
            FRPC_WATCHDOG_PID=$!
            disown "$FRPC_WATCHDOG_PID"
            echo "$FRPC_WATCHDOG_PID" > /tmp/frpc-watchdog.pid
            echo -e "${G}✔${W} frpc watchdog khởi động (PID: $FRPC_WATCHDOG_PID, interval: 120s)"
        else
            if [[ "${TUNNEL_BACKEND:-auto}" == "frpc" ]]; then
                echo -e "${Y}⚠${W}  frpc không dùng được (thiếu binary hoặc ZO_CLIENT_IDENTITY_TOKEN)"
            fi
        fi
    fi

    # Bore tunnel đã bị loại bỏ hoàn toàn (không ổn định, dễ crash/disconnect)
    if [[ -z "$TUNNEL_BACKEND_SELECTED" ]]; then
        echo -e "${Y}⚠${W}  Không có tunnel backend khả dụng."
        echo -e "${B}ℹ${W}  Bore tunnel đã bị loại bỏ (không ổn định, dễ crash/disconnect)."
        echo -e "${B}ℹ${W}  Để dùng tunnel, hãy cung cấp frpc + ZO_CLIENT_IDENTITY_TOKEN."
        echo -e "${B}ℹ${W}  RDP vẫn truy cập được qua: localhost:${WINVM_RDP_PORT}"
    fi
fi

# ── SUMMARY ───────────────────────────────────────────────────────
echo ""
echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "${C}🚀 WINBOX DEPLOYED SUCCESSFULLY${W}"
[[ "$AUTO_MODE" == "1" ]] && \
    echo -e "${C}🤖 Launched via: --auto${AUTO_WIN:+ --win$AUTO_WIN}${AUTO_RDP:+ --rdp}${W}"
echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "🪟 OS           : ${Y}$WIN_NAME${W}"
echo -e "⚙  CPU Cores    : ${B}$cpu_core${W}"
echo -e "💾 RAM          : ${B}${ram_size} GB${W}"
if [[ "$KVM_AVAILABLE" == "1" ]]; then
    echo -e "⚡ Acceleration : ${G}KVM (hardware) + CPU host${W}"
else
    if [[ "$LLVM_ACCEL" == "1" ]]; then
        echo -e "⚡ Acceleration : ${C}TCG + LLVM Hybrid${W} | TB cache: ${TCG_TB_MB:-?}MB"
        echo -e "⬡  LLVM         : ${C}Threshold=${LLVM_THRESHOLD:-1000} | Async | O2${W}"
    else
        echo -e "⚡ Acceleration : ${Y}TCG (software) | TB cache: ${TCG_TB_MB:-?}MB${W}"
    fi
    echo -e "🧠 CPU Model    : ${B}${cpu_host:-unknown}${W}"
fi
echo -e "${C}──────────────────────────────────────────────${W}"
if [[ -n "$PUBLIC" ]]; then
    echo -e "📡 RDP Address  : ${G}${PUBLIC}${W}"
    if [[ "$TUNNEL_BACKEND_SELECTED" == "frpc" ]]; then
        echo -e "🔗 Tunnel       : ${B}frpc${W}"
        echo -e "📋 Log tunnel   : ${B}${FRPC_LOG}${W}"
        echo -e "🛑 Stop tunnel  : ${Y}kill \$(cat ${FRPC_PID_FILE})${W}"
        echo -e "📍 RDP hiện tại : ${Y}cat ${FRPC_URL_FILE}${W}"
    fi
else
    echo -e "📡 RDP (local)  : ${G}localhost:${WINVM_RDP_PORT}${W}"
    [[ "$use_rdp" == "y" ]] && \
        echo -e "${Y}   ⚠  Tunnel chưa lấy được endpoint — xem log ở trên${W}"
fi
echo -e "👤 Username     : ${Y}$RDP_USER${W}"
echo -e "🔑 Password     : ${Y}$RDP_PASS${W}"
echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "${G}🟢 Status       : RUNNING (PID: $QEMU_PID)${W}"
echo    "⏱  GUI Mode     : Headless / RDP"
echo -e "${C}══════════════════════════════════════════════${W}"

