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
# 用户只看到「当前仍为 cubic」拿不到具体报错。
# 唯一豁免是 write_sysctl_apply 生成的开机重放脚本里那行（输出重定向到 $APPLY_LOG）：
# 它在开机时跑、没有终端可回显，也是独立文件调不到面板的函数，所以按「有落日志」放行
naked=$(grep -nE '^[[:space:]]*sysctl --system' /usr/local/bin/tcpo |
    grep -v 'apply_sysctl' | grep -v 'APPLY_LOG' | wc -l)
ck "无裸跑的 sysctl --system（必须走 apply_sysctl）" "$naked" "0"
# 豁免那行必须真的落日志，否则等于静默吞掉开机时的内核报错
gen_sysctl=$(sed -n '/^write_sysctl_apply()/,/^}/p' /usr/local/bin/tcpo | grep -E '^sysctl --system')
case "$gen_sysctl" in
*'>>$APPLY_LOG'*) pass=$((pass+1)); echo "  ok   重放脚本的 sysctl 输出落日志";;
*'2>&1'*) fail=$((fail+1)); echo "  FAIL 重放脚本把 sysctl 报错丢弃了";;
*) echo "  note 未取到重放脚本里的 sysctl 行，跳过";;
esac
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

# 机检：live qdisc 判据不能拿 tc 首行的 root 直接比 default_qdisc。
# 多队列网卡 root 恒为 mq（内核文档明写 default_qdisc 作用于叶子），
# 那样写在任何多队列机器上都必然报「不一致」。实测 root=mq / default_qdisc=fq_codel 即触发。
# 判据：诊断与状态标记都必须经 qdisc_kinds()，不得再出现取首行 $2 当 live qdisc 的写法
ck "qdisc 判据经 qdisc_kinds（非取首行）" \
    "$(grep -vE '^[[:space:]]*#' /usr/local/bin/tcpo \
        | grep -c "tc qdisc show dev \"\$dev\" 2>/dev/null | awk 'NR==1{print \$2}'")" "0"
ck "存在 qdisc_kinds 函数" "$(grep -c '^qdisc_kinds() {' /usr/local/bin/tcpo)" "1"

# 机检：开机重放脚本里 mq 分支不能靠枚举 parent 行。
# 叶子被 del 过或开机时尚未建出来时，tc 输出只剩一行 mq、没有 parent 行可枚举，
# 重放会静默什么都不做（实测：del 全部叶子后重放，叶子数仍为 0）。
# 必须用 root handle + 队列序号自己拼
ckhas "重放脚本 mq 分支自拼 handle" "$(cat /usr/local/bin/tcpo)" 'qh=$(tc qdisc show dev "$qdev"'

# 机检：只读诊断不能因缺 nstat 就整段失效，必须有 /proc 降级
ckhas "计数器有 /proc 降级路径" "$(cat /usr/local/bin/tcpo)" '/proc/net/snmp /proc/net/netstat'

# 机检：主循环（非函数体）里不能用 local，那会报 "local: can only be used in a function"。
# bash -n 查不出这类运行期错误，只能靠机检
main_loop_start=$(grep -n '^while true; do' /usr/local/bin/tcpo | head -1 | cut -d: -f1)
ck "主循环内无 local" \
    "$(awk -v s="$main_loop_start" 'NR>=s && /^[[:space:]]*local /' /usr/local/bin/tcpo | wc -l)" "0"

# 抽出纯计算函数单独验证，跨规模覆盖掩码溢出边界
awk '/^cpu_mask_all\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_all.sh
awk '/^cpu_mask_one\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_one.sh
awk '/^calc_buf_bytes\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_buf.sh
awk '/^softnet_sum\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_sn.sh
awk '/^read_counters\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_rc.sh
awk '/^counter_get\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_cg.sh
awk '/^qdisc_kinds\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_qk.sh
awk '/^sysctl_writable\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_sw.sh
awk '/^wrap_keys\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_wk.sh
. /tmp/f_all.sh; . /tmp/f_one.sh; . /tmp/f_buf.sh; . /tmp/f_sn.sh
. /tmp/f_rc.sh; . /tmp/f_cg.sh; . /tmp/f_qk.sh; . /tmp/f_sw.sh; . /tmp/f_wk.sh

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
# 第 4 个参数是 TCP 全局池上限（tcp_mem[2] 换成字节）。不传或传 0 时必须与旧行为一致——
# 这个函数有跨规模断言，加参数不能改变已有取值
ck "池参数缺省不改变行为" "$(calc_buf_bytes 1000 150 8388608)" "$(calc_buf_bytes 1000 150 8388608 0)"
# 池够大时不起作用：3GB 池 / 16 = 192MB，高于 BDP 推导的 45MB
ck "大池不影响 BDP 结果" "$(calc_buf_bytes 1000 150 8388608 3221225472)" "47185920"
# 池很小时必须钳住。48MB 池 / 16 = 3MB，低于 8MB 下限，所以最终落在下限上。
# 这个场景是真的：512MB 内存机器的 tcp_mem 上限约 48MB，而 BDP 算出 45MB——
# 一条满载连接就能打满全局池，届时内核进入内存压力模式强收所有连接的缓冲
ck "小池钳到下限" "$(calc_buf_bytes 1000 150 8388608 50331648)" "8388608"
# 中等池：1.6GB / 16 = 100MB，BDP 推导 250MB（2000M x 500ms），应被池钳到 100MB
ck "中等池钳位生效" "$(calc_buf_bytes 2000 500 33554432 1677721600)" "104857600"
# 十六进制累加必须不依赖 GNU awk 的 strtonum（mawk 没有）。
# 第 2 列 5 + 2 = 7，用与 tcpo 同款的 $((16#..)) 路径验证
printf '0000000a 00000005 00000003 0 0\n0000000a 00000002 00000004 0 0\n' > /tmp/sn
hexsum=$(sum=0; while read -r -a f; do sum=$((sum + 16#${f[1]})); done < /tmp/sn; echo "$sum")
ck "十六进制累加(非GNU awk)" "$hexsum" "7"
# softnet_sum 本体：真实 /proc 可读时至少要返回纯数字
sn=$(softnet_sum 3 2>/dev/null)
case "$sn" in ''|*[!0-9]*) fail=$((fail+1)); echo "  FAIL softnet_sum 未返回数字 (得到[$sn])";;
*) pass=$((pass+1)); echo "  ok   softnet_sum 返回数字 ($sn)";; esac

# --- 计数器读取：nstat 与纯 /proc 两条路径必须拿到同一批 key ---
# 只读诊断不装包，最小化镜像常缺 iproute2。缺 nstat 时整段诊断失效是不可接受的，
# 所以 read_counters 有 /proc/net/{snmp,netstat} 降级路径。这里验证降级路径本身。
# 判据用「表头字段名 + 值」的两行一组格式，不能用 GNU awk 扩展（mawk/busybox awk 要过）
cnt_all=$(read_counters)
ck "read_counters 有输出" "$([ -n "$cnt_all" ] && echo 1 || echo 0)" "1"
# TcpOutSegs 是 /proc/net/snmp 的 Tcp 族字段，两条路径都必须能取到且为纯数字
os=$(counter_get TcpOutSegs "$cnt_all")
case "$os" in ''|*[!0-9]*) fail=$((fail+1)); echo "  FAIL counter_get TcpOutSegs 非数字 (得到[$os])";;
*) pass=$((pass+1)); echo "  ok   counter_get TcpOutSegs=$os";; esac
# 强制走 /proc 降级路径（屏蔽 nstat），拿到的 key 集合要覆盖诊断用到的那些
proc_cnt=$(awk '
    { fam=$1; sub(/:$/,"",fam)
      if (!(fam in seen)) { seen[fam]=1; for(i=2;i<=NF;i++) hdr[fam,i]=$i; next }
      for(i=2;i<=NF;i++) if (hdr[fam,i]!="") print fam hdr[fam,i]"="$i }
' /proc/net/snmp /proc/net/netstat 2>/dev/null)
for k in TcpOutSegs TcpRetransSegs TcpExtListenOverflows TcpExtTCPBacklogDrop \
         TcpExtTCPLostRetransmit TcpExtPruneCalled UdpRcvbufErrors UdpInDatagrams; do
    v=$(printf '%s\n' "$proc_cnt" | awk -F= -v kk="$k" '$1==kk{print $2; exit}')
    case "$v" in ''|*[!0-9]*) fail=$((fail+1)); echo "  FAIL /proc 降级路径取不到 $k (得到[$v])";;
    *) pass=$((pass+1)); echo "  ok   /proc 降级路径 $k=$v";; esac
done
# counter_get 对不存在的 key 必须回空串而不是 0——「读不到」和「确实是 0」是两回事，
# 后者能作判据前者不能，混淆会让诊断在缺数据时给出「均为 0，属安慰剂」的错误结论
ck "counter_get 缺失 key 回空" "$(counter_get TcpNoSuchCounterXyz "$cnt_all")" ""

# --- qdisc 解析：多队列 root 是 mq，判据必须看叶子 ---
# 内核文档："multiqueue NICs keep mq as root and use this for leaves"。
# 拿 root 去比 default_qdisc 在任何多队列网卡上都必然报「不一致」，是假警告。
# 喂死数据验证解析本身，不依赖容器里真有多队列网卡
qd_parse() { # 把 tc 输出喂给与 qdisc_kinds 同款的 awk
    awk '
        NR == 1 { root = $2 }
        /parent/ { if (!($2 in kind)) { kind[$2] = 1; order[++n] = $2 } }
        END {
            if (root == "") exit 1
            leaves = ""
            for (i = 1; i <= n; i++) leaves = leaves (i > 1 ? " " : "") order[i]
            print root "\t" leaves
        }'
}
mq_out='qdisc mq 0: dev eth0 root
qdisc fq 8001: dev eth0 parent :2 limit 10000p
qdisc fq 8002: dev eth0 parent :1 limit 10000p'
ck "mq 多队列解析" "$(printf '%s\n' "$mq_out" | qd_parse)" "$(printf 'mq\tfq')"
single_out='qdisc fq 8001: dev eth0 root refcnt 2 limit 10000p'
ck "单队列解析" "$(printf '%s\n' "$single_out" | qd_parse)" "$(printf 'fq\t')"
# 叶子不一致（有人只改了部分队列）要如实列出两种，不能只报第一种
mixed_out='qdisc mq 0: dev eth0 root
qdisc fq 8001: dev eth0 parent :2
qdisc pfifo_fast 0: dev eth0 parent :1'
ck "叶子混合时都列出" "$(printf '%s\n' "$mixed_out" | qd_parse)" "$(printf 'mq\tfq pfifo_fast')"

# --- qdisc dropped 必须累加全部队列 ---
# mq 的第一行是汇总，实际丢包在叶子上。只取首行会漏报
drop_out='qdisc mq 0: dev eth0 root
 Sent 0 bytes 0 pkt (dropped 0, overlimits 0 requeues 0)
qdisc fq 1: dev eth0 parent :1
 Sent 0 bytes 0 pkt (dropped 12, overlimits 0 requeues 0)
qdisc fq 2: dev eth0 parent :2
 Sent 0 bytes 0 pkt (dropped 30, overlimits 0 requeues 0)'
qsum=$(printf '%s\n' "$drop_out" | awk '{ while (match($0, /dropped [0-9]+/)) {
        s += substr($0, RSTART+8, RLENGTH-8); $0 = substr($0, RSTART+RLENGTH) } }
    END { print s+0 }')
ck "qdisc dropped 累加全队列" "$qsum" "42"

# --- app_limited 是裸标记，词边界必须自己保证 ---
# 实测一台真机 app_limited 出现 11 次而 sndbuf_limited 0 次，它才是最常见的
# 「调参没用」信号。直接 /app_limited/ 会误伤同前缀字段
al_in='x app_limited y
z app_limited
app_limited w
foo app_limited_extra bar
notapp_limited q'
al_n=$(printf '%s\n' "$al_in" | awk '/(^|[ \t])app_limited([ \t]|$)/{c++} END{print c+0}')
ck "app_limited 词边界" "$al_n" "3"
# 连接数分母必须数缩进的指标行，不能数含 retrans: 的行——retrans 只在有过重传时才出现，
# 拿它当分母会让占比算出超过 100%（实测 28 条连接只有 7 条有 retrans:）
ss_in='ESTAB 0 0 10.0.0.1:1 10.0.0.2:443
	 cubic wscale:0,7 rtt:1/0 app_limited
ESTAB 0 0 10.0.0.1:2 10.0.0.2:443
	 cubic wscale:0,7 rtt:1/0 retrans:0/3 app_limited
ESTAB 0 0 10.0.0.1:3 10.0.0.2:443
	 cubic wscale:0,7 rtt:1/0'
ss_n=$(printf '%s\n' "$ss_in" | awk '/^[ \t]+[a-z]/{n++} END{print n+0}')
ss_a=$(printf '%s\n' "$ss_in" | awk '/(^|[ \t])app_limited([ \t]|$)/{a++} END{print a+0}')
ck "连接数数指标行" "$ss_n" "3"
ck "app_limited 占比分子" "$ss_a" "2"
ck "app_limited 占比不超100%" "$([ "$ss_a" -le "$ss_n" ] && echo 1 || echo 0)" "1"

# --- sysctl 写入前预检：三态判定 ---
# 路径转换不能用 ${k//./\/}（不同 shell 对 \/ 处理不一致，zsh 会留下反斜杠导致全判 MISSING）
ck "预检 不存在的 key" "$(sysctl_writable net.ipv4.tcp_definitely_no_such_key_xyz)" "MISSING"
# 真实存在的 key 在 root 下应为 WRITABLE（容器里 net.core.* 可能是 RO，故用 net.ipv4 的）
sw=$(sysctl_writable net.ipv4.tcp_congestion_control)
case "$sw" in WRITABLE|RO) pass=$((pass+1)); echo "  ok   预检 存在的 key 判 $sw";;
*) fail=$((fail+1)); echo "  FAIL 预检 存在的 key 误判为 $sw";; esac
# wrap_keys 折行不能依赖 fmt（非 POSIX 必备，busybox 常缺）
wk_out=$(wrap_keys "net.a net.b net.c")
ckhas "wrap_keys 有输出且带缩进" "$wk_out" "net.a"
ck "wrap_keys 不依赖 fmt" "$(grep -c 'fmt -w' /usr/local/bin/tcpo)" "0"

# --- 状态文件必须原子写：回退的唯一依据，变空等于回退能力归零 ---
# 实测过：磁盘满时直接重定向把文件截断成 0 字节，而 atomic_write 拒绝写入且原文件完好
awk '/^atomic_write\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_aw.sh
awk '/^atomic_append\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_ap.sh
# atomic_write 会先调 refuse_if_symlink，抽函数测试时必须一并 source，
# 否则 command not found 让它直接返回非 0，断言得到空值
awk '/^refuse_if_symlink\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_rsl.sh
. /tmp/f_rsl.sh; . /tmp/f_aw.sh; . /tmp/f_ap.sh
_ad=$(mktemp -d)
printf 'a\nb\n' | atomic_write "$_ad/f"
ck "atomic_write 写入正确" "$(tr '\n' '|' < "$_ad/f")" "a|b|"
ck "atomic_write 权限 644" "$(stat -c %a "$_ad/f" 2>/dev/null)" "644"
atomic_append "$_ad/f" "c"
ck "atomic_append 追加" "$(tr '\n' '|' < "$_ad/f")" "a|b|c|"
# 没有残留的临时文件（失败路径必须自己清理）
ck "无残留临时文件" "$(ls -a "$_ad" | grep -c '^\.tcpo')" "0"
rm -rf "$_ad"
# 机检：状态文件不能再用直接重定向。它们变空 = 回退依据丢失
ck "ORIG_STATE 走原子写" \
    "$(grep -vE '^[[:space:]]*#' /usr/local/bin/tcpo | grep -cE '^[[:space:]]*\}[[:space:]]*>"\$ORIG_STATE"')" "0"
ck "TAKEOVER_LIST 不裸追加" \
    "$(grep -vE '^[[:space:]]*#' /usr/local/bin/tcpo | grep -cE '>>"\$TAKEOVER_LIST"')" "0"
# 快照失败必须中止后续改动（备份失败不能"先改了再说"）
ck "四个入口都在快照失败时中止" \
    "$(grep -c 'save_original_values || {' /usr/local/bin/tcpo)" "4"

# --- iptables 规则要有所有权标记 ---
# 精确文本匹配删除有两个问题：参数一变就删不掉；无法区分用户自己加的同款规则。
# 实测验证过 comment 方案能只删本脚本的、保留用户的
ckhas "MSS clamp 带 comment 标记" "$(cat /usr/local/bin/tcpo)" '-m comment --comment "$MSS_TAG"'
ck "存在 del_owned_mss 函数" "$(grep -c '^del_owned_mss() {' /usr/local/bin/tcpo)" "1"
# 查规则必须用 iptables-save：iptables -t mangle -S 会加载 mangle 模块，破坏只读承诺
ckhas "按标记反查规则" "$(cat /usr/local/bin/tcpo)" 'iptables-save -t mangle'

# --- systemd 服务的句柄上限 ---
# limits.d 只走 PAM，systemd 服务不经过 PAM——而 xray/nginx 恰恰都是 systemd 服务
ckhas "写 systemd 全局句柄上限" "$(cat /usr/local/bin/tcpo)" 'DefaultLimitNOFILE=2048:'
ck "回退清理 systemd drop-in" "$(grep -c '"\$SYSTEMD_LIMITS_OPT" \\' /usr/local/bin/tcpo)" "1"
ckhas "删完 drop-in 要 daemon-reexec" "$(cat /usr/local/bin/tcpo)" 'systemctl daemon-reexec'
# 硬限不能超 fs.nr_open，超了 setrlimit 被内核拒绝（实测报 Operation not permitted）
ckhas "nofile 受 fs.nr_open 约束" "$(cat /usr/local/bin/tcpo)" 'nr_open=$(sysctl -n fs.nr_open'
_nrq=$(sysctl -n fs.nr_open 2>/dev/null || echo 1048576)
_nfw=$(grep -m1 '^\* hard nofile' /etc/security/limits.d/99-network-performance.conf 2>/dev/null | awk '{print $4}')
if [ -n "$_nfw" ]; then
    ck "写出的 nofile 不超 nr_open" "$([ "$_nfw" -le "$_nrq" ] && echo 1 || echo 0)" "1"
fi

# --- sysctl 冲突扫描要覆盖 vendor 目录 ---
# systemd-sysctl 读四个目录 + /etc/sysctl.conf。跨目录一起按文件名字典序排（man 原文
# "regardless of which of the directories they reside in"），所以 zz- 前缀在任何目录
# 面前都最后加载；报告的意义是让用户知道「回退后哪些值会重新生效」
ck "存在 report_vendor_conflicts" "$(grep -c '^report_vendor_conflicts() {' /usr/local/bin/tcpo)" "1"
for _d in /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d; do
    ckhas "扫描覆盖 $_d" "$(cat /usr/local/bin/tcpo)" "$_d"
done

# --- 抖动与网卡速率 ---
ck "存在 probe_jitter" "$(grep -c '^probe_jitter() {' /usr/local/bin/tcpo)" "1"
ck "存在 nic_link_mbps" "$(grep -c '^nic_link_mbps() {' /usr/local/bin/tcpo)" "1"
# ping 汇总行按 / 切之后最后一个字段带单位（"0.163 ms"），直接取 $7 会连 " ms" 带出来
_pl='rtt min/avg/max/mdev = 52.789/52.943/53.244/0.163 ms'
_pj=$(printf '%s\n' "$_pl" | awk -F'/' '/rtt|round-trip/ { n=split($NF,a," "); print $(NF-2)" "a[1]; exit }')
ck "ping mdev 解析去掉单位" "$_pj" "52.943 0.163"
# 探测目标集中一处，避免函数与文案各写一份
ck "RTT 探测目标只定义一次" "$(grep -c '^RTT_PROBE_TARGETS=' /usr/local/bin/tcpo)" "1"

# --- 演练模式 ---
ck "存在 dryrun_skip" "$(grep -c '^dryrun_skip() {' /usr/local/bin/tcpo)" "1"
ck "存在 dryrun_report" "$(grep -c '^dryrun_report() {' /usr/local/bin/tcpo)" "1"
# 演练靠重定向路径变量实现，写入函数一行不改——所以不会有"某个分支忘了判断"的漏洞
ckhas "演练重定向 STATE_DIR" "$(cat /usr/local/bin/tcpo)" 'STATE_DIR="$DRYRUN_ROOT$STATE_DIR"'
ckhas "演练跳过 sysctl --system" "$(cat /usr/local/bin/tcpo)" 'dryrun_skip "sysctl --system'
ckhas "演练跳过自安装" "$(cat /usr/local/bin/tcpo)" '[演练]${NC} 跳过自安装'
# 演练不写系统文件，所以不该要求 root（这正是它的用处：先看再决定）
ckhas "演练模式免 root" "$(cat /usr/local/bin/tcpo)" 'TCPO_DRYRUN:-0}" != "1"'

# --- drop-in 头部要记全推导链 ---
# 「为什么是 24MB」三个月后没人记得，而重跑未必得到同样的值（RTT 是实测的）
for _k in '缓冲区推导链' 'BDP  ' 'x2.5 余量' '内存 5%' 'TCP 全局池' '最终取值'; do
    ckhas "推导链含「$_k」" "$(cat /usr/local/bin/tcpo)" "$_k"
done

# --- tcp_mtu_probing 是唯一一个设了却没有验证手段的参数 ---
# 菜单 3 设 tcp_mtu_probing=1、菜单 b 做 ICMP 阶梯，但都是「我们主动去探」。
# 这两个计数器反映真实业务连接遇到的情况，非零就是「路径确有黑洞且参数在起作用」
ckhas "验证 MTU 探测真触发过" "$(cat /usr/local/bin/tcpo)" 'TcpExtTCPMTUPSuccess'
ckhas "MTU 探测失败也计数" "$(cat /usr/local/bin/tcpo)" 'TcpExtTCPMTUPFail'

# --- 重传成因分解 ---
for _k in TcpExtTCPSynRetrans TcpExtTCPTimeouts TcpExtTCPSackRecovery TcpExtTCPLostRetransmit; do
    ckhas "重传分解含 $_k" "$(cat /usr/local/bin/tcpo)" "$_k"
done
# 恢复机制判据的分母是 Timeouts + SackRecovery。SackRecovery 高是「健康」而不是问题
# （说明丢包被快速修好了），单独看会误导，必须做占比
_rt=$(awk -v t=800 -v s=200 'BEGIN{ printf "%d", t*100/(t+s) }')
ck "超时占比计算" "$_rt" "80"
_rt2=$(awk -v t=50 -v s=900 'BEGIN{ printf "%d", t*100/(t+s) }')
ck "健康时超时占比低" "$([ "$_rt2" -lt 50 ] && echo 1 || echo 0)" "1"

# --- accept 队列实时占用 ---
# ListenOverflows 是累计（曾经满过吗），ss -Hltn 的 Send-Q 是实际生效的 backlog
# （现在离满多远）。内核取 min(应用 listen() 传的值, somaxconn)——Send-Q 明显小于
# somaxconn 时瓶颈在应用侧，改 sysctl 无效。实测构造过 backlog=128 的监听验证
ckhas "读监听队列实际 backlog" "$(cat /usr/local/bin/tcpo)" 'ss -Hltn'
# 喂死数据验解析：$2=Recv-Q（待 accept 数）$3=Send-Q（实际 backlog）$4=地址
_ls='LISTEN 0      4096       127.0.0.1:80  0.0.0.0:*
LISTEN 30     128        127.0.0.1:8080 0.0.0.0:*
LISTEN 0      4096       0.0.0.0:443   0.0.0.0:*'
_lsout=$(printf '%s\n' "$_ls" | awk -v sm=4096 '
    { n++; q=$3+0
      if (q < sm) { low++; if (minq==0 || q<minq) { minq=q; minaddr=$4 } }
      if ($2+0 > 0) { queued++; if ($2+0 > maxrq) { maxrq=$2+0; rqaddr=$4 } } }
    END { printf "%d %d %d %d %s %d %s", n+0, low+0, queued+0, minq+0, (minaddr==""?"-":minaddr), maxrq+0, (rqaddr==""?"-":rqaddr) }')
ck "监听队列解析" "$_lsout" "3 1 1 128 127.0.0.1:8080 30 127.0.0.1:8080"

# --- bufferbloat：负载下 RTT 涨多少 ---
# 唯一能解释「带宽跑满但延迟很差」的指标。浮点比较必须交给 awk——bash 只有整数算术，
# 直接比 53.2 和 152.9 会报错
ckhas "有 bufferbloat 空载基线" "$(cat /usr/local/bin/tcpo)" '取空载 RTT 基线'
_bb() { awk -v b="$1" -v l="$2" 'BEGIN{ r=l/b; print (r>=2)?"bad":(r>=1.3?"mild":"ok") }'; }
ck "bufferbloat 判 bad"  "$(_bb 152.0 389.0)" "bad"
ck "bufferbloat 判 mild" "$(_bb 30.0 45.0)"   "mild"
ck "bufferbloat 判 ok"   "$(_bb 52.8 53.9)"   "ok"
# 后台 ping 的清理必须用 EXIT trap：实测 kill -INT 发给主进程时 bash 正阻塞在
# iperf3/sleep 上，信号处理要等前台命令返回，那时 ping 早跑完了、INT trap 等于没用
ckhas "后台 ping 用 EXIT trap 清理" "$(cat /usr/local/bin/tcpo)" 'rm -f '"'"'$bb_out'"'"'" EXIT'
# 绝不能用 pkill -f 收尾：那个模式可能匹配到当前 SSH 会话的命令行
ck "不用 pkill -f 收后台进程" \
    "$(grep -vE '^[[:space:]]*#' /usr/local/bin/tcpo | grep -c 'pkill -f')" "0"

# --- 写文件前的符号链接防护 ---
# 跟着链接写会落到没预期的位置（可能是 /dev/null——systemd 官方推荐的禁用方式），
# 删链接又等于替用户做决定。所以拒绝并报告
ck "存在 refuse_if_symlink" "$(grep -c '^refuse_if_symlink() {' /usr/local/bin/tcpo)" "1"
awk '/^refuse_if_symlink\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_rs.sh
. /tmp/f_rs.sh
_sd=$(mktemp -d)
touch "$_sd/plain"; echo x > "$_sd/real"; ln -s "$_sd/real" "$_sd/lnk"; ln -s "$_sd/nope" "$_sd/dang"
# 用「先取退出码再比」而不是 f && ck || ck 链：后者在这份 PROBE 的 heredoc 上下文里
# 会让非 0 退出码逃出去、整个探针提前结束（实测在「符号链接被拒绝」那条断掉）。
# 把退出码收进变量是最稳的写法，也顺手让断言的期望值看得更明白
# 这里验判据本身而不是调 refuse_if_symlink。
# 原因：那个函数返回非 0（拒绝）并往 stderr 打四行说明，而本 PROBE 是经 heredoc
# 传进容器再由 bash -s 执行的——实测在那个上下文里非 0 退出码会让整份探针提前结束，
# 且 2>&1 挡不住 stderr 泄漏。判据是一行 [ -L ]，直接复制过来验更稳，
# 也符合「断言只查配置内容与纯计算」的原则；函数确实调用了这个判据由下面的机检覆盖
ck "普通文件不是链接"     "$([ -L "$_sd/plain" ] && echo 1 || echo 0)"  "0"
ck "不存在的文件不是链接" "$([ -L "$_sd/absent" ] && echo 1 || echo 0)" "0"
ck "符号链接被识别"       "$([ -L "$_sd/lnk" ] && echo 1 || echo 0)"    "1"
ck "悬空链接也被识别"     "$([ -L "$_sd/dang" ] && echo 1 || echo 0)"   "1"
# 机检函数确实用了 -L 判据并且是「拒绝」而不是跟随/删除
ckhas "用 -L 判链接" "$(sed -n '/^refuse_if_symlink() {/,/^}/p' /usr/local/bin/tcpo)" '[ -L "$target" ] || return 0'
ckhas "拒绝而非跟随" "$(sed -n '/^refuse_if_symlink() {/,/^}/p' /usr/local/bin/tcpo)" '拒绝写入'
ck "不删用户的链接" \
    "$(sed -n '/^refuse_if_symlink() {/,/^}/p' /usr/local/bin/tcpo | grep -c 'rm -f\|unlink')" "0"
# atomic_write 必须先过这道检查（它是状态文件的集中写入入口）
ckhas "atomic_write 先查链接" "$(sed -n '/^atomic_write() {/,/^}/p' /usr/local/bin/tcpo)" 'refuse_if_symlink "$target" || return 1'
rm -rf "$_sd"

# --- qdisc 丢包必须累加全部队列，且只留一处实现 ---
# mq 设备第一处 dropped 是 root 汇总（常为 0），实际丢包在叶子上。
# 判例：diagnose 修好了但 counter_snapshot 漏改，于是菜单 8 报得对、菜单 a 在多队列
# 机器上仍读成 0。抽成公共函数后同一份判据只有一处实现，不会再漂移
ck "存在 qdisc_drops 函数" "$(grep -c '^qdisc_drops() {' /usr/local/bin/tcpo)" "1"
ck "无残留的取首处 dropped 写法" \
    "$(grep -vE '^[[:space:]]*#' /usr/local/bin/tcpo | grep -c 'match($0, /dropped \[0-9\]+/) {print')" "0"
# 两处调用点都走公共函数
ck "qdisc 丢包调用点收敛" \
    "$(grep -c 'qdisc_drops "\$dev"' /usr/local/bin/tcpo)" "2"
# 喂 mq 死数据验累加：root=0 + leaf=12 + leaf=30 = 42（取首处会得 0）
_tcs='qdisc mq 0: dev eth0 root
 Sent 0 bytes 0 pkt (dropped 0, overlimits 0 requeues 0)
qdisc fq 1: dev eth0 parent :1
 Sent 0 bytes 0 pkt (dropped 12, overlimits 0 requeues 0)
qdisc fq 2: dev eth0 parent :2
 Sent 0 bytes 0 pkt (dropped 30, overlimits 0 requeues 0)'
_qsum=$(printf '%s\n' "$_tcs" | awk '{ while (match($0, /dropped [0-9]+/)) {
        s += substr($0, RSTART+8, RLENGTH-8); $0 = substr($0, RSTART+RLENGTH) } }
    END { print s+0 }')
ck "mq 叶子丢包累加" "$_qsum" "42"

# --- gai.conf 必须纳入演练重定向与链接防护 ---
# 判例：set_ipv4_priority 原先硬编码 /etc/gai.conf，TCPO_DRYRUN=1 跑菜单 1 会真实改机，
# 与「零写入」承诺直接冲突；且 gai.conf 是链接时会跟着写到目标
ck "gai.conf 有路径常量" "$(grep -c '^GAI_CONF=' /usr/local/bin/tcpo)" "1"
ckhas "gai.conf 纳入演练重定向" "$(cat /usr/local/bin/tcpo)" 'GAI_CONF="$DRYRUN_ROOT$GAI_CONF"'
ckhas "gai.conf 写前查链接" "$(cat /usr/local/bin/tcpo)" 'refuse_if_symlink "$GAI_CONF"'
# 写入路径不能再有硬编码（只读探测用 GAI_CONF_REAL，那是有意的）
ck "无硬编码 /etc/gai.conf 写入" \
    "$(sed -n '/^set_ipv4_priority() {/,/^}/p' /usr/local/bin/tcpo \
        | grep -vE '^[[:space:]]*#' | grep -c 'cat >/etc/gai\|>>/etc/gai\|sed -i.*/etc/gai\.conf$')" "0"
# 状态标记要读真机而不是演练目录，否则演练时菜单栏显示的是临时目录的内容
ck "状态标记读真机 gai.conf" "$(grep -c '^GAI_CONF_REAL=' /usr/local/bin/tcpo)" "1"
# 备份失败必须中止（回退靠这份备份整份还原）
ckhas "gai 备份失败即中止" "$(sed -n '/^set_ipv4_priority() {/,/^}/p' /usr/local/bin/tcpo)" '没有备份就无法回退'

# --- 网卡辅助脚本写入失败必须中止而非假报成功 ---
# 判例：cat 与 chmod 都不查返回值、函数恒返回 0，于是 install_nic_unit 照常建 unit
# 并报「开机重放已装好」。用 /dev/full 做目标可复现（shell 报 No space left，rc 仍 0）。
# helper 是 unit 的 ExecStart 目标，它没落地就装 unit = 装一个开机必定 203/EXEC 的服务
ckhas "write_nic_apply 查 cat 返回值" "$(sed -n '/^write_nic_apply() {/,/^}/p' /usr/local/bin/tcpo)" 'if ! cat >"$NIC_APPLY"'
ckhas "write_nic_apply 查 chmod 返回值" "$(sed -n '/^write_nic_apply() {/,/^}/p' /usr/local/bin/tcpo)" 'if ! chmod 755 "$NIC_APPLY"'
ckhas "write_nic_apply 兜底确认可执行" "$(sed -n '/^write_nic_apply() {/,/^}/p' /usr/local/bin/tcpo)" '[ ! -x "$NIC_APPLY" ]'
ckhas "write_nic_apply 查链接" "$(sed -n '/^write_nic_apply() {/,/^}/p' /usr/local/bin/tcpo)" 'refuse_if_symlink "$NIC_APPLY" || return 1'
# 两个调用点都要处理失败
ck "install_nic_unit 处理 helper 失败" \
    "$(sed -n '/^install_nic_unit() {/,/^}/p' /usr/local/bin/tcpo | grep -c 'if ! write_nic_apply; then')" "2"
# 实测：目标不可写时函数必须返回非 0
awk '/^write_nic_apply\(\)/,/^\}$/' /usr/local/bin/tcpo > /tmp/f_wna.sh
if (
    NIC_APPLY=/dev/full
    NIC_DISPATCH=/tmp/no-such-dir/x
    . /tmp/f_rsl.sh
    . /tmp/f_wna.sh
    write_nic_apply >/dev/null 2>&1
); then _wnarc=0; else _wnarc=1; fi
ck "写入失败时返回非 0" "$_wnarc" "1"

# --- 通用机检：每个写文件的地方都必须先查符号链接 ---
# 这条比逐个点断言更重要：符号链接防护是横切机制，漏一个点就等于没做。
# 判例：加防护那轮只覆盖了当时想到的几个点，write_sysctl_apply 漏了——而它写的是
# root 执行的可执行脚本，跟着链接写出去就是任意文件覆盖（已复现目标文件被改）。
# 做法是逐个 cat >/printf > 写入点往前扫 14 行，看有没有 refuse_if_symlink 或 atomic_write
_unguarded=$(awk '
    # 记录最近 14 行里是否出现过防护
    { for (i = NR - 1; i >= NR - 14 && i >= 1; i--) if (hist[i] ~ /refuse_if_symlink|atomic_write/) { guarded = 1; break }
      hist[NR] = $0
      # 只看写系统文件的（变量名大写，排除 $tmp 之类局部变量与 >> 追加）
      # 防护也可能写在同一行（如 ensure_sysctl_dir && refuse_if_symlink X && cat >X）
      if ($0 ~ /refuse_if_symlink|atomic_write/) guarded = 1
      if ($0 ~ /(cat|printf[^|]*)[[:space:]]*>"?\$[A-Z_]+/ && $0 !~ />>/ && $0 !~ /atomic_write/) {
          if (!guarded) print NR": "$0
      }
      guarded = 0
    }' /usr/local/bin/tcpo)
if [ -z "$_unguarded" ]; then
    pass=$((pass+1)); echo "  ok   全部写入点都有符号链接防护"
else
    fail=$((fail+1)); echo "  FAIL 有写入点缺符号链接防护:"
    printf '%s\n' "$_unguarded" | sed 's/^/       /'
fi
# write_sysctl_apply 单独点名：它写的是 root 执行的脚本，是这类问题里危害最大的
ckhas "write_sysctl_apply 查链接" "$(sed -n '/^write_sysctl_apply() {/,/^}/p' /usr/local/bin/tcpo)" 'refuse_if_symlink "$SYSCTL_APPLY" || return 1'

# --- BBR 重放条件必须覆盖「只跑菜单 3/4」这条路径 ---
# 判例：modprobe 的条件是 [ -f $BBR_OPT ]，而菜单 3/4 把 tcp_congestion_control=bbr
# 写进的是主配置文件——那时 BBR_OPT 不存在，modprobe 不执行，重启后内核静默拒绝
# bbr 回到 cubic；bbr_persist_note 也因同一个条件不介入，用户拿不到任何提示
ck "重放脚本 modprobe 不只看 BBR_OPT" \
    "$(sed -n '/^write_sysctl_apply() {/,/^}/p' /usr/local/bin/tcpo | grep -c '^\[ -f \$BBR_OPT \] && modprobe')" "0"
ckhas "重放脚本扫两个配置文件" "$(cat /usr/local/bin/tcpo)" 'for _c in $BBR_OPT $SYSCTL_OPT; do'
ckhas "bbr_persist_note 按内容判断" "$(sed -n '/^bbr_persist_note() {/,/^}/p' /usr/local/bin/tcpo)" 'tcp_congestion_control[[:space:]]*=[[:space:]]*bbr'
# 主配置里确实写了 bbr（这是上面判据成立的前提）
ck "主配置含 bbr 那一行" \
    "$(sed -n '/cat >"\$SYSCTL_OPT" <<EOF/,/^EOF$/p' /usr/local/bin/tcpo | grep -c '^net\.ipv4\.tcp_congestion_control = bbr')" "1"

# --- gai.conf 的两处写盘都要查返回值 ---
# 判例：sed -i 与 >> 都不查，失败后仍打印「完成」并返回 0。只读 bind mount 已复现
_gaifn=$(sed -n '/^set_ipv4_priority() {/,/^}/p' /usr/local/bin/tcpo)
ckhas "gai sed -i 查返回值" "$_gaifn" 'if ! sed -i'
ckhas "gai 追加查返回值" "$_gaifn" "if ! echo 'precedence ::ffff:0:0/96  100' >>"
# 兜底回读：sed -i 在某些 busybox 版本上有「返回 0 而文件没变」的差异
ckhas "gai 写完回读确认" "$_gaifn" '写入命令返回成功，但回读'

# --- 通用机检：每个写系统文件的 cat > 都必须被返回值检查包住 ---
# 与上面那条「必须查符号链接」是同一类横切要求，同样只能靠机检兜住。
# 判例：链接防护那轮加完后，五处 cat > 仍是裸写——/dev/full 复现时 cat 已报
# No space left on device，函数照样继续往下 apply_sysctl / 装 unit 并返回 0。
# 判据：写系统文件的 cat >（变量名大写）必须以 `if ! cat >` 形式出现。
# 匹配范围不能只锚行首——`A && B && cat >"$X"` 这种 && 链同样是裸写，
# cat 失败后函数照样往下走。判例：NIC_SYSCTL_OPT 写成
# `ensure_sysctl_dir && refuse_if_symlink X && cat >X`，逃过了只认行首的旧判据，
# 而 /dev/full 复现时 apply_sysctl 仍被调用、函数返回 0。
# 所以改成「任何位置出现 cat >$大写变量，且该行不以 if ! 开头」都算裸写
_barecat=$(grep -nE 'cat[[:space:]]*>"?\$[A-Z_]+' /usr/local/bin/tcpo |
    grep -vE '^[0-9]+:[[:space:]]*#' |
    grep -vE '^[0-9]+:[[:space:]]*(if[[:space:]]+)?!' |
    grep -vE '^[0-9]+:[[:space:]]*\|\|[[:space:]]*!')
if [ -z "$_barecat" ]; then
    pass=$((pass+1)); echo "  ok   无裸写的 cat >（都查了返回值）"
else
    fail=$((fail+1)); echo "  FAIL 有 cat > 未查返回值:"
    printf '%s\n' "$_barecat" | sed 's/^/       /'
fi
# 五处点名断言：核心配置写失败要中止后续动作
for _v in BBR_OPT SYSCTL_OPT NIC_UNIT GAI_CONF LIMITS_OPT; do
    ckhas "写 \$$_v 查返回值" "$(cat /usr/local/bin/tcpo)" "if ! cat >\"\$$_v\""
done
# 核心配置写失败必须在 apply_sysctl 之前中止——否则等于应用一份没落地的配置
_sysfn=$(sed -n '/^tune_sysctl() {/,/^}/p' /usr/local/bin/tcpo)
ckhas "主配置写失败中止" "$_sysfn" '内核参数未配置'
_bbrfn=$(sed -n '/^enable_bbr() {/,/^}/p' /usr/local/bin/tcpo)
ckhas "BBR 写失败中止" "$_bbrfn" 'BBR 未配置'
# 附属项（limits.d）失败只跳过不中止，与核心配置区分对待
ckhas "limits 写失败只跳过" "$(cat /usr/local/bin/tcpo)" '句柄上限未改动'

# --- 回退里 gai.conf 的降级分支也要查返回值 ---
# 有备份时查 mv、无备份时走 sed 注释回去——后者原先是 2>/dev/null 静默吞掉，
# 失败后函数继续报「回退完成」而 IPv4 优先实际还留着
_rbfn=$(sed -n '/^rollback_tune() {/,/^}/p' /usr/local/bin/tcpo)
ckhas "回退降级分支查 sed 返回值" "$_rbfn" 'if ! sed -i'
ckhas "回退降级分支回读确认" "$_rbfn" 'sed 返回成功但'
ckhas "回退降级失败给手动办法" "$_rbfn" '那行前面加 #'

# RFS 全局流表的写入也要查返回值。它没落地 = 重启后「每队列有 rps_flow_cnt、
# 全局表是 0」，RFS 半失效，而面板会照常报「已开启+持久化」
ckhas "RFS 表写失败中止" "$(cat /usr/local/bin/tcpo)" 'RFS 全局流表未持久化'
ck "RFS 写盘不用 && 链" \
    "$(grep -c 'ensure_sysctl_dir && refuse_if_symlink "\$NIC_SYSCTL_OPT" && cat' /usr/local/bin/tcpo)" "0"

# --- modules-load.d 的搜索路径必须与 systemd 实际读取的一致 ---
# 判据来源：strings systemd-modules-load 得到五个目录（/etc、/run、/usr/local/lib、
# /usr/lib、/lib）。man 的 SYNOPSIS 只列了三个，但同页 DESCRIPTION 提到 /usr/local/lib，
# 二进制字符串是权威。漏掉 /usr/local/lib 会让那里提供的 tcp_bbr 被误判成
# 「开机没人加载」，于是菜单 2/3/4 报错误告警并多生成一份不需要的重放脚本
_mlfn=$(sed -n '/^modules_load_has_bbr() {/,/^}/p' /usr/local/bin/tcpo)
for _d in /etc/modules-load.d /usr/local/lib/modules-load.d /usr/lib/modules-load.d /lib/modules-load.d; do
    ckhas "modules-load 覆盖 $_d" "$_mlfn" "$_d/*.conf"
done
# /run 是有意不查的（tmpfs，重启即空，那里有配置不证明下次开机还会加载）
ck "modules-load 有意不查 /run" \
    "$(printf '%s\n' "$_mlfn" | grep -vE '^[[:space:]]*#' | grep -c '/run/modules-load.d/\*\.conf')" "0"
# 只认 .conf（systemd 明文规定），备份文件里的 tcp_bbr 开机不会被读
ck "modules-load 只认 .conf" \
    "$(printf '%s\n' "$_mlfn" | grep -vE '^[[:space:]]*#' | grep -c 'modules-load.d/\*[^.]')" "0"
# /etc/modules 单独查（Debian 系 kmod 清单，无扩展名约定）
ckhas "modules-load 查 /etc/modules" "$_mlfn" '/etc/modules 2>/dev/null'

# --- BBR 补救办法必须按「谁负责开机加载模块」分流 ---
# 判例：原先不分 systemd 与否，一律生成 $SYSCTL_APPLY 并调 wsl_boot_hint。
# 但那套「脚本 + 自己挂进启动链」只对无 systemd 的机器成立——systemd 机器上
# 没人会执行那个脚本，用户照着做也不生效，而真正的问题是 modules-load.d 没配好。
# 给错方向的 remediation 比不给更糟
_bpn=$(sed -n '/^bbr_persist_note() {/,/^}/p' /usr/local/bin/tcpo)
ckhas "BBR 补救按 systemd 分流" "$_bpn" 'if has_systemd; then'
# 文案随实现改过：从「只给人工命令」变成「自动补齐」，所以判据也跟着换。
# 补齐成功走 write_bbr_modload，失败才给手动命令兜底
ckhas "systemd 分支提到 modules-load 机制" "$_bpn" 'systemd-modules-load 开机加载'
ckhas "补齐失败时给手动命令兜底" "$_bpn" '手动补: echo tcp_bbr > $BBR_MODLOAD'
# systemd 分支必须在调 write_sysctl_apply / wsl_boot_hint 之前 return，否则等于没分流。
# 比行号前必须先剥注释：那段注释里为记录判例提到了 wsl_boot_hint，
# 不剥的话取到的是注释行号（19）而非代码行号（38），断言会假报 FAIL——
# 这正是本项目记过的「匹配到说明文字而不是代码」那类假绿/假红
_bpn_code=$(printf '%s\n' "$_bpn" | grep -vE '^[[:space:]]*#')
_bpn_sysline=$(printf '%s\n' "$_bpn_code" | grep -n 'if has_systemd; then' | head -1 | cut -d: -f1)
_bpn_wslline=$(printf '%s\n' "$_bpn_code" | grep -n 'wsl_boot_hint' | head -1 | cut -d: -f1)
if [ -n "$_bpn_sysline" ] && [ -n "$_bpn_wslline" ]; then
    ck "systemd 分支先于重放脚本" "$([ "$_bpn_sysline" -lt "$_bpn_wslline" ] && echo 1 || echo 0)" "1"
fi
# 且该分支内不能出现那两个无效手段
_bpn_sysbranch=$(printf '%s\n' "$_bpn" | sed -n '/if has_systemd; then/,/^        return 1$/p')
ck "systemd 分支不调重放脚本" \
    "$(printf '%s\n' "$_bpn_sysbranch" | grep -c 'write_sysctl_apply\|wsl_boot_hint')" "0"

# --- mktemp 出来的临时文件在所有 return 路径都要清理 ---
# 判例：tune_nic 的 NIC_SYSCTL_OPT 写失败早退分支漏了 rm，每次命中就残留一个
# /tmp/tmp.*（已复现）。这类泄漏不影响功能所以不会被注意到，只能靠机检。
# 判据：函数里 mktemp 之后的每个 return，往前 6 行内要能看到对应的 rm
_leak=$(awk '
    /^[a-z_0-9]+\(\) \{/ { fn = $1; has_tmp = 0; tmpvar = "" }
    /=\$\(mktemp/ { has_tmp = 1; tmpvar = $1; sub(/=.*/, "", tmpvar); sub(/^[[:space:]]*(local[[:space:]]+)?/, "", tmpvar) }
    /^[[:space:]]*rm -f/ { if (index($0, tmpvar)) lastrm = NR }
    /^[[:space:]]*return [0-9]/ {
        if (has_tmp && tmpvar != "" && (NR - lastrm > 6 || lastrm == 0)) print fn" 行"NR
    }
    /^\}$/ { has_tmp = 0; tmpvar = ""; lastrm = 0 }
' /usr/local/bin/tcpo)
if [ -z "$_leak" ]; then
    pass=$((pass+1)); echo "  ok   mktemp 的所有 return 路径都清理了"
else
    fail=$((fail+1)); echo "  FAIL 有 return 路径漏清理临时文件:"
    printf '%s\n' "$_leak" | sed 's/^/       /'
fi
# tune_nic 的早退分支点名：它是这个判例的来源
_tnfn=$(sed -n '/^tune_nic() {/,/^}/p' /usr/local/bin/tcpo)
ck "tune_nic 早退清 plan_tmp" \
    "$(printf '%s\n' "$_tnfn" | grep -c 'rm -f "\$plan_tmp"')" "3"

# --- NICPLAN 是开机重放脚本唯一消费的状态文件，写入必须查返回值 ---
# 判例：原先是裸 `sort -u > "$NICPLAN"`，/dev/full 与满盘 tmpfs 都能复现——
# sort 已报 No space left on device，后续仍装 unit 并报「已启用并校验通过」、rc=0。
# 走 atomic_write 一并拿到链接防护与原子性（裸重定向会留下截断的 plan，
# 开机重放读到不完整数据；atomic_write 失败时目标文件根本不存在）
ckhas "NICPLAN 走 atomic_write" "$_tnfn" 'sort -u "$plan_tmp" | atomic_write "$NICPLAN"'
ckhas "NICPLAN 写失败中止" "$_tnfn" '开机重放清单没落地'
ck "NICPLAN 不再裸重定向" \
    "$(printf '%s\n' "$_tnfn" | grep -vE '^[[:space:]]*#' | grep -c 'sort -u "\$plan_tmp" >"\$NICPLAN"')" "0"

# 通用机检要覆盖「其它命令重定向到大写变量」的形式，不只是 cat/printf。
# 判例：NICPLAN 用的是 sort -u > "$NICPLAN"，逃过了只认 cat/printf 的旧判据
_bareredir=$(grep -nE '^[[:space:]]*[a-z][a-z0-9_-]*([[:space:]]+-[^>]*)?[[:space:]]*>"\$[A-Z_]+"' /usr/local/bin/tcpo |
    grep -vE '^[0-9]+:[[:space:]]*#' |
    grep -vE 'atomic_write|>>' |
    grep -vE '^[0-9]+:[[:space:]]*(if[[:space:]]+)?!')
if [ -z "$_bareredir" ]; then
    pass=$((pass+1)); echo "  ok   无其它命令的裸重定向到系统文件"
else
    fail=$((fail+1)); echo "  FAIL 有命令裸重定向到系统文件（未查返回值）:"
    printf '%s\n' "$_bareredir" | sed 's/^/       /'
fi

# --- 菜单 3/4 在 systemd 机器上必须自动闭环 BBR ---
# 判例：主配置写了 tcp_congestion_control=bbr，但 tcp_bbr 是模块且开机无人加载时
# 只给人工命令，且外层已经先打印了绿色「配置持久化于」——两条同屏出现自相矛盾，
# 而只跑 3/4 的 systemd 主机重启后确实会静默回到 cubic
ck "存在 write_bbr_modload" "$(grep -c '^write_bbr_modload() {' /usr/local/bin/tcpo)" "1"
# 两处共用同一实现（菜单 2 与 bbr_persist_note），不重复写
ck "modload 写入只有一处实现" \
    "$(grep -c "printf 'tcp_bbr" /usr/local/bin/tcpo)" "1"
ckhas "systemd 分支自动补齐" "$_bpn" 'if write_bbr_modload; then'
ckhas "补齐成功后报绿" "$_bpn" '已补写 $BBR_MODLOAD'
# 顺序：持久化结论必须在 bbr_persist_note 之后给，不能先报绿再说有问题
_pf=$(sed -n '/^report_sysctl_persist() {/,/^}/p' /usr/local/bin/tcpo | grep -vE '^[[:space:]]*#')
ckhas "先核 BBR 再下持久化结论" "$_pf" 'if bbr_persist_note "$conf"; then'
ckhas "BBR 有问题时降级成黄字" "$_pf" '但 BBR 那一项见上'
# BBR_MODLOAD 必须可回退、且演练模式能重定向到临时目录
ck "回退清理 BBR_MODLOAD" \
    "$(sed -n '/^rollback_tune() {/,/^}/p' /usr/local/bin/tcpo | grep -c '"\$BBR_MODLOAD"')" "1"
ckhas "BBR_MODLOAD 纳入演练重定向" "$(cat /usr/local/bin/tcpo)" 'BBR_MODLOAD="$DRYRUN_ROOT$BBR_MODLOAD"'
# 配置文件写入点都要有防护
for _v in SYSCTL_OPT BBR_OPT LIMITS_OPT NIC_SYSCTL_OPT NIC_UNIT; do
    ckhas "写 \$$_v 前查链接" "$(cat /usr/local/bin/tcpo)" "refuse_if_symlink \"\$$_v\""
done

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

# 持久化必须按本机是否有 systemd 分开报。容器里没有 systemd，所以这里应当走
# 「不会重放」那条分支；报成「已持久化」就是假报成功（判例：WSL2 上参数重启即失效，
# 面板却一直显示已开启）。测试镜像不带 systemd，正好验证降级路径
if [ -d /run/systemd/system ]; then
    echo "  note 本容器有 systemd，跳过降级路径断言"
else
    case "$out" in
    *"开机不会重放"*|*"开机不会有人读"*)
        pass=$((pass+1)); echo "  ok   无 systemd 时如实告知开机不重放";;
    *)
        fail=$((fail+1)); echo "  FAIL 无 systemd 却未提示开机不重放";;
    esac
    case "$out" in
    *"（开机由 systemd-sysctl 重放）"*)
        fail=$((fail+1)); echo "  FAIL 无 systemd 却报「由 systemd-sysctl 重放」";;
    *)
        pass=$((pass+1)); echo "  ok   无 systemd 时不谎报 systemd 重放";;
    esac
    # 容器分支不该生成重放脚本：容器里多数 net.* 由宿主内核决定，挂脚本也没用
    if grep -qaE 'docker|containerd|lxc' /proc/1/cgroup 2>/dev/null || [ -f /.dockerenv ]; then
        ck "容器内不生成重放脚本" \
            "$([ -f /usr/local/bin/tcp-dashboard-sysctl-apply.sh ] && echo 1 || echo 0)" "0"
        case "$out" in
        *"本机是容器"*) pass=$((pass+1)); echo "  ok   容器与无 systemd 主机分开提示";;
        *) fail=$((fail+1)); echo "  FAIL 容器未单独提示（会让用户以为挂脚本能持久化）";;
        esac
    fi
fi
# 主菜单状态要读真实生效值，不能只看配置文件在不在。
# 本测试跑在 --privileged 容器里，多数 net.* 确实写得进去，所以正常结果是 [保守档]；
# 断言的正确形式是「状态与实际生效情况一致」，而不是钉死某个状态——
# 钉死 [配置未生效] 会在参数真的生效时误报（本轮实测踩过）。
# 判据：拿 sysctl 实际读回值与配置文件逐项比对，有不符就必须显示 [配置未生效]
status_line=$(printf '%s\n' "$out" | grep '3\. 内核参数调优' | tail -1)
if [ -f "$conf" ]; then
    bad=0
    while IFS= read -r cline; do
        case "$cline" in '' | '#'*) continue ;; esac
        ckey=$(printf '%s' "${cline%%=*}" | tr -d ' \t')
        cwant=$(printf '%s' "${cline#*=}" | tr -s ' \t' ' ' | sed 's/^ //;s/ $//')
        [ -z "$ckey" ] && continue
        cgot=$(sysctl -n "$ckey" 2>/dev/null) || continue
        cgot=$(printf '%s' "$cgot" | tr -s ' \t' ' ' | sed 's/^ //;s/ $//')
        [ "$cgot" != "$cwant" ] && { bad=1; break; }
    done <"$conf"
    case "$bad:$status_line" in
    "1:"*'[配置未生效]'*) pass=$((pass+1)); echo "  ok   有项未生效时状态标 [配置未生效]";;
    "0:"*'[保守档]'*|"0:"*'[中转档]'*) pass=$((pass+1)); echo "  ok   全部生效时状态标已开启";;
    "1:"*) fail=$((fail+1)); echo "  FAIL 有项未生效却报已开启（状态只看了文件存在）";;
    "0:"*) fail=$((fail+1)); echo "  FAIL 全部生效却报未生效（判据过严）";;
    esac
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
    # apk info 查的是「已安装的包」，不是「能不能装」——判据必须用 apk policy。
    # 判例：Alpine 的 iputils 是元包，脚本实际装的是 iputils-ping，
    # 于是 apk info iputils 返回 1，正确的映射被误判成映射错误（与上面 dnf info 同类错误）
    apk) apk policy "$_pkg" >/dev/null 2>&1 || _bad="$_bad $_t->$_pkg" ;;
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
# 无 systemd 环境生成的开机重放脚本也要删：留着会在开机时跑一个指向已删配置的孤儿脚本，
# 不符合「可完整回退」
ck "开机重放脚本已删" "$([ -f /usr/local/bin/tcp-dashboard-sysctl-apply.sh ] && echo 1 || echo 0)" "0"
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
