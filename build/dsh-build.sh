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

echo "[builder] running as $(id -u):$(id -g); node $(node --version), pnpm $(pnpm --version), store ${npm_config_store_dir}"

# CI=true 跳过 lefthook postinstall(此副本不需要 git hook); node_modules 已最新
# 时就是一次快速的空验证。
CI=true pnpm install --frozen-lockfile

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
