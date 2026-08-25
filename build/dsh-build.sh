#!/usr/bin/env bash
# one-shot BUILDER 容器执行的构建脚本(task build / docker compose run --rm
# builder)。Dockerfile.builder 把本文件 COPY 到 /tmp/dsh-build 并用作 ENTRYPOINT。
#
# NB: 必须保持为 COPY 进镜像的真实文件, 不要内联回 Dockerfile 的 heredoc -
# classic builder(buildx 不可用时 compose 回退它, 见 label
# com.docker.compose.image.builder=classic)解析 heredoc 但从不喂 stdin: cat 会
# 静默写出空的 /tmp/dsh-build, 容器死于 `exec /tmp/dsh-build: exec format
# error`(0 字节文件的 ENOEXEC)。
set -euo pipefail

cd /app/dsh

# 挂载检出属主与 HOST_UID 不符时, 一行清晰报错代替满屏 EACCES。
if [ "$(stat -c '%u' .)" != "$(id -u)" ] || [ "$(stat -c '%g' .)" != "$(id -g)" ]; then
  echo "[builder] FATAL: /app/dsh is owned by $(stat -c '%u:%g' .), but the builder runs as $(id -u):$(id -g) (HOST_UID/HOST_GID from .env)." >&2
  echo "[builder] Align them: chown the checkout on the host, or adjust HOST_UID/HOST_GID in .env and rebuild." >&2
  exit 1
fi

# pnpm 包存储位置, 显式传给 pnpm。不用环境变量: pnpm 11 不识别
# npm_config_store_dir(下划线)写法, 曾因此静默回落到默认的
# $HOME/.local/share/pnpm, 又因当时 HOME=检出根, 1.4GB 的 .local/ 漏进了仓库。
# /app/dsh/.pnpm-store 随 bind mount 持久化到宿主机 deepseek-harness/.pnpm-store
# (repo 的 .gitignore 已忽略), 与 node_modules 同文件系统, 保持硬链接安装。
STORE_DIR=/app/dsh/.pnpm-store

# HOME 由 Dockerfile.builder 指向易失临时目录; 确保 pnpm 有可写的 home。
mkdir -p "${HOME}"

echo "[builder] running as $(id -u):$(id -g); node $(node --version), pnpm $(pnpm --version)"
echo "[builder] store: ${STORE_DIR} (pnpm resolves: $(pnpm store path --store-dir "${STORE_DIR}"))"

# CI=true 跳过 lefthook postinstall(此副本不需要 git hook); node_modules 已最新
# 时就是一次快速的空验证。
CI=true pnpm install --frozen-lockfile --store-dir "${STORE_DIR}"

# 库(tsc + tsdown)与 web 前端(vite)。'dsh web' 服务 apps/web/dist,
# 必须先于 runtime 容器跑。
NODE_OPTIONS=--max-old-space-size=8192 pnpm run build

# 本架构的 landlock-run 启动器: 沙箱 rung-2 后端(rung-1 是 bwrap, 需要容器默认
# seccomp 拒绝的 user namespace; landlock 完全非特权)。二进制 git-ignored,
# 在这里构建让新克隆自愈, runtime 容器因此完全不需要 security_opt/cap_add。
(cd native/landlock-run && pnpm run build:native)

echo "[builder] artifacts:"
ls -ld node_modules apps/web/dist
ls -l native/landlock-run/packages/*/bin/* 2>/dev/null || true
echo "[builder] done"
