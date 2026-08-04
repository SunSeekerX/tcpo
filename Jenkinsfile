// tcp.itssx.com 静态站点发布：介绍网页 + tcpo 分发（脚本的 SCRIPT_URL 指向本站，两者必须同批发出）
// 无构建工具链。产物只有下面 PUBLISH 白名单里列的文件，不是整个仓库——
// 根目录还有 README/CLAUDE.md/test/ 等不该上线的东西。这里不写具体数量：
// 白名单加过文件（VERSION），而注释里的数字没跟着改，已漂过一次
pipeline {
    agent any

    options {
        disableConcurrentBuilds()
    }

    environment {
        // 换域名只改 SITE_HOST 这一处，其余全部派生。
        // 曾经 DEPLOY_DIR / SITE_URL / 线上校验的三个 curl 各写一遍域名，
        // 换站点必漏改，且漏改后 CI 会去校验另一个站点（假绿）
        SITE_HOST = 'tcp.itssx.com'
        DEPLOY_DIR = "/www/wwwroot/${SITE_HOST}"
        SITE_URL = "https://${SITE_HOST}/tcpo"
        SITE_VERSION_URL = "https://${SITE_HOST}/VERSION"
    }

    stages {
        stage('打包') {
            steps {
                // 纯静态无需 node；打包前把「脚本能不能跑」的三道门在 CI 侧关掉，
                // 因为 tcpo 一旦发坏，已安装用户的自更新会把坏版本拉走
                sh '''
                    set -e
                    rm -rf .dist dist.tar.gz
                    mkdir -p .dist

                    # 上线白名单。加文件必须同步改这里——漏改只是网页少个资源，
                    # 多发反而会把 README/CLAUDE.md/test/ 之类的内部文件挂到公网
                    PUBLISH="index.html style.css tcpo VERSION"

                    # 门 1: CRLF。NTFS 下开发极易漂成 CRLF，shebang 后带 \\r 会让脚本在 Linux 上直接跑不起来
                    for f in $PUBLISH; do
                        if LC_ALL=C grep -q "$(printf '\\r')" "$f"; then
                            echo "错误: $f 含 CRLF 行尾，修法 sed -i 's/\\r\$//' $f"
                            exit 1
                        fi
                    done

                    # 门 2: bash 语法
                    bash -n tcpo

                    # 门 3: SCRIPT_URL 必须指向本站。指错了脚本会从别处自更新，等于这次发布没意义。
                    # 必须解析出 SCRIPT_URL 的默认值再逐字比对，不能 grep 全文找 URL——
                    # 脚本注释里本来就写着本站地址，全文 grep 时把 SCRIPT_URL 改成
                    # https://evil.example/tcpo 这道门照样返回 PASS（实测过的假绿）
                    code_url=$(sed -n 's/^SCRIPT_URL="${TCP_DASHBOARD_URL:-\\(.*\\)}"$/\\1/p' tcpo)
                    if [ -z "$code_url" ]; then
                        echo "错误: 解析不出 tcpo 的 SCRIPT_URL 默认值（格式变了？）"
                        grep -n '^SCRIPT_URL=' tcpo || true
                        exit 1
                    fi
                    if [ "$code_url" != "$SITE_URL" ]; then
                        echo "错误: tcpo 的 SCRIPT_URL [$code_url] 不等于 $SITE_URL"
                        exit 1
                    fi

                    # 版本检查的候选源第一条也必须指向本站，否则已安装用户会一直去旧域名问版本
                    ver_url=$(sed -n 's|^VERSION_URLS="\\(.*\\)$|\\1|p' tcpo)
                    if [ "$ver_url" != "$SITE_VERSION_URL" ]; then
                        echo "错误: tcpo 的 VERSION_URLS 首行 [$ver_url] 不等于 $SITE_VERSION_URL"
                        exit 1
                    fi

                    # 门 4: VERSION 与脚本内的 SCRIPT_VERSION 必须一致。
                    # 不一致会让已安装用户永久看到「有新版」提示（线上版本号与脚本自报版本对不上）
                    file_ver=$(head -1 VERSION | tr -d ' \\r\\n\\t')
                    code_ver=$(sed -n 's/^SCRIPT_VERSION="\\(.*\\)"$/\\1/p' tcpo)
                    if [ -z "$file_ver" ] || [ "$file_ver" != "$code_ver" ]; then
                        echo "错误: VERSION [$file_ver] 与 tcpo 的 SCRIPT_VERSION [$code_ver] 不一致"
                        exit 1
                    fi
                    echo "=== 发布版本 $file_ver ==="

                    cp $PUBLISH .dist/

                    # 权限在打包侧定好，避免上线后再 chmod 造成短暂 403。
                    # 必须核对：不支持权限位的文件系统（NTFS 挂载等）上 chmod 会静默失败，
                    # 打出的包权限不对，nginx 侧就是 403
                    find .dist -type d -exec chmod 755 {} +
                    find .dist -type f -exec chmod 644 {} +
                    badperm=$(find .dist -type f ! -perm 644 | head -3)
                    if [ -n "$badperm" ]; then
                        echo "错误: 产物权限不是 644（工作区文件系统不支持权限位？）"
                        ls -l $badperm
                        exit 1
                    fi

                    tar -czf dist.tar.gz -C .dist .
                    rm -rf .dist
                    echo "=== 产物 $(du -h dist.tar.gz | cut -f1) ==="
                    tar -tzf dist.tar.gz
                '''
            }
        }

        stage('部署') {
            steps {
                // SFTP 传输阶段无内建超时，会话僵死会永久挂起（参考项目曾两次挂起，一次 12 小时）：
                // 每次尝试限时 5 分钟（正常全程几秒），超时快速失败自动重试一次
                retry(2) {
                    timeout(time: 5, unit: 'MINUTES') {
                        sshPublisher(
                            failOnError: true,
                            continueOnError: false,
                            publishers: [
                                sshPublisherDesc(
                                    configName: 'us_4',
                                    verbose: true,
                                    transfers: [
                                        sshTransfer(
                                            sourceFiles: 'dist.tar.gz',
                                            remoteDirectory: "${DEPLOY_DIR}",
                                            execTimeout: 120000,
                                            execCommand: """
                                                set -e
                                                cd ${DEPLOY_DIR}
                                                # 原子发布: 完整暂存新版 -> 旧版整体挪入 _prev_release -> 新版挪到位; 失败/信号回滚,
                                                # 任何时刻只见完整旧版或完整新版, _prev_release 留作上一版本回滚副本(下轮发布重建)
                                                # 保护清单只留三项: 宝塔生成的 .htaccess/.user.ini, 与证书续签验证目录 .well-known(删了会导致 Let's Encrypt 续签失败)
                                                rm -rf _new_release _prev_release
                                                mkdir _new_release
                                                tar -zxf dist.tar.gz -C _new_release
                                                chown -R www:www _new_release 2>/dev/null || true
                                                mkdir _prev_release
                                                PHASE=1
                                                restore() {
                                                    echo "发布失败, 回滚上一版本..."
                                                    if [ "\$1" -ge 2 ]; then
                                                        find . -mindepth 1 -maxdepth 1 \\( -name _new_release -o -name _prev_release -o -name .htaccess -o -name .user.ini -o -name .well-known -o -name dist.tar.gz \\) -prune -o -exec rm -rf {} +
                                                    fi
                                                    find _prev_release -mindepth 1 -maxdepth 1 -exec mv -t . {} + 2>/dev/null || true
                                                    rmdir _prev_release 2>/dev/null || true
                                                    rm -rf _new_release
                                                }
                                                swap_in() {
                                                    find . -mindepth 1 -maxdepth 1 \\( -name _new_release -o -name _prev_release -o -name .htaccess -o -name .user.ini -o -name .well-known -o -name dist.tar.gz \\) -prune -o -exec mv -t _prev_release {} + || return 1
                                                    PHASE=2
                                                    find _new_release -mindepth 1 -maxdepth 1 -exec mv -t . {} + || return 2
                                                    return 0
                                                }
                                                on_signal() { restore "\$PHASE"; exit 1; }
                                                trap on_signal INT TERM
                                                if swap_in; then
                                                    trap - INT TERM
                                                    # 换入后核对产物都在位: 少了 tcpo 等于分发地址返 404、已安装用户自更新会失败,
                                                    # 少了 VERSION 则版本检查静默失效(拉不到就当「未知」, 不报错)
                                                    if [ -s index.html ] && [ -s style.css ] && [ -s tcpo ] && [ -s VERSION ]; then
                                                        rm -rf _new_release dist.tar.gz
                                                        echo "已发布: \$(ls -1 | tr '\\n' ' ')"
                                                    else
                                                        echo "产物不完整, 回滚..."
                                                        restore 2
                                                        exit 1
                                                    fi
                                                else
                                                    rc=\$?
                                                    trap - INT TERM
                                                    restore "\$rc"
                                                    exit 1
                                                fi
                                            """.stripIndent().trim()
                                        )
                                    ]
                                )
                            ]
                        )
                    }
                }
            }
        }

        stage('线上校验') {
            steps {
                // 只读校验：确认域名真的返回了这次的产物，而不是缓存或旧版
                sh '''
                    set -e
                    curl -fsS -o /dev/null -w '网页 %{http_code} %{size_download}B\\n' "https://$SITE_HOST/"
                    curl -fsS -o /tmp/tcp_check.sh -w '脚本 %{http_code} %{size_download}B\\n' "$SITE_URL"

                    # 分发地址必须返回脚本本体而不是 HTML（比如站点配置错误导致回落到 index.html）
                    head -1 /tmp/tcp_check.sh | grep -q '^#!/bin/bash' || {
                        echo "错误: /tcpo 返回的不是脚本"
                        head -3 /tmp/tcp_check.sh
                        exit 1
                    }
                    cmp -s /tmp/tcp_check.sh tcpo || {
                        echo "错误: 线上 tcpo 与本次产物不一致（缓存未刷新或发布未生效）"
                        exit 1
                    }

                    # VERSION 是已安装用户「检查有无新版」读的那个文件。
                    # 它 404 或内容不对，等于版本提示功能全线失效，且用户完全无感
                    curl -fsS -o /tmp/tcp_check.ver -w 'VERSION %{http_code} %{size_download}B\\n' "$SITE_VERSION_URL"
                    online_ver=$(head -1 /tmp/tcp_check.ver | tr -d ' \\r\\n\\t')
                    local_ver=$(head -1 VERSION | tr -d ' \\r\\n\\t')
                    if [ "$online_ver" != "$local_ver" ]; then
                        echo "错误: 线上 VERSION [$online_ver] 与本次产物 [$local_ver] 不一致"
                        exit 1
                    fi

                    rm -f /tmp/tcp_check.sh /tmp/tcp_check.ver
                    echo "线上校验通过（版本 $local_ver）"
                '''
            }
        }
    }

    post {
        always {
            sh 'rm -f dist.tar.gz /tmp/tcp_check.sh /tmp/tcp_check.ver'
        }
        success { echo '部署成功' }
        failure { echo '部署失败' }
    }
}
