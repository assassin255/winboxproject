#!/usr/bin/env bash
set -euo pipefail

# Đảm bảo biến môi trường cơ bản khi chạy qua sudo su (HOME/USER có thể bị unset)
HOME="${HOME:-/root}"
USER="${USER:-$(id -un 2>/dev/null || echo root)}"
LOGNAME="${LOGNAME:-$USER}"
export HOME USER LOGNAME

# ════════════════════════════════════════════════════════════════
#  WINDOWS VM TOOL v26
#  LLVM 16 via apt (không dùng external repo)
#  Rootless: toàn bộ libs build từ source (zlib/libffi/pixman/glib/libslirp)
#  aria2: cài qua conda nếu có, fallback wget static binary, fallback wget
#  Fix: removed --user from pip install (virtualenv compatibility)
#  KVM: Auto detect /dev/kvm → enable KVM acceleration if available
#  NEW: CLI flags --auto --winXXXX để chạy hoàn toàn không tương tác
#  NEW: Tự động skip build nếu QEMU đã tồn tại (--rebuild để build lại)
#
#  Cách dùng:
#    bash winv24.sh                          # chế độ interactive như cũ
#    bash winv24.sh --auto --win2012         # auto, Windows Server 2012 R2
#    bash winv24.sh --auto --win2022         # auto, Windows Server 2022
#    bash winv24.sh --auto --win11           # auto, Windows 11 LTSB
#    bash winv24.sh --auto --win10ltsb       # auto, Windows 10 LTSB 2015
#    bash winv24.sh --auto --win10ltsc       # auto, Windows 10 LTSC 2023
#    bash winv24.sh --auto --win2012 --rdp   # auto + mở tunnel RDP
# ════════════════════════════════════════════════════════════════

# ── MÀU SẮC ────────────────────────────────────────────────────
R='\033[1;31m'; G='\033[1;32m'; Y='\033[1;33m'
B='\033[1;34m'; C='\033[1;36m'; W='\033[0m'

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
        --help|-h)
            echo "Usage: bash winv26.sh [OPTIONS]"
            echo ""
            echo "  --auto          Chạy không tương tác (bắt buộc kết hợp với --winXXXX)"
            echo "  --win2012       Windows Server 2012 R2"
            echo "  --win2022       Windows Server 2022"
            echo "  --win11         Windows 11 LTSB"
            echo "  --win10ltsb     Windows 10 LTSB 2015"
            echo "  --win10ltsc     Windows 10 LTSC 2023"
            echo "  --rdp           Tự động mở tunnel RDP"
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
            echo ""
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
        echo -e "${R}✘${W}  VM đang chạy — phải stop trước: bash winv26.sh --stop --id=$INSTANCE_ID"; exit 1
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
    echo -e "${B}ℹ${W}  Chạy lại script để build mới: bash winv26.sh --rebuild"
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
        echo -e "${Y}\u26a0${W}  Fallback: tải 1 luồng..."
        _download_chunked "$WIN_URL" win.img 900
        return 0
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
            if [[ "${SAFE_DOWNLOAD:-0}" == "1" ]]; then
            echo -e "${B}ℹ${W}  Chế độ --safe-download: tải chunks 900MB"
            _download_chunked "$WIN_URL" "$WIN_IMG_PATH" 900
        else
        if command -v aria2c &>/dev/null; then
                aria2c --header="Range: bytes=${start}-${end}" \
                    -x8 -s8 --file-allocation=none \
                    --console-log-level=warn --summary-interval=5 \
                    --human-readable=true "$url" -o "$_tmp" 2>&1 && ok=1 && break
            else
                curl -fL --range "${start}-${end}" --retry 3 \
                    --progress-bar -o "$_tmp" "$url" && ok=1 && break
            fi
        fi
            echo -e "${Y}\u26a0${W}  Thử lại lần ${_try}..."; sleep 3
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

    # ── Ưu tiên 2: build glib 2.76.6 từ source (tương thích meson 1.x) ─
    local GLIB_VER="2.76.6"
    local GLIB_MAJ="2.76"
    echo -e "${B}ℹ${W}  Build glib ${GLIB_VER} từ source..."
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

    echo -e "${B}ℹ${W}  meson setup glib ${GLIB_VER}... (timeout 600s)"
    export PKG_CONFIG_PATH="$prefix/lib/pkgconfig:$prefix/lib64/pkgconfig:${PKG_CONFIG_PATH:-}"

    # Flags tối giản — tắt mọi thứ không cần cho QEMU headless
    local _meson_flags=(
        --prefix="$prefix"
        -Dlibdir="lib"
        --wrap-mode=nodownload
        -Dtests=false
        -Dinstalled_tests=false
        -Dman=false
        -Dgtk_doc=false
        -Dlibmount=disabled
        -Dselinux=disabled
        -Ddtrace=false
        -Dsystemtap=false
        -Dxattr=false
        -Dlibelf=disabled
        -Dnls=disabled
    )
    # glib 2.66 không có -Dpcre2, 2.76+ có → thêm nếu cần
    if [[ "$GLIB_VER" == 2.7* ]]; then
        _meson_flags+=( -Dpcre2=internal )
    fi
    # tắt gobject-introspection (tránh phụ thuộc thêm)
    _meson_flags+=( -Dintrospection=disabled )

    local _meson_exit=0
    timeout 600 "$meson_cmd" setup . .. "${_meson_flags[@]}" \
        > /tmp/glib-meson.log 2>&1 || _meson_exit=$?
    if [[ $_meson_exit -eq 124 ]]; then
        echo -e "${R}✘${W} meson setup glib TIMEOUT (>600s) — xem /tmp/glib-meson.log"
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
            && CC="$CC_PLAIN" ./configure --prefix="$PREFIX" > /tmp/make-build.log 2>&1 \
            && CC="$CC_PLAIN" ./build.sh >> /tmp/make-build.log 2>&1 \
            && cp make "$PREFIX/bin/make" \
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

    # ── Ensure pkg-config binary is available (required by meson) ──
    if ! command -v pkg-config &>/dev/null && ! command -v pkgconf &>/dev/null; then
        echo -e "${Y}⚠${W}  pkg-config không có — thử cài..."
        # 1. Conda (thường có trong JupyterHub)
        if command -v conda &>/dev/null; then
            conda install -y -q -c conda-forge pkg-config > /tmp/pkgconfig-conda.log 2>&1                 && echo -e "${G}✔${W} pkg-config từ conda"                 || echo -e "${Y}⚠${W}  conda install pkg-config thất bại"
        fi
        # 2. Build từ source nếu vẫn chưa có
        if ! command -v pkg-config &>/dev/null; then
            echo -e "${B}ℹ${W}  Build pkg-config 0.29.2 từ source (~30s)..."
            (cd "$BUILD"                 && wget -q "https://pkgconfig.freedesktop.org/releases/pkg-config-0.29.2.tar.gz"                        -O pkg-config.tar.gz 2>/dev/null                 && tar xzf pkg-config.tar.gz 2>/dev/null                 && cd pkg-config-0.29.2                 && ./configure --prefix="$PREFIX" --with-internal-glib                        > /tmp/pkgconfig-build.log 2>&1                 && ${MAKE:-make} -j"$(nproc)" >> /tmp/pkgconfig-build.log 2>&1                 && ${MAKE:-make} install    >> /tmp/pkgconfig-build.log 2>&1)                 && echo -e "${G}✔${W} pkg-config built from source → $PREFIX/bin"                 || echo -e "${Y}⚠${W}  Build pkg-config thất bại — xem /tmp/pkgconfig-build.log"
        fi
    fi
    if command -v pkg-config &>/dev/null; then
        hash -r 2>/dev/null || true          # flush bash cache so new binary is found
        export PKG_CONFIG="$(command -v pkg-config)"
        echo -e "${G}✔${W} pkg-config: $PKG_CONFIG"
    else
        echo -e "${Y}⚠${W}  pkg-config vẫn không tìm thấy — QEMU configure có thể thất bại"
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
    PKG_CONFIG="${PKG_CONFIG:-$(command -v pkg-config 2>/dev/null || echo "")}" \
    PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}" \
    PIP_TARGET="" \
    PYTHONPATH="" \
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
        2>&1 | tee /tmp/qemu-configure.log
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo -e "${R}✘${W} Configure QEMU thất bại — xem /tmp/qemu-configure.log"
        exit 1
    fi
    echo -e "\r${G}✔${W} Configure QEMU xong          "

    echo ""
    echo -e "${C}════════════════════════════════════${W}"
    echo -e "${C}🔨 Compile QEMU (mất 10-20 phút)${W}"
    echo -e "${C}════════════════════════════════════${W}"
    ${MAKE:-make} -j"$(nproc)" 2>&1 | grep --line-buffered -E "^\[|error:|warning:|FAILED"
    if [[ ${PIPESTATUS[0]} -ne 0 ]]; then
        echo -e "${R}✘ Compile QEMU thất bại — xem /tmp/qemu-build.log${W}"
        ${MAKE:-make} -j"$(nproc)" > /tmp/qemu-build.log 2>&1
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

# ═══════════════════════════════════════════════════════════════
#  MENU CHÍNH — phải hiện trước khi hỏi bất cứ gì
# ═══════════════════════════════════════════════════════════════
echo ""
echo -e "${C}════════════════════════════════════${W}"
echo -e "${C}🖥️  WINDOWS VM MANAGER  v26${W}"
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

        spin_start "Cài LLVM 16 (clang, lld, llvm)..."
        export DEBIAN_FRONTEND=noninteractive
        if silent $APT_CMD install -y clang-16 lld-16 llvm-16 llvm-16-dev llvm-16-tools; then
            spin_stop "LLVM 16 đã cài (từ repo OS)"
        else
            spin_fail "LLVM 16 không có trong repo OS — thêm repo llvm.org..."

            # ── Fallback: thêm repo chính thức llvm.org ──────────
            # Detect distro codename
            DISTRO_CODENAME=$(. /etc/os-release 2>/dev/null && echo "${VERSION_CODENAME:-}" \
                || lsb_release -sc 2>/dev/null || echo "")

            if [[ -z "$DISTRO_CODENAME" ]]; then
                echo -e "${R}✘${W} Không detect được distro codename — không thể thêm repo LLVM"; exit 1
            fi
            echo -e "${B}ℹ${W}  Distro codename: ${DISTRO_CODENAME}"

            # Tải script cài repo llvm.org
            echo -e "${B}ℹ${W}  Tải llvm install script..."
            if wget -qO /tmp/llvm.sh https://apt.llvm.org/llvm.sh; then
                chmod +x /tmp/llvm.sh
                echo -e "${B}ℹ${W}  Chạy llvm.sh 16 (có thể mất 1-2 phút)..."
                if bash /tmp/llvm.sh 16 > /tmp/llvm-repo.log 2>&1; then
                    echo -e "${G}✔${W} Repo llvm.org thêm thành công"
                else
                    # llvm.sh thất bại → thêm repo thủ công
                    echo -e "${Y}⚠${W}  llvm.sh thất bại — thêm repo thủ công..."
                    # Thêm GPG key — dùng sudo nếu APT_CMD có sudo
                    if echo "$APT_CMD" | grep -q sudo; then
                        wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key \
                            | sudo tee /etc/apt/trusted.gpg.d/llvm.asc > /dev/null 2>&1
                        sudo tee /etc/apt/sources.list.d/llvm-16.list > /dev/null <<EOF
deb http://apt.llvm.org/${DISTRO_CODENAME}/ llvm-toolchain-${DISTRO_CODENAME}-16 main
deb-src http://apt.llvm.org/${DISTRO_CODENAME}/ llvm-toolchain-${DISTRO_CODENAME}-16 main
EOF
                    else
                        wget -qO- https://apt.llvm.org/llvm-snapshot.gpg.key \
                            | tee /etc/apt/trusted.gpg.d/llvm.asc > /dev/null 2>&1
                        tee /etc/apt/sources.list.d/llvm-16.list > /dev/null <<EOF
deb http://apt.llvm.org/${DISTRO_CODENAME}/ llvm-toolchain-${DISTRO_CODENAME}-16 main
deb-src http://apt.llvm.org/${DISTRO_CODENAME}/ llvm-toolchain-${DISTRO_CODENAME}-16 main
EOF
                    fi
                fi

                echo -e "${B}ℹ${W}  apt update sau khi thêm repo LLVM..."
                $APT_CMD update -qq > /dev/null 2>&1

                echo -e "${B}ℹ${W}  Cài LLVM 16 từ repo llvm.org..."
                if $APT_CMD install -y clang-16 lld-16 llvm-16 llvm-16-dev llvm-16-tools \
                        > /tmp/llvm-install.log 2>&1; then
                    echo -e "${G}✔${W} LLVM 16 đã cài từ repo llvm.org"
                else
                    echo -e "${R}✘${W} LLVM 16 thất bại cả 2 cách — xem /tmp/llvm-install.log"
                    cat /tmp/llvm-install.log | tail -20
                    exit 1
                fi
            else
                echo -e "${R}✘${W} Không tải được llvm.sh (kiểm tra mạng)"; exit 1
            fi
        fi

        export PATH="/usr/lib/llvm-16/bin:$PATH"
        export CC="clang-16"; export CXX="clang++-16"; export LD="lld-16"

        if command -v lld-16 &>/dev/null; then
            LLD_AVAILABLE=1; echo -e "${G}✔ lld-16 tìm thấy${W}"
        else
            LLD_AVAILABLE=0; echo -e "${Y}⚠️  lld-16 không tìm thấy, fallback sang ld mặc định${W}"
        fi

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

        rm -rf /tmp/qemu-build
        mkdir -p /tmp/qemu-build
        cd /tmp/qemu-build

        TCG_TB_COMPILE=$(( 256 * 1024 * 1024 ))

        EXTRA_CFLAGS="-O3 -march=native -mtune=native -pipe -fno-plt -fno-semantic-interposition -fomit-frame-pointer -fno-stack-protector -ffunction-sections -fdata-sections -DNDEBUG"
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
            --enable-vnc \            --disable-mshv \
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
            CC="$CC" CXX="$CXX" LD="$LD" \
            CFLAGS="$EXTRA_CFLAGS" CXXFLAGS="$EXTRA_CFLAGS" LDFLAGS="$LDFLAGS" \
            > /tmp/qemu-configure.log 2>&1; then
            spin_stop "Configure xong"
        else
            spin_fail "Configure QEMU thất bại"
            echo -e "${R}═══ LỖI CONFIGURE — /tmp/qemu-configure.log (30 dòng cuối) ═══${W}" >&2
            tail -30 /tmp/qemu-configure.log >&2
            echo -e "${R}══════════════════════════════════════════════════════════════${W}" >&2
            exit 1
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
    echo -e "   2. Xoá bore tunnel nếu đang chạy"
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

    # ── Kill bore tunnel + watchdog ──────────────────────────────
    pkill -f "bore local.*--to" 2>/dev/null || true
    [[ -f /tmp/bore-rdp.pid ]] && {
        kill "$(cat /tmp/bore-rdp.pid)" 2>/dev/null || true
        rm -f /tmp/bore-rdp.pid /tmp/bore-rdp.url /tmp/bore-rdp.log
    }
    [[ -f /tmp/bore-watchdog.pid ]] && {
        kill "$(cat /tmp/bore-watchdog.pid)" 2>/dev/null || true
        rm -f /tmp/bore-watchdog.pid
    }
    echo -e "${G}✔${W} Bore tunnel + watchdog đã dọn"

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
    rm -f /tmp/qemu-launch.log /tmp/bore-rdp.* 2>/dev/null || true

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
        -machine q35,hpet=off,accel=kvm
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
    cpu_host=$(grep -m1 "model name" /proc/cpuinfo | sed 's/^.*: //')
    cpu_host="${cpu_host//,/ }"
    cpu_model_id="AMD EPYC Milan Processor"
    CPU_EXTRA=""
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
for _fwd in "${EXTRA_FWDS[@]:-}"; do
    [[ -z "$_fwd" ]] && continue
    _h="${_fwd%%:*}"; _g="${_fwd##*:}"
    _EXTRA_FWDS_STR+=",hostfwd=tcp::${_h}-:${_g}"
done
# Add QMP socket to QEMU command
QEMU_CMD+=(-qmp unix:"$WINVM_QMP_SOCK",server,nowait)

echo "QEMU CMD: ${QEMU_CMD[*]}" > "$QEMU_LOG"

# Tuning disabled — launch QEMU plain
LAUNCH_PREFIX=""

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
#  TUNNEL RDP (frpc/bore tunnel)
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
name = "winv24-rdp"
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
                echo -e "${Y}⚠${W}  frpc không dùng được (thiếu binary hoặc ZO_CLIENT_IDENTITY_TOKEN) — sẽ thử bore"
            fi
        fi
    fi

    if [[ -z "$TUNNEL_BACKEND_SELECTED" && ( "${TUNNEL_BACKEND:-auto}" == "bore" || "${TUNNEL_BACKEND:-auto}" == "auto" ) ]]; then
        TUNNEL_BACKEND_SELECTED="bore"

        # ── 1. Tìm thư mục cài bore (root → /opt, rootless → ~/bore-tunnel) ──
        if [[ $EUID -eq 0 ]]; then
            BORE_ROOT="/opt/bore-tunnel"
        else
            BORE_ROOT="$HOME/bore-tunnel"
        fi
        BORE_BIN="$BORE_ROOT/bin/bore"
        BORE_LOG="/tmp/bore-rdp.log"
        BORE_PID_FILE="/tmp/bore-rdp.pid"
        BORE_URL_FILE="/tmp/bore-rdp.url"
        BORE_RELAY="${BORE_RELAY:-bore.pub}"
        mkdir -p "$BORE_ROOT/bin"

        # ── 2. Cài bore binary ─────────────────────────────────────────
        if command -v bore &>/dev/null; then
            BORE_BIN="$(command -v bore)"
            echo -e "${G}✔${W} bore đã có: $BORE_BIN"
        elif [[ -x "$BORE_BIN" ]]; then
            echo -e "${G}✔${W} bore đã có: $BORE_BIN"
        else
            echo -e "${B}ℹ${W}  Tải bore binary..."
            BORE_ASSET_URL=$(python3 - <<'PY'
import json, urllib.request
FALLBACK = "https://github.com/ekzhang/bore/releases/download/v0.6.0/bore-v0.6.0-x86_64-unknown-linux-musl.tar.gz"
try:
    req = urllib.request.Request(
        "https://api.github.com/repos/ekzhang/bore/releases/latest",
        headers={"User-Agent": "winvm-bore-installer"},
    )
    data = json.load(urllib.request.urlopen(req, timeout=20))
    tag = data.get("tag_name", "v0.6.0")
    wanted = f"bore-{tag}-x86_64-unknown-linux-musl.tar.gz"
    for asset in data.get("assets", []):
        if asset.get("name") == wanted:
            print(asset["browser_download_url"]); exit()
    print(FALLBACK)
except Exception:
    print(FALLBACK)
PY
)
            BORE_ARCHIVE="$BORE_ROOT/bore.tar.gz"
            if wget -q "$BORE_ASSET_URL" -O "$BORE_ARCHIVE" 2>/dev/null \
                    || curl -fsSL "$BORE_ASSET_URL" -o "$BORE_ARCHIVE" 2>/dev/null; then
                BORE_EXTRACT="$BORE_ROOT/extract"
                mkdir -p "$BORE_EXTRACT"
                tar -xzf "$BORE_ARCHIVE" -C "$BORE_EXTRACT" 2>/dev/null
                BORE_SRC=$(find "$BORE_EXTRACT" -type f -name bore -perm -111 | head -1 \
                         || find "$BORE_EXTRACT" -type f -name bore | head -1)
                if [[ -n "$BORE_SRC" ]]; then
                    install -m755 "$BORE_SRC" "$BORE_BIN"
                    echo -e "${G}✔${W} bore cài xong → $BORE_BIN"
                else
                    echo -e "${R}✘${W} Không tìm thấy bore binary sau khi giải nén"; use_rdp="n"
                fi
            else
                echo -e "${R}✘${W} Không tải được bore (kiểm tra mạng)"; use_rdp="n"
            fi
        fi

        if [[ "$use_rdp" == "y" && -x "$BORE_BIN" ]]; then

            # ── 3. Kill bore cũ nếu còn ──────────────────────────────
            if [[ -f "$BORE_PID_FILE" ]]; then
                OLD_PID=$(cat "$BORE_PID_FILE" 2>/dev/null || true)
                [[ -n "$OLD_PID" ]] && kill "$OLD_PID" 2>/dev/null || true
            fi
            BORE_WATCHDOG_PID_FILE="/tmp/bore-watchdog.pid"
            if [[ -f "$BORE_WATCHDOG_PID_FILE" ]]; then
                OLD_WD=$(cat "$BORE_WATCHDOG_PID_FILE" 2>/dev/null || true)
                [[ -n "$OLD_WD" ]] && kill "$OLD_WD" 2>/dev/null || true
            fi
            pkill -f "bore local.*--to.*bore" 2>/dev/null || true
            rm -f "$BORE_PID_FILE" "$BORE_URL_FILE" "$BORE_WATCHDOG_PID_FILE"

            # ── Hàm start một bore process ────────────────────────────
            _bore_start_once() {
                : > "$BORE_LOG"
                nohup "$BORE_BIN" local "${WINVM_RDP_PORT}" \
                    --local-host 127.0.0.1 \
                    --to "$BORE_RELAY" \
                    > "$BORE_LOG" 2>&1 &
                local pid=$!
                disown "$pid"
                echo "$pid" > "$BORE_PID_FILE"
            }

            # ── 4. Khởi động bore tunnel lần đầu ─────────────────────
            echo -e "${B}ℹ${W}  Khởi động bore tunnel → ${BORE_RELAY}:3389..."
            _bore_start_once

            # ── 5. Chờ lấy public endpoint (max 30s) ─────────────────
            echo -ne "${B}◜${W} Chờ bore endpoint"
            for i in $(seq 1 30); do
                ENDPOINT=$(grep -m1 -oE 'bore\.pub:[0-9]+' "$BORE_LOG" 2>/dev/null || true)
                if [[ -n "$ENDPOINT" ]]; then
                    echo "$ENDPOINT" > "$BORE_URL_FILE"
                    PUBLIC="$ENDPOINT"
                    echo -e "\r${G}✔${W} Bore tunnel: ${G}${PUBLIC}${W}          "
                    break
                fi
                echo -ne "."
                sleep 1
            done
            [[ -z "$PUBLIC" ]] && echo -e "\r${Y}⚠${W}  Không lấy được endpoint — xem $BORE_LOG"

            # ── 6. Watchdog: auto reconnect + cập nhật địa chỉ ───────
            (
                WATCH_INTERVAL=120
                WATCH_BORE_BIN="$BORE_BIN"
                WATCH_RELAY="$BORE_RELAY"
                WATCH_LOG="$BORE_LOG"
                WATCH_PID_FILE="$BORE_PID_FILE"
                WATCH_URL_FILE="$BORE_URL_FILE"
                LAST_ENDPOINT="$PUBLIC"
                RECONNECT_COUNT=0

                while true; do
                    sleep "$WATCH_INTERVAL"

                    CUR_PID=$(cat "$WATCH_PID_FILE" 2>/dev/null || echo "")
                    BORE_ALIVE=0
                    [[ -n "$CUR_PID" ]] && kill -0 "$CUR_PID" 2>/dev/null && BORE_ALIVE=1

                    if [[ "$BORE_ALIVE" -eq 0 ]]; then
                        RECONNECT_COUNT=$(( RECONNECT_COUNT + 1 ))
                        echo -e "\n${Y}⚠  [bore watchdog] Tunnel mất kết nối (lần ${RECONNECT_COUNT}) — đang reconnect...${W}" >&2
                        pkill -f "bore local.*--to.*bore" 2>/dev/null || true
                        sleep 2
                        : > "$WATCH_LOG"
                        nohup "$WATCH_BORE_BIN" local "${WINVM_RDP_PORT}" \
                            --local-host 127.0.0.1 \
                            --to "$WATCH_RELAY" \
                            > "$WATCH_LOG" 2>&1 &
                        NEW_PID=$!
                        disown "$NEW_PID"
                        echo "$NEW_PID" > "$WATCH_PID_FILE"

                        NEW_ENDPOINT=""
                        for _ in $(seq 1 30); do
                            NEW_ENDPOINT=$(grep -m1 -oE 'bore\.pub:[0-9]+' \
                                "$WATCH_LOG" 2>/dev/null || true)
                            [[ -n "$NEW_ENDPOINT" ]] && break
                            sleep 1
                        done

                        if [[ -n "$NEW_ENDPOINT" ]]; then
                            echo "$NEW_ENDPOINT" > "$WATCH_URL_FILE"
                            if [[ "$NEW_ENDPOINT" != "$LAST_ENDPOINT" ]]; then
                                echo -e "\n${G}✔  [bore watchdog] Reconnected! RDP address đã thay đổi:${W}" >&2
                                echo -e "   ${R}Cũ:${W} ${LAST_ENDPOINT}" >&2
                                echo -e "   ${G}Mới:${W} ${NEW_ENDPOINT}" >&2
                                LAST_ENDPOINT="$NEW_ENDPOINT"
                            else
                                echo -e "\n${G}✔  [bore watchdog] Reconnected! RDP address: ${NEW_ENDPOINT}${W}" >&2
                            fi
                        else
                            echo -e "\n${R}✘  [bore watchdog] Reconnect thất bại — sẽ thử lại sau ${WATCH_INTERVAL}s${W}" >&2
                        fi
                    else
                        CURRENT_ENDPOINT=$(grep -m1 -oE 'bore\.pub:[0-9]+' \
                            "$WATCH_LOG" 2>/dev/null || true)
                        if [[ -n "$CURRENT_ENDPOINT" && \
                              "$CURRENT_ENDPOINT" != "$LAST_ENDPOINT" ]]; then
                            echo "$CURRENT_ENDPOINT" > "$WATCH_URL_FILE"
                            echo -e "\n${Y}ℹ  [bore watchdog] RDP port thay đổi:${W}" >&2
                            echo -e "   ${R}Cũ:${W} ${LAST_ENDPOINT}" >&2
                            echo -e "   ${G}Mới:${W} ${CURRENT_ENDPOINT}" >&2
                            LAST_ENDPOINT="$CURRENT_ENDPOINT"
                        fi
                    fi

                    SHOWN_ADDR=$(cat "$WATCH_URL_FILE" 2>/dev/null || echo "unknown")
                    echo -e "\n${C}[bore watchdog $(date '+%H:%M:%S')] RDP: ${G}${SHOWN_ADDR}${W}  |  reconnects: ${RECONNECT_COUNT}${W}" >&2
                done
            ) &
            BORE_WATCHDOG_PID=$!
            disown "$BORE_WATCHDOG_PID"
            echo "$BORE_WATCHDOG_PID" > "$BORE_WATCHDOG_PID_FILE"
            echo -e "${G}✔${W} Bore watchdog khởi động (PID: $BORE_WATCHDOG_PID, interval: 120s)"
        fi
    fi
fi

# ── SUMMARY ───────────────────────────────────────────────────────
echo ""
echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "${C}🚀 WINDOWS VM DEPLOYED SUCCESSFULLY  [v26]${W}"
[[ "$AUTO_MODE" == "1" ]] && \
    echo -e "${C}🤖 Launched via: --auto${AUTO_WIN:+ --win$AUTO_WIN}${AUTO_RDP:+ --rdp}${W}"
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
    if [[ "$TUNNEL_BACKEND_SELECTED" == "frpc" ]]; then
        echo -e "🔗 Tunnel       : ${B}frpc${W}"
        echo -e "📋 Log tunnel   : ${B}${FRPC_LOG}${W}"
        echo -e "🛑 Stop tunnel  : ${Y}kill \$(cat ${FRPC_PID_FILE})${W}"
        echo -e "📍 RDP hiện tại : ${Y}cat ${FRPC_URL_FILE}${W}"
    else
        echo -e "🔗 Tunnel       : ${B}bore${W}"
        echo -e "🔗 Bore relay   : ${B}${BORE_RELAY}${W}"
        echo -e "🔄 Auto reconnect: ${G}enabled (watchdog every 120s)${W}"
        echo -e "📋 Log tunnel   : ${B}${BORE_LOG}${W}"
        echo -e "🛑 Stop tunnel  : ${Y}kill \$(cat ${BORE_PID_FILE}) \$(cat ${BORE_WATCHDOG_PID_FILE:-/tmp/bore-watchdog.pid})${W}"
        echo -e "📍 RDP hiện tại : ${Y}cat ${BORE_URL_FILE}${W}"
    fi
else
    echo -e "📡 RDP (local)  : ${G}localhost:3389${W}"
    [[ "$use_rdp" == "y" ]] && \
        echo -e "${Y}   ⚠  Tunnel chưa lấy được endpoint — xem log ở trên${W}"
fi
echo -e "👤 Username     : ${Y}$RDP_USER${W}"
echo -e "🔑 Password     : ${Y}$RDP_PASS${W}"
echo -e "${C}══════════════════════════════════════════════${W}"
echo -e "${G}🟢 Status       : RUNNING (PID: $QEMU_PID)${W}"
echo    "⏱  GUI Mode     : Headless / RDP"
echo -e "${C}══════════════════════════════════════════════${W}"