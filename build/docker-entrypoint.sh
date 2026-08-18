#!/usr/bin/env bash
# 运行时容器入口(COPY 进镜像 /usr/local/bin/docker-entrypoint.sh, 见
# Dockerfile.runtime): 校验挂载的检出、跑 'dsh web'(以 .env 的非特权用户)+
# nginx(root)、转发信号、任一退出即退。降权启动器 /usr/local/bin/dsh-run.sh
# 同样 COPY 进镜像, 不在启动时生成。
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

# --- 预检: 检出是挂载的, 从不烧进镜像 -------------------------------
# 必须已含安装+构建产物(node_modules 来自 pnpm install, apps/web/dist 来自
# pnpm run build), 由 builder 容器(`task build`)在宿主机产出。
for p in node_modules apps/web/dist/index.html; do
  if [ ! -e "/app/dsh/${p}" ]; then
    echo "[entrypoint] FATAL: /app/dsh/${p} is missing." >&2
    echo "[entrypoint] This image ships no sources: compose mounts the host" >&2
    echo "[entrypoint] checkout at /app/dsh. Run 'task build' on the host" >&2
    echo "[entrypoint] first (builder container: pnpm install + build)." >&2
    exit 1
  fi
done

# --- 非特权 'dsh web' 启动器 -----------------------------------------
# 以 DSH_UID:DSH_GID、HOME=/data/workspace 运行; 先为该用户配 git
# safe.directory(宿主机属主的检出/工作区, "dubious ownership")。脚本 COPY 在
# /usr/local/bin/dsh-run.sh(与 Dockerfile.builder 的 dsh-build.sh 同模式),
# 不要在这里重新生成。
echo "[entrypoint] dsh web -> http://127.0.0.1:3080  (DSH_HOME=${DSH_HOME}, user ${DSH_UID}:${DSH_GID})"
setpriv --reuid="${DSH_UID}" --regid="${DSH_GID}" --clear-groups \
  env HOME=/data/workspace /usr/local/bin/dsh-run.sh &
dsh_pid=$!

echo "[entrypoint] nginx :80 (http) -> 127.0.0.1:3080"
nginx -g 'daemon off;' &
nginx_pid=$!

shutdown() {
  echo "[entrypoint] shutting down"
  kill "${dsh_pid}" "${nginx_pid}" 2>/dev/null || true
}
trap shutdown TERM INT QUIT

set +e
wait -n "${dsh_pid}" "${nginx_pid}"
status=$?
set -e

shutdown
wait "${dsh_pid}" "${nginx_pid}" 2>/dev/null || true
exit "${status}"
