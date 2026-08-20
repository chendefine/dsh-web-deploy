# DeepSeek Harness（dsh）容器部署

用 Docker Compose 一键部署 [DeepSeek Harness（dsh）](https://github.com/deepseek-ai/deepseek-harness)：只需两个开关，即可在本机单实例、多用户认证（Authelia SSO）、内置 TLS 等四种拓扑之间自由切换，[Task](https://taskfile.dev/) 驱动构建、启动、用户管理与升级的全流程。

## 目录

- [简介](#简介)
- [适用场景](#适用场景)
- [快速开始](#快速开始)
- [日常使用](#日常使用)
- [命令参考](#命令参考)
- [配置参考](#配置参考)
- [运行模式详解](#运行模式详解)
- [TLS](#tls)
- [用户管理](#用户管理)
- [架构与实现细节](#架构与实现细节)
- [数据持久化与隔离边界](#数据持久化与隔离边界)
- [安全注意事项](#安全注意事项)
- [网络](#网络)
- [从旧版本迁移](#从旧版本迁移)
- [故障排查](#故障排查)

## 简介

本目录是一套模块化的 dsh 容器部署方案，由三个相互独立的运行块组成，Taskfile 按开关选择并收敛目标拓扑：

| 块   | 内容                     | 说明                                                           |
| ---- | ------------------------ | -------------------------------------------------------------- |
| dsh  | dsh runtime 实例         | `AUTH_GATEWAY=false` 时只启动第一个实例；`true` 时启动全部实例 |
| auth | Authelia + nginx gateway | 可选认证块：SSO 登录，按用户路由到各自独立实例                 |
| tls  | 内置 HTTPS 终结器        | 可选 TLS 块：自动生成/复用证书并反代 HTTP 入口                 |

## 适用场景

- **本机 / 内网单人使用**（`AUTH_GATEWAY=false`）：零认证，一条命令起服务，`HTTP_PORT` 直接可访问；
- **团队 / 多用户共享主机**（`AUTH_GATEWAY=true`）：Authelia SSO 统一登录，每个用户拥有独立的 DSH_HOME 与 workspace 实例，互不干扰；
- **需要 HTTPS 的部署**：内置 TLS 终结器开箱即用（自签或自有证书），也可对接外部 Caddy / Traefik / nginx 终结器；
- **追求低成本运维**：`task up` 是幂等收敛操作，`task update` 一条命令完成版本升级重建，数据全部落盘保留。

## 快速开始

### 1. 环境要求

- Docker 与 Docker Compose
- [Task](https://taskfile.dev/)
- jq（`task config:validate` 解析合并模型时依赖）
- 当前目录可写

### 2. 首次启动

默认配置（`.env.example` ）：

```dotenv
AUTH_GATEWAY=false
HTTPS_EXPORT=true
HTTP_PORT=3080
HTTPS_PORT=443
```

因此默认模式是 **single+tls**：只启动第一个 dsh runtime 实例，`HTTP_PORT` 直接发布在该实例的内置 nginx 上，`HTTPS_PORT` 由内置 TLS 终结器发布。

```bash
cp .env.example .env
# 按需修改 .env，尤其是 HOST_UID/HOST_GID、域名与模式开关
task build
task up
```

- `task build`：缺少源码时自动 clone，构建 builder/runtime 镜像并生成源码产物；不启动运行服务。
- `task up`：验证配置与合并模型、重建共享 runtime 镜像，清理与目标模式冲突的入口，然后启动目标拓扑（含按 `HTTPS_EXPORT` 决定的 TLS）。
- **全新环境必须先 `task build`**；仅 `task up` 不会运行 builder 生成前端与包产物。

源码默认从 `https://github.com/deepseek-ai/deepseek-harness.git` 获取，可覆盖：

```bash
DSH_REPO_URL=https://example.com/deepseek-harness.git task init
```

`task init` 遇到有效检出会跳过；目录已存在但不是有效仓库时会报错，不覆盖现场。

### 3. 访问验证

默认内置证书是自签名证书。确保 `DSH_DOMAIN` 能解析到部署主机，例如本机可设置：

```dotenv
DSH_DOMAIN=dsh.localhost
```

然后访问 `https://dsh.localhost/`（或明文 `http://<host>:3080/`）。浏览器首次会显示自签证书警告；可导入 `nginx/tls/` 中的证书到信任库，或换用受信证书（见 [TLS](#tls)）。

### 4. 下一步

- 需要多用户认证？见 [运行模式详解](#运行模式详解) 与 [用户管理](#用户管理)。
- 需要外部 TLS 终结器或自定义端口/域名？见 [配置参考](#配置参考)。
- 遇到问题？先跑 `task config:validate`，再看 [故障排查](#故障排查)。

## 日常使用

### 常用命令速查

| 场景                       | 命令                                                                     |
| -------------------------- | ------------------------------------------------------------------------ |
| 启动 / 收敛当前模式        | `task up`                                                                |
| 停止全部容器（保留数据）   | `task down`                                                              |
| 重启（强制重建）当前模式栈 | `task restart`                                                           |
| 查看容器状态               | `task ps`                                                                |
| 跟踪日志                   | `task logs`，或分块 `task dsh:logs` / `auth:logs` / `tls:logs`           |
| 升级版本                   | `task update`                                                            |
| 进入实例 shell             | `task shell`（无认证模式进入第一个实例）；认证模式 `task shell -- user1` |
| 校验配置                   | `task config:validate`                                                   |
| 查看渲染后的 Compose 模型  | `task config:show`                                                       |

### 切换运行模式

编辑 `.env` 中的两个开关，再运行：

```bash
task up
```

`task up` 是收敛操作：它会移除与新模式冲突的 HTTP 入口持有者（例如从认证切回单实例时移除 gateway，或反向移除仍带端口的旧 runtime 容器），并按模式重建 dsh/auth 块。切换期间 TLS 若在运行会自动 reload 以刷新 `dsh-http-entry` 解析，允许短暂 502，不会出现认证绕过。

注意：`task restart` 以 `up -d --force-recreate` 强制重建所选容器，因此会应用端口/别名等 Compose 配置；但它不做入口冲突清理，切换模式请一律使用 `task up`。

### 升级版本

```bash
task update
```

重建源码产物和镜像，再以 `task up` 同款的收敛方式更新当前目标模式：只有镜像或配置发生变化的服务会被重建（重建后的 runtime 镜像会被自动采用），未变化的服务（如 authelia/gateway）保持运行、Authelia 会话不受影响（`HTTPS_EXPORT=false` 时不启动也不移除已有 TLS 容器，仅对运行中的容器做 best-effort reload）。挂载的数据目录不会被删除。需要强制重建全部所选容器时使用 `task restart`，或 `task update -- --force-recreate` 显式传入。

### 多用户基本操作（认证模式）

```bash
task user:create -- user1 password1         # 创建用户：自动同步认证、实例与路由
task dsh:up -- user1                        # 只启动该用户的实例
task user:reset_password -- user1 password2 # 重置密码
task user:list                              # 查看用户列表
```

详细规则见 [用户管理](#用户管理)。

## 命令参考

### 总栈与维护命令

| 命令                                          | 作用                                                                                                                                                                                                                            |
| --------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `task up`                                     | 收敛并启动两个开关选中的完整模式                                                                                                                                                                                                |
| `task down`                                   | 清除 dsh/auth/tls 的全部运行容器及项目资源，保留挂载数据                                                                                                                                                                        |
| `task update`                                 | 重建源码产物和镜像，再以收敛方式更新当前目标模式（仅重建镜像/配置变化的服务，未变化的服务保持运行；需强制重建用 `task restart` 或 `task update -- --force-recreate`；`HTTPS_EXPORT=false` 时不启动也不移除已有 TLS 容器，仅对运行中的容器做 best-effort reload）                |
| `task build`                                  | 构建 builder/runtime 镜像和源码产物，不启动运行服务                                                                                                                                                                             |
| `task config:validate`                        | 校验布尔值、端口、合并模型不变量，并输出所选模式与 HTTP 入口                                                                                                                                                                    |
| `task config:show`                            | 展示当前模式渲染后的 Compose 模型                                                                                                                                                                                               |
| `task ps`                                     | 显示所有 profile 中的容器                                                                                                                                                                                                       |
| `task logs`                                   | 跟踪当前完整模式日志                                                                                                                                                                                                            |
| `task dsh:logs` / `auth:logs` / `tls:logs`    | 跟踪指定块日志                                                                                                                                                                                                                  |
| `task restart`                                | 以 `up -d --force-recreate` 重建两个开关选中的完整栈：dsh 实例 + `AUTH_GATEWAY=true` 时的 auth 块 + `HTTPS_EXPORT=true` 时的 tls 块；未创建的所选块会被直接创建（模式切换仍请用 `task up`，restart 不清理与新模式冲突的旧容器） |
| `task shell`                                  | 无认证模式默认进入第一个实例；认证模式使用 `task shell -- user`                                                                                                                                                                 |
| `task hash -- '口令'`                         | 生成 Authelia argon2id 密码摘要                                                                                                                                                                                                 |
| `task user:create -- <name> <密码>`           | 创建用户：同步 Authelia 用户库（含 dsh 组）、compose 实例、gateway 路由，创建数据目录，**自动启动新实例并优雅 reload gateway**；全程零重启，创建完即可登录                     |
| `task user:reset_password -- <name> <新密码>` | 重置用户密码（重新生成 argon2id 摘要）                                                                                                                                                                                          |
| `task user:remove -- <name>`                  | 删除用户全部配置与运行容器；**保留** `dsh-home/<name>`、`workspace/<name>`                                                                                                                                                      |
| `task user:list`                              | 列出用户（标注 primary 实例）                                                                                                                                                                                                   |
| `task clean` / `task clean:store`             | 清构建产物 / 再清 pnpm store                                                                                                                                                                                                    |

### 块级命令

| 命令                | 作用                                                                                                                                                                                                                                                                                                                      |
| ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `task dsh:up`       | 启动选中的 dsh 块：`AUTH_GATEWAY=false` 只启动第一个实例并直接发布 `HTTP_PORT`；`true` 启动全部实例（无宿主机端口）。可指定单个用户：`task dsh:up -- user1 [--force-recreate 等 compose 参数]`                                                                                                                            |
| `task dsh:down`     | 删除全部 dsh 实例及旧版遗留容器；保留宿主机数据。可指定单个用户：`task dsh:down -- user1` 只删除该实例（同时跳过遗留容器清理）                                                                                                                                                                                            |
| `task dsh:restart`  | 以 `up -d --force-recreate` 重建选中的 dsh 实例（`AUTH_GATEWAY=false` 只重建第一个实例，其余实例不动）。可指定单个用户：`task dsh:restart -- user1`                                                                                                                                                                       |
| `task auth:up`      | 启动 Authelia/gateway，`HTTP_PORT` 直接发布在 gateway；要求 `AUTH_GATEWAY=true`                                                                                                                                                                                                                                           |
| `task auth:down`    | 删除 Authelia、gateway；保留认证数据                                                                                                                                                                                                                                                                                      |
| `task auth:restart` | 以 `up -d --force-recreate` 重建 Authelia/gateway；要求 `AUTH_GATEWAY=true`（会使 Authelia 内存会话失效，用户需重新登录）                                                                                                                                                                                                 |
| `task auth:reload`  | 零中断热加载，**不重建容器、不重启进程**：gateway 在容器内重渲染路由模板并 `nginx -s reload`（master 不退，既有 SSE/WS 长连接由旧 worker 继续服务至自然结束）；Authelia 用户库由 `watch: true` 自动热载，无需任何操作。适用于用户口令/用户库条目与 gateway 路由变更；`configuration.yml`（ACL 等）变更仍需 `auth:restart` |
| `task tls:up`       | 启动内置 TLS；**不受 `HTTPS_EXPORT` 限制**，随时可用                                                                                                                                                                                                                                                                      |
| `task tls:down`     | 删除内置 TLS 容器；保留证书                                                                                                                                                                                                                                                                                               |
| `task tls:restart`  | 以 `up -d --force-recreate` 重建内置 TLS 容器；**不受 `HTTPS_EXPORT` 限制**，随时可用                                                                                                                                                                                                                                     |

块级命令互相独立。若只启动下游块，上游缺失时看到 502 属于预期；上游出现后自动恢复。`restart` 系列以 `up -d --force-recreate` 强制重建所选容器（容器按当前 Compose 模型重建，端口/别名等配置会一并应用；未创建的所选容器会被直接创建），但从不删除所选范围之外的容器，也不做入口冲突清理——切换模式请用 `task up`。

### 单用户定向操作

三个 dsh 块命令都支持 `-- <name>` 只操作某个用户的实例，不影响其他用户容器：

```bash
task dsh:up -- user1                  # 只启动 user1 的实例
task dsh:up -- user1 --force-recreate # 名字后可继续跟 compose up 参数
task dsh:down -- user1                # 只停止并删除 user1 的实例
task dsh:restart -- user1             # 只强制重建 user1 的实例
```

- 名字可用裸用户名或服务名（`user1` 与 `dsh-user1` 等价，与 `task shell -- user1` 一致）；首个以 `-` 开头的词视为 compose 参数而非用户名；
- 未知用户名直接报错并列出可用实例，不会执行任何 docker 命令；
- 定向 `up` 只 `--no-deps` 启动目标实例：不删除其他实例、不清理遗留容器；`AUTH_GATEWAY=false` 时若目标不是第一个实例会给出警告（该模式仅 primary 发布 `HTTP_PORT`，其余实例无入口端口）；
- 聚合命令 `task up/down/restart` 不接受定向参数，行为保持全量；单用户操作请使用 `dsh:` 前缀命令。

### 配置读取规则

部署开关（`AUTH_GATEWAY`、`HTTPS_EXPORT`、`HTTP_PORT`、`HTTPS_PORT`、`HOST_UID`、`HOST_GID`）**只从 `.env` 读取**（Go Task 原生 `dotenv:`，文件缺失时使用默认值）。Shell 环境变量前缀（如 `AUTH_GATEWAY=true task up`）已不受支持且不产生任何效果：Task 的 dotenv 机制使 shell 导出无法进入模板上下文，每次 docker 调用也带有强制覆盖的环境前缀。配置校验会在 Compose 渲染前拒绝非法布尔值、非法端口、相同的 HTTP/HTTPS 端口以及不可用的 UID/GID 范围。

## 配置参考

### `.env` 变量总览

| 变量                              | 默认值                 | 说明                                                                                               |
| --------------------------------- | ---------------------- | -------------------------------------------------------------------------------------------------- |
| `AUTH_GATEWAY`                    | `false`                | 认证开关：`false` 单实例直发；`true` 启动全部实例 + Authelia。详见 [运行模式详解](#运行模式详解)   |
| `HTTPS_EXPORT`                    | `true`                 | `task up` / `task update` 是否自动启动内置 TLS；不影响 HTTP 端口，也不会停止/删除已存在的 TLS 容器 |
| `DSH_DOMAIN`                      | `harness.deepseek.com` | 认证模式与内置 TLS 使用的域名；不能用裸 `localhost`                                                |
| `HTTP_PORT`                       | `3080`                 | 宿主机 HTTP 发布端口，四种模式下始终开放                                                           |
| `HTTPS_PORT`                      | `443`                  | 浏览器侧公开 HTTPS 端口；不能与 `HTTP_PORT` 相同                                                   |
| `HOST_UID` / `HOST_GID`           | `1000` / `1000`        | 构建与运行时写入文件使用的 uid/gid；修改后需 `task build` 或 `task update`                         |
| `TZ`                              | 空（UTC）              | 时区，如 `Asia/Shanghai`                                                                           |
| `BUILDER_NETWORK` / `RUN_NETWORK` | 空                     | 设置即加入已存在的 external 网络；详见 [网络](#网络)                                               |
| `DEEPSEEK_API_KEY`                | 空                     | 所有 dsh 实例共享、只读且优先于 UI 的 API key；需要用户级隔离请勿设置                              |
| `DSH_REPO_URL`                    | GitHub 官方仓库        | `task init` 克隆源码的地址                                                                         |
| `GATEWAY_PORT`                    | 已弃用                 | 仅为旧 `.env` 保留兼容回退；新配置请改用 `HTTP_PORT`                                               |

### HTTP_PORT

`HTTP_PORT` 默认 `3080`，是宿主机 HTTP 发布端口的权威配置，四种模式组合下始终开放：

- `AUTH_GATEWAY=false`：直接发布在第一个 runtime 实例的内置 nginx 上，浏览器可访问（无认证，请勿暴露到不受信网络）；
- `AUTH_GATEWAY=true`：直接发布在 gateway 上，主要供外部 TLS 终结器反代；明文端口不能完成 Authelia 登录。

`GATEWAY_PORT` 已弃用。当前实现为旧的、通常被忽略的 `.env` 提供临时兼容回退：仅当没有 `HTTP_PORT` 时才采用 `GATEWAY_PORT`。新配置应删除旧变量并改用 `HTTP_PORT`；`task config:validate` 会给出弃用警告。

### HTTPS_PORT

`HTTPS_PORT` 默认 `443`，不能与 `HTTP_PORT` 相同（两个端口会同时发布）：

- 内置 TLS 模式中，它是 `tls` 发布的宿主机端口；
- 外部 TLS 模式中，它应等于外部终结器面向浏览器公开的端口，以便 Authelia 构造正确 URL；
- 非 443 时访问地址和 Authelia 跳转均包含该端口。

### DSH_DOMAIN

认证模式和内置 TLS 使用 `DSH_DOMAIN`。认证模式不可使用裸 `localhost`，因为 Authelia cookie domain 必须含点；本机可用 `dsh.localhost`。其他域名需设置 DNS，或在客户端 `/etc/hosts` 中映射。

## 运行模式详解

### 两个开关的语义

- `AUTH_GATEWAY` 决定实例拓扑与 HTTP 入口：
  - `false`：只启动 `compose.yaml` 中**第一个** `<<: *dsh-runtime` 服务，并把它的内置 nginx（容器内 `:80`）直接发布到 `HTTP_PORT`；
  - `true`：启动全部 runtime 实例 + Authelia 认证，并把 gateway 的 `:80` 直接发布到 `HTTP_PORT`。
- `HTTPS_EXPORT` 只决定 `task up` / `task update` 是否自动带上 `task tls:up`：
  - HTTP 端口在任何组合下都开放；
  - `HTTPS_EXPORT=false` 不会停止、删除或重建已存在的 TLS 容器（无论其运行中还是已停止）；
  - 显式 `task tls:up` / `task tls:down` / `task tls:restart` / `task tls:logs` 不受该开关限制。

### 四种运行模式

| `AUTH_GATEWAY` | `HTTPS_EXPORT` | 模式         | 浏览器入口                                                 | 运行服务与端口                                                                             |
| -------------- | -------------- | ------------ | ---------------------------------------------------------- | ------------------------------------------------------------------------------------------ |
| `false`        | `false`        | `single`     | `http://<host>:HTTP_PORT`                                  | 第一个 runtime 实例（发布 `HTTP_PORT`）                                                    |
| `false`        | `true`         | `single+tls` | `https://DSH_DOMAIN:HTTPS_PORT`（HTTP 同样可用的明文入口） | 第一个 runtime 实例（发布 `HTTP_PORT`）+ `tls`（发布 `HTTPS_PORT`）                        |
| `true`         | `false`        | `auth`       | 外部终结器的 HTTPS 地址                                    | 全部 runtime 实例 + `authelia` + `gateway`（发布 `HTTP_PORT`）                             |
| `true`         | `true`         | `auth+tls`   | `https://DSH_DOMAIN:HTTPS_PORT`                            | 全部 runtime 实例 + `authelia` + `gateway`（发布 `HTTP_PORT`）+ `tls`（发布 `HTTPS_PORT`） |

### 关键 HTTPS 约束

Authelia 4.39 要求浏览器登录地址为 HTTPS，并使用 Secure cookie。因此认证模式下：

- `HTTP_PORT` 发布在 gateway 上，但**不是浏览器登录入口**；
- 它供外部 Caddy、Traefik、nginx 等 TLS 终结器作为明文 HTTP upstream，以及探活/冒烟；
- 浏览器必须访问终结器（或内置 TLS）公开的 HTTPS 地址；直接访问 `http://<host>:HTTP_PORT` 无法完成登录；
- 若浏览器误从明文 `HTTP_PORT` 进入，gateway 会把认证回跳 URL 统一归一化为 `https://DSH_DOMAIN[:HTTPS_PORT]`（登录门户、`rd` 回跳与 `safe-redirection` 均不会携带明文端口），登录后自动落到正确的 HTTPS 地址。

## TLS

### 内置 TLS

`tls` 服务启动时根据 `DSH_DOMAIN` 在 `nginx/tls/` 生成或复用证书：

- 有效、匹配域名和私钥的自签证书会复用，临近过期时重签；
- 有效的 CA 证书会保留，不由启动脚本覆盖；
- 可把证书链放为 `nginx/tls/$DSH_DOMAIN.crt`，私钥放为 `nginx/tls/$DSH_DOMAIN.key`；
- 自签证书会触发浏览器警告，正式公网部署应使用受信证书或外部终结器。

`tls` 的上游固定为 runtime 网络别名 `dsh-http-entry:80`。修改域名后运行 `task up`，内置 TLS 会为新域名准备相应证书；切换 `AUTH_GATEWAY` 不需要重建 TLS 容器。

### 外部 TLS

认证模式使用外部终结器时，终结器必须：

1. 将 HTTPS 请求反代到 `127.0.0.1:HTTP_PORT`（即 gateway 的明文端口）；
2. 保留原始 `Host`；
3. 设置 `X-Forwarded-Proto: https`；
4. 支持 WebSocket/SSE。

Caddy 示例：

```caddyfile
harness.deepseek.com {
    reverse_proxy 127.0.0.1:3080
}
```

如果公开端口不是 443，例如 8443，应设置：

```dotenv
AUTH_GATEWAY=true
HTTPS_EXPORT=false
HTTP_PORT=3080
HTTPS_PORT=8443
```

不要同时让内置和外部 TLS 终结器占用同一个宿主机端口。

## 用户管理

用户增删改查由 Task 命令完成（需要 Docker 运行：密码摘要由 authelia 镜像生成）：

```bash
task user:list                              # 查看用户列表
task user:create -- user1 password1         # 创建 user1，密码初始化为 password1
task user:reset_password -- user1 password2 # 重置 user1 密码为 password2
task user:remove -- user1                   # 删除 user1 配置（保留 workspace 与 dsh-home 数据）
```

使用约定：

- 位置参数必须跟在 `--` 之后（Go Task 约定，与 `task shell -- user` 一致）；
- 口令含空白时改用变量形式：`task user:create NAME=user1 PASSWORD='p w d'`（位置参数形式按空格拆分，无法携带空白口令）；
- 用户名限 `[a-z][a-z0-9_-]{0,30}`；保留字 `runtime`、`single`、`http`、`auth-http` 不可用（会与 compose 服务/遗留容器名冲突）；
- `user:create`/`user:remove` 均拒绝重复/不存在的用户；仅当实例是**最后一个** dsh 实例时禁止删除（primary 即 `compose.yaml` 中第一个 `dsh-*` 服务，`AUTH_GATEWAY=false` 模式靠它发布 `HTTP_PORT`）。删除 primary 时若还有其他实例，声明顺序中的下一个服务自动接任 primary，此时需再执行 `task up` 重新发布端口；
- 单个用户的实例可定向启停/重启：`task dsh:up|dsh:down|dsh:restart -- <name>`，不影响其他用户（见「单用户定向操作」）；
- 配置变更后应用：**用户库（`users_database.yml`）变更无需任何操作**——authelia 开启了 `watch: true`，文件一有变动（含 groups 组归属）即在进程内热载，会话与进程保留。gateway 路由模板变更用零中断的 `task auth:reload`。`user:create` 全自动收尾：**启动新实例 → 等其就绪 → 优雅 reload gateway**（reload 时实例已在，DNS 立即解析，无 502 窗口），ACL 按 `group:dsh` 组匹配、不触碰 `configuration.yml`——**创建完即可登录，全程零重启**（`auth:reload` 无需手动跑）。`user:remove` 会自动删容器并 reload gateway。`configuration.yml` 自身（ACL 规则等）变更仍需 `task auth:restart`（authelia 上游不支持配置级热载）。需要全量收敛时用 `task up`；
- `user:remove` 删除四处配置与容器，但**不删除** `dsh-home/<name>` 与 `workspace/<name>`；确需清除数据请手动删除目录；
- 安全提示：口令会出现在 shell 历史与 `docker inspect` 的一次性 run 命令中，请注意清理或改用变量形式。

默认演示账号：

| 用户   | 口令       | 后端       |
| ------ | ---------- | ---------- |
| `user` | `password` | `dsh-user` |

正式使用前必须修改口令：

```bash
task user:reset_password -- user '新的强口令'
# 无需重启: watch: true 让 authelia 自动热载用户库, 立即生效
```

同一浏览器 profile 通常只有一份同域 SSO 会话；并行测试多个账号应使用不同浏览器 profile 或隐私窗口。

### 一个用户对应三处配置

每个认证用户有独立 DSH_HOME/workspace，并在三处配置中各有一条记录；`task user:create` / `task user:remove`（实现于 `scripts/user_admin.sh`）自动保持同步。**访问授权按组而非逐用户**：`authelia/configuration.yml` 的 ACL 规则写死为 `subject: ["group:dsh"]`，用户的组归属（`groups: [dsh]`）放在用户库里、随 `watch: true` 热载——因此增删用户**不触碰** `configuration.yml`，也无需重启 authelia：

| 文件                          | 记录                                                                    |
| ----------------------------- | ----------------------------------------------------------------------- |
| `authelia/users_database.yml` | 用户名、argon2id 密码摘要、email、`groups: [dsh]`（ACL 按此组授权）    |
| `compose.yaml`                | `dsh-<name>` runtime 实例（挂载 `dsh-home/<name>`、`workspace/<name>`） |
| `nginx/gateway/default.conf.template` | `upstream dsh_<name>` 与 `$dsh_user` → 后端的 map 条目                  |

> `dsh-user` 是 `compose.yaml` 中第一个 runtime 服务，因此同时是 `AUTH_GATEWAY=false` 模式的单实例；新增实例总是追加在其后，不改变声明顺序。手工编辑这三处配置仍可，但必须自行保证一致（遗漏 `dsh` 组或路由会导致 403/502），推荐始终使用 Task 命令。

## 架构与实现细节

### HTTP 入口的实现方式

`compose.yaml` 基础文件不发布任何业务 HTTP 端口：同一个 runtime 在无认证模式需要发布端口、在认证模式又必须禁止发布，单个 Compose service 无法仅靠布尔环境变量条件化 `ports`。

`scripts/compose_mode.sh` 负责模式化：

1. 解析 `compose.yaml`，按**声明顺序**找出所有真实的 `<<: *dsh-runtime` 服务（构建指针 `dsh-runtime` 除外），第一个即无认证模式的实例；
2. 为当前 HTTP 入口生成一次性 override 文件：`HTTP_PORT:80` 直接发布到该服务（无认证）或 `gateway`（认证），并在 runtime 网络上分配别名 `dsh-http-entry`；
3. 校验合并模型：恰好一个 HTTP 发布者、恰好一个 `dsh-http-entry` 持有者、认证模式下 runtime 一律不发布宿主机端口、已删除的旧服务（`dsh-single`/`dsh-http`/`auth-http`）不再出现。

整个 override 不新增任何容器，只是把端口和别名直接加到现有服务上。`tls` 永远反代 `dsh-http-entry:80`，配合 Docker 内嵌 DNS 动态解析，切换 `AUTH_GATEWAY` 无需重建 TLS 容器（切换期间允许短暂 502）。

> 首个 runtime 服务按 `compose.yaml` 声明顺序确定，这是约定行为：把某个实例挪到 services 列表最前面会改变无认证模式使用的实例和数据目录。

### 数据流

```text
single / single+tls:
  browser --HTTP_PORT/http--> 第一个 runtime 实例(内置 nginx)
  browser --HTTPS_PORT/https--> tls --dsh-http-entry--> 同一实例   (仅 HTTPS_EXPORT=true)

auth / auth+tls:
  browser --https--> 外部终结器或内置 tls
                     --dsh-http-entry--> gateway
                                          |--> authelia
                                          `--> dsh-<user>
  （gateway 的 :80 同时直接发布在 HTTP_PORT 上，供终结器作明文 upstream）
```

认证模式中，gateway 通过 Authelia `auth_request` 取得 `Remote-User`，再按 nginx 映射转发到对应实例。门户位于：

```text
https://DSH_DOMAIN[:HTTPS_PORT]/authelia/
```

## 数据持久化与隔离边界

| 宿主机路径          | 容器内路径        | 范围                                                |
| ------------------- | ----------------- | --------------------------------------------------- |
| `deepseek-harness/` | `/app/dsh`        | 所有实例共享的代码和构建产物，读写挂载              |
| `dsh-home/<name>/`  | `/data/dsh-home`  | 对应用户实例（无认证模式为第一个实例）独立 DSH_HOME |
| `workspace/<name>/` | `/data/workspace` | 对应实例独立工作区                                  |
| `authelia/`         | `/config`         | 用户库、配置、sqlite 与通知文件                     |
| `nginx/tls/`        | `/etc/nginx/tls`  | 内置 TLS 证书与私钥                                 |

无认证模式直接使用第一个声明实例的数据目录（即该实例在 compose.yaml 中挂载到 `/data/dsh-home`、`/data/workspace` 的宿主机路径，`task` 依 compose 挂载预创建这些目录，见 `dirs:base`，不写死用户名）。旧版本若用过 `dsh-home/single`、`workspace/single` 或模板默认的 `dsh-home/user`、`workspace/user`，迁移时可在确认目标目录为空后手工清理，部署不会自动移动或删除这些数据。

隔离边界必须明确：

- 认证用户的 DSH_HOME 和 workspace 彼此独立；
- 所有实例共享 `/app/dsh` 代码，因此任一实例对源码的修改对其他实例可见，这不是代码级隔离；
- `.env` 中 `DEEPSEEK_API_KEY` 会注入所有 dsh 实例，是可选的共享密钥；
- 若需要用户独立 API key，不要设置共享环境变量，而应在各自 UI 中保存到独立 DSH_HOME；
- 除模式选中的 HTTP 入口和 TLS 端口外，任何 dsh 服务都不应额外向宿主机发布端口，否则会绕过外层认证边界。

runtime 中 `dsh web` 以 `HOST_UID:HOST_GID` 降权运行。修改 UID/GID 后应运行 `task build` 或 `task update` 重建镜像。

## 安全注意事项

- **无认证模式**：`HTTP_PORT` 直接暴露第一个 runtime 实例，且其内置 nginx 会把 Host 归一化为 loopback 并丢弃 Origin（这是 dsh /api 信任防线的设计前提）。该端口等于完全管理权限，请仅在内网/本机使用，或用防火墙限制来源。
- **认证模式的明文 HTTP**：gateway 把缺失/伪造的 `X-Forwarded-Proto` 一律视为 https 并 fail closed，Authelia 不会在明文端口完成登录；但明文端口本身不做 TLS，请仅将其暴露给可信的外部终结器。
- **容器名固定**（基础设施 `dsh-base-*`，用户 runtime 实例 `dsh-web-<name>`，构建器 `dsh-deploy-builder`）：同一台主机只能运行一个本部署项目，避免并行项目。

## 网络

未配置时，Compose 管理 `deepseek-harness_builder` 和 `deepseek-harness_runtime` 网络。设置 `BUILDER_NETWORK` 或 `RUN_NETWORK` 时，Taskfile 将它们视为已存在的 external 网络；直接运行裸 `docker compose` 时需同时显式设置对应 `*_EXTERNAL=true`。

runtime 网络同时承载 `dsh-http-entry` 别名解析：HTTP 入口服务与 `tls` 必须位于同一 runtime 网络（默认已满足）。

## 从旧版本迁移

旧版本的 `dsh-single`、`dsh-http`、`auth-http` 服务已删除：

- `task dsh:down` / `task down` 会自动清理这些遗留容器（按项目标签校验后删除）；
- 仍占着 `HTTP_PORT` 的旧转发容器会在 `task up` 的入口清理阶段被移除；
- 建议：`task down`（旧版本执行一次）→ 拉取新版本 → `task up`；
- `TLS_UPSTREAM` 环境变量已删除，`tls` 固定反代 `dsh-http-entry`。

容器已统一改名：基础设施 `dsh-deploy-gateway`/`dsh-deploy-authelia`/`dsh-deploy-tls` → `dsh-base-*`；用户 runtime 实例 `dsh-deploy-<name>` → `dsh-web-<name>`（`task user:create` 新建实例同样生成 `dsh-web-<name>`）；构建器 `dsh-deploy-builder` 不变。Compose 按项目/服务标签识别容器，升级后首次 `task up` 或对应块级命令（如 `task auth:down`）即会以新名称重建并移除旧名容器，无需手工清理。

## 故障排查

### 配置与模式

- 先运行 `task config:validate`，确认输出的 mode、开关、`primary`、`http_entry` 与端口。
- `AUTH_GATEWAY`、`HTTPS_EXPORT` 只接受大小写不敏感的 `true` 或 `false`；其他值会失败。
- 切换模式后使用 `task up` 收敛；`task restart` 虽会按当前模型重建所选容器，但不清理与新模式冲突的旧容器（例如仍持有 `HTTP_PORT` 的旧入口），不能替代 `task up`。
- 彻底停止全部块使用 `task down`，不是只执行某个块的 down。

### 登录和跳转

- **HTTP 登录失败或循环**：Authelia 4.39 必须使用 HTTPS。认证模式下不要让浏览器直连 `HTTP_PORT` 完成登录。
- **登录后回跳端口错误**：gateway 将认证回跳统一归一化为 `https://DSH_DOMAIN[:HTTPS_PORT]`。若回跳端口仍不对，确认 `HTTPS_PORT` 与浏览器实际访问的公开 HTTPS 端口一致（内置 TLS 与外部终结器同理），再 `task auth:up` 重建 gateway。
- **跳错 HTTPS 端口**：把 `HTTPS_PORT` 设置为浏览器实际访问的公开端口，再重建认证块。
- **404 unknown host**：访问 Host 与 `DSH_DOMAIN` 不一致，或外部终结器没有保留 Host。
- **cookie/登录循环**：确认域名完全一致、证书入口是 HTTPS、浏览器未拦截 cookie；重启 Authelia 会使内存会话失效并要求重新登录。
- **403**：用户的 groups 未含 `dsh`（ACL 按 `group:dsh` 授权），或 gateway 未配置用户名到后端的映射。
- **切换模式后 HTTPS 短暂 502**：别名切换与 nginx 解析缓存（≤5s）叠加的预期窗口，稍候即恢复；持续 502 请检查当前入口块是否已启动。

### 网络和服务

- **502 Bad Gateway**：所选上游块尚未启动或别名/网络不匹配。运行 `task ps`，再查看对应块日志。
- **内置 HTTPS 证书告警**：默认自签证书属预期；导入信任库、放置 CA 证书，或使用外部 TLS。
- **端口已占用**：`task up` 会先移除本项目内仍占用 `HTTP_PORT` 的旧入口容器；若是外部进程占用，请调整 `HTTP_PORT`/`HTTPS_PORT`。
- **旧 `.env` 只设置 GATEWAY_PORT**：暂时仍可回退，但会警告；迁移为 `HTTP_PORT`。

### 构建与权限

- **提示 source artifacts are missing**：先运行 `task build`。
- **builder 失败**：检查 `docker compose --profile build logs builder` 或重新执行 `task build`。
- **UID/GID 修改后权限异常**：确认目录属主并运行 `task update`。
- **Buildx 状态目录**：Taskfile 已默认把 `BUILDX_CONFIG` 指向项目内 `.buildx/`（可用环境变量 `BUILDX_CONFIG` 覆盖）；若构建报只读错误，检查该目录属主。
- **需要重建运行栈但保留数据**：`task down && task update`；挂载目录不会被删除。
