#!/usr/bin/env bash
# 非特权 'dsh web' 启动器: 由运行时容器入口(build/docker-entrypoint.sh)在
# setpriv 下以 DSH_UID:DSH_GID、HOME=/data/workspace 运行。COPY 在镜像的
# /usr/local/bin/dsh-run.sh, 入口直接用, 不在启动时重新生成。
set -euo pipefail

exec pnpm dsh web "$@"
