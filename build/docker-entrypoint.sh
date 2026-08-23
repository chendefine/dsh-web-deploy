#!/usr/bin/env bash
# 运行时容器入口(COPY 进镜像 /usr/local/bin/docker-entrypoint.sh, 见
# Dockerfile.runtime): 校验挂载的检出、跑 'dsh web'(以 .env 的非特权用户)+
# nginx(root)、转发信号、任一退出即退。dsh CLI 包装器 /usr/local/bin/dsh
# (exec 检出 node_modules 里的 tsx 直跑 apps/cli/src/bin.ts, 与 package.json
# 的 'dsh' 脚本等价)同样 COPY 进镜像, 不在启动时生成。
#
# 进程模型:
#   root      本入口 + nginx master(绑 :80); nginx worker 自行降为 nginx 用户
#   DSH_UID   'dsh web' 及其子进程(agent、工具)经 setpriv 以 .env 的 uid/gid
#             运行, 写入的数据(DSH_HOME、/data/workspace、检出)全部归宿主机
#             用户, 永不归 root
set -euo pipefail

DSH_HOME="${DSH_HOME:-/data/dsh-home}"

# 'dsh web' 的非特权身份(compose 从 .env 传 HOST_UID/HOST_GID)。严格校验:
# 坏值必须中止, 而不是静默换用户运行。
DSH_UID="${DSH_UID:-1000}"
DSH_GID="${DSH_GID:-1000}"
case "${DSH_UID}:${DSH_GID}" in
  *[!0-9:]*) echo "[entrypoint] FATAL: DSH_UID/DSH_GID must be numeric, got '${DSH_UID}:${DSH_GID}'" >&2; exit 1;;
esac

# 镜像为 HOST_UID 烧了 passwd 条目(Dockerfile.runtime 步骤 5)。若 DSH_UID 漂移
# (.env 改了没重建), 数字 setpriv 降权仍可用, 但 uid->name 查询会失败 - 大声警告。
if ! getent passwd "${DSH_UID}" >/dev/null; then
  echo "[entrypoint] WARN: uid ${DSH_UID} has no passwd entry in this image" >&2
  echo "[entrypoint] (built with a different HOST_UID? rebuild: task build)" >&2
fi

mkdir -p "${DSH_HOME}" /data/workspace
cd /app/dsh

# 数据挂载归宿主机用户; 若 docker daemon 在首启前以 root 建了顶层目录, 移交之。
# 已有文件不动 - 只修宿主机上既存的 root 属主数据。
chown "${DSH_UID}:${DSH_GID}" "${DSH_HOME}" /data/workspace 2>/dev/null || \
  echo "[entrypoint] WARN: could not chown data dirs (running as $(id -u):$(id -g))" >&2

# --- 首启播种 dsh 的交互式 shell 配置 ---------------------------------
# .zshrc 是镜像定制的 oh-my-zsh 模板(Dockerfile.runtime 步骤 7), .bashrc/
# .profile 则是 Debian 基础镜像 /etc/skel 自带 - 登录 shell 是 zsh 只读
# .zshrc, 后两者服务 'docker exec ... bash' 与 'bash -l' 场景(Debian 的
# .profile 会 source .bashrc)。dsh 的 HOME=/data/workspace 是运行时挂载、
# 构建期不存在 - 每个文件各自仅在缺失时播种一次, 已有文件(含用户后续
# 改动)永不覆盖。
for f in .zshrc .bashrc .profile; do
  if [ ! -e "/data/workspace/${f}" ]; then
    install -m 0644 -o "${DSH_UID}" -g "${DSH_GID}" \
      "/etc/skel/${f}" "/data/workspace/${f}" 2>/dev/null \
      || echo "[entrypoint] WARN: could not seed /data/workspace/${f}" >&2
  fi
done

# --- 预检: 检出是挂载的, 从不烧进镜像 -------------------------------
# 必须已含安装+构建产物(node_modules 来自 pnpm install, apps/web/dist 来自
# pnpm run build), 由 builder 容器(`task build`)在宿主机产出。除 web 产物外
# 也查 dsh 包装器的两处依赖: node_modules/.bin/tsx 与 apps/cli/src/bin.ts
# (package.json 的 'dsh' 脚本同一路径), 缺失即提前给出可操作的报错。
for p in node_modules/.bin/tsx apps/cli/src/bin.ts apps/web/dist/index.html; do
  if [ ! -e "/app/dsh/${p}" ]; then
    echo "[entrypoint] FATAL: /app/dsh/${p} is missing." >&2
    echo "[entrypoint] This image ships no sources: compose mounts the host" >&2
    echo "[entrypoint] checkout at /app/dsh. Run 'task build' on the host" >&2
    echo "[entrypoint] first (builder container: pnpm install + build)." >&2
    exit 1
  fi
done

# --- 容器内dsh命令: /usr/local/bin/dsh ---------------------------
cat > /usr/local/bin/dsh << 'EOF'
#!/usr/bin/env bash
# dsh CLI wrapper — runs the /app/dsh checkout CLI

cd /app/dsh

exec /app/dsh/node_modules/.bin/tsx /app/dsh/apps/cli/src/bin.ts "$@"
EOF
chmod 0755 /usr/local/bin/dsh

# --- 容器内自重启命令: /usr/local/bin/reboot ---------------------------
# 每次启动重写, 内容固定故幂等。compose 给每个实例 stamp 了 `restart:
# unless-stopped`: PID 1 退出的瞬间, daemon 就把同一个容器对象(端口/挂载/
# 别名不变)拉回来 - 所以容器内自重启只需让容器退出, 即对 PID 1 发一个
# TERM。PID 1 是 docker-init(init: true), 它把 TERM 转发给本入口的 trap,
# 优雅收尾 'dsh web' + nginx(卡死不理 TERM 的子进程由下方 watchdog 兜底)。
# 脚本里经 sudo 是因为 task/agent 会话以非特权 dsh 运行, 而 PID 1 只收
# root 的信号(镜像烧了 dsh 的 NOPASSWD sudo; root 会话里 sudo 直接放行,
# 同一条命令两态通用)。这是 plain reboot 非 recreate: compose.yaml/镜像
# 变更仍需宿主机上的 task dsh:restart。基础镜像无同名命令(无 systemd/
# sysvinit), /usr/local/bin 在所有用户 PATH 首位, 无遮蔽冲突。
cat > /usr/local/bin/reboot <<'EOF'
#!/bin/sh
# Reboot THIS container: TERM -> PID 1 (docker-init -> entrypoint trap) ->
# graceful shutdown -> the daemon restart policy (unless-stopped) starts
# the same container again.
echo 'reboot: signaling PID 1; this shell dies when the container exits, the daemon brings it back'
exec sudo -n kill -TERM 1
EOF
chmod 0755 /usr/local/bin/reboot
# echo "[entrypoint] wrote /usr/local/bin/reboot (in-container self-reboot)"

# --- 非特权 'dsh web' 启动 -------------------------------------------
# 以 DSH_UID:DSH_GID、HOME=/data/workspace 运行, 直接 exec 镜像烧入的 dsh
# CLI 包装器(与 Dockerfile.builder 的 dsh-build.sh 同 COPY 模式): 它 exec
# 检出 node_modules 里的 tsx 跑 apps/cli/src/bin.ts, 与 package.json 的
# 'dsh' 脚本等价, tsx 负责向真正的 CLI 进程转发 TERM/INT。git
# safe.directory(宿主机属主的检出/工作区, "dubious ownership")已烧进镜像
# /etc/gitconfig(Dockerfile.runtime 步骤 9), 启动不再写用户级配置。
echo "[entrypoint] dsh web -> http://127.0.0.1:3080  (DSH_HOME=${DSH_HOME}, user ${DSH_UID}:${DSH_GID})"
setpriv --reuid="${DSH_UID}" --regid="${DSH_GID}" --clear-groups \
  env HOME=/data/workspace /usr/local/bin/dsh web &
dsh_pid=$!

echo "[entrypoint] nginx :80 (http) -> 127.0.0.1:3080"
nginx -g 'daemon off;' &
nginx_pid=$!

# 关停宽限(秒), 期满 TERM 升级 KILL。镜像 docker 默认停止宽限同为 10s。
SHUTDOWN_GRACE="${SHUTDOWN_GRACE:-10}"
kill_watchdog=""

# TERM 的有界宽限后升级 KILL。daemon 的停止宽限 + SIGKILL 兜底只覆盖
# daemon 主动停止(docker stop/restart); 容器自行退出路径 —— 任一子进程
# 崩溃, 或容器内 `sudo kill -TERM 1` 自重启 —— 外部没有任何力量强制
# 容器退出: 子进程若卡死不理 TERM, 入口会永远悬在 wait 上, 容器不退出,
# daemon 的 restart policy(unless-stopped)也就永远不触发。watchdog 让
# 关停有界: 先 TERM 优雅收尾, 宽限期后 KILL 强制兜底(容器退出时残留的
# watchdog 子壳随 PID 命名空间一起被内核清掉, 无泄漏)。
shutdown() {
  echo "[entrypoint] shutting down"
  kill "${dsh_pid}" "${nginx_pid}" 2>/dev/null || true
  ( sleep "${SHUTDOWN_GRACE}" && kill -KILL "${dsh_pid}" "${nginx_pid}" 2>/dev/null ) &
  kill_watchdog=$!
}
trap shutdown TERM INT QUIT

set +e
wait -n "${dsh_pid}" "${nginx_pid}"
status=$?
set -e

shutdown
wait "${dsh_pid}" "${nginx_pid}" 2>/dev/null || true
kill "${kill_watchdog}" 2>/dev/null || true
exit "${status}"
