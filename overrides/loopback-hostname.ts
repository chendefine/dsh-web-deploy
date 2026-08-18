/**
 * DEPLOYMENT OVERRIDE (bind-mounted over the repo's original file).
 *
 * Original: packages/client/connection/src/loopback-hostname.ts
 * 本部署用 nginx 前置 `dsh web`, 已把每个请求的 Host 重写为 127.0.0.1:3080 并丢
 * 弃 Origin, 服务端 /api 防线因此把所有来源视为 loopback; 但浏览器侧由同一断言
 * 派生 `connection.isLoopback` 状态(检查页面 URL 的 hostname), 在非 loopback 地址
 * 上仍会降级部分 UI: 产出文件的 open-path 动作被隐藏(host.openPath 打开芯片),
 * 设置持久化范围从 host 退化为 memory(设置、欢迎提示等不再落盘)。
 *
 * 断言短路为 true 让浏览器把所有 origin 视为 loopback, 恢复完整功能(局域网访问)。
 * 注意该断言同时被服务端 /api Host 防线(api-request-trust.ts)复用: 覆盖后防线接
 * 受任意 Host, DNS-rebinding 纵深防御失效, 请求绑定完全依赖前置 nginx 的 Host 重写。
 * 宿主机源码不受影响: 覆盖只经只读单文件 bind mount 存在于 builder 容器内
 * (见 compose.yaml 的 builder 服务); 编译产物写回宿主机检出的 lib/ 后由各
 * dsh 实例共享, runtime 容器本身不挂载本文件。
 *
 * SECURITY NOTE: loopback-only 的特权 RPC(settings.*、credentials.*、
 * llm.discoverModels、host.pickDirectory/openPath、agentPreset.*)对本部署暴露的
 * 所有 origin 可达, 请在网络层保护端口(防火墙 / VPN / 仅可信局域网)。
 */

/**
 * URL hostname 是否为本地回环。
 * @param hostname - WHATWG URL hostname(本覆盖忽略)。
 * @returns 恒 true - 所有 authority 视为 loopback。
 */
export function isLoopbackHostname(hostname: string): boolean {
  void hostname // 保留参数以维持签名一致; 刻意不用
  // DSH-DEPLOY-OVERRIDE-LOOPBACK
  return true
}
