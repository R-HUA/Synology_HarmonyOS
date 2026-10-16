import { NasFailure } from './DsmProtocol';

/** 提交回执只描述执行器是否接管，后续执行结果由任务记录呈现。 */
export interface DownloadSubmitResult {
  status: 'created' | 'duplicate' | 'rejected' | 'failed' | 'unconfirmed';
  taskId?: string;
  message: string;
  failure?: NasFailure;
}
