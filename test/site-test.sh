#!/bin/bash
# 站点与发布配置测试。不需要容器、不联网、零副作用，几秒跑完。
#
# 用法（在项目根目录执行）:
#   bash test/site-test.sh
#
# 覆盖三类：
#   1. 行尾 —— NTFS 下开发极易漂成 CRLF，tcpo 带 \r 会在 Linux 上直接跑不起来
#   2. 分发地址一致性 —— tcpo 的 SCRIPT_URL 必须与 Jenkinsfile 的 SITE_URL 相同，
#      且与网页上展示、复制按钮里的命令是同一个地址。四处任一处漂了都会导致
#      「网页教的命令」与「脚本自更新拉的地址」不是一回事
#   3. 网页自洽 —— 标签配对、双语文案成对、无外部资源依赖
#
# 这些断言与 distro-test.sh 互补：那个测脚本在各发行版上的运行行为，
# 这个测发布产物本身写对了没有。

set -u
cd "$(dirname "$0")/.." || exit 1

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'; CYAN=$'\033[0;36m'; NC=$'\033[0m'

pass=0; fail=0
ck() { # ck 描述 实际 期望
    if [ "$2" = "$3" ]; then pass=$((pass+1)); echo "  ok   $1"
    else fail=$((fail+1)); echo "  ${RED}FAIL $1 (得到[$2] 期望[$3])${NC}"; fi
}
ok() { pass=$((pass+1)); echo "  ok   $1"; }
no() { fail=$((fail+1)); echo "  ${RED}FAIL $1${NC}"; }

# 必须剥掉注释再匹配：注释里提一句「与菜单 7 共用 validate_script」也会让
# 裸 case 匹配成功，删掉真正的调用照样绿。这和门 3 的假绿是同一类错误
# （匹配到说明文字而不是代码），本轮实测踩过两次
strip_comments() { grep -vE '^\s*#' | grep -vE '^\s*$'; }

HTML=index.html
CSS=style.css
JF=Jenkinsfile

echo "${CYAN}=== 1. 文件齐全 ===${NC}"
for f in tcpo VERSION "$HTML" "$CSS" "$JF" .gitattributes .gitignore; do
    [ -f "$f" ] && ok "存在 $f" || no "缺少 $f"
done

echo "${CYAN}=== 2. 行尾（CRLF 会让脚本在 Linux 上跑不起来）===${NC}"
# 用 tr -d 删 \r 后比对字节数，比 grep 匹配 \r 更稳（不依赖 grep 对 \r 的处理）
for f in tcpo VERSION "$HTML" "$CSS" "$JF" .gitattributes .gitignore test/distro-test.sh test/effect-test.sh test/site-test.sh; do
    [ -f "$f" ] || continue
    raw=$(wc -c < "$f")
    stripped=$(tr -d '\r' < "$f" | wc -c)
    ck "无 CRLF: $f" "$raw" "$stripped"
done

echo "${CYAN}=== 3. bash 语法 ===${NC}"
for f in tcpo test/distro-test.sh test/effect-test.sh test/site-test.sh; do
    bash -n "$f" 2>/dev/null && ok "bash -n $f" || no "bash -n $f 失败"
done

echo "${CYAN}=== 4. 分发地址四处一致 ===${NC}"
# tcpo 的 SCRIPT_URL 默认值（去掉 ${TCP_DASHBOARD_URL:- 与结尾 }"）
script_url=$(sed -n 's/^SCRIPT_URL="\${TCP_DASHBOARD_URL:-\(.*\)}"$/\1/p' tcpo)
[ -n "$script_url" ] && ok "读到 tcpo 的 SCRIPT_URL: $script_url" \
    || no "解析不出 tcpo 的 SCRIPT_URL（格式变了？）"

# Jenkinsfile 的域名收口在 SITE_HOST 一处，其余全部派生。
# 曾经 DEPLOY_DIR / SITE_URL / 线上校验的三个 curl 各写一遍域名，换站点必漏改
site_host=$(sed -n "s/^ *SITE_HOST *= *'\(.*\)'$/\1/p" "$JF")
[ -n "$site_host" ] && ok "Jenkinsfile 域名收口在 SITE_HOST: $site_host" \
    || no "Jenkinsfile 缺 SITE_HOST，域名散落多处"
ck "SCRIPT_URL 与 SITE_HOST 一致" "$script_url" "https://$site_host/tcpo"

# 派生变量不能再硬编码域名，否则改 SITE_HOST 会漏
hardcoded=$(grep -n "$site_host" "$JF" | grep -v "SITE_HOST *=" | grep -vE '^\s*[0-9]+:\s*//' || true)
if [ -z "$hardcoded" ]; then
    ok "Jenkinsfile 其余位置不再硬编码域名"
else
    no "Jenkinsfile 仍有硬编码域名（改 SITE_HOST 会漏）: $(printf '%s' "$hardcoded" | head -2 | tr '\n' ' ')"
fi

# VERSION_URLS 首行必须指向自己的站点。指错的话已安装用户会一直去旧域名问版本，
# 而这个错误完全静默——版本提示看着正常，只是永远来自别人的站点
ver_first=$(sed -n 's|^VERSION_URLS="\(.*\)$|\1|p' tcpo)
ck "VERSION_URLS 首行指向本站" "$ver_first" "https://$site_host/VERSION"

# 环境变量覆盖必须还在：本地调试靠它，不然只能改文件
grep -q 'TCP_DASHBOARD_URL' tcpo && ok "SCRIPT_URL 保留环境变量覆盖" \
    || no "SCRIPT_URL 丢了 TCP_DASHBOARD_URL 覆盖能力"

# 网页展示的命令与复制按钮的命令必须一致，且指向同一地址
# 每个 .cmd 块里「展示的命令」与「复制按钮的内容」必须逐一配对。
# 页面有多个命令块（一键安装、离线下载），所以按块比对而不是取第一个：
# 用户点复制拿到的和眼睛看到的不一样，是最难被发现的一类错
cmd_pairs=$(python3 - "$HTML" 2>/dev/null <<'PYEOF'
import sys, re, html
src = open(sys.argv[1], encoding='utf-8').read()
# 每个 <div class="cmd"> ... </div> 内取 <code> 文本与 data-copy 属性
for block in re.findall(r'<div class="cmd">(.*?)</div>', src, re.S):
    code = re.search(r'<code>(.*?)</code>', block, re.S)
    copy = re.search(r'data-copy="([^"]*)"', block)
    if not code or not copy:
        print('MISSING', repr(block[:60])); continue
    shown = html.unescape(re.sub(r'<[^>]+>', '', code.group(1))).strip()
    copied = html.unescape(copy.group(1)).strip()
    print('OK' if shown == copied else 'MISMATCH', shown, '||', copied)
PYEOF
)
if [ -z "$cmd_pairs" ]; then
    no "解析不出命令块（页面结构变了或无 python3）"
else
    bad_pairs=$(printf '%s\n' "$cmd_pairs" | grep -v '^OK ' | head -3)
    n_pairs=$(printf '%s\n' "$cmd_pairs" | grep -c '^OK ')
    if [ -n "$bad_pairs" ]; then
        no "复制按钮与展示命令不一致: $bad_pairs"
    else
        ok "$n_pairs 个命令块的复制内容与展示一致"
    fi
fi

# 一键安装命令（含 curl -sL 的那个）必须指向 SCRIPT_URL 同一地址。
# 网页写裸域名、SCRIPT_URL 带 https://，所以比对去掉协议头的部分
shown=$(printf '%s\n' "$cmd_pairs" | sed -n 's/^OK \(bash <(curl -sL [^|]*\) ||.*/\1/p' | head -1)
shown=${shown% }
[ -n "$shown" ] && ok "读到一键安装命令: $shown" || no "网页里找不到一键安装命令"
url_bare=${script_url#https://}
url_bare=${url_bare#http://}
case "$shown" in
    *"$url_bare"*) ok "网页命令指向 SCRIPT_URL 同一地址 ($url_bare)";;
    *) no "网页命令 [$shown] 与 SCRIPT_URL [$script_url] 不是同一地址";;
esac

# 部署目录必须由 SITE_HOST 派生（宝塔站点目录约定），写死会与域名脱节
deploy_dir=$(sed -n 's|^ *DEPLOY_DIR *= *"\(.*\)"$|\1|p' "$JF")
ck "DEPLOY_DIR 由 SITE_HOST 派生" "$deploy_dir" '/www/wwwroot/${SITE_HOST}'

echo "${CYAN}=== 4b. 版本号与快捷命令 ===${NC}"
# VERSION 与 SCRIPT_VERSION 不一致会让已安装用户永久看到「有新版」提示
file_ver=$(head -1 VERSION 2>/dev/null | tr -d ' \r\n\t')
code_ver=$(sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' tcpo)
[ -n "$code_ver" ] && ok "读到 SCRIPT_VERSION: $code_ver" || no "tcpo 缺 SCRIPT_VERSION"
ck "VERSION 文件与 SCRIPT_VERSION 一致" "$file_ver" "$code_ver"
case "$file_ver" in
    '' | *[!0-9.]*) no "VERSION 内容不是版本号: [$file_ver]";;
    *) ok "VERSION 格式合法";;
esac

# 安装路径即命令名：文件名无扩展名，装到 PATH 里本身就是命令，不需要软链。
# 名字不能撞 tcpd（tcp-wrappers 占 /usr/sbin/tcpd、tcm 占 /usr/bin/tcpd，
# 装到 /usr/local/bin 会靠 PATH 优先级静默劫持）或 ttcp（经典吞吐测试工具）
installed=$(sed -n 's|^SCRIPT_PATH="/usr/local/bin/\(.*\)"$|\1|p' tcpo)
ck "安装后的命令名为 tcpo" "$installed" "tcpo"
ck "仓库里的脚本文件名与命令名一致" "$installed" "tcpo"
case " tcpd ttcp t tuned tc ss ip " in
    *" $installed "*) no "命令名 $installed 与系统命令/经典工具冲突";;
    *) ok "命令名不在已知冲突名单里";;
esac
# 不该再有软链逻辑：文件名即命令名之后它是多余的一层概念
if grep -q 'SHORTCUT_PATH\|LEGACY_SHORTCUTS' tcpo; then
    no "仍有软链逻辑残留（文件名已等于命令名，不需要）"
else
    ok "无多余软链逻辑"
fi
# 安装是直接落到 PATH 下的可执行文件
grep -q 'chmod +x "$SCRIPT_PATH"' tcpo && ok "安装后置可执行位" || no "安装未 chmod +x"

# 版本检查：必须静默失败、必须可关、必须有超时、必须不自动更新
grep -q 'TCP_DASHBOARD_NO_CHECK' tcpo && ok "版本检查可用环境变量关闭" \
    || no "版本检查无法关闭（离线环境无法禁用联网）"
grep -q 'max-time "$VERSION_TIMEOUT"' tcpo && ok "版本检查有超时" \
    || no "版本检查无超时，源不可达会卡住面板启动"
grep -q 'VERSION_CACHE' tcpo && ok "版本检查有缓存" || no "版本检查无缓存，每次启动都联网"
# 检查函数里不能出现下载脚本本体的动作——那就成了自动更新。
# 模式必须用单引号：双引号会让 $SCRIPT_PATH 被本脚本展开，set -u 下直接
# unbound variable，条件求值失败后静默走 else 分支报 ok——断言等于没写
if sed -n '/^fetch_latest_version()/,/^}/p' tcpo | grep -qF 'SCRIPT_PATH'; then
    no "版本检查函数里写了 SCRIPT_PATH，可能在自动更新"
else
    ok "版本检查不触碰脚本本体（不自动更新）"
fi

echo "${CYAN}=== 4d. 分发安全 ===${NC}"
# 一键命令必须带 https://。curl 不带协议头时先走明文 HTTP，而这是
# 「curl | bash 且以 root 执行」的分发方式，明文即中间人可直接注入代码
bare=$(grep -noE 'curl -[a-zA-Z]* (-o [^ ]+ )?tcp\.itssx\.com' README.md index.html 2>/dev/null)
if [ -z "$bare" ]; then
    ok "所有 curl 命令都带 https://（无明文 HTTP 分发）"
else
    no "有 curl 命令缺 https://，会先走明文 HTTP: $bare"
fi
# wget 同理
if grep -qnoE 'wget [^ ]*[^:/]tcp\.itssx\.com' README.md index.html 2>/dev/null; then
    no "有 wget 命令缺 https://"
else
    ok "所有 wget 命令都带 https://"
fi

# 首次安装与菜单 7 更新必须共用同一套校验。曾经首次安装直接把远端响应写进
# $SCRIPT_PATH 并立刻 exec，比后续更新更脆弱——站点误配返回 HTML 时坏内容
# 会直接成为正式命令
grep -q '^validate_script()' tcpo && ok "存在统一的下载内容校验函数" \
    || no "缺 validate_script，安装与更新的校验会各写一套并逐渐分叉"
inst=$(sed -n '/^if \[ "\$SELF" != "\$SCRIPT_PATH" \]/,/^fi$/p' tcpo | strip_comments)
case "$inst" in
    *'validate_script "$SCRIPT_PATH.tmp"'*) ok "首次安装路径有内容校验";;
    *) no "首次安装未校验下载内容（比菜单 7 更新更脆弱）";;
esac
case "$inst" in
    *'-o "$SCRIPT_PATH.tmp"'*) ok "首次安装先落临时文件再就位";;
    *) no "首次安装直接写 SCRIPT_PATH，坏内容会直接成为正式命令";;
esac
upd_fn=$(sed -n '/^check_update()/,/^}/p' tcpo | strip_comments)
case "$upd_fn" in
    *'validate_script "$SCRIPT_PATH.tmp"'*) ok "菜单 7 更新复用同一校验";;
    *) no "菜单 7 未用 validate_script，两条路径会松紧不一";;
esac

# 落地类操作（cp/mv/chmod）必须查返回值。它们失败时只往 stderr 报一行，
# 不查就会一路走到「已安装」/「更新成功」并 exit 0，而文件根本没换——
# 实测：目标只读时旧版打印「已安装」、rc=0、目标文件压根不存在
for _op in 'cp -f "$SELF" "$SCRIPT_PATH"' 'mv "$SCRIPT_PATH.tmp" "$SCRIPT_PATH"' 'chmod +x "$SCRIPT_PATH"'; do
    if printf '%s\n' "$inst" | grep -qF "if ! $_op"; then
        ok "安装路径检查了 ${_op%% *} 的返回值"
    else
        no "安装路径未检查 ${_op%% *}，失败会假报成功"
    fi
done
# 兜底断言：前面每步都查了，这里再确认文件真的在位且可执行
case "$inst" in
    *'! -x "$SCRIPT_PATH"'*) ok "安装末尾兜底确认文件可执行";;
    *) no "安装缺兜底确认，任何漏检都会以「已安装」骗过用户";;
esac
# 更新路径同理
case "$upd_fn" in
    *'if ! mv "$SCRIPT_PATH.tmp" "$SCRIPT_PATH"'*) ok "更新检查了 mv 的返回值";;
    *) no "更新未检查 mv，只读目标时会假报更新成功";;
esac
case "$upd_fn" in
    *'! chmod +x "$SCRIPT_PATH"'*) ok "更新检查了 chmod 的返回值";;
    *) no "更新未检查 chmod";;
esac

# 回退与接管路径的落地操作同样不能静默失败——「可回退性」是最高优先级
rb=$(sed -n '/^rollback_tune()/,/^}/p' tcpo | strip_comments)
case "$rb" in
    *'if ! mv /etc/gai.conf.bak'*) ok "回退检查了 gai.conf 还原结果";;
    *) no "回退未检查 gai.conf 还原，失败会静默留下 IPv4 优先设置";;
esac
# 接管前的备份失败必须放弃接管：没备份成功就改原文件 = 制造不可逆改动
tk=$(sed -n '/^takeover_conflicts()/,/^}/p' tcpo | strip_comments)
if [ -z "$tk" ]; then
    tk=$(sed -n '/backup_dir/,/^}/p' tcpo | strip_comments)
fi
case "$tk" in
    *'if ! cp -a'*) ok "备份失败时放弃接管（不做不可逆改动）";;
    *) no "备份 cp 未查返回值，备份失败仍会改原文件（无法回退）";;
esac

echo "${CYAN}=== 4e. 只读功能真的零副作用 ===${NC}"
# 文案对外承诺 8/a/b「不装包、生产机可直接跑」。装包会刷新索引、改 dpkg/rpm
# 数据库、装新二进制，那不是零副作用——代码必须与文案一致
grep -q '^require_tools_readonly()' tcpo && ok "存在只读专用的工具检测函数" \
    || no "缺 require_tools_readonly，只读功能会用会装包的 ensure_tools"
for fn in diagnose probe_mtu; do
    body=$(sed -n "/^$fn()/,/^}/p" tcpo)
    case "$body" in
        *ensure_tools*) no "$fn 里调了 ensure_tools（会装包，违反零副作用承诺）";;
        *require_tools_readonly*) ok "$fn 不装包（用 require_tools_readonly）";;
        *) no "$fn 既没检测也没声明工具依赖";;
    esac
done
# measure 特殊：iperf3 会打真实流量，必须问过才装，且只在用户指定了对端时
m_body=$(sed -n '/^measure()/,/^}/p' tcpo | strip_comments)
case "$m_body" in
    *require_tools_readonly*) ok "measure 的纯读工具不装包";;
    *) no "measure 未用 require_tools_readonly";;
esac
m_ins=$(printf '%s\n' "$m_body" | grep -c 'ensure_tools')
ck "measure 里仅 iperf3 一处安装（且需用户确认）" "$m_ins" "1"
# iperf3 会打真实流量，装它必须由用户点头。判据取「ensure_tools iperf3 所在行
# 是否挂在 $_ins 的判断上」——不能只查 measure 里有没有 read -p：
# 这个函数本来就用 read -p 问对端地址和窗口秒数，泛匹配恒真（实测漏检过）
iperf_line=$(printf '%s\n' "$m_body" | grep -n 'ensure_tools iperf3' | cut -d: -f1)
if [ -n "$iperf_line" ] &&
    printf '%s\n' "$m_body" | sed -n "${iperf_line}p" | grep -q '_ins.*&&.*ensure_tools iperf3'; then
    ok "iperf3 安装挂在用户确认之后"
else
    no "iperf3 未经确认就装（会产生真实流量）"
fi
# 确认提示本身也要在，且要说明会产生流量
case "$m_body" in
    *'未装 iperf3'*'真实流量'*) ok "确认提示说明了会产生真实流量";;
    *) no "缺 iperf3 的确认提示或未说明会产生流量";;
esac

# 文档里凡出现「只读菜单不装包」这类绝对表述，同一段内必须提到 iperf3 例外。
# 摘要句与例外说明隔太远时，只看摘要的读者会以为 8/a/b 在任何情况下都不装
# （实测漂过：README 第 3 行是绝对表述，例外在 200 多行之后）。
# 按空行分段检查，段内既有绝对表述又无 iperf3 即为不完整
_absolute=$(python3 - README.md index.html <<'PYEOF'
import sys, re
NEG = (r'(只读菜单|只读功能|8 / a / b|8/a/b|read-only (menus|ones))'
       r'[^\n]{0,80}?(不装|不会自动装|不会替你装|一个包都不装|不主动装|installs? nothing|install nothing)')
# 判据是「邻近 12 行内能否读到 iperf3 例外」而不是严格同段：
# 摘要句与例外说明常隔一个空行（连着讲同一件事），严格同段会误报。
# 只查对外承诺的正文——代码块里是面板的真实输出、引导句（以「：」结尾）
# 后面紧跟示例，都不是承诺，纳入检查会误报
WINDOW = 12
for path in sys.argv[1:]:
    lines = open(path, encoding='utf-8').read().split('\n')
    in_code = False
    for i, line in enumerate(lines):
        if line.lstrip().startswith('```'):
            in_code = not in_code
            continue
        if in_code or line.rstrip().endswith('：') or line.rstrip().endswith(':'):
            continue
        if not re.search(NEG, line):
            continue
        near = '\n'.join(lines[max(0, i - WINDOW):i + WINDOW + 1])
        if 'iperf3' not in near:
            print(f'{path}:{i + 1}: {line.strip()[:70]}')
PYEOF
)
if [ -z "$_absolute" ]; then
    ok "「只读不装包」的表述都在同段内说明了 iperf3 例外"
else
    no "有绝对表述未在同段说明 iperf3 例外: $(printf '%s' "$_absolute" | head -2 | tr '\n' ' ')"
fi

# 文档不许在「只读菜单专用的工具」上声称自动装。判据是这些工具只出现在
# require_tools_readonly 的参数里，从没被 ensure_tools 装过。
# 实测漂过一次：代码改成只读不装包，README 与网页四处仍写着「缺哪个装哪个」，
# 用户会以为跑菜单 8 能自动补齐 tc/nstat —— 而实际只会跳过
_ro_only=""
for _t in nstat tc tracepath; do
    grep -qE "^\s*ensure_tools .*\b$_t\b" tcpo && continue
    _ro_only="$_ro_only $_t"
done
if [ -z "$_ro_only" ]; then
    ok "无「只读专用工具」（都会被写入类菜单装）"
else
    _liar=""
    for _t in $_ro_only; do
        # 同一句里既提到该工具、又承诺自动装即为不实。
        # 必须排除否定形式（「不会自动装包」「installs nothing」）——
        # 正确的说明里也含这些词，不排除会把对的表述判成错的（实测误报过）
        _hits=$(
            grep -hoE "[^。；<]*\b$_t\b[^。；]*(自动装|自动安装|installed automatically|tries to install)[^。；]*" \
                README.md index.html 2>/dev/null
            grep -hoE "[^。；<]*(自动装|自动安装|installed automatically|tries to install)[^。；]*\b$_t\b[^。；]*" \
                README.md index.html 2>/dev/null
        )
        _hits=$(printf '%s\n' "$_hits" | grep -vE '不装|不会自动装|不自动装|不会替你装|installs? nothing|install nothing' || true)
        [ -n "$_hits" ] && _liar="$_liar $_t"
    done
    if [ -z "$_liar" ]; then
        ok "文档未对只读专用工具（$_ro_only）承诺自动装"
    else
        no "文档声称会自动装只读专用工具:$_liar（实际只会跳过并提示）"
    fi
fi
# 校验的具体内容查 validate_script（安装与更新共用它，见 4d 段）。
# 三条判据缺一条就有对应的坏内容能落到正式命令路径
vs=$(sed -n '/^validate_script()/,/^}/p' tcpo | strip_comments)
case "$vs" in
    *'#!/bin/bash'*) ok "校验含 shebang 判据（挡 HTML 错误页）";;
    *) no "校验缺 shebang 判据，拉到 HTML 会搞坏 tcpo";;
esac
case "$vs" in
    *'bash -n'*) ok "校验含语法判据（挡传输截断）";;
    *) no "校验缺 bash -n，传输截断会搞坏 tcpo";;
esac
case "$vs" in
    *SCRIPT_VERSION*) ok "校验含特征串判据（挡别的 shell 脚本）";;
    *) no "校验缺特征串判据，拿到别的脚本也会被当成 tcpo";;
esac

upd=$(sed -n '/^check_update()/,/^}/p' tcpo | strip_comments)
case "$upd" in
    *'rm -f "$VERSION_CACHE"'*) ok "更新后清版本缓存";;
    *) no "更新后未清缓存，新版仍会提示有新版";;
esac

echo "${CYAN}=== 4f. BBR 版本识别 ===${NC}"
# 主线 tcp_bbr.c 没有 MODULE_VERSION，「读不到 version」既可能是模块没报版本、
# 也可能是 modinfo 通路坏了。少了探针就只能一律报「版本未知」，两种情况分不开。
# 探针取 tcp_cubic（主线一直写着 MODULE_VERSION("2.3")）
bbr_fn=$(sed -n '/^bbr_version_label()/,/^}/p' tcpo | strip_comments)
case "$bbr_fn" in
    *'modinfo tcp_cubic'*) ok "用 tcp_cubic 当 modinfo 通路探针";;
    *) no "缺通路探针，「模块未报版本」与「读不到」会混成一种";;
esac
# 探针只证明 modinfo 通路可用，证明不了「这就是主线 BBR」——不写 MODULE_VERSION 的
# 下游补丁在这里和主线长得一样。所以标签不许出现「主线」这类关于实现来源的断言，
# 缺少 version 不是「是主线」的证据。这条断言防的是文案回退成过度下结论的措辞
case "$bbr_fn" in
    *'主线 BBR'*) no "标签断言了实现来源（无 version 不构成「是主线」的证据）";;
    *) ok "标签不对实现来源下结论";;
esac
# 三个标签必须同时出现在实现与 README 里：漏一处就是文案与实现不一致，
# 而这类漂移不影响运行、只在用户看到陌生标签时才暴露
for lbl in 'BBRv3' '模块未报版本' '版本未知'; do
    case "$bbr_fn" in
        *"$lbl"*) ok "实现有标签 [$lbl]";;
        *) no "实现缺标签 [$lbl]";;
    esac
    grep -qF "[$lbl]" README.md && ok "README 记了标签 [$lbl]" \
        || no "README 未记标签 [$lbl]（文案与实现漂移）"
done

echo "${CYAN}=== 4c. 装包进度与报错归属 ===${NC}"
# 装包全静默会让用户以为卡死（慢源上要几十秒）。判据是 run_pkg 里有转轮循环
grep -q 'kill -0 "$pid"' tcpo && ok "装包有进度指示（转轮）" || no "装包无进度，慢源上像卡死"
grep -q 'PKG_LOG' tcpo && ok "装包输出落日志" || no "装包输出被丢弃，排查无依据"
# 无 tty 时不能画转轮，否则日志里全是转轮字符
grep -q '\[ ! -t 2 \]' tcpo && ok "非交互环境不画转轮" || no "非交互环境会往日志刷转轮字符"
# 清行必须用 \033[K 而不是补固定宽度空格：秒数进位会变宽，空格补位会留残影
grep -q '033\[K' tcpo && ok "转轮用 ANSI 清行（秒数进位不留残影）" \
    || no "转轮靠空格补位清行，秒数进位会留残影"
# 逐包报进度：一次装多个包时要能看出卡在哪个
grep -q '\[\$done_n/\$total\]' tcpo && ok "多包安装逐个报进度" || no "多包安装看不出进度"

# sysctl --system 应用系统里全部 conf，报错可能来自别的文件（systemd 自带的
# 50-default.conf 用通配符命中伪接口 all，必然报错）。无条件报成「sysctl 报错」
# 会让用户以为本次调优失败
grep -q 'MANAGED_KEYS' <(sed -n '/^apply_sysctl()/,/^}/p' tcpo) &&
    ok "sysctl 报错按受管 key 区分归属" || no "sysctl 报错未区分归属，会误报成调优失败"
grep -q '与本次调优无关' tcpo && ok "外部报错措辞明确说明无关" \
    || no "缺「与本次调优无关」的措辞，用户无法判断要不要管"
# sysctl 报错有三种格式，只认 setting key 会把另两种误判成「别人的」——
# 判例：netdev_budget 的 permission denied 与 tcp_fastopen 的 cannot stat
# 都是受管 key，曾被错误归类为外部报错
apply_fn=$(sed -n '/^apply_sysctl()/,/^}/p' tcpo | strip_comments)
case "$apply_fn" in
    *'key "\([^"]*\)"'*) ok "认 setting key / permission denied 两种格式";;
    *) no "未覆盖 permission denied 格式（会误判归属）";;
esac
case "$apply_fn" in
    *'/proc/sys/'*) ok "认 cannot stat 的路径格式";;
    *) no "未覆盖 cannot stat 格式（会误判归属）";;
esac

echo "${CYAN}=== 5. Jenkinsfile 的四道门都在 ===${NC}"
# 门 1-3 在打包阶段，门 4 在线上校验阶段。少任何一道，坏产物就可能发上线
grep -q "含 CRLF" "$JF" && ok "门1 CRLF 检查在" || no "门1 CRLF 检查缺失"
grep -q 'bash -n tcpo' "$JF" && ok "门2 bash -n 在" || no "门2 bash -n 缺失"
# 门 3 必须解析出 SCRIPT_URL 的值再逐字比对。曾经是 grep -q "$SITE_URL" tcpo
# 扫全文——而脚本注释里本来就写着本站地址，把 SCRIPT_URL 改成 evil.example
# 这道门照样 PASS（实测过的假绿）
grep -q 'code_url=' "$JF" && ok "门3 解析 SCRIPT_URL 的值（非全文 grep）" \
    || no "门3 是全文 grep，注释里的 URL 会让它假绿"
grep -q 'code_url" != "\$SITE_URL' "$JF" && ok "门3 逐字比对 SCRIPT_URL" || no "门3 未逐字比对"
grep -q 'VERSION_URLS 首行' "$JF" && ok "门3 同时校验 VERSION_URLS 首行" \
    || no "门3 未校验 VERSION_URLS，换域名后用户会一直问旧站点版本"
grep -q 'SCRIPT_VERSION \[' "$JF" && ok "门4 VERSION 一致性校验在" || no "门4 VERSION 校验缺失"
grep -q '线上 VERSION' "$JF" && ok "线上 VERSION 回读在" || no "缺线上 VERSION 回读（版本提示会失效）"
grep -q 'cmp -s' "$JF" && ok "门4 线上逐字节回读在" || no "门4 线上回读缺失"
grep -q '#!/bin/bash' "$JF" && ok "门4 校验线上返回的是脚本非 HTML" || no "门4 缺少脚本首行校验"

# 回滚与保护清单
grep -q '_prev_release' "$JF" && ok "原子发布（_prev_release 暂存）在" || no "原子发布逻辑缺失"
grep -q 'trap on_signal INT TERM' "$JF" && ok "信号回滚在" || no "信号回滚缺失"
for keep in .htaccess .user.ini .well-known; do
    # 保护清单在 swap_in 和 restore 两处各出现一次，缺一处就会在对应阶段被删
    n=$(grep -c -- "-name $keep" "$JF")
    ck "保护 $keep（两处）" "$n" "2"
done
# 权限校验：不支持权限位的文件系统上 chmod 会静默失败，打出的包 nginx 读不到就是 403
grep -q '! -perm 644' "$JF" && ok "产物权限校验在" || no "缺产物权限校验（chmod 可能静默失败）"
grep -q 'retry(2)' "$JF" && ok "SFTP retry 在" || no "SFTP retry 缺失"
grep -q 'timeout(time: 5' "$JF" && ok "SFTP 超时在" || no "SFTP 超时缺失"
grep -q 'disableConcurrentBuilds' "$JF" && ok "禁并发构建在" || no "禁并发构建缺失"

# 上线白名单：产物在仓库根，必须逐个列出。少 tcpo 等于分发地址 404，
# 多列或改成通配则会把 README/CLAUDE.md/test/ 之类的内部文件挂到公网
whitelist=$(sed -n 's/^ *PUBLISH="\(.*\)"$/\1/p' "$JF")
ck "上线白名单恰为四个产物" "$whitelist" "index.html style.css tcpo VERSION"
grep -q 'cp \$PUBLISH .dist/' "$JF" && ok "打包只拷白名单内的文件" \
    || no "打包未按白名单拷贝，可能发出内部文件"

# 文档与代码注释里对产物数量的表述必须与白名单一致。这不只是措辞问题：
# 有人按 README 手工同步「那三个文件」会漏掉 VERSION，版本检查随即静默失效
# （拉不到就当「未知」，不报错）。实测漂过一次——白名单加了 VERSION，README 没跟
_n_pub=$(printf '%s\n' $whitelist | wc -l | tr -d ' ')
_cnw=$(printf '%s' "$_n_pub" | sed 's/^2$/两/; s/^3$/三/; s/^4$/四/; s/^5$/五/; s/^6$/六/')
# 只查确实在描述上线白名单的措辞（「上线的只有 N 个」「白名单里那 N 个」「N 个产物」）。
# 不能泛匹配所有「N 个文件」——README 里还有「网页本身：单页、两个文件」这类
# 与白名单无关的表述，泛匹配会误报
# 连 Jenkinsfile 自己的注释一起查：它的注释写「那三个文件」而白名单是四个，
# 已漂过两次（顶部说明 + 部署阶段的核对注释）。同一个仓库里写死同一个数字
# 的地方越多，漏改的概率越高——所以这里查全，不只查 README
_wrong=$(grep -noE '上线的只有[^。]*[两三四五六]个文件|白名单里那[两三四五六]个文件|[两三四五六]个产物' \
    README.md "$JF" |
    grep -vE "${_cnw}个文件|${_cnw}个产物" || true)
if [ -z "$_wrong" ]; then
    ok "文档与注释里的产物数量与白名单一致（$_n_pub 个）"
else
    no "产物数量与白名单（$_n_pub 个）不符: $(printf '%s' "$_wrong" | head -2 | tr '\n' ' ')"
fi
# 不能出现把工作区整体拷进产物的写法（从 .dist 打包是正确的，不算）
if grep -qE 'cp -[ra][a-z]* \.?/? *\.dist|cp \*|cp -r \./?[^d]' "$JF"; then
    no "打包出现整目录/通配拷贝，会把内部文件发上线"
else
    ok "打包无整目录/通配拷贝"
fi
# tar 的源必须是 .dist（白名单产物目录），不能是工作区根
tar_src=$(sed -n 's/.*tar -czf dist.tar.gz -C \([^ ]*\).*/\1/p' "$JF")
ck "tar 从白名单目录打包" "$tar_src" ".dist"

echo "${CYAN}=== 6. 网页自洽 ===${NC}"
# 标签配对与双语成对用 python3 查（awk 做不了嵌套栈）。没有 python3 就跳过并说明
if command -v python3 >/dev/null 2>&1; then
    py_out=$(python3 - "$HTML" <<'PYEOF'
import sys, html.parser, collections
src = open(sys.argv[1], encoding='utf-8').read()
VOID = {'meta','link','br','hr','img','input','area','base','col','embed','source','track','wbr'}
class P(html.parser.HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.stack = []; self.err = []
        self.groups = collections.defaultdict(collections.Counter); self.total = collections.Counter()
    def handle_starttag(self, tag, attrs):
        d = dict(attrs)
        if 'data-l' in d:
            parent = self.stack[-1] if self.stack else ('ROOT', 0)
            self.groups[parent][d['data-l']] += 1
            self.total[d['data-l']] += 1
        if tag not in VOID:
            self.stack.append((tag, self.getpos()[0]))
    def handle_endtag(self, tag):
        if tag in VOID: return
        if not self.stack:
            self.err.append(f'line {self.getpos()[0]}: 多余闭合 </{tag}>'); return
        open_tag, line = self.stack.pop()
        if open_tag != tag:
            self.err.append(f'line {self.getpos()[0]}: </{tag}> 与 <{open_tag}> (line {line}) 不匹配')

p = P(); p.feed(src)
for tag, line in p.stack:
    p.err.append(f'line {line}: <{tag}> 未闭合')
print('TAGS', 'ok' if not p.err else 'fail:' + '; '.join(p.err[:3]))

# 每个父级容器下 zh/en 数量必须相等。唯一例外是 header 里那句
# "面板界面是中文" 的提示，只给英文读者看
bad = [(k, v) for k, v in p.groups.items() if v['zh'] != v['en']]
allowed = [(k, v) for k, v in bad if k[0] == 'header' and v['zh'] == 0 and v['en'] == 1]
unexpected = [x for x in bad if x not in allowed]
print('PAIRS', 'ok' if not unexpected else 'fail:' + '; '.join(
    f'<{k[0]}> line {k[1]}: zh={v["zh"]} en={v["en"]}' for k, v in unexpected[:3]))
print('COUNT', p.total['zh'], p.total['en'])
print('EXEMPT', len(allowed))
PYEOF
)
    case "$py_out" in
        *"TAGS ok"*) ok "HTML 标签全部配对";;
        *) no "HTML 标签配对: $(echo "$py_out" | sed -n 's/^TAGS //p')";;
    esac
    case "$py_out" in
        *"PAIRS ok"*) ok "双语文案按父级成对";;
        *) no "双语文案未成对: $(echo "$py_out" | sed -n 's/^PAIRS //p')";;
    esac
    zh=$(echo "$py_out" | awk '/^COUNT/{print $2}')
    en=$(echo "$py_out" | awk '/^COUNT/{print $3}')
    exempt=$(echo "$py_out" | awk '/^EXEMPT/{print $2}')
    ck "双语总数差恰为豁免项数" "$((en - zh))" "$exempt"
    [ "$zh" -ge 40 ] && ok "双语文案 $zh 组（内容量合理）" \
        || no "双语文案只有 $zh 组，可能漏译"
else
    echo "  ${YELLOW}跳过 HTML 结构检查（无 python3）${NC}"
fi

# 外部资源：网页必须零外链依赖（离线可看、不给第三方留追踪点）。
# 允许的只有指向 GitHub 的超链接（<a href>，不是资源加载）
ext_res=$(grep -oE '<(link|script|img)[^>]*(src|href)="https?://[^"]*"' "$HTML" | wc -l)
ck "无外部资源加载（字体/CSS/JS/图片）" "$ext_res" "0"
grep -q 'fonts.googleapis\|cdn\.' "$HTML" && no "引用了 CDN 字体或库" || ok "无 CDN 依赖"

# 本地资源引用的文件必须真的存在
for res in $(grep -o '<link[^>]*href="[^":]*"' "$HTML" | sed 's/.*href="//; s/"$//'); do
    [ -f "$res" ] && ok "本地资源存在: $res" || no "引用了不存在的资源: $res"
done

# 网页不能承诺「浏览器点开会显示脚本内容」——tcpo 无扩展名，nginx 默认返
# application/octet-stream，浏览器是下载而非显示。除非站点配了 default_type text/plain，
# 而本项目把那条列为可选配置，所以文案不能依赖它
if grep -qE '直接显示脚本内容|renders the script as text' "$HTML"; then
    no "网页承诺浏览器会显示脚本内容，但这需要可选的 nginx default_type 配置"
else
    ok "网页未对 content-type 做未成立的承诺"
fi

# 网页里所有指向本仓库文件的相对链接，都必须在上线白名单里——
# 本地打开能看不代表线上能访问（比如链了 README.md 但它不发上线，线上就是 404）
# 用 grep -o 而非 sed：同一行有多个 <a> 时 sed 的贪婪 .* 只会取到最后一个
for res in $(grep -o '<a href="[^":#]*"' "$HTML" | sed 's/.*href="//; s/"$//'); do
    case " $whitelist " in
        *" $res "*) ok "站内链接在白名单内: $res";;
        *) no "站内链接 $res 不在上线白名单，线上会 404";;
    esac
done

# 语言判定必须在 <head> 里同步执行：放到 body 末尾会先渲染中文再切成英文，英文用户看到闪烁。
# 判据是「设置 documentElement.dataset.lang」这个动作出现在 </head> 之前，
# 光查 navigator.language 不够——它在 body 末尾的切换脚本里也可能出现
head_part=$(sed -n '1,/<\/head>/p' "$HTML")
case "$head_part" in
    *documentElement.dataset.lang*) ok "语言判定在 <head> 内同步执行（无闪烁）";;
    *) no "语言判定不在 <head> 内，英文用户会看到中文闪一下";;
esac
case "$head_part" in
    *navigator.language*) ok "首次访问跟随浏览器语言";;
    *) no "<head> 内未读 navigator.language，首访不跟随浏览器语言";;
esac
# 手动切换要能记住，否则每次刷新都退回浏览器语言
grep -q 'localStorage' "$HTML" && ok "语言选择持久化（localStorage）" \
    || no "语言选择未持久化，刷新即丢"

# viewport 与 charset：缺 viewport 手机上会按桌面宽度缩放，字全部变小
grep -q 'name="viewport"' "$HTML" && ok "有 viewport 声明" || no "缺 viewport，移动端会缩放"
grep -q 'charset="utf-8"\|charset=utf-8' "$HTML" && ok "有 charset 声明" || no "缺 charset，中文可能乱码"

# CSS 里两种语言的显示切换规则必须都在，缺一条就会两种语言同时显示
grep -q "data-lang='zh'\] \[data-l='en'\]" "$CSS" && ok "CSS 语言切换规则在" \
    || no "CSS 缺语言切换规则，会两种语言同时显示"

echo "${CYAN}=== 7. 开源卫生 ===${NC}"
# 不该入库的本机配置必须被 .gitignore 挡住。整个 .claude/ 都忽略——
# 只列已知子路径的话，将来多出的文件（settings.json、hooks 等）会漏网
grep -qE '^\.claude/$' .gitignore && ok ".gitignore 挡住整个 .claude/ 目录" \
    || no ".claude/ 未整体忽略（含本机路径与会话记录）"
grep -qE '^\.vscode/$' .gitignore && ok ".gitignore 挡住编辑器配置" \
    || no ".vscode/ 未被忽略"
grep -q 'dist.tar.gz' .gitignore && ok ".gitignore 挡住发布产物" || no "发布产物未被忽略"

# 公网 IP 不该出现在发布文件里。允许清单三类，每类都有依据：
#   私网/回环——不指向真实主机；公共 DNS（1.1.1.1 等）——脚本 ping 它们测 RTT，是功能；
#   RFC 5737 文档保留段与惯用占位符 1.2.3.4
leaked=$(grep -rhoE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' \
    tcpo "$HTML" "$CSS" "$JF" README.md test/*.sh 2>/dev/null |
    grep -vE '^(10\.|127\.|0\.0\.0\.0|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)' |
    grep -vE '^(1\.1\.1\.1|8\.8\.8\.8|9\.9\.9\.9|223\.5\.5\.5)$' |
    grep -vE '^(1\.2\.3\.4|192\.0\.2\.[0-9]+|198\.51\.100\.[0-9]+|203\.0\.113\.[0-9]+)$' |
    sort -u)
if [ -z "$leaked" ]; then
    ok "无泄漏的公网 IP"
else
    no "出现了真实公网 IP: $(printf '%s' "$leaked" | tr '\n' ' ')"
fi

# .gitattributes 必须钉住关键类型的 LF，否则 CRLF 问题会反复发作
for pat in '\*\.sh' 'Jenkinsfile' '\*\.html' '\*\.css'; do
    grep -qE "^$pat text eol=lf" .gitattributes && ok ".gitattributes 钉住 ${pat//\\/} 为 LF" \
        || no ".gitattributes 未钉住 ${pat//\\/}"
done

echo ""
if [ "$fail" -eq 0 ]; then
    echo "${GREEN}RESULT pass=$pass fail=$fail —— 全部通过${NC}"
else
    echo "${RED}RESULT pass=$pass fail=$fail${NC}"
fi
exit $((fail > 0 ? 1 : 0))
