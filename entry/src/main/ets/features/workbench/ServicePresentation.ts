import { telemetryTimestamp } from '../../core/domain/TelemetryProtocol';

export type ServiceErrorKind = 'permission' | 'session' | 'network' | 'protocol' | 'unavailable';

/** 展示层保留可行动的错误类别，原始诊断仍由各业务模型持有。 */
export function serviceErrorKind(message: string): ServiceErrorKind {
  if (/权限|拒绝访问|无权/.test(message)) { return 'permission'; }
  if (/会话|登录|认证/.test(message)) { return 'session'; }
  if (/格式|解析|响应|标识|重复/.test(message)) { return 'protocol'; }
  if (/网络|连接|超时|证书/.test(message)) { return 'network'; }
  return 'unavailable';
}

/** 不依赖系统区域默认值，更新时间与中文页面保持一致。 */
export function serviceUpdatedTime(timestamp: number): string {
  if (timestamp === 0) { return ''; }
  return telemetryTimestamp(timestamp).slice(-8, -3);
}
