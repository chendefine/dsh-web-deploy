# syntax=docker/dockerfile:1
# =============================================================================
# DeepSeek Harness (dsh) - one-shot BUILDER 容器
#
# 镜像不含仓库源码: compose 把宿主机检出 bind-mount 到 /opt/dsh(见 compose.yaml
# 的 builder 服务), 本容器原地执行:
#   1. pnpm install --frozen-lockfile   -> node_modules/ 留在宿主机
#   2. pnpm run build                   -> lib/ + apps/web/dist 留在宿主机
# 以 .env 的 HOST_UID/HOST_GID(-> compose build args -> 这些 ARG)非特权用户运行,
# 产物自始归宿主机用户: 无 root 属主的 node_modules、无 chown、无需 sudo 清理。
# 经 `task build` 运行, 等价:
#   docker compose build builder && docker compose run --rm builder
# NODE_VERSION 须与 Dockerfile.runtime 同步: 两镜像共用宿主机 node_modules。
# =============================================================================

# Debian trixie(= 13, 与 runtime 镜像同 suite/glibc - 共用的 node_modules 两边都
# 要执行)。显式 pin: 裸 node:<version> 标签跟随当前 Debian stable, 未必是 trixie。
ARG NODE_VERSION=24.16.0
FROM node:${NODE_VERSION}-trixie

# 宿主机检出属主的 uid/gid(compose 从 .env 传入); 改动需重建本镜像。
ARG HOST_UID=1000
ARG HOST_GID=1000

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

ENV DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8 LC_ALL=C.UTF-8 \
    # pnpm store 放检出内(/opt/dsh 已被 compose 挂载), 随挂载持久化到宿主机
    # deepseek-harness/.pnpm-store, 无需单独卷, repo 的 .gitignore 已忽略。
    npm_config_store_dir=/opt/dsh/.pnpm-store

# pnpm 锁定 package.json 的 "packageManager"(11.7.0); node 来自基础镜像。
RUN npm install --global pnpm@11.7.0; node --version; pnpm --version

# landlock-run 启动器工具链: musl-gcc 编译沙箱的 landlock 二进制(静态 musl,
# git-ignored, 由下方构建脚本原地产出)。见 native/landlock-run/scripts/build.ts。
RUN apt-get update && apt-get install -y --no-install-recommends musl-tools && rm -rf /var/lib/apt/lists/*

# 镜像宿主机用户的非特权构建用户。先删基础镜像默认 'node' 用户/组(uid/gid 1000):
# 会与常见的 HOST_UID/HOST_GID=1000 相撞。HOME=/opt/dsh(可写的挂载检出; pnpm 与
# git 需要可写 home)。
RUN userdel --remove node 2>/dev/null || true; \
    groupdel node 2>/dev/null || true; \
    groupadd --gid "${HOST_GID}" dsh \
    && useradd --uid "${HOST_UID}" --gid "${HOST_GID}" -M --shell /bin/bash dsh

# 构建脚本: build context 里的真实文件(./build/dsh-build.sh)
COPY dsh-build.sh /usr/local/bin/dsh-build.sh
RUN chmod 0755 /usr/local/bin/dsh-build.sh

USER dsh
ENV HOME=/opt/dsh

WORKDIR /opt/dsh

ENTRYPOINT ["/usr/local/bin/dsh-build.sh"]
