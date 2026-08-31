/**
 * DEPLOYMENT OVERRIDE (bind-mounted over the repo's original file).
 *
 * Original: packages/client/connection/src/browser-auth.ts
 * 本部署由 nginx/Authelia 网关承担全部认证(AUTH_GATEWAY=true), dsh web 自带的
 * 浏览器会话层(进程启动 token `?token=...` 换签名 cookie)因此成为第二道重复
 * 登录: token 只出现在容器日志里, 网关后的用户拿不到它, 只能面对 401。
 *
 * 本覆盖把 BrowserAuth 替换为恒放行的同公共签名实现:
 *   - authorizeIndex: 任意 root/index 请求直接放行(不再 303 换 cookie / 401)。
 *   - isAuthenticated: 任意 /api 与 WebSocket 请求视为已认证(所有 RPC 防线经
 *     HostConnectionService.requestRejection 汇聚到这一个方法)。
 *   - authenticatedUrl: 打印/打开的根 URL 不再携带 ?token=。
 *   - create: 不再读写 credentials 中的 client-connection/browser-session
 *     签名密钥记录。
 *
 * SECURITY NOTE: 覆盖后 dsh 进程自身对到达请求零认证, 浏览器会话防线完全依赖
 * 前置网关(Authelia)与网络隔离; 任何能直连 runtime 容器 80 端口的来源都拥有
 * 完整控制权(runtime 网络内勿暴露该端口)。/api 的 Host/Origin 防线
 * (api-request-trust.ts)不在本覆盖范围: 服务端跑的是原始实现, 非 loopback
 * Host 仍需 web 配置的 trustedHosts 放行。
 *
 * 宿主机源码不受影响: 覆盖只经只读单文件 bind mount 存在于 builder 与各
 * runtime 容器内(见 compose.yaml 的 builder 服务与 x-dsh-runtime 模板)。
 * 注意 dsh 以 tsx 从源码启动(tsconfig paths 把 workspace 包指向 src/),
 * 服务端加载的是本文件而非编译产物 — 因此除 builder(编译 lib/ 保持一致)外,
 * 本覆盖还必须挂进每个 runtime 容器的同一 src 路径; 且 mount 属容器 spec,
 * 增删后需 `docker compose up -d <svc>` 重建容器, `docker restart` 不生效。
 */

import type {
  ConnectionIndexRequest,
  ConnectionIndexResponse,
  ConnectionTrustRequest,
} from './rpc.ts'

/**
 * 无认证浏览器会话: 所有请求恒放行。
 * 公共签名与原 BrowserAuth 一致(index.ts / rpc-host.ts 只经该面使用)。
 */
export class BrowserAuth {
  /**
   * 创建无认证实例; 跳过原实现的签名密钥初始化。
   * @param _processOwner - 原进程启动 token 持有者(本覆盖忽略)。
   * @param _credentials - 原 cookie 签名密钥存储(本覆盖忽略)。
   * @param _maxAgeDays - 原 cookie 生命周期天数(本覆盖忽略)。
   * @returns 恒放行的认证实例。
   */
  static async create(
    _processOwner: object,
    _credentials: unknown,
    _maxAgeDays: number,
  ): Promise<BrowserAuth> {
    return new BrowserAuth()
  }

  /**
   * 输出干净的根 URL, 不携带任何 token。
   * @param baseUrl - 规范浏览器 origin。
   * @returns 指向 `/` 且无查询串与片段的根 URL。
   */
  authenticatedUrl(baseUrl: string): string {
    const url = new URL(baseUrl)
    url.pathname = '/'
    url.search = ''
    url.hash = ''
    return url.href
  }

  /**
   * 任意 index 请求直接放行。
   * @param _req - 到达的 root/index 请求(本覆盖忽略)。
   * @param _res - 响应对象(本覆盖不再持有它)。
   * @returns 恒 true - 调用方直接提供 index.html。
   */
  authorizeIndex(_req: ConnectionIndexRequest, _res: ConnectionIndexResponse): boolean {
    // DSH-DEPLOY-OVERRIDE-NOAUTH
    return true
  }

  /**
   * 任意请求视为已认证。
   * @param _request - 请求头(本覆盖忽略)。
   * @returns 恒 true - 不再校验签名 cookie。
   */
  isAuthenticated(_request: ConnectionTrustRequest): boolean {
    // DSH-DEPLOY-OVERRIDE-NOAUTH
    return true
  }
}
