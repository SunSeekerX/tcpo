# TCP/UDP 网络调优面板

面向跨境链路（长肥网络 LFN）的 Linux 内核网络参数调优脚本。纯 bash，写入类菜单缺的系统工具会自动装、只读菜单不装（`iperf3` 例外，问过才装），可完整回退。

## 快速使用

```bash
bash <(curl -sL https://tcp.itssx.com/tcpo)
```

首次运行会把自己装到 `/usr/local/bin/tcpo`，之后任意目录敲 `tcpo` 即可打开面板。文件名无扩展名、装进 PATH 后本身就是命令，不需要额外的软链。

介绍网页在 <https://tcp.itssx.com>（同一站点，根路径是网页、`/tcpo` 是脚本）。也可以直接走 GitHub：

```bash
bash <(curl -sL https://raw.githubusercontent.com/SunSeekerX/tcpo/main/tcpo)
```

两者内容一致。想换成自己的分发地址见下方「发布」。

### 为什么叫 tcpo

`tcp optimize` 的缩写。选名字时排除了几个看起来更顺的：

- **`tcpd`** — Debian 的 `tcpd` 包（Wietse Venema 的 TCP wrapper）装的是 `/usr/sbin/tcpd`，`tcm` 包装的是更危险的 `/usr/bin/tcpd`。本面板必须 root 运行且装在 `/usr/local/bin`，PATH 优先级更高，等于静默劫持系统命令
- **`ttcp`** — 1980 年代的经典吞吐测试工具 Test TCP，Cisco 设备内置、Red Hat 有 man page，同领域撞名最糟
- **`t`** — 单字母极易被别的工具占用

`tcpo` 查过 Debian 全仓库无同名文件、无同名开源项目，Debian / RHEL / Alpine / Arch 四系均不冲突。

脚本文件本身也叫 `tcpo`（无扩展名）：文件名、URL 路径、安装后的命令名三者一致，省掉了「装个 `xxx.sh` 再建软链」那一层。

### 目标机没有外网

脚本是单文件、无第三方依赖，离线安装就是「把一个文件传上去」。在能上网的机器上：

```bash
curl -fL -o tcpo https://tcp.itssx.com/tcpo   # 或 wget https://tcp.itssx.com/tcpo
scp tcpo root@1.2.3.4:/root/
ssh root@1.2.3.4 'bash /root/tcpo'    # 会自装到 /usr/local/bin 并建 tcpo
```

本地文件执行时脚本**不联网**（直接复制自身），所以这条路完全不需要目标机有外网。

没有 `scp`（只有网页版控制台、跳板机）时走剪贴板，在目标机上敲：

```bash
cat > /root/tcpo <<'TCPSH_EOF'
# 粘贴 tcpo 全文，然后 Ctrl-D
TCPSH_EOF
bash /root/tcpo
```

`<<'TCPSH_EOF'` 的引号是必须的：不加引号 shell 会展开脚本里的 `$` 变量和反引号，粘进去的内容被改坏且不报错。粘完核对一下 `wc -c /root/tcpo`。

脚本本身无依赖，但部分**功能**要用 `ss` / `nstat` / `tc` / `ethtool` / `ping`。目标机连软件源也不通时这些装不上，相关功能会降级并说明影响，核心的 sysctl 与 BBR 配置不受影响。

### 更新策略：不自动更新

脚本从不自己替换代码。启动时只读一个小文本文件（`VERSION`）判断有没有新版，有就在标题栏提示一行，换不换由你敲菜单 7 决定——这台机器可能正在跑业务，让远端代码在用户没同意时改动生产机不合适。

- **多源**：先试 `https://tcp.itssx.com/VERSION`，失败再试 GitHub raw。自建域名挂了仍能发现新版
- **静默失败**：无网络、域名不通、`curl` 没装，一律当「未知」，不打印任何错误
- **有缓存**：结果存 `/var/lib/tcp-dashboard/version-check`，24 小时内最多查一次，每个源超时 3 秒
- **可关**：`TCP_DASHBOARD_NO_CHECK=1` 完全跳过，脚本一次网络调用都不发

菜单 7 的更新也做了两道校验：拉到的内容首行必须是 `#!/bin/bash`、必须过 `bash -n`，任一不满足就放弃并保留当前版本。少了这层，域名被泛解析返回 HTML 时会把 `tcpo` 直接搞坏，而你可能正在远程 SSH 里。

## 仓库结构

```
tcpo                 全部实现，单文件纯 bash，无第三方依赖
VERSION                版本号，与 tcpo 的 SCRIPT_VERSION 必须一致（流水线会校验）
index.html             介绍网页，单页，中英双语文案都在里面
style.css
Jenkinsfile            把网页与 tcpo 同批发到 nginx 静态目录
test/
  site-test.sh         站点与发布配置（不联网、零副作用，几秒）
  distro-test.sh       六大发行版系容器兼容性测试
  effect-test.sh       netem 造长肥链路，实测参数的真实效果
```

上线的只有 `index.html`、`style.css`、`tcpo`、`VERSION` 四个文件，由 `Jenkinsfile` 里的 `PUBLISH` 白名单控制——根目录其余文件（README、规则文件、`test/`）不发布。

## 功能

| 菜单 | 做什么 |
|---|---|
| **9** | **一键全部**：先问角色（普通业务 / 中转节点）和带宽，再依次跑 1+2+3+5 |
| 1 | IPv4 优先解析（改 `/etc/gai.conf`，避免 IPv6 绕路导致的握手延迟） |
| 2 | BBR + FQ（模块未加载时自动 `modprobe tcp_bbr` 并持久化） |
| 3 | 内核参数 · 保守档（缓冲区 / 队列容量 / 连接回收，**不开 IP 转发**） |
| 4 | 内核参数 · 中转档（保守档 + IP 转发 + MSS Clamp，仅中转/代理/隧道节点） |
| 5 | 网卡队列（RPS / RFS / XPS，含开机自动生效的 systemd 单元） |
| **8** | **瓶颈诊断**（只读）：判断调 sysctl 到底有没有用 |
| **a** | **调优效果测量**（只读）：时间窗内的计数器增量对比 |
| **b** | **MTU / PMTU 探测**（只读）：查路径有没有 MTU 黑洞 |
| 6 | 回退全部优化（还原到首次运行前的真实值） |
| 7 | 在线更新脚本 |
| q | 卸载面板（同时回退并清理状态目录） |

**8 / a / b 是零副作用的只读功能**，生产机可直接跑：不改配置、不重启服务、也**不会替你装包**。缺 `ss` / `nstat` / `tc` / `ping` 这些工具时，相关指标跳过并打印手动补装命令，其余项照常跑。

写入类菜单（1-5、9）与此不同，缺的工具会自动装 —— 那些菜单本来就在改这台机器，装个 `ethtool` 不改变性质。

唯一需要你点头的例外在菜单 a：如果指定了压测对端且没装 `iperf3`，会问一次要不要装（压测产生真实流量），答 `N` 则只做被动观测。

### 保守档和中转档怎么选

普通 Web、面板、数据库、一般应用服务器选 **3（保守档）**。

代理、VPN、WireGuard、隧道、中转节点选 **4（中转档）**。它比保守档多两件事：`net.ipv4.ip_forward = 1`，以及给 `mangle FORWARD` 链加 MSS Clamp。

分档的原因是这两项只对「经过本机转发」的流量有意义。普通业务机开 IP 转发等于把自己变成路由器，配上不当的防火墙规则可能成为开放中继；MSS Clamp 在没有转发流量的机器上是条空规则，本机自己发起的连接由 `tcp_mtu_probing` 处理。

### 诊断能回答什么

参数写进去了不代表有效果。内核在每条连接上记了瓶颈到底在哪，菜单 8 把它读出来：

- **发送缓冲受限** → 加大 `wmem` 有效，菜单 3 正对这个问题
- **对端窗口受限** → 本机调 sysctl 无效，要对端也调
- **重传率高（>2%）** → 线路丢包，BBR 能缓解但治不了，`sysctl` 无解，该考虑换线路或上 FEC 类方案（kcptun / Hysteria）
- **都不受限、重传也低** → 应用自己没喂满，调内核参数不会有任何变化

顺带还会报 `softnet` 的 squeeze 次数（判断 `netdev_budget` 那两项对本机是否有意义，长期为 0 就是安慰剂）、出向队列丢包（区分本地发送能力问题和路径问题）、conntrack 使用率（表满会静默丢包）。

诊断需要有流量才有判断力，请在业务跑着或压测时执行。

## 为什么要调

Linux 默认网络参数是给局域网设计的，在高带宽高延迟的跨境链路上有两个瓶颈：

- **缓冲区太小**：默认 `rmem_max`/`wmem_max` 只有 212KB。所需窗口 = 带宽 × RTT（BDP），1Gbps × 200ms ÷ 8 ≈ 25MB，默认值差两个数量级，链路跑不满。
- **Cubic 见丢包就砍速**：跨境公网晚高峰 5% 以内的随机丢包是常态，Cubic 一遇丢包就把发送速率减半。BBR 改为实时测量链路真实容量与延迟，管道没满就继续发，不被随机丢包误导。

这两条不是推导，是实测的。`test/effect-test.sh` 用 netem 造出可控的长肥链路，在同一条链路上对比参数（多次运行的实测区间）：

| 场景 | 调优前 | 调优后 | 倍数 |
|---|---|---|---|
| RTT 160ms + 1.5% 丢包，CUBIC → BBR | 1.2-1.6 Mbps | 113-121 Mbps | **68-95×** |
| RTT 200ms 无丢包，缓冲区 256KB → 64MB | 14-16 Mbps | 110-124 Mbps | **6.8-9.2×** |
| RTT 180ms + 1% 丢包，跑完菜单 2+3 | 1.1-3.3 Mbps | 105-112 Mbps | **32-98×** |
| RTT 200ms，空闲 8 秒后恢复（`slow_start_after_idle` 1→0） | 189-190 Mbps | 309-324 Mbps | **1.6-1.7×** |

第一行是 BBR 的价值：CUBIC 在 1.5% 丢包下几乎跑不动（每次丢包腰斩发送速率，160ms RTT 下要几十秒才爬回来），BBR 不理会随机丢包。

第二行是缓冲区的价值：窗口不够装下 BDP 时，发完一窗就得等 ACK 回来，链路大半时间空着。

第三行是端到端的实际收益——不是手工设参数，而是真的跑一遍菜单 2 + 3。测试会把链路的 RTT（180ms）通过 `TUNE_RTT` 传给脚本，然后核对它算出的缓冲上限与 BDP 公式的期望值是否逐字节一致（实测 BDP 21MB × 2.5 = 54MB，脚本写出的正是 54MB）。

要说明一点：脚本自己的 RTT 探测 ping 的是公网地址（1.1.1.1 等）、走默认路由，探不到 netem 造的这条模拟链路。所以测试显式传 RTT——不传的话只能证明「换了 BBR 有效」，证明不了「按本链路的 RTT 算 BDP」。

有个反向对照值得看：**同样 160ms RTT 但不加丢包**时，CUBIC 141 Mbps、BBR 237 Mbps，只差 68%。所以 BBR 不是「总是快 80 倍」，它的价值是**不被随机丢包误导**——线路干净时两者本来就在同一量级。这也说明第一行那个倍数确实来自丢包，不是测试环境有偏。

倍数区间较宽是因为容器内绝对吞吐受宿主负载影响，所以测试只断言同一次运行内的相对关系。你自己的机器上数字会不同，但方向一致。

## 缓冲区是怎么算的

按 **BDP**（带宽 × 延迟）算，不是拍内存百分比：

```
BDP(bytes) = 带宽Mbps × 125 × RTT_ms
缓冲区上限 = BDP × 2.5，再受总内存 5% 约束，钳到 [8MB, 256MB]
```

RTT 由脚本 ping 三个公共地址取最小值实测（失败则按跨境典型值 150ms），带宽问你。

按内存百分比算是代理指标：同一台 2G 内存的机器，跑 1Gbps/10ms 的同城线和 100Mbps/250ms 的跨境线，需要的窗口差 20 倍，但按内存算会得到同一个值。乘 2.5 是留给丢包重传期间的在途数据。

## 写到哪里

| 路径 | 内容 | 回退时 |
|---|---|---|
| `/etc/sysctl.d/10-bbr.conf` | BBR + fq | 删除 |
| `/etc/sysctl.d/zz-network-performance.conf` | 内核参数（`zz-` 前缀确保最后加载） | 删除 |
| `/etc/security/limits.d/99-network-performance.conf` | 文件句柄上限 | 删除 |
| `/etc/modules-load.d/bbr.conf` | BBR 模块开机加载 | 删除 |
| `/etc/gai.conf` | IPv4 优先（原文件备份为 `gai.conf.bak`） | 还原备份 |
| `/etc/sysctl.d/zz-network-rfs.conf` | RFS 全局流表（菜单 5 单独写，不依赖主配置文件是否存在） | 删除 |
| `/var/lib/tcp-dashboard/original-values` | 首次运行前的参数快照，回退时据此还原 | 卸载时才删 |
| `/var/lib/tcp-dashboard/taken-over` + `takeover-<时间戳>/` | 被接管文件的清单与整份备份 | 逐条还原 |
| `/var/lib/tcp-dashboard/apply.log` | `sysctl --system` 的完整输出（排查用） | 卸载时才删 |
| `/var/lib/tcp-dashboard/pkg.log` | 装包命令的完整输出（源不可达时用来看源返回了什么） | 卸载时才删 |
| `/var/lib/tcp-dashboard/version-check` | 版本检查缓存（一行「时间戳 线上版本号」） | 卸载时才删 |
| `/etc/systemd/system/tcp-dashboard-nic.service` + `/usr/local/bin/tcp-dashboard-nic-apply.sh` | 开机重放 RPS/RFS/XPS | disable 并删除 |
| iptables mangle FORWARD 的 MSS clamp（仅中转档） | 规则不持久化，重启即失效 | 删除规则 |

### 冲突文件接管

`zz-` 前缀只能赢过字典序在它之前的文件。遇到 `zzz-*.conf`，或别的面板脚本写在 `/etc/sysctl.conf` 里的同名参数，依然会被盖掉。

所以菜单 3/4 会主动接管，做法是**逐行注释**：把冲突行改成 `# moved to ... by tcp-dashboard: <原行>`，原文件先整份备份到 `/var/lib/tcp-dashboard/takeover-<时间戳>/`，清单落盘。

只动冲突的那几行，**不禁用整个文件**。发行版和安全加固包常把多个不相关的参数放在同一个 `.conf` 里（比如 `10-network-security.conf` 同时有 `rp_filter`、`accept_redirects` 和一个我们要管的 key），整文件移走会把那些无关的安全参数一起停掉。

跳过 `*.bak`、`*.disabled`、`*.old`、`README*`，不会动这些。回退时从最早那份备份整份还原（多次调优会产生多个备份目录，第一份才是你的原文件）。

### 回退还原真实值

回退分两步，顺序不能反：

1. 删掉本脚本写的配置文件，跑 `sysctl --system` 重新应用系统里剩下的配置（含刚还原的被接管文件）
2. 按受管 key 清单，逐个把运行时值写回快照记录的原值

第 2 步是必须的：`sysctl --system` 只应用「配置文件里还写着的」值，对「文件里已经没有的」key 不做任何事。光删文件的话，中转档写进去的 `ip_forward=1`、本次调优写入的 `tcp_no_metrics_save`、`netdev_budget` 等都会原样留在运行时——`ip_forward` 遗留意味着机器还在当路由器转包，是明确的安全问题。所以回退最后会单独确认一次 `ip_forward`，没能还原就红字提示。

快照在首次运行时生成（`/var/lib/tcp-dashboard/original-values`），**菜单 2、3、4、5 任一入口都会先快照**，所以只跑菜单 2 再回退也能还原到真实原值。快照里记不到的 key 标为 `ABSENT`，回退时跳过而不是瞎写默认值。

不用硬编码兜底值去猜：机器原本可能就在跑 BBR 甚至 reno，发行版默认也可能是 `fq_codel` 而不是 `pfifo_fast`，猜错就是把机器改成了另一个状态。

## 依赖怎么处理

脚本用到的系统工具在最小化安装的机器上常常没有（RHEL/Fedora/openSUSE/Alpine 连 `ss`、`ping` 都不自带）。**装不装取决于菜单类型**，不是缺了就装：

**写入类菜单（1-5、9）缺工具会自动装**，覆盖 `apt-get` / `dnf` / `yum` / `zypper` / `pacman` / `apk` 六种包管理器。这些菜单本来就在改这台机器，装个 `ethtool` 不改变性质：

| 工具 | 谁需要 | 缺了会怎样 |
|---|---|---|
| `ping` | 菜单 3/4 算 BDP | RTT 探不到，缓冲区只能按 150ms 猜 |
| `ss` | 菜单 3/4 保留监听端口 | 端口保留列表生成不了 |
| `ethtool` | 菜单 5 读硬件队列数与丢包计数 | 队列数改用目录数估算，ring buffer 检查跳过 |
| `iptables` | 中转档（菜单 4）的 MSS Clamp | 规则加不上（会明确提示，不假装成功） |

**只读菜单（8、a、b）不主动装包**（唯一例外是下面说的 `iperf3`，要你点头），缺了就跳过相关指标并打印手动补装命令。这是「零副作用、生产机可直接跑」承诺的一部分——装包会刷新包索引、改 dpkg/rpm 数据库、往系统里装新二进制：

| 工具 | 谁需要 | 缺了会怎样 |
|---|---|---|
| `ss` | 菜单 8 的连接级瓶颈归因 | 跳过归因，其余项照常 |
| `nstat` | 菜单 8 重传率、菜单 a 测量 | 跳过重传与计数器增量 |
| `tc` | 菜单 8 查实际 qdisc 与队列丢包 | 看不出 `default_qdisc` 是否真生效 |
| `ping` / `tracepath` | 菜单 b 探 MTU 与路径跳数 | 整项无法进行，会说明原因 |

所以 `ss` 和 `ping` 在两张表里都有：走菜单 3/4 时会装，走菜单 8/b 时只提示。

`iperf3` 是唯一需要你点头的例外——它会打真实流量，菜单 a 里指定了压测对端且没装时会问一次，答 `N` 则只做被动观测。

包名不是简单映射：同一个命令各发行版包名不同，而且 RHEL 系把 `tc` 拆到了独立包 `iproute-tc`（装 `iproute` 拿不到），Debian 系把 `tracepath` 拆到了 `iputils-tracepath`。RHEL 9 起没有名为 `iptables` 的包了，但 `iptables-nft` 声明了 `Provides: iptables`，所以写 `iptables` 照样能装上。

装包动作都套了 180 秒超时，装的过程有转轮 + 已用秒数（慢源上要几十秒，全静默会让人以为卡死），完整输出落 `/var/lib/tcp-dashboard/pkg.log`。软件源不可达时（境外机器拉官方源、被墙、源配置坏了）不会让面板无限卡住，而是明确告诉你哪个包装失败、仍缺哪些工具、以及手动补装的命令，然后降级继续跑：

```
  缺少 ping ss，正在用 dnf 安装 ...
  [1/2] iputils ...
  [1/2] iputils 安装失败（源不可达、超时或包名不符），详见 /var/lib/tcp-dashboard/pkg.log
  [2/2] iproute ...
  [2/2] iproute 完成
  仍缺 ping，相关功能会降级。手动补装:
      dnf install -y iputils
```

只读菜单缺工具时不装，只提示：

```
  缺少 ss nstat tc，相关指标会跳过（只读功能不会自动装包）
  要补装:  dnf install -y iproute iproute-tc
```

`apt` 的索引更新只在索引超过一天没更新时才跑（读 `update-success-stamp` 或 lists 目录的时间），不会每装一个包都 `apt-get update` 一遍。

## 几个要知道的边界

- **`limits.d` 只对登录 shell 生效**。systemd 服务的句柄数由 unit 文件里的 `LimitNOFILE=` 决定，容器内的进程更是完全不受宿主 limits 影响。要给某个服务提句柄数，得改它的 unit。
- **iptables MSS clamp 规则重启即失效**。要持久化请自行安装 `iptables-persistent` 并 `netfilter-persistent save`。
- **缓冲区上限不是预分配**。`tcp_rmem` 第三个值是上限，内核按需增长，配 50MB 不代表每条连接占 50MB。
- **`ip_local_port_range` 有意不从 1024 开始**。1024-32767 之间有大量服务的默认端口（MySQL 3306 / Redis 6379 / PostgreSQL 5432 等），出站连接的随机源端口一旦占用其中之一，该服务重启时 `bind()` 会失败报 `Address already in use`——概率低但极难归因。菜单 3/4 还会扫当前监听端口，把落在 32768-65535 内的自动写进 `ip_local_reserved_ports`（连续端口合并成区间）。**新增服务后重跑菜单 3 可刷新这个列表**。
- **写进 `/etc/sysctl.d/` 不等于生效**。被后加载的文件覆盖、内核不支持该参数、模块没加载，三种情况都静默失败。菜单 3/4 跑完会逐项比对「配置文件写的」与「`sysctl` 实际读到的」，并把三种结果分开报：已生效 / 不一致（红字列出）/ 本内核无此参数。`sysctl --system` 的完整输出留在 `/var/lib/tcp-dashboard/apply.log`。
- **`sysctl --system` 的报错不一定来自本脚本**。它应用系统里的**全部** conf 文件，别的文件报错也会一起打印。最常见的是 systemd 自带的 `/usr/lib/sysctl.d/50-default.conf`：它用 `net.ipv4.conf.*.accept_source_route` 这种通配写法，展开后命中伪接口 `all`，内核直接拒绝，于是**任何一次** `sysctl --system` 都会打印两行 `Invalid argument`（`accept_source_route` 与 `promote_secondaries`）。这跟调优毫无关系。所以面板按受管 key 清单区分归属，分两类显示：本脚本管理的参数写入失败（红字，要管）/ 来自系统其他配置文件（黄字，明确标注与本次调优无关）。混在一起报会让人以为调优失败了。
- **`default_qdisc` 只影响之后新建的队列**。已存在的网卡不会自动换 qdisc，要重启或 `tc qdisc replace` 才生效。菜单 8 会同时显示 `default_qdisc` 和该网卡实际挂的 root qdisc，不一致会提示。
- **`tcp_ecn` 与 `tcp_retries2` 默认注释掉**。前者设为 1 是主动请求 ECN，遇到老旧中间设备可能丢 SYN；后者从 15 降到 8 虽然能更快失败换路，但长静默连接可能被误断。需要就自己在配置文件里放开。
- **ring buffer 不再无条件拉满**。加大能减少突发丢包，但会抬高排队延迟、加剧网卡级 bufferbloat，且已知会瞬断几百毫秒。菜单 5 改为先读 `ethtool -S` 的丢包计数，只有确实有丢包才提示你手动执行 `ethtool -G`。
- **硬件队列够多时不开 RPS**。`ethtool -l` 的 Combined 已经接近核数时，RSS 本身就在分摊，再叠一层软件分发只是多一次 IPI 和跨核唤醒，延迟反而升高。菜单 5 会跳过这类网卡并说明原因。
- **持久化状态不会假报**。菜单 5 的「已持久化」判据是 `systemctl is-enabled` 真的返回 `enabled`，不是「unit 文件存在」——文件是无条件写出来的，容器里或 `systemctl enable` 失败时也在。非 systemd 环境（容器、sysvinit）会明确告诉你无法安装开机单元、本次设置重启后失效，同时仍把应用脚本写出来方便你自己挂到 init 流程。
- **本脚本不换内核**。所有改动都是文件级、可完整回退的。换内核（XanMod BBRv3 那类）最坏情况是重启后开不了机，而这个面板是通过 SSH 用的，出事就失联无法自救——这跟「可完整回退」的性质冲突，所以不做。要装 BBRv3 请单独找专门的脚本，并确保不删旧内核、不自动重启。
- **BBR 版本识别**：`sysctl` 回显 `bbr` 和 `uname -r` 里有 `xanmod` 都证明不了版本。唯一可靠判据是 `modinfo tcp_bbr | awk '/^version:/{print $2}'` 等于 3。主线 `tcp_bbr.c` 从来没写 `MODULE_VERSION`，所以读不到 version 有两种成因：模块确实没报版本，或者 modinfo 通路本身不可用（内建 BBR 且 kmod 太老）。面板拿 `tcp_cubic` 当探针区分——主线一直给它写着 `MODULE_VERSION("2.3")`，探针读得到就说明通路正常。状态栏因此显示 `[BBRv3]` / `[模块未报版本]` / `[版本未知]`。注意 `[模块未报版本]` 只陈述事实、不等于「是主线 BBR」：任何不写 `MODULE_VERSION` 的下游补丁在这里和主线长得一样，缺少 version 不构成「是主线」的证据。要真正判定实现来源得另找判据（比对模块签名或符号）。

## 有些参数是故意不设的

配置文件末尾有一段注释列了「社区脚本普遍在写、但本脚本不写」的参数及原因，摘几条要紧的：

- **`tcp_mem` / `udp_mem`**：单位是页不是字节，同类脚本大面积搞错（见过写出 256GB 的）。内核按空闲内存自动分三档，ESnet 的建议是保持默认；红帽曾专门提交 commit 删掉显式 `udp_mem`，理由是没考虑用户内存大小。
- **`tcp_adv_win_scale = -2`**：6.6 起内核文档标注 Obsolete，已换成 per-socket 的 `scaling_ratio`，唯一消费者不再读这个字段。能写入、不报错、完全无效。
- **`tcp_tw_recycle`**：4.12 起从内核删除，写了 `sysctl --system` 会报 unknown key。
- **`tcp_fack` / `tcp_low_latency`**：内核文档原文「this is a legacy option, it has no effect anymore」（5.4 / 4.14 起）。
- **`tcp_max_tw_buckets` 往小设**：文档明写不该人为降低。设小会让超限的 TIME_WAIT socket 被立即销毁，等于绕过 TIME_WAIT 语义、人为制造 RFC1337 风险，只为让 `ss | wc -l` 的数字好看。
- **`tcp_sack` / `tcp_timestamps` / `tcp_window_scaling` 设 0**：硬化类脚本为省 CPU 或防指纹这么做，对长肥网络是灾难——没有 SACK 一次丢包只能靠累积确认恢复，关掉窗口缩放等于把窗口锁在 64KB。
- **`rp_filter`**：是安全项不是性能项，且 `all` 设 1 后无法在单个接口降回来。代理机常有的非对称回程会静默丢包。取值取决于你的路由拓扑，不该由通用脚本代做决定。
- **`rmem_default` / `wmem_default`**：这是每 socket 的默认值而非上限，抬高对 UDP 尤其浪费（每个 socket 实打实占用）。

## 发布

`Jenkinsfile` 把**网页和 `tcpo` 同批**发到 nginx 静态目录，产物由 `PUBLISH` 白名单控制。

同批发是必须的：`tcpo` 顶部的 `SCRIPT_URL` 指向本站的 `/tcpo`，管道安装（脚本头部的自装块）和菜单 7 在线更新（`check_update()`）都读它。只发网页不发脚本 = 分发地址 404，已安装用户的自更新会失败。

### 站点形态

| 地址 | 返回 |
|---|---|
| `https://tcp.itssx.com/` | 介绍网页 |
| `https://tcp.itssx.com/tcpo` | 脚本本体 |

**`curl | bash` 这条路 nginx 零配置就能用**，普通静态站点即可。宝塔面板新建站点会自动创建 `/www/wwwroot/tcp.itssx.com` 并可一键申请 Let's Encrypt 证书。

有两处可选的配置，不加也不影响安装：

**一、让浏览器能直接查看脚本。** `tcpo` 无扩展名，nginx 按 `default_type` 返 `application/octet-stream`，浏览器会当二进制文件下载而不是显示内容。想让人点开链接先审一遍代码再执行（`curl | bash` 类脚本值得给这个便利）：

```nginx
location = /tcpo { default_type text/plain; charset utf-8; }
```

`curl` 不看 content-type，所以这条只影响浏览器行为。

**二、省掉子路径。** 网页占了根路径，所以一键命令带 `/tcpo`。想让 `curl -sL https://tcp.itssx.com` 直接拿到脚本，可以按 User-Agent 分流（rustup.rs 的做法）：

```nginx
map $http_user_agent $entry {
    default      /index.html;
    ~*curl|wget  /tcpo;
}
location = / { rewrite ^ $entry last; }
```

本项目**没有采用**第二条：它依赖一段站点配置，宝塔重建站点会丢，而某些 CDN 或代理会改写 UA。子路径零配置、行为确定，值那 5 个字符。

两条都要写进宝塔的站点自定义配置目录（`/www/server/panel/vhost/nginx/extension/<域名>/`），面板重写主配置时不覆盖该目录。

### 流水线做了什么

打包阶段有四道门，任一失败就不发（`tcpo` 一旦发坏，已安装用户会通过自更新把坏版本拉走）：

1. **CRLF 检查** — NTFS 下开发极易漂成 CRLF，shebang 后带 `\r` 会让脚本在 Linux 上直接跑不起来
2. **`bash -n`** — 语法检查
3. **`SCRIPT_URL` 指向校验** — 必须等于流水线的 `SITE_URL`，指错了等于这次发布没意义
4. **线上回读** — 部署后 `curl` 拉 `/tcpo`，校验首行是 `#!/bin/bash`（防站点配置错误回落到 `index.html`）且与本次产物逐字节一致（防缓存未刷新）

部署阶段沿用原子发布：完整暂存新版 → 旧版整体挪入 `_prev_release` → 新版挪到位。失败或收到信号都回滚，任何时刻访问者只会看到完整旧版或完整新版。保护清单只留三项：`.htaccess`、`.user.ini`（宝塔生成）、`.well-known`（证书续签验证目录，删了会导致 Let's Encrypt 续签失败）。

SFTP 传输套了 `retry(2)` + `timeout(5min)`：SFTP 阶段无内建超时，会话僵死会永久挂起。

### 换成自己的分发地址

域名出现在三处，改完跑 `bash test/site-test.sh` 会核对一致性：

- **`Jenkinsfile` 的 `SITE_HOST`** —— 只改这一个，`DEPLOY_DIR` / `SITE_URL` / `SITE_VERSION_URL` 与线上校验的三个 `curl` 全部由它派生
- **`tcpo` 的 `SCRIPT_URL`** 默认值 —— 管道安装与菜单 7 更新都读它
- **`tcpo` 的 `VERSION_URLS`** —— 版本检查的候选源。首行必须是自己的域名，否则已安装用户会一直去旧站点问版本；第二行的 GitHub raw 兜底也要换成自己的仓库

流水线的门 3 会校验 `SCRIPT_URL` 与 `VERSION_URLS` 首行都等于 `SITE_URL` / `SITE_VERSION_URL`，指错就不发。

网页与 README 里的命令是给人看的文案，一并改成自己的地址（`site-test.sh` 会核对网页命令与 `SCRIPT_URL` 是否同一地址）。

不想自建服务器的话，两个零成本选项：

- **GitHub raw** 直接用，什么都不用配，代价是地址长、国内偶尔超时
- **jsDelivr**：`bash <(curl -sL https://cdn.jsdelivr.net/gh/SunSeekerX/tcpo@main/tcpo)`

本地调试不用改文件，`SCRIPT_URL` 支持环境变量覆盖：

```bash
TCP_DASHBOARD_URL=http://127.0.0.1:8000/tcpo bash tcpo
```

### 网页本身

单页、两个文件、零外部资源（字体走系统栈，favicon 是内联 data URI SVG）。中英双语文案都在 `index.html` 里，`<head>` 中一行同步脚本按 `navigator.language` 定语言（与 `Accept-Language` 同源），右上角可手动切换并记住选择。全站唯一的 JS 是这个语言切换加一个复制按钮，共约 18 行内联，不引任何库。

## 本地测试

不要拿生产机试。用 Docker：

```bash
docker run --rm -it -v "$PWD":/work ubuntu:24.04 bash -c "apt-get update -qq && apt-get install -y -qq curl procps && bash /work/tcpo"
```

容器里 `net.core.*` 多数是只读的，sysctl 写入会失败（脚本已吞掉报错），但菜单流程、配置文件生成、回退、卸载都能完整验证。

改脚本时想让它从本地拉，不用改文件，`SCRIPT_URL` 支持环境变量覆盖：

```bash
python3 -m http.server 8000 &                                  # 在项目根目录起个静态服务
TCP_DASHBOARD_URL=http://127.0.0.1:8000/tcpo bash tcpo
```

网页是纯静态的，浏览器直接打开 `index.html` 就能看。上面那个静态服务同时也是「网页 + 脚本同站」的完整形态（四个产物本来就在同一目录）：

```
http://127.0.0.1:8000/         → 网页
http://127.0.0.1:8000/tcpo   → 脚本
```

线上目录只有白名单里那四个文件（`index.html`、`style.css`、`tcpo`、`VERSION`），本地多出的 README、`test/` 等不影响这两个地址的行为。手工同步时别漏 `VERSION` —— 少了它版本检查会静默失效（拉不到就当「未知」，不报错）。

## 测试

三套测试，回答三个不同的问题。

**站点与发布配置测试** — 「发布产物本身写对了没有」

```bash
bash test/site-test.sh
```

不需要容器、不联网、零副作用，几秒跑完（项数随规则增加而变动，以实际输出的 `RESULT pass=` 为准）。覆盖三类：

- **行尾** — 所有脚本与网页文件不含 CRLF。NTFS 下开发极易漂成 CRLF，`tcpo` 带 `\r` 会在 Linux 上直接跑不起来
- **分发地址四处一致** — `tcpo` 的 `SCRIPT_URL`、`Jenkinsfile` 的 `SITE_URL`、网页展示的命令、复制按钮里的命令必须指向同一地址，`DEPLOY_DIR` 的目录名要与域名相同。任一处漂了都会导致「网页教的命令」与「脚本自更新拉的地址」不是一回事
- **流水线四道门与回滚逻辑都在** — 保护清单的三项各须在 `swap_in` 和 `restore` 两处都出现（缺一处就会在对应阶段被删）
- **网页自洽** — 标签配对、双语文案按父级容器成对、零外部资源加载、语言判定在 `<head>` 内同步执行
- **开源卫生** — `.gitignore` 挡住含本机路径的 `settings.local.json`、无泄漏的公网 IP、`.gitattributes` 钉住关键类型为 LF

**兼容性测试** — 「在各发行版上跑不跑得起来、参数写对没写错」

```bash
bash test/distro-test.sh              # 全部发行版
bash test/distro-test.sh debian:12    # 只测指定镜像
```

每个发行版跑六十余项断言（当前 62 项，随规则增加而变动，以实际输出的 `RESULT pass=` 为准），覆盖：

- **纯计算**：掩码跨 1/8/32/33/64/128 核、BDP 与内存钳位、十六进制累加不依赖 GNU awk
- **依赖处理**：故意不预装任何工具。验写入类菜单能否自己补齐 `ping`/`ss`/`ethtool`/`iptables`；验只读菜单**不主动装包**（跑完比对包数量前后不变）且给出补装提示，`iperf3` 那条需用户确认的路径由 site-test 的静态断言覆盖；验七个工具的包名映射在本发行版真实存在（`provides` 查询，不是 `info`——RHEL 9 的 `iptables` 是 `iptables-nft` 提供的虚拟包）
- **配置内容**：保守档与中转档各自该设的都设了、该不设的都没设
- **网卡队列与持久化**、**只读菜单无 shell 错误**、**冲突接管只动冲突行**、**回退复原**、**卸载清理**
- **机检项目规则**：无裸跑的 `sysctl --system`（必须走 `apply_sysctl`）、无裸跑装包命令（必须走 `run_pkg` 以套超时）、apt 索引新鲜度判据不依赖锁文件时间戳、`MANAGED_KEYS` 项数下限

最后那组是静态检查，用来守住那些「规则写了但某处漏改」的问题——判例都是实际踩过的。

**效果测试** — 「网络是不是真的变快了」

```bash
bash test/effect-test.sh              # 全部 8 组
bash test/effect-test.sh 1 3          # 只跑第 1、3 组
```

用 netns + veth + netem 在容器里造一条可控的长肥网络（可调 RTT 和丢包率），在同一条链路上对比不同参数的真实吞吐与重传，每组取中位数。8 组分别验：BBR vs CUBIC（有丢包）、BBR vs CUBIC（无丢包，反向对照）、缓冲区上限、端到端跑菜单、诊断结论是否与真实链路一致、测量能否读到真实增量、`notsent_lowat` 取值、`slow_start_after_idle` 空闲恢复。

多数组用 `iperf3`，但组 8 不能——`iperf3` 每次都新建连接，根本没有「空闲」状态可言。那组用一段 python 在**同一条连接**里造出「发 4 秒 → 静默 8 秒 → 再发 1.5 秒」，只测第二段的头 1.5 秒：慢启动的影响集中在重启后的头几个 RTT，测太久会被后面爬满的部分稀释掉。

每组独立跑一个容器——串在一起要 20 分钟以上容易被超时打断，且某组崩了会带走全部结果。

两套测试都有墙钟上限，软件源不可达时快速失败而不是挂死：容器内装包默认 240 秒（`DEP_TIMEOUT`），单组/单发行版默认 900 秒（`GROUP_TIMEOUT` / `DISTRO_TIMEOUT`），超时会清掉容器并在汇总里标「超时未跑完」。效果测试还会先检查 `iperf3`/`tc`/`ip` 是否可用，缺了直接判失败——否则会产出一堆「吞吐为 0」的假结果。

**哪些参数真的被实测覆盖了**（不含糊其辞，一项一项对应到测试组）：

| 参数 | 由哪组验证 |
|---|---|
| `tcp_congestion_control`（BBR） | 组 1 有丢包、组 2 无丢包反向对照、组 4 端到端 |
| `tcp_rmem` / `tcp_wmem` | 组 3 上限对吞吐的影响、组 4 按 BDP 取值是否算对 |
| `tcp_notsent_lowat` | 组 7（本项目取 128K 而非社区常见 16K，验它不损失吞吐） |
| `tcp_slow_start_after_idle` | 组 8（同一连接内「传输 → 空闲 8s → 再传输」，测第二段头 1.5 秒） |

组 5 和组 6 验的是脚本自身的功能（诊断结论与真实链路是否一致、测量能否读到真实增量），不是某个参数。

**没被实测覆盖的**，分两类，都如实说明：

- `net.core.rmem_max` / `wmem_max` / `default_qdisc` —— **测不了**。Docker Desktop（WSL2 后端）把 `/proc/sys/net/core` 整体屏蔽，连节点都不存在，`--privileged`、`--sysctl`、容器内 `unshare --net` 三种都试过。要验需要真实 VM 或裸机。
- `tcp_mtu_probing` / `udp_rmem_min` / `tcp_no_metrics_save` / `netdev_budget` / `somaxconn` 等 —— **没测**。它们要么依赖特定路径条件（PMTU 黑洞、UDP 高并发），要么效果体现在跨连接或长期行为上，容器里造不出可复现的对照。这些参数的依据是内核文档和权威 profile（红帽 tuned / Cloudflare / ESnet），不是本测试。

已通过的发行版：

| 发行版 | 结果 | 备注 |
|---|---|---|
| Ubuntu 24.04 / 22.04 | 通过 | mawk |
| Debian 12 / 13 | 通过 | mawk |
| Rocky Linux 9 | 通过 | gawk，`/etc/sysctl.d` 需现建 |
| AlmaLinux 9 | 通过 | 同上 |
| Fedora 41 | 通过 | 同上 |
| openSUSE Leap 15 | 通过 | |
| Arch Linux | 通过 | |
| Alpine 3.21 | 通过 | busybox 环境，需显式装 bash |

容器里 `net.core.*` 多数不在命名空间内，所以断言只检查配置文件内容、纯计算结果、流程无错、回退能复原，不检查那些参数的运行时生效值。systemd 相关的正向路径（unit 真能 enable）在 `jrei/systemd-ubuntu:24.04` 里单独验过。

## 与上游 fork 的差异

本仓库 fork 自 [666shen/tcp-dashboard](https://github.com/666shen/tcp-dashboard)。

### 本轮改动（对照 93 个同类开源项目 + 内核文档 / 红帽 tuned / Cloudflare / ESnet 做的审查）

修错：

- **RPS 掩码在 64 核及以上算出 `0`，等于关掉 RPS，但面板显示「已开启」**。`printf '%x' $(((1 << n) - 1))` 在 bash 里是 64 位算术，`n>=64` 时移位溢出；33-63 核算出的连续长十六进制串内核也不接受。改为逗号分隔的 32 位字、高位在前（实测 64 核旧写法得 `0`、128 核得 `0`、33 核得 `1ffffffff` 全是错的）
- **状态判据改读真实掩码**。原先判 `rps_sock_flow_entries == 32768`：一是那个值只设了运行时、重启就丢，二是它跟 `rps_cpus` 到底有没有生效毫无关系。且内核会重排掩码格式（去前导零、改分组），所以判「去掉 0 和逗号后还有内容」而不是字符串相等
- `rps_sock_flow_entries` 写进配置文件持久化（原先只 `sysctl -w`，重启即失效）
- `tcp_rmem` 中间值 `87380` → `131072`。87380 是 2.6 时代的老默认值，现代内核默认已是 131072（红帽 RHEL-25847 专门抬过），写它等于把初始接收窗口往回压
- `tcp_wmem` 中间值 `65536` → `16384`（内核默认值，红帽两个 profile 同值）。发送缓冲有自动调优，抬高初值只是每条连接起步多占内存
- `tcp_notsent_lowat` `16384` → `131072`。16384 的出处是 Cloudflare HTTP/2 优先级场景（nginx 直服浏览器），长肥网络转发该用 131072
- 移除 `udp_wmem_min`。内核文档原文「UDP does not have tx memory accounting and this tunable has no effect」
- 移除 `tcp_max_orphans = 32768`。文档明写不该人为降低，默认 `ehash/2` 随内存伸缩，2GB 以上机器通常已超过 32768
- 修正 `tcp_max_syn_backlog` 的注释。现代内核里这个值不再决定 SYN 队列长度（`somaxconn` 钳住 `sk_max_ack_backlog`），它只在 syncookies 关闭时保留末 1/4 队列
- `softnet_stat` 的十六进制累加不再用 `awk` 的 `strtonum`——那是 GNU 扩展，Debian/Ubuntu 默认的 mawk 没有，结果会显示 `?`
- 校验结果把「本内核无此参数」从「全部生效」里分出来，不再自相矛盾；读不到 `rmem_max` 时显示「不可读(容器环境)」而不是 `0MB`

新增：

- **菜单 8 瓶颈诊断**：读 `ss -ti` 的 `sndbuf_limited`/`rwnd_limited` 与 `nstat` 重传率，判断调 sysctl 有没有用；顺带报 softnet squeeze、出向队列丢包、conntrack 使用率、以及 `default_qdisc` 与网卡实际 root qdisc 是否一致
- **菜单 a 效果测量**：计数器取时间窗内的增量而非开机累计值，有 iperf3 就跑主动压测（`-O 2` 丢掉慢启动）
- **菜单 b MTU 探测**：DF 置位的载荷阶梯 + 基线探测（先确认 ICMP 通、`ping` 支持 `-M do`，否则说明「全 FAIL 是没数据不是有黑洞」）
- **保守档 / 中转档分离**：`ip_forward` 和 MSS Clamp 只在中转档出现，且 MSS Clamp 从 `mangle POSTROUTING` 改挂 `mangle FORWARD`（转发路径的专用链）
- **缓冲区按 BDP 算**（带宽 × RTT × 2.5，受内存 5% 约束），RTT 实测，替代原先的固定「内存 5% 钳 16-128MB」
- **冲突文件接管**：`zz-` 前缀赢不过 `zzz-*.conf`，所以主动把冲突文件改名备份、把 `/etc/sysctl.conf` 冲突行注释并留痕，清单落盘供回退
- **回退还原首次运行前的真实值**，不再硬写 `cubic` + `pfifo_fast`
- **RPS/RFS/XPS 开机持久化**：生成一个只读 plan 的独立脚本 + oneshot unit。unit 不调用本脚本的函数——bash 不 hoist 函数定义，「参数分发在文件头、函数在后面」的写法会让 unit 报 command not found 却仍 `exit 0`，`systemctl status` 显示成功而实际什么都没做
- **补 XPS**（发送侧，原先完全没做），`rps_flow_cnt` 改为按队列数分配（原先固定 4096），并确保全局表先分配
- **硬件队列够多时跳过 RPS**（`ethtool -l` Combined 接近核数时 RSS 已足够，叠 RPS 反而升高延迟）
- **ring buffer 改为按需**：先读 `ethtool -S` 的丢包计数，有丢包才提示手动执行，不再无条件拉满
- **自动保留监听端口**：扫落在 32768-65535 内的监听端口，连续端口合并成区间写进 `ip_local_reserved_ports`
- `tcp_no_metrics_save = 1`（跨境链路最值得加的一项：默认 0 会让一次拥塞留下的低 ssthresh 污染同目的地址后续所有连接，表现为「卡过之后一直上不去速」）
- `netdev_budget` / `netdev_budget_usecs`、`tcp_syncookies = 1`
- **BBR 版本识别**（`modinfo tcp_bbr` 的 version 字段，以 `tcp_cubic` 的 version 作通路探针），状态栏显示 `[BBRv3]`/`[模块未报版本]`/`[版本未知]`
- **参数写入改为「只升不降」**（红帽 tuned 的 `=>` 语义）：容量类参数取 `max(内核现值, 目标值)`，避免今后内核默认值抬高后被写回旧值
- **`sysctl --system` 的报错不再吞掉**，完整输出留在 `/var/lib/tcp-dashboard/apply.log`
- 配置文件末尾记录「故意不设哪些参数及原因」，防止后续版本把有意的省略当成遗漏补上

### 早前的改动

- 新增菜单 9「一键全部优化」，四步连续执行不再逐个等回车
- 移除全部假进度条与夸大话术，只输出真实的前后对比
- 移除 `net.ipv4.tcp_congestion_control_version = 3`——这个 sysctl 在任何 Linux 内核上都不存在，BBRv3 也不是这样开的
- `ip_local_port_range` 从 `1024 65535` 改为 `32768 65535`（理由见上方边界说明）
- `tcp_ecn` / `tcp_retries2` 从默认开启改为注释掉，按需自行放开
- 缓冲区上限从「内存 5%」改为「内存 5%，钳到 16MB-128MB」，避免大内存机器算出几百 MB 的无意义值
- `limits.d` 补 `root` 显式条目（PAM 的 `*` 通配不含 root）
- 修：`curl | bash` 管道执行时 stdin 已耗尽，菜单 `read` 拿到 EOF 后空转刷屏
- 修：通过软链 `t` 启动时 `$0` 不等于安装路径，每次都重跑一遍安装并报 `cp: are the same file`（本项目自己已不再建软链，但 `readlink -f "$0"` 保留——用户可能自己建软链指过来）
- 修：回退时 `sed` 分隔符与内容里的 `/96` 冲突导致语法错误
- 修：安装判据 `[ "$_ != $SCRIPT_PATH" ]` 整体是一个非空字符串、条件恒真
- 新增：写完 sysctl 后逐项校验实际生效值，并把配置文件名从 `99-network-performance.conf` 改为 `zz-` 前缀（systemd-sysctl 按字典序应用、后者覆盖前者，多数发行版自带的 `99-sysctl.conf` 会把 somaxconn 等值悄悄盖回去——实测判例：写了 65535、实际生效 1024，全程无任何报错）
- 移除：`net.core.rmem_default` / `wmem_default = 2MB`（这两个是每 socket 默认值不是上限，抬高 10 倍对 UDP 尤其浪费）
- 修：CRLF 行尾与被转义的 `\$`（上游仓库里的 `tcpo` 在 Linux 上跑不起来）
- 分发地址收口到 `SCRIPT_URL` 一处，支持 `TCP_DASHBOARD_URL` 环境变量覆盖，便于本地测试

## 协议

[MIT](LICENSE)
