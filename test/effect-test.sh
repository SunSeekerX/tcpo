#!/bin/bash
# 效果测试：证明参数改动真的改变了网络行为，不只是「写进去没报错」。
#
# 用法（项目根目录执行）:
#   bash test/effect-test.sh          跑全部 8 组
#   bash test/effect-test.sh 1 3      只跑第 1、3 组
#
# 做法：在容器里用 netns + veth + netem 造一条可控的长肥网络（高 RTT、可选丢包），
# 然后在同一条链路上跑 iperf3，对比不同参数下的真实吞吐与重传。
#
# 能验证什么 / 不能验证什么（重要）：
#   本文件实测覆盖的参数（改测试组时请同步这份清单，不要写「等」这类含糊措辞——
#   项目规则要求「效果主张必须有 effect-test 实测支撑」，清单和实际组必须一一对应）：
#     tcp_congestion_control  组 1(有丢包) / 组 2(无丢包反向对照) / 组 4(端到端)
#     tcp_rmem / tcp_wmem     组 3(上限对吞吐的影响) / 组 4(按 BDP 取值是否正确)
#     tcp_notsent_lowat       组 7(本项目取 128K 而非社区常见 16K，验不损失吞吐)
#     tcp_slow_start_after_idle 组 8(同一连接内空闲后恢复速度)
#   顺带验证脚本自身的功能：组 5(诊断结论与真实链路一致) / 组 6(测量读到真实增量)
#
#   不能 —— net.core.rmem_max / wmem_max / default_qdisc。Docker Desktop（WSL2 后端）
#           把 /proc/sys/net/core 整体屏蔽了，连节点都不存在，任何方式都改不了。
#           要验 net.core.* 需要真实 VM 或裸机。
#   未实测 —— tcp_mtu_probing / udp_rmem_min / tcp_no_metrics_save / netdev_budget /
#           somaxconn 等。它们要么依赖特定路径条件（PMTU 黑洞、UDP 高并发），
#           要么效果体现在跨连接/长期行为上，容器内造不出可复现的对照。
#           这些参数的依据是内核文档与权威 profile，不是本测试。
#
# 每组独立跑一个容器：8 组串在一起要 20 分钟以上容易被超时打断，
# 且某组崩了会带走全部结果。每组 3 次取中位数，避免单次抖动误判。

set -u
cd "$(dirname "$0")/.." || exit 1
[ -f tcpo ] || { echo "找不到 tcpo，请在项目根目录执行"; exit 1; }

IMAGE=${IMAGE:-ubuntu:24.04}
# 变量名不能叫 GROUPS：Git Bash / 部分 Linux 发行版会把它作为只读环境变量
# 预置成用户的组 ID（实测 Windows Git Bash 下 GROUPS=197121），赋值静默无效
TEST_GROUPS="1 2 3 4 5 6 7 8"
[ $# -gt 0 ] && TEST_GROUPS="$*"
RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'

echo "${CYAN}=== 网络优化效果测试 ===${NC}"
echo "镜像: $IMAGE | 测试组: $TEST_GROUPS"

# 自检：头注释里声称「实测覆盖」的参数，必须真的在某个测试组的代码里出现。
# 判例：组 7 从 slow_start_after_idle 改成 notsent_lowat 时，头注释和 README
# 都漏改，于是宣称验了一项其实没验的参数——项目规则要求效果主张有实测支撑，
# 这类脱节靠人工核对早晚会漏，让脚本自己守着
self_check() {
    local claimed p bad_claim=0
    # 从头注释的覆盖清单里抽出参数名（缩进两个字段、以 tcp_/udp_ 开头的行）
    # 只取「参数名 + 组号」那几行（形如 "#     tcp_xxx   组 N(...)"），
    # 不要整段 sed 范围——那会把「未实测」段落里提到的参数名也扫进来造成误报
    # 只取「参数名(可能多个，用 / 分隔) + 组号」那几行，形如
    #   "#     tcp_rmem / tcp_wmem     组 3(...) / 组 4(...)"
    # 不要整段 sed 范围——那会把「未实测」段落里提到的参数名也扫进来造成误报
    claimed=$(grep -E '^#[[:space:]]+(tcp|udp)_[a-z_/ ]+组 [0-9]' "$0" |
        sed 's/组 [0-9].*//' | grep -oE '(tcp|udp)_[a-z_]+' | sort -u)
    for p in $claimed; do
        # 在 group*() 函数体里找它的实际使用（sysctl -w 或断言文案）
        if ! sed -n '/^group[0-9]*()/,/^}/p' "$0" | grep -q "$p"; then
            echo "${RED}自检失败: 头注释声称验证 $p，但没有任何测试组用到它${NC}"
            bad_claim=1
        fi
    done
    # 顺带核对「组数」这个到处写死的数字：函数定义数、默认跑的组列表、
    # 本文件头注释的用法说明必须一致。判例：曾长期写着旧的组数，
    # 与实际输出不符，让人对覆盖面产生错误印象。
    # 不再核 README——它已收窄为纯用户手册，不描述测试内部结构，
    # 这个数字只散落在本文件内部，就地锁住即可
    local n_func n_default
    n_func=$(grep -cE '^group[0-9]+\(\)' "$0")
    n_default=$(grep -oE 'TEST_GROUPS="[^"]*"' "$0" | head -1 | grep -oE '[0-9]+' | wc -l)
    if [ "$n_func" != "$n_default" ]; then
        echo "${RED}自检失败: 定义了 $n_func 个测试组，但默认只跑 $n_default 个${NC}"
        bad_claim=1
    fi
    if ! grep -q "跑全部 ${n_func} 组" "$0"; then
        echo "${RED}自检失败: 头注释的用法说明与实际 $n_func 组不一致${NC}"
        bad_claim=1
    fi

    [ "$bad_claim" = "0" ] &&
        echo "${GREEN}自检通过: 覆盖清单与组数（$n_func 组）一致${NC}"
    return $bad_claim
}
self_check || exit 1
echo ""

# ============================================================
# 容器内执行体。RUN_GROUP 决定跑哪一组
# ============================================================
read -r -d '' BODY <<'BODYEOF'
set -u
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ok   $1"; }
bad() { fail=$((fail+1)); echo "  FAIL $1"; }

# ---- 测试自身的依赖：必须套超时并检查结果 ----
# 外层用命令替换同步等待整个 docker run 结束，所以这里一挂就是整组无限挂起、
# 连 RESULT 都出不来。运行时脚本里已经为装包加了超时，测试脚本不能反而没有
export DEBIAN_FRONTEND=noninteractive
DEP_TIMEOUT=${DEP_TIMEOUT:-240}
prep_deps() {
    timeout "$DEP_TIMEOUT" apt-get update -qq >/dev/null 2>&1 ||
        echo "  警告: apt-get update 超时/失败（${DEP_TIMEOUT}s），继续尝试安装"
    # python3 供组 8 用（同一连接内的间歇传输，iperf3 做不到）
    timeout "$DEP_TIMEOUT" apt-get install -y -qq iproute2 iperf3 iputils-ping python3 >/dev/null 2>&1 ||
        echo "  警告: 依赖安装超时/失败（${DEP_TIMEOUT}s）"
    # iperf3 和 tc 是效果测试的命脉，缺任何一个都测不出吞吐，直接判失败并退出，
    # 不要在缺工具的情况下跑出一堆「吞吐为 0」的假失败去误导判断
    local miss=""
    for c in iperf3 tc ip; do command -v "$c" >/dev/null 2>&1 || miss="$miss $c"; done
    if [ -n "$miss" ]; then
        echo "  FAIL 效果测试的必备工具缺失:$miss（软件源不可达？）"
        echo "       本机无法进行效果测量，跳过全部测试组"
        echo "RESULT pass=0 fail=1"
        exit 1
    fi
}
prep_deps

# ---- 造链路 ----
# srv 侧在独立 netns，两端各加一半延迟。丢包只在发送侧加（模拟单向劣化路径）
setup_link() {
    local rtt_half=$1 loss=$2 rate=$3
    teardown_link
    ip netns add srv 2>/dev/null
    ip link add veth0 type veth peer name veth1 2>/dev/null
    ip link set veth1 netns srv
    ip addr add 10.90.0.1/24 dev veth0 2>/dev/null
    ip link set veth0 up
    ip netns exec srv ip addr add 10.90.0.2/24 dev veth1 2>/dev/null
    ip netns exec srv ip link set veth1 up
    ip netns exec srv ip link set lo up

    # netem 队列长度要按 BDP 给足，否则瓶颈变成 netem 自己的队列而不是 TCP 窗口
    local limit=$((rate * 1000 * rtt_half * 2 / 8 / 1500 * 4))
    [ "$limit" -lt 1000 ] && limit=1000
    local args="delay ${rtt_half}ms limit $limit"
    [ "$loss" != "0" ] && args="$args loss ${loss}%"
    tc qdisc add dev veth0 root netem $args 2>/dev/null
    ip netns exec srv tc qdisc add dev veth1 root netem delay "${rtt_half}ms" limit "$limit" 2>/dev/null
}

teardown_link() {
    ip netns pids srv 2>/dev/null | xargs -r kill 2>/dev/null
    ip netns del srv 2>/dev/null
    ip link del veth0 2>/dev/null
    return 0
}

start_server() {
    ip netns exec srv pkill -x iperf3 2>/dev/null
    sleep 0.3
    ip netns exec srv iperf3 -s -D >/dev/null 2>&1
    sleep 0.6
}

# 跑一次 iperf3，输出 "Kbps 重传数"。
# 单位用 Kbps 而不是 Mbps：CUBIC 在高丢包链路上只有 1.5 Mbps，
# 整数除以 1000000 会截断成 1，更低的直接变 0，导致「测量失败」误判
run_iperf() {
    local secs=$1; shift
    local out bits retr
    out=$(iperf3 -c 10.90.0.2 -t "$secs" -O 2 -J "$@" 2>/dev/null)
    [ -z "$out" ] && { echo "0 0"; return; }
    bits=$(echo "$out" | awk -F'[:,]' '/"bits_per_second"/{v=$2} END{printf "%.0f", v}')
    retr=$(echo "$out" | awk -F'[:,]' '/"retransmits"/{v=$2} END{printf "%.0f", v+0}')
    echo "$(( ${bits:-0} / 1000 )) ${retr:-0}"
}

fmt_bw() {
    local k=$1
    if [ "$k" -ge 10000 ]; then echo "$((k / 1000)) Mbps"
    else echo "$((k / 1000)).$(( (k % 1000) / 100 )) Mbps"; fi
}

# 3 次取中位数
median_iperf() {
    local secs=$1; shift
    local m1 m2 m3 r1 r2 r3 mb rt
    read -r m1 r1 <<<"$(run_iperf "$secs" "$@")"
    read -r m2 r2 <<<"$(run_iperf "$secs" "$@")"
    read -r m3 r3 <<<"$(run_iperf "$secs" "$@")"
    mb=$(printf '%s\n%s\n%s\n' "$m1" "$m2" "$m3" | sort -n | sed -n 2p)
    rt=$(printf '%s\n%s\n%s\n' "$r1" "$r2" "$r3" | sort -n | sed -n 2p)
    echo "$mb $rt"
}

# 把发行版默认值写回，作为「调优前」基线
reset_defaults() {
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 131072 6291456" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 16384 4194304" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_notsent_lowat=4294967295 >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_slow_start_after_idle=1 >/dev/null 2>&1
}

echo "=== 环境 ==="
echo "  内核: $(uname -r)"
echo "  可用算法: $(sysctl -n net.ipv4.tcp_available_congestion_control)"
echo "  net.core 可见: $([ -e /proc/sys/net/core/rmem_max ] && echo 是 || echo '否（Docker 屏蔽，见脚本头注释）')"
echo ""

# ============================================================
# 组 1: BBR vs CUBIC，有丢包的长肥链路
# 本项目最核心的主张——「Cubic 见丢包就砍速，BBR 不会」
# ============================================================
group1() {
    echo "=== 组 1: 有丢包的长肥链路，BBR vs CUBIC ==="
    echo "  链路: RTT 160ms, 丢包 1.5%"
    setup_link 80 1.5 1000
    start_server
    sysctl -w net.ipv4.tcp_rmem="4096 131072 67108864" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 16384 67108864" >/dev/null 2>&1

    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
    read -r ck crt <<<"$(median_iperf 8)"
    echo "  CUBIC : $(fmt_bw "$ck") (重传 ${crt})"
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    read -r bk brt <<<"$(median_iperf 8)"
    echo "  BBR   : $(fmt_bw "$bk") (重传 ${brt})"

    if [ "$ck" -gt 0 ] && [ "$bk" -gt 0 ]; then
        local gain ratio
        gain=$(( (bk - ck) * 100 / ck ))
        ratio=$(( bk * 10 / ck ))
        echo "  BBR 是 CUBIC 的 $((ratio / 10)).$((ratio % 10)) 倍（+${gain}%）"
        if [ "$bk" -gt "$ck" ]; then
            ok "BBR 在丢包链路上吞吐高于 CUBIC（+${gain}%）"
        else
            bad "BBR 未优于 CUBIC（${gain}%）——本项目开 BBR 的核心依据不成立"
        fi
    else
        bad "测量失败（吞吐为 0），链路或 iperf3 有问题"
    fi
}

# ============================================================
# 组 2: 无丢包纯高延迟，两者应接近
# 反向对照——BBR 的价值是「不被随机丢包误导」，不是「总是更快」。
# 若无丢包时 BBR 也大幅领先，说明组 1 的结论来自环境偏差而非抗丢包能力
# ============================================================
group2() {
    echo "=== 组 2: 无丢包纯高延迟，BBR vs CUBIC（应接近）==="
    echo "  链路: RTT 160ms, 无丢包"
    setup_link 80 0 1000
    start_server
    sysctl -w net.ipv4.tcp_rmem="4096 131072 67108864" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 16384 67108864" >/dev/null 2>&1

    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
    read -r ck _ <<<"$(median_iperf 8)"
    echo "  CUBIC : $(fmt_bw "$ck")"
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    read -r bk _ <<<"$(median_iperf 8)"
    echo "  BBR   : $(fmt_bw "$bk")"

    if [ "$ck" -gt 1000 ] && [ "$bk" -gt 1000 ]; then
        local d ratio
        d=$(( (bk - ck) * 100 / ck ))
        [ "$d" -lt 0 ] && d=$(( -d ))
        # 倍数用整十倍表示（ratio=15 即 1.5 倍），避免整数除法丢精度
        ratio=$(( bk * 10 / ck ))
        echo "  BBR/CUBIC = $((ratio / 10)).$((ratio % 10)) 倍（差异 ${d}%）"
        # 这里必须有真实阈值：本组的全部意义是「无丢包时两者应在同一量级」，
        # 只判「都 > 1Mbps 然后无条件 ok」等于没有对照——即使 BBR 高 10 倍也会通过，
        # 那样组 1 的「差距来自丢包」就失去了反证。
        # 阈值取 3 倍：组 1 实测是 70-85 倍，同量级判据放到 3 倍已经很宽松，
        # 既容得下容器内的抖动，又能真的拦住「环境本身就偏向 BBR」这种情况
        if [ "$ratio" -le 30 ]; then
            ok "无丢包时两者在同一量级（$((ratio / 10)).$((ratio % 10)) 倍 <= 3 倍），组 1 的巨大差距确实来自丢包"
        else
            bad "无丢包时 BBR 已经比 CUBIC 高 $((ratio / 10)).$((ratio % 10)) 倍（超过 3 倍阈值）——组 1 的差距不能归因于丢包，测试环境本身偏向 BBR"
        fi
    else
        bad "无丢包链路上有一侧跑不起来（CUBIC=$(fmt_bw "$ck") BBR=$(fmt_bw "$bk")），环境异常"
    fi
}

# ============================================================
# 组 3: tcp_rmem/tcp_wmem 上限对长肥网络吞吐的影响
# 直接验证「缓冲区太小导致链路跑不满」这个主张
# ============================================================
group3() {
    echo "=== 组 3: 缓冲区上限对吞吐的影响 ==="
    echo "  链路: RTT 200ms, 无丢包（1Gbps 下 BDP 约 25MB）"
    setup_link 100 0 1000
    start_server
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1

    sysctl -w net.ipv4.tcp_rmem="4096 87380 262144" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 16384 262144" >/dev/null 2>&1
    read -r sk _ <<<"$(median_iperf 8)"
    echo "  上限 256KB : $(fmt_bw "$sk")"

    sysctl -w net.ipv4.tcp_rmem="4096 131072 67108864" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 16384 67108864" >/dev/null 2>&1
    read -r gk _ <<<"$(median_iperf 8)"
    echo "  上限 64MB  : $(fmt_bw "$gk")"

    if [ "$sk" -gt 0 ]; then
        local gain ratio
        gain=$(( (gk - sk) * 100 / sk ))
        ratio=$(( gk * 10 / sk ))
        echo "  大缓冲是小缓冲的 $((ratio / 10)).$((ratio % 10)) 倍（+${gain}%）"
        if [ "$gk" -gt "$sk" ]; then
            ok "加大缓冲区上限确实提升长肥链路吞吐（+${gain}%）"
        else
            bad "加大缓冲区未提升吞吐（${gain}%）——「缓冲区太小跑不满」在此环境不成立"
        fi
    else
        bad "缓冲区对比测量失败"
    fi
}

# ============================================================
# 组 4: 端到端 —— 直接跑 tcpo 的菜单，验证「用户点一下」真有效果
# 前三组是手工设参数，这组证明脚本本身的动作有效
# ============================================================
group4() {
    echo "=== 组 4: 跑 tcpo 菜单前后的端到端对比 ==="
    echo "  链路: RTT 180ms, 丢包 1%"
    setup_link 90 1 1000
    start_server

    reset_defaults
    read -r bk brt <<<"$(median_iperf 8)"
    echo "  调优前 : $(fmt_bw "$bk") (重传 ${brt})"

    # RTT 必须显式传给脚本。脚本的 probe_rtt 探测的是 1.1.1.1/8.8.8.8 那类公网地址、
    # 走容器默认路由，跟这条 netem 造的 10.90.0.x 链路无关。
    # 不传的话本组只能证明「换了 BBR 有效」，证明不了「按本链路的 RTT 算 BDP」。
    # 传入 180ms 后即可校验 BDP 公式：1000Mbps x 125 x 180ms x 2.5 = 56.25MB，
    # 但受内存 5% 约束会被钳低，所以断言只校验「不小于按 BDP 该有的量级」
    local want_rtt=180 want_mbps=1000
    printf "2\n\n3\n${want_mbps}\n\n0\n" |
        TUNE_RTT=$want_rtt bash /usr/local/bin/tcpo >/tmp/tune.log 2>&1

    echo "  --- 脚本实际改到的值 ---"
    local k
    for k in net.ipv4.tcp_congestion_control net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_notsent_lowat; do
        printf "      %-34s = %s\n" "$k" "$(sysctl -n "$k" 2>/dev/null | tr -s ' \t' ' ')"
    done
    # 脚本自己算出的 BDP 与缓冲上限，从它的输出里抓出来对账
    grep -E 'BDP|缓冲区上限' /tmp/tune.log | sed -e 's/\x1b\[[0-9;]*m//g' | sed 's/^/      /' | head -2

    read -r ak art <<<"$(median_iperf 8)"
    echo "  调优后 : $(fmt_bw "$ak") (重传 ${art})"

    local cc wmax
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    [ "$cc" = "bbr" ] && ok "菜单执行后拥塞算法确实变成 bbr" || bad "算法仍是 $cc"

    # 校验 BDP 公式真的被用上了：脚本的输出里必须出现我们传入的 RTT
    # 日志里带 ANSI 色码，形如 "带宽: 1000 Mbps | RTT: 180 ms | BDP: 21 MB"，
    # 先去色再匹配，否则 RTT 后面夹着转义序列匹配不上
    if sed -e 's/\x1b\[[0-9;]*m//g' /tmp/tune.log | grep -qE "RTT: *${want_rtt} *ms"; then
        ok "脚本采用了传入的 RTT ${want_rtt}ms 而非默认猜测值"
    else
        bad "脚本没采用传入的 RTT ${want_rtt}ms（TUNE_RTT 未生效？）"
    fi

    # 期望缓冲 = min(BDP x 2.5, 内存 5%)，向上取整到整 MB
    local mem_kb bdp_bytes want_buf mem_cap
    mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    bdp_bytes=$((want_mbps * 125 * want_rtt))
    want_buf=$((bdp_bytes * 5 / 2))
    mem_cap=$((mem_kb * 5 / 100 * 1024))
    [ "$want_buf" -gt "$mem_cap" ] && want_buf=$mem_cap
    want_buf=$(((want_buf + 1048575) / 1048576 * 1048576))
    echo "      期望缓冲上限（BDP $((bdp_bytes / 1048576))MB x2.5 受内存钳位后）= $((want_buf / 1048576))MB"

    wmax=$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null | awk '{print $3}')
    if [ "${wmax:-0}" -eq "$want_buf" ]; then
        ok "tcp_wmem 上限 $((wmax / 1048576))MB 与按 BDP 公式算出的期望值完全一致"
    elif [ "${wmax:-0}" -gt 8388608 ]; then
        bad "tcp_wmem 上限 $((wmax / 1048576))MB 与期望 $((want_buf / 1048576))MB 不符（BDP 公式或钳位逻辑有变）"
    else
        bad "tcp_wmem 上限仍是 $((${wmax:-0} / 1024 / 1024))MB，未按 BDP 抬高"
    fi

    if [ "$bk" -gt 0 ]; then
        local gain ratio
        gain=$(( (ak - bk) * 100 / bk ))
        ratio=$(( ak * 10 / bk ))
        echo "  调优后是调优前的 $((ratio / 10)).$((ratio % 10)) 倍（+${gain}%）"
        if [ "$ak" -ge "$bk" ]; then
            ok "端到端：跑完菜单后吞吐不低于调优前（+${gain}%）"
        else
            bad "端到端：跑完菜单后吞吐下降 ${gain}%——调优是负优化"
        fi
    else
        bad "端到端基线测量失败"
    fi
}

# ============================================================
# 组 5: 诊断结论是否与真实链路状况一致
# 人为注入 5% 丢包，诊断必须报出来。
# 重点验「近期窗口」而非累计值——累计值会被历史流量稀释
# ============================================================
group5() {
    echo "=== 组 5: 诊断结论与真实链路状况是否一致 ==="
    echo "  造 5% 丢包链路，诊断应报出丢包"
    setup_link 80 5 1000
    start_server
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 16384 67108864" >/dev/null 2>&1

    # 诊断会做 5 秒窗口采样，必须在采样期间有真实流量，否则只能退回累计值
    iperf3 -c 10.90.0.2 -t 45 -O 1 >/dev/null 2>&1 &
    local bg=$!
    sleep 4
    local diag
    diag=$(printf "8\n\n0\n" | bash /usr/local/bin/tcpo 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g')
    kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null

    echo "$diag" | grep -E '累计重传率|近期重传率|=>' | head -5 | sed 's/^/      /'

    echo "$diag" | grep -q '累计重传率' && ok "诊断读到了累计重传率" || bad "诊断未能读出累计重传率"

    # 容器里累计值会被回环/历史流量稀释（实测 5% 注入只显示 0.47%），
    # 所以必须有近期窗口值，结论要按窗口值给
    if echo "$diag" | grep -q '近期重传率'; then
        ok "诊断做了近期窗口采样（不只看开机以来的累计值）"
    else
        bad "诊断没有近期窗口采样，长期运行的机器上累计值会被稀释成看不出问题"
    fi

    if echo "$diag" | grep -qE '超过 2%|0\.5%-2%|跨境常态|丢包受限'; then
        ok "诊断在 5% 丢包链路上给出了丢包相关结论"
    else
        bad "诊断未识别出丢包（人为注入 5% 却报线路干净）"
    fi
}

# ============================================================
# 组 6: 菜单 a（效果测量）能否读到真实流量增量
# 它声称取时间窗增量而非开机累计值，验证有流量时读到非零
# ============================================================
group6() {
    echo "=== 组 6: 效果测量能否读到真实流量增量 ==="
    setup_link 50 0 1000
    start_server
    iperf3 -c 10.90.0.2 -t 30 -O 1 >/dev/null 2>&1 &
    local bg=$!
    sleep 2
    local meas
    meas=$(printf "a\n\n6\n\n0\n" | bash /usr/local/bin/tcpo 2>&1 | sed -e 's/\x1b\[[0-9;]*m//g')
    kill "$bg" 2>/dev/null; wait "$bg" 2>/dev/null

    echo "$meas" | grep -E 'TcpOutSegs|tx_bytes|rx_bytes|retrans_rate' | head -5 | sed 's/^/      /'
    local seg
    seg=$(echo "$meas" | awk '/TcpOutSegs/{print $2; exit}')
    if [ -n "$seg" ] && [ "${seg:-0}" -gt 100 ]; then
        ok "测量读到窗口内 TcpOutSegs 增量 ${seg}（确实在测真实流量）"
    else
        bad "测量未读到有效流量增量（TcpOutSegs=${seg:-空}）"
    fi
    echo "$meas" | grep -q 'tx_bytes' && ok "测量输出了网卡字节增量" || bad "测量未输出网卡字节增量"
}

# ============================================================
# 组 7: notsent_lowat 与端到端参数组合不会造成负优化
# 本项目把 notsent_lowat 设成 131072（而非社区常见的 16384），
# 验证这个取值在长肥链路上不损失吞吐
# ============================================================
group7() {
    echo "=== 组 7: tcp_notsent_lowat 取值对长肥链路吞吐的影响 ==="
    echo "  链路: RTT 200ms, 无丢包"
    setup_link 100 0 1000
    start_server
    sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 131072 67108864" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 16384 67108864" >/dev/null 2>&1

    sysctl -w net.ipv4.tcp_notsent_lowat=16384 >/dev/null 2>&1
    read -r lo _ <<<"$(median_iperf 8)"
    echo "  notsent_lowat 16K (社区常见值) : $(fmt_bw "$lo")"
    sysctl -w net.ipv4.tcp_notsent_lowat=131072 >/dev/null 2>&1
    read -r hi _ <<<"$(median_iperf 8)"
    echo "  notsent_lowat 128K (本项目取值): $(fmt_bw "$hi")"

    if [ "$lo" -gt 0 ] && [ "$hi" -gt 0 ]; then
        local d
        d=$(( (hi - lo) * 100 / lo ))
        echo "  128K 相对 16K: ${d}%"
        # iperf3 是单流大文件传输，notsent_lowat 的差异主要体现在多流交互场景，
        # 这里只要 128K 不明显更差就算通过（不低于 16K 的 85%）
        if [ "$hi" -ge $(( lo * 85 / 100 )) ]; then
            ok "128K 取值未损失吞吐（${d}%，本项目选它是为高 RTT 下减少写侧空隙）"
        else
            bad "128K 比 16K 低 $(( -d ))%，本项目的取值在此场景是负优化"
        fi
    else
        bad "notsent_lowat 对比测量失败"
    fi
}

# ============================================================
# 组 8: slow_start_after_idle=0 对空闲后恢复速度的影响
# 本项目设这一项的理由是「长连接空闲后不退回慢启动」（对 SSE / 长轮询 /
# 视频流有效），这组给它实测支撑。
#
# iperf3 测不了这个：它每次都是新建连接，根本没有「空闲」状态。
# 必须在同一条连接里造出「传输 → 静默 → 再传输」，并且只测第二段的头 1.5 秒——
# 慢启动的影响集中在重启后的头几个 RTT，测太久会被后面爬满的部分稀释掉
# ============================================================
group8() {
    echo "=== 组 8: slow_start_after_idle 对空闲后恢复速度的影响 ==="
    echo "  链路: RTT 200ms（空闲后重新爬窗代价大）"
    if ! command -v python3 >/dev/null 2>&1; then
        timeout "${DEP_TIMEOUT:-240}" apt-get install -y -qq python3 >/dev/null 2>&1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        bad "缺 python3，无法做同一连接内的间歇传输测量"
        return
    fi

    setup_link 100 0 1000
    sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_rmem="4096 131072 67108864" >/dev/null 2>&1
    sysctl -w net.ipv4.tcp_wmem="4096 16384 67108864" >/dev/null 2>&1

    cat >/tmp/idle_srv.py <<'PYEOF'
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("10.90.0.2", 5999)); s.listen(5)
while True:
    c, _ = s.accept()
    try:
        while c.recv(1 << 20): pass
    except Exception: pass
    c.close()
PYEOF
    cat >/tmp/idle_cli.py <<'PYEOF'
import socket, time, sys
# 同一连接内: 发 4 秒把 cwnd 爬起来 -> 静默 idle 秒 -> 再发 1.5 秒并测这段吞吐
idle = float(sys.argv[1])
c = socket.create_connection(("10.90.0.2", 5999))
c.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
buf = b"x" * (1 << 16)
def burst(dur):
    n = 0; t0 = time.time()
    while time.time() - t0 < dur:
        n += c.send(buf)
    return n * 8 / (time.time() - t0) / 1e6
burst(4.0)
time.sleep(idle)
mbps = burst(1.5)
c.close()
print("%.1f" % mbps)
PYEOF

    ip netns exec srv python3 /tmp/idle_srv.py >/dev/null 2>&1 &
    local srv_pid=$!
    sleep 1

    # 5 次取中位数：这个测量比 iperf3 抖，样本要多一点
    probe_idle() {
        local vals="" i v
        for i in 1 2 3 4 5; do
            v=$(timeout 30 python3 /tmp/idle_cli.py 8 2>/dev/null)
            case "$v" in '' | *[!0-9.]*) v=0 ;; esac
            vals="$vals $v"
        done
        # 用整数 Kbps 排序，避免 sort -n 处理小数在不同 locale 下的差异
        echo "$vals" | tr ' ' '\n' | grep -v '^$' |
            awk '{printf "%d\n", $1 * 1000}' | sort -n | sed -n 3p
    }

    local on off
    sysctl -w net.ipv4.tcp_slow_start_after_idle=1 >/dev/null 2>&1
    on=$(probe_idle)
    echo "  slow_start_after_idle=1 (内核默认) : $(fmt_bw "${on:-0}")"
    sysctl -w net.ipv4.tcp_slow_start_after_idle=0 >/dev/null 2>&1
    off=$(probe_idle)
    echo "  slow_start_after_idle=0 (本项目值) : $(fmt_bw "${off:-0}")"

    kill "$srv_pid" 2>/dev/null
    ip netns pids srv 2>/dev/null | xargs -r kill 2>/dev/null

    if [ "${on:-0}" -gt 1000 ] && [ "${off:-0}" -gt 1000 ]; then
        local gain ratio
        gain=$(( (off - on) * 100 / on ))
        ratio=$(( off * 10 / on ))
        echo "  设 0 是设 1 的 $((ratio / 10)).$((ratio % 10)) 倍（+${gain}%）"
        if [ "$off" -gt "$on" ]; then
            ok "slow_start_after_idle=0 让空闲后恢复更快（+${gain}%），本项目设 0 有实测支撑"
        else
            bad "设 0 未带来改善（${gain}%）——本项目设这一项的依据在此场景不成立"
        fi
    else
        bad "空闲恢复测量失败（ssai=1: ${on:-0} Kbps, ssai=0: ${off:-0} Kbps）"
    fi
}

for g in ${RUN_GROUP:-1}; do
    case "$g" in
    1) group1 ;; 2) group2 ;; 3) group3 ;; 4) group4 ;;
    5) group5 ;; 6) group6 ;; 7) group7 ;; 8) group8 ;;
    esac
    echo ""
done

teardown_link
echo "RESULT pass=$pass fail=$fail"
BODYEOF

# ============================================================
# 主循环：每组一个容器
# ============================================================
total_pass=0; total_fail=0; overall=0
# 单组容器的墙钟上限。容器内的 apt 已有自己的超时，这一层兜住「容器整体卡住」
# （镜像拉取慢、docker 守护进程异常、netem 把链路搞死导致 iperf3 不返回）。
# 外层是命令替换同步等待，没有这层就是无限挂起、连 RESULT 都出不来
GROUP_TIMEOUT=${GROUP_TIMEOUT:-900}
declare -A GRES
for g in $TEST_GROUPS; do
    cname="tcpdash-eff-$g-$$"
    log=$(MSYS_NO_PATHCONV=1 timeout --kill-after=30 "$GROUP_TIMEOUT" \
        docker run --rm --privileged --name "$cname" \
        -v "$(pwd -W 2>/dev/null || pwd):/work" \
        -e RUN_GROUP="$g" \
        -e DEP_TIMEOUT="${DEP_TIMEOUT:-240}" \
        "$IMAGE" bash -c "
            cp /work/tcpo /usr/local/bin/tcpo && chmod +x /usr/local/bin/tcpo
            bash -s <<'OUTEREOF'
$BODY
OUTEREOF
        " 2>&1)
    rc=$?
    # timeout 杀掉的是 docker CLI，容器本身还在跑，必须显式清掉否则占着资源和名字
    if [ "$rc" -ge 124 ]; then
        docker rm -f "$cname" >/dev/null 2>&1
        echo "${RED}组 $g 超时（${GROUP_TIMEOUT}s）已强制终止，容器已清理${NC}"
    fi
    echo "$log" | sed -e 's/\x1b\[[0-9;]*m//g' | grep -vE '^=== 环境|^  内核:|^  可用算法:|^  net.core 可见:'
    line=$(echo "$log" | grep -oE 'RESULT pass=[0-9]+ fail=[0-9]+' | tail -1)
    if [ -z "$line" ]; then
        if [ "$rc" -ge 124 ]; then
            GRES["$g"]="${RED}超时未跑完${NC}"
        else
            GRES["$g"]="${RED}未跑完（exit=$rc）${NC}"
        fi
        overall=1
    else
        p=${line#RESULT pass=}; p=${p%% *}; f=${line##*fail=}
        total_pass=$((total_pass + p)); total_fail=$((total_fail + f))
        if [ "$f" = "0" ]; then GRES["$g"]="${GREEN}通过 ($p)${NC}"
        else GRES["$g"]="${RED}失败 $f (通过 $p)${NC}"; overall=1; fi
    fi
done

echo "${YELLOW}==================== 效果测试汇总 ====================${NC}"
for g in $TEST_GROUPS; do printf "  组 %-3s %s\n" "$g" "${GRES["$g"]:-未执行}"; done
echo "  合计: 通过 $total_pass，失败 $total_fail"
exit $overall
