import { common } from '@kit.AbilityKit';
import { request, BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure } from '../core/domain/DsmProtocol';

export interface TransferListeners {
  response: (value: request.agent.HttpResponse) => void;
  progress: (value: request.agent.Progress) => void;
  completed: (value: request.agent.Progress) => void;
  failed: (value: request.agent.Progress) => void;
  error: (error: Error) => void;
}

function transferFailure(error: Error): NasFailure {
  if (error instanceof NasFailure) { return error; }
  return new NasFailure(NasErrorKind.Protocol, '系统传输操作失败，请重新检查任务状态。', (error as BusinessError).code);
}

export class SdkTransferAgent {
  requireCapability(): void {
    if (!canIUse('SystemCapability.Request.FileTransferAgent')) {
      throw new NasFailure(NasErrorKind.Unsupported, '当前设备不支持手机托管传输，无法上传或下载文件。');
    }
  }

  private async run<T>(action: () => Promise<T>): Promise<T> {
    this.requireCapability();
    try { return await action(); }
    catch (error) { throw transferFailure(error as Error); }
  }

  create(context: common.UIAbilityContext, config: request.agent.Config): Promise<request.agent.Task> {
    return this.run((): Promise<request.agent.Task> => request.agent.create(context, config));
  }

  getTask(context: common.UIAbilityContext, id: string): Promise<request.agent.Task> {
    return this.run((): Promise<request.agent.Task> => request.agent.getTask(context, id));
  }

  show(id: string): Promise<request.agent.TaskInfo> {
    return this.run((): Promise<request.agent.TaskInfo> => request.agent.show(id));
  }

  search(filter: request.agent.Filter): Promise<string[]> {
    return this.run((): Promise<string[]> => request.agent.search(filter));
  }

  remove(id: string): Promise<void> {
    return this.run((): Promise<void> => request.agent.remove(id));
  }

  start(task: request.agent.Task): Promise<void> {
    return this.run((): Promise<void> => task.start());
  }

  stop(task: request.agent.Task): Promise<void> {
    return this.run((): Promise<void> => task.stop());
  }

  observe(task: request.agent.Task, listeners: TransferListeners): () => void {
    this.requireCapability();
    let active = true;
    const invoke = (action: () => void): void => {
      if (!active) { return; }
      try { action(); }
      catch (error) { listeners.error(transferFailure(error as Error) as Error); }
    };
    const response = (value: request.agent.HttpResponse): void => invoke((): void => listeners.response(value));
    const progress = (value: request.agent.Progress): void => invoke((): void => listeners.progress(value));
    const completed = (value: request.agent.Progress): void => invoke((): void => listeners.completed(value));
    const failed = (value: request.agent.Progress): void => invoke((): void => listeners.failed(value));
    const removals: (() => void)[] = [];
    const dispose = (): void => {
      if (!active) { return; }
      active = false;
      for (const remove of removals) {
        try { remove(); }
        catch (error) {
          hilog.error(0x0000, 'NasTransfer', 'operation=listener_remove result=failed code=%{public}d', (error as BusinessError).code);
        }
      }
    };
    try {
      removals.push((): void => task.off('response', response));
      task.on('response', response);
      removals.push((): void => task.off('progress', progress));
      task.on('progress', progress);
      removals.push((): void => task.off('completed', completed));
      task.on('completed', completed);
      removals.push((): void => task.off('failed', failed));
      task.on('failed', failed);
    } catch (error) {
      dispose();
      throw transferFailure(error as Error);
    }
    return dispose;
  }
}

export const sdkTransferAgent = new SdkTransferAgent();
