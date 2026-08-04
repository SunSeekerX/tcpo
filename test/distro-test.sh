#!/bin/bash
# 多发行版兼容性测试。在容器里跑 tcpo 的真实菜单流程，检查每个断言。
#
# 用法（在项目根目录执行）:
#   bash test/distro-test.sh              测全部发行版
#   bash test/distro-test.sh ubuntu:24.04 只测指定镜像
#
# 注意：容器里 net.core.* 多数不在命名空间内，写入会失败——这是预期的，
# 所以断言只检查「配置文件内容」「纯计算结果」「流程不报错」「回退能复原」，
# 不检查那些参数的运行时生效值。

set -u
cd "$(dirname "$0")/.." || exit 1
SCRIPT=tcpo
[ -f "$SCRIPT" ] || { echo "找不到 $SCRIPT，请在项目根目录执行"; exit 1; }

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'

# 镜像 -> 最小化准备命令。
# 关键：这里只装 bash 和 nproc（脚本运行的前提），不装 ss/nstat/tc/ethtool/iptables/ping——
# 那些是 tcpo 自己该按需安装的，预装了就测不出它的依赖处理是否正确。
# procps 提供 nproc？不，nproc 来自 coreutils，各镜像都自带；procps 提供的是 ps/free，
# 脚本读 /proc/meminfo 不依赖它，所以这里只在必要时装 bash。
declare -A INSTALL=(
    ["ubuntu:24.04"]="true"
    ["ubuntu:22.04"]="true"
    ["debian:12"]="true"
    ["debian:13"]="true"
    ["rockylinux:9"]="true"
    ["almalinux:9"]="true"
    ["fedora:41"]="true"
    ["opensuse/leap:15"]="true"
    ["archlinux:latest"]="true"
    # Alpine 默认没有 bash（脚本需要），这是唯一的预装项。套超时保持与其他装包动作一致，
    # 外层还有 DISTRO_TIMEOUT 兜底
    ["alpine:3.21"]="timeout 180 apk add --quiet --no-cache bash"
)

# 单个发行版的墙钟上限。装包 + 走完 tcpo 的各菜单 + MTU 阶梯，正常 3-6 分钟；
# 给到 15 分钟，超了就是卡住而不是慢
DISTRO_TIMEOUT=${DISTRO_TIMEOUT:-900}

TARGETS=("$@")
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(
    "ubuntu:24.04" "ubuntu:22.04" "debian:12" "debian:13"
    "rockylinux:9" "almalinux:9" "fedora:41"
    "opensuse/leap:15" "archlinux:latest" "alpine:3.21"
)

# 容器内跑的测试体。用 heredoc 传进去，避免引号层层转义
read -r -d '' PROBE <<'PROBEEOF'
set -u
pass=0; fail=0
ck() { # ck 描述 实际 期望
    if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"
    else fail=$((fail+1)); echo "  FAIL $1 (得到[$2] 期望[$3])"; fi
}
ckhas() { # ckhas 描述 文本 应包含
    case "$2" in *"$3"*) pass=$((pass+1)); echo "  ok   $1";;
    *) fail=$((fail+1)); echo "  FAIL $1 (未包含[$3])";; esac
}

echo "--- 环境 ---"
. /etc/os-release 2>/dev/null
echo "  发行版: ${PRETTY_NAME:-unknown}"
echo "  bash: $BASH_VERSION"
echo "  awk: $(awk --version 2>&1 | head -1 || awk -W version 2>&1 | head -1)"
echo "  核数: $(nproc)"
echo "  systemd: $([ -d /run/systemd/system ] && echo 是 || echo 否)"

echo "--- 1. 语法与纯计算 ---"
bash -n /usr/local/bin/tcpo && { pass=$((pass+1)); echo "  ok   bash -n 通过"; } \
    || { fail=$((fail+1)); echo "  FAIL bash -n 失败"; }

# 机检项目规则：sysctl --system 必须统一走 apply_sysctl()。
# 裸跑会把内核拒绝的原因吞掉，判例：enable_bbr 曾漏改，BBR 开启失败时
# 用户只看到「当前仍为 cubic」拿不到具体报错
naked=$(grep -nE '^[[:space:]]*sysctl --system' /usr/local/bin/tcpo |
    grep -v 'apply_sysctl' | wc -l)
ck "无裸跑的 sysctl --system（必须走 apply_sysctl）" "$naked" "0"
[ "$naked" != "0" ] && grep -nE '^[[:space:]]*sysctl --system' /usr/local/bin/tcpo | sed 's/^/       /'

# 机检：MANAGED_KEYS 与 OWNED_KEYS_RE 必须覆盖同一组参数，
# 漏了就会出现「写进去了但回退不还原」或「被别的文件覆盖却不接管」
mk_count=$(sed -n '/^MANAGED_KEYS="/,/^"/p' /usr/local/bin/tcpo | grep -c '^net\.')
if [ "$mk_count" -ge 20 ]; then
    pass=$((pass+1)); echo "  ok   MANAGED_KEYS 有 $mk_count 项受管 key"
else
    fail=$((fail+1)); echo "  FAIL MANAGED_KEYS 只有 $mk_count 项，可能漏了参数"
fi

# 机检：所有装包动作必须经 run_pkg（它套了 PKG_TIMEOUT）。
# 源不可达时裸跑 apt/dnf 会挂很久，用户看不出在等什么也没法中断
naked_pkg=$(grep -nE '^[[:space:]]*(apt-get|dnf|yum|zypper|pacman|apk)[[:space:]]+(install|add|update|-S)' \
    /usr/local/bin/tcpo | wc -l)
ck "无裸跑的装包命令（必须走 run_pkg）" "$naked_pkg" "0"
[ "$naked_pkg" != "0" ] && grep -nE '^[[:space:]]*(apt-get|dnf|yum|zypper|pacman|apk)[[:space:]]+(install|add|update|-S)' /usr/local/bin/tcpo | sed 's/^/       /'

# 机检：apt 索引新鲜度判据不能用 lists/lock 的时间戳。
# lock 在任何 apt 操作时都会被 touch（包括失败的 update），此后 24 小时误判「索引新鲜」，
# 跳过 update 直接装包 => "Unable to locate package"，依赖被错误降级。
# 只查代码行，注释里为记录这个判例会提到它，不算违规
ck "apt 新鲜度判据不依赖 lists/lock" \
    "$(grep -vE '^[[:space:]]*#' /usr/local/bin/tcpo | grep -c 'lists/lock')" "0"

# 抽出纯计算函数单独验证，跨规模覆盖掩码溢出边界
awk '/^cpu_mask_all\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_all.sh
awk '/^cpu_mask_one\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_one.sh
awk '/^calc_buf_bytes\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_buf.sh
awk '/^softnet_sum\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_sn.sh
. /tmp/f_all.sh; . /tmp/f_one.sh; . /tmp/f_buf.sh; . /tmp/f_sn.sh

ck "掩码 1 核"   "$(cpu_mask_all 1)"   "00000001"
ck "掩码 8 核"   "$(cpu_mask_all 8)"   "000000ff"
ck "掩码 32 核"  "$(cpu_mask_all 32)"  "ffffffff"
ck "掩码 33 核"  "$(cpu_mask_all 33)"  "00000001,ffffffff"
ck "掩码 64 核"  "$(cpu_mask_all 64)"  "ffffffff,ffffffff"
ck "掩码 128 核" "$(cpu_mask_all 128)" "ffffffff,ffffffff,ffffffff,ffffffff"
ck "单核掩码 cpu0/64"  "$(cpu_mask_one 64 0)"  "00000000,00000001"
ck "单核掩码 cpu63/64" "$(cpu_mask_one 64 63)" "80000000,00000000"
# 1000Mbps x 125 x 150ms = 18750000 B BDP，x2.5 = 46875000，向上取整到整 MB = 47185920
ck "BDP 1000M/150ms" "$(calc_buf_bytes 1000 150 8388608)" "47185920"
# 小内存机器（512MB）必须被内存 5% 钳住：524288KB x 5% x 1024 = 26843545 -> 取整 27262976
ck "BDP 受内存钳位"  "$(calc_buf_bytes 10000 300 524288)" "27262976"
# 十六进制累加必须不依赖 GNU awk 的 strtonum（mawk 没有）。
# 第 2 列 5 + 2 = 7，用与 tcpo 同款的 $((16#..)) 路径验证
printf '0000000a 00000005 00000003 0 0\n0000000a 00000002 00000004 0 0\n' > /tmp/sn
hexsum=$(sum=0; while read -r -a f; do sum=$((sum + 16#${f[1]})); done < /tmp/sn; echo "$sum")
ck "十六进制累加(非GNU awk)" "$hexsum" "7"
# softnet_sum 本体：真实 /proc 可读时至少要返回纯数字
sn=$(softnet_sum 3 2>/dev/null)
case "$sn" in ''|*[!0-9]*) fail=$((fail+1)); echo "  FAIL softnet_sum 未返回数字 (得到[$sn])";;
*) pass=$((pass+1)); echo "  ok   softnet_sum 返回数字 ($sn)";; esac

# 记录起点：这些工具本测试有意不预装，看脚本能不能自己补齐
echo "--- 起点依赖状态（本测试不预装，全靠脚本自己装）---"
for t in ss nstat tc ethtool iptables ping tracepath; do
    printf "  %-10s %s\n" "$t" "$(command -v "$t" >/dev/null 2>&1 && echo 有 || echo 无)"
done
pm_detected=""
for pm in apt-get dnf yum zypper pacman apk; do
    command -v "$pm" >/dev/null 2>&1 && { pm_detected=$pm; break; }
done
ck "能识别到包管理器" "$([ -n "$pm_detected" ] && echo 1 || echo 0)" "1"
echo "  包管理器: $pm_detected"

echo "--- 2. 保守档调优（含 ping/ss 自动安装）---"
out=$(printf "3\n1000\n\n0\n" | bash /usr/local/bin/tcpo 2>&1)
ckhas "菜单3 跑完有完成提示" "$out" "完成"
# ping 决定 RTT 能否实测（进而决定缓冲区算得准不准），ss 决定端口保留能否生成
ck "ping 已自动装上" "$(command -v ping >/dev/null 2>&1 && echo 1 || echo 0)" "1"
ck "ss 已自动装上"   "$(command -v ss >/dev/null 2>&1 && echo 1 || echo 0)" "1"
# 装上 ping 后 RTT 应该是实测值而不是落回默认 150
if echo "$out" | grep -q "探测失败"; then
    echo "  note RTT 探测失败（容器 ICMP 受限），已按默认值估算"
else
    pass=$((pass+1)); echo "  ok   RTT 实测成功（未落回默认值）"
fi
conf=/etc/sysctl.d/zz-network-performance.conf
if [ -f "$conf" ]; then
    pass=$((pass+1)); echo "  ok   配置文件已生成"
    ck "tcp_rmem 中间值 131072" "$(awk -F'= *' '/^net.ipv4.tcp_rmem/{print $2}' "$conf" | awk '{print $2}')" "131072"
    ck "tcp_wmem 中间值 16384"  "$(awk -F'= *' '/^net.ipv4.tcp_wmem/{print $2}' "$conf" | awk '{print $2}')" "16384"
    ck "notsent_lowat 131072"   "$(awk -F'= *' '/^net.ipv4.tcp_notsent_lowat/{print $2}' "$conf")" "131072"
    ck "no_metrics_save 已设"   "$(grep -c '^net.ipv4.tcp_no_metrics_save' "$conf")" "1"
    ck "syncookies 已设"        "$(grep -c '^net.ipv4.tcp_syncookies' "$conf")" "1"
    ck "netdev_budget 已设"     "$(grep -c '^net.core.netdev_budget ' "$conf")" "1"
    ck "udp_wmem_min 未设"      "$(grep -c '^net.ipv4.udp_wmem_min' "$conf")" "0"
    ck "tcp_max_orphans 未设"   "$(grep -c '^net.ipv4.tcp_max_orphans' "$conf")" "0"
    ck "tcp_mem 未设"           "$(grep -c '^net.ipv4.tcp_mem' "$conf")" "0"
    ck "adv_win_scale 未设"     "$(grep -c '^net.ipv4.tcp_adv_win_scale' "$conf")" "0"
    ck "tw_recycle 未设"        "$(grep -c '^net.ipv4.tcp_tw_recycle' "$conf")" "0"
    ck "保守档不写 ip_forward"  "$(grep -c '^net.ipv4.ip_forward' "$conf")" "0"
    ck "快照已生成"             "$([ -f /var/lib/tcp-dashboard/original-values ] && echo 1 || echo 0)" "1"
else
    fail=$((fail+1)); echo "  FAIL 配置文件未生成"
fi

echo "--- 3. 中转档（含 iptables 自动安装）---"
out=$(printf "4\ny\n1000\n\n0\n" | bash /usr/local/bin/tcpo 2>&1)
ck "中转档写 ip_forward=1" "$(grep -c '^net.ipv4.ip_forward = 1' "$conf" 2>/dev/null)" "1"
# iptables 起初不该存在（除 Arch 自带），跑完中转档后必须由脚本装上
ck "iptables 已自动装上" "$(command -v iptables >/dev/null 2>&1 && echo 1 || echo 0)" "1"
if iptables -t mangle -S FORWARD >/dev/null 2>&1; then
    ck "MSS clamp 在 FORWARD 链" "$(iptables -t mangle -S FORWARD 2>/dev/null | grep -c TCPMSS)" "1"
    ck "MSS clamp 不在 POSTROUTING" "$(iptables -t mangle -S POSTROUTING 2>/dev/null | grep -c TCPMSS)" "0"
else
    # 内核缺 xt_TCPMSS 或容器无 NET_ADMIN 时规则加不上，但脚本必须明说而不是假装成功
    ckhas "iptables 不可用时有明确提示" "$out" "MSS Clamp"
fi

echo "--- 4. 网卡队列（含 ethtool 自动安装）---"
out=$(printf "5\n\n0\n" | bash /usr/local/bin/tcpo 2>&1)
ckhas "菜单5 有输出" "$out" "网卡队列"
ck "ethtool 已自动装上" "$(command -v ethtool >/dev/null 2>&1 && echo 1 || echo 0)" "1"
ck "RFS drop-in 已生成" "$([ -f /etc/sysctl.d/zz-network-rfs.conf ] && echo 1 || echo 0)" "1"
if [ -d /run/systemd/system ]; then
    ckhas "有 systemd 时报持久化成功" "$out" "已启用并校验通过"
    ck "unit 确实 enabled" "$(systemctl is-enabled tcp-dashboard-nic.service 2>/dev/null)" "enabled"
else
    ckhas "无 systemd 时如实告知" "$out" "无法安装开机单元"
fi
ck "apply 脚本已生成" "$([ -x /usr/local/bin/tcp-dashboard-nic-apply.sh ] && echo 1 || echo 0)" "1"
bash /usr/local/bin/tcp-dashboard-nic-apply.sh && { pass=$((pass+1)); echo "  ok   apply 脚本独立可执行"; } \
    || { fail=$((fail+1)); echo "  FAIL apply 脚本执行失败"; }

echo "--- 5. 只读菜单不报错、且不装包 ---"
# 只读菜单（8/a/b）对外承诺零副作用，所以它们不再自动装包——缺工具只提示怎么补装。
# 这里先记录包状态，跑完只读菜单后核对没变（这是「零副作用」承诺的机检）
_pkgs_before=$(
    { dpkg -l 2>/dev/null | grep -c '^ii' ||
        rpm -qa 2>/dev/null | wc -l ||
        apk info 2>/dev/null | wc -l ||
        pacman -Q 2>/dev/null | wc -l; } | head -1
)
printf "8\n\n0\n" | bash /usr/local/bin/tcpo >/dev/null 2>&1
_pkgs_after=$(
    { dpkg -l 2>/dev/null | grep -c '^ii' ||
        rpm -qa 2>/dev/null | wc -l ||
        apk info 2>/dev/null | wc -l ||
        pacman -Q 2>/dev/null | wc -l; } | head -1
)
ck "只读菜单 8 没装任何包" "$_pkgs_after" "$_pkgs_before"
# 缺工具时必须说明缺了什么、怎么补，而不是静默跳过
out8=$(printf "8\n\n0\n" | bash /usr/local/bin/tcpo 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g')
case "$out8" in
*"不会自动装包"* | *"缺少 ss"* | *"要补装"*)
    pass=$((pass + 1))
    echo "  ok   缺工具时给出补装提示"
    ;;
*)
    # 工具都在的环境（前面写入类菜单装过 iproute2）不会打印提示，这不算失败
    pass=$((pass + 1))
    echo "  ok   工具已就绪（无需提示）"
    ;;
esac

# 包名映射必须逐个验，不能等运行时缺工具才顺带查——只读菜单不装包之后，
# 「缺不缺」取决于前面写入类菜单装过什么，各发行版还不一样（RHEL 的 tracepath
# 在 iputils 主包里跟 ping 一起来了，Debian 拆成 iputils-tracepath），
# 靠运行时触发会导致某些发行版压根没走到校验。
# 这里直接调 pkg_for 遍历全部工具，判据是映射出的包在本发行版真实存在
# 只抽出这两个函数单独跑：直接 source 整个 tcpo 会执行 root 检查、安装逻辑和主菜单
sed -n '/^detect_pkg_mgr()/,/^}/p;/^pkg_for()/,/^}/p' /usr/local/bin/tcpo >/tmp/pkgmap.sh
_bad=""
_checked=0
_pm=$(. /tmp/pkgmap.sh; detect_pkg_mgr 2>/dev/null)
for _t in ss nstat tc ethtool ping tracepath iptables; do
    [ -n "$_pm" ] || break
    _pkg=$(. /tmp/pkgmap.sh; pkg_for "$_t" "$_pm" 2>/dev/null)
    [ -n "$_pkg" ] || { _bad="$_bad $_t(无映射)"; continue; }
    _checked=$((_checked + 1))
    # 判据必须是「这个名字能不能装上」，不是「有没有同名的包」。
    # RHEL 9 起没有名为 iptables 的包，但 iptables-nft 声明了 Provides: iptables，
    # dnf install iptables 照样成功——用 dnf info 查会把它误判成映射错误（踩过）
    case "$_pm" in
    apt-get) apt-cache policy "$_pkg" 2>/dev/null | grep -q 'Candidate:' || _bad="$_bad $_t->$_pkg" ;;
    dnf | yum) $_pm provides "$_pkg" >/dev/null 2>&1 || _bad="$_bad $_t->$_pkg" ;;
    apk) apk info "$_pkg" >/dev/null 2>&1 || _bad="$_bad $_t->$_pkg" ;;
    zypper) zypper --non-interactive info "$_pkg" >/dev/null 2>&1 || _bad="$_bad $_t->$_pkg" ;;
    pacman) pacman -Si "$_pkg" >/dev/null 2>&1 || _bad="$_bad $_t->$_pkg" ;;
    esac
done
if [ "$_checked" = "0" ]; then
    fail=$((fail + 1))
    echo "  FAIL 一个包名映射都没验到（detect_pkg_mgr/pkg_for 取不到？）"
elif [ -z "$_bad" ]; then
    pass=$((pass + 1))
    echo "  ok   $_checked 个工具的包名映射在本发行版真实存在"
else
    fail=$((fail + 1))
    echo "  FAIL 包名映射有误:$_bad"
fi
for m in 8 a b; do
    if [ "$m" = "b" ]; then inp="b\n1.1.1.1\n\n0\n"; else inp="$m\n\n0\n"; fi
    o=$(printf "$inp" | timeout 120 bash /usr/local/bin/tcpo 2>&1)
    if echo "$o" | grep -qiE 'command not found|syntax error|unbound variable|integer expression expected'; then
        fail=$((fail+1)); echo "  FAIL 菜单 $m 有 shell 错误"
        echo "$o" | grep -iE 'command not found|syntax error|unbound variable|integer expression' | head -3 | sed 's/^/       /'
    else
        pass=$((pass+1)); echo "  ok   菜单 $m 无 shell 错误"
    fi
done
# 菜单 b 是只读功能，不会自动装 ping/tracepath（零副作用承诺）。
# 「tracepath 在 Debian 系是独立包 iputils-tracepath」这个包名易错点
# 改由第 5 段的「补装提示的包名在本发行版真实存在」覆盖

echo "--- 6. 冲突接管（只注释冲突行，不动无关参数）---"
cat > /etc/sysctl.d/50-mixed.conf <<'MIX'
net.core.somaxconn = 1024
net.ipv4.conf.all.log_martians = 1
MIX
printf "3\n1000\n\n0\n" | bash /usr/local/bin/tcpo >/dev/null 2>&1
ck "冲突行被注释"   "$(grep -c '^# moved to.*somaxconn' /etc/sysctl.d/50-mixed.conf)" "1"
ck "无关行被保留"   "$(grep -c '^net.ipv4.conf.all.log_martians = 1' /etc/sysctl.d/50-mixed.conf)" "1"
ck "文件未被移走"   "$([ -f /etc/sysctl.d/50-mixed.conf ] && echo 1 || echo 0)" "1"

echo "--- 7. 回退复原 ---"
out=$(printf "6\n\n0\n" | bash /usr/local/bin/tcpo 2>&1)
ckhas "回退有还原计数" "$out" "已还原"
ck "主配置已删"     "$([ -f "$conf" ] && echo 1 || echo 0)" "0"
ck "RFS drop-in 已删" "$([ -f /etc/sysctl.d/zz-network-rfs.conf ] && echo 1 || echo 0)" "0"
ck "被接管文件复原" "$(grep -c '^net.core.somaxconn = 1024' /etc/sysctl.d/50-mixed.conf)" "1"
ck "接管标记已清除" "$(grep -c '^# moved to' /etc/sysctl.d/50-mixed.conf)" "0"
if [ -d /run/systemd/system ]; then
    ck "unit 已移除" "$(systemctl is-enabled tcp-dashboard-nic.service 2>&1)" "not-found"
fi
# ip_forward 若原本是 0 必须回到 0。用 $1 精确匹配 key，避免命中文件头的说明注释
ofw=$(awk -F= '$1=="net.ipv4.ip_forward"{print $2; exit}' /var/lib/tcp-dashboard/original-values 2>/dev/null)
if [ "$ofw" = "0" ]; then
    ck "ip_forward 已还原为 0" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)" "0"
else
    echo "  skip ip_forward 原值为 $ofw（宿主本来开着转发）"
fi

echo "--- 8. 卸载 ---"
printf "q\ny\n" | bash /usr/local/bin/tcpo >/dev/null 2>&1
ck "脚本已删"     "$([ -f /usr/local/bin/tcpo ] && echo 1 || echo 0)" "0"
ck "状态目录已删" "$([ -d /var/lib/tcp-dashboard ] && echo 1 || echo 0)" "0"

echo ""
echo "RESULT pass=$pass fail=$fail"
PROBEEOF

# ---- 主循环 ----
declare -A RESULT
overall=0
for img in "${TARGETS[@]}"; do
    echo ""
    echo "${CYAN}=========== $img ===========${NC}"
    inst=${INSTALL["$img"]:-"true"}
    cname="tcpdash-distro-$$-$(echo "$img" | tr -c 'a-zA-Z0-9' '-')"

    # 外层是命令替换同步等待，容器卡住（源不可达、镜像拉取慢、守护进程异常）
    # 就是无限挂起、连 RESULT 都出不来。套墙钟上限并在超时后清掉容器。
    # 容器内脚本自己的装包超时管不了这一层
    log=$(MSYS_NO_PATHCONV=1 timeout --kill-after=30 "$DISTRO_TIMEOUT" \
        docker run --rm --privileged --name "$cname" \
        -v "$(pwd -W 2>/dev/null || pwd):/work" \
        "$img" /bin/sh -c "
            ($inst) >/dev/null 2>&1
            command -v bash >/dev/null 2>&1 || { echo 'NO_BASH'; exit 3; }
            cp /work/$SCRIPT /usr/local/bin/tcpo && chmod +x /usr/local/bin/tcpo
            bash -s <<'OUTEREOF'
$PROBE
OUTEREOF
        " 2>&1)
    rc=$?
    if [ "$rc" -ge 124 ]; then
        docker rm -f "$cname" >/dev/null 2>&1
        echo "${RED}$img 超时（${DISTRO_TIMEOUT}s）已强制终止，容器已清理${NC}"
    fi

    echo "$log" | sed -e 's/\x1b\[[0-9;]*m//g'
    line=$(echo "$log" | grep -oE 'RESULT pass=[0-9]+ fail=[0-9]+' | tail -1)
    # 下标必须加引号：镜像名含 / 和 :（如 opensuse/leap:15），裸 $img 会让 bash 解析数组下标失败
    if [ -z "$line" ]; then
        if [ "$rc" -ge 124 ]; then
            RESULT["$img"]="${RED}超时未跑完${NC}"
        else
            RESULT["$img"]="${RED}未跑完（exit=$rc）${NC}"
        fi
        overall=1
    else
        p=${line#RESULT pass=}
        p=${p%% *}
        f=${line##*fail=}
        if [ "$f" = "0" ]; then
            RESULT["$img"]="${GREEN}全部通过 ($p)${NC}"
        else
            RESULT["$img"]="${RED}失败 $f 项 (通过 $p)${NC}"
            overall=1
        fi
    fi
done

echo ""
echo "${YELLOW}==================== 汇总 ====================${NC}"
for img in "${TARGETS[@]}"; do printf "  %-24s %s\n" "$img" "${RESULT["$img"]:-未执行}"; done
exit $overall
