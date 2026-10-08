import { common } from '@kit.AbilityKit';
import { request, BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { NasErrorKind, NasFailure } from '../core/domain/DsmProtocol';
import { localSpaceBudget } from './LocalSpaceBudget';

interface DownloadSpace { path: string; bytes: number; }

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
  private downloads: Map<string, DownloadSpace> = new Map();
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

  async create(context: common.UIAbilityContext, config: request.agent.Config): Promise<request.agent.Task> {
    this.requireCapability();
    const path = config.saveas;
    const bytes = typeof config.extras?.['spaceBytes'] === 'string' ? Number(config.extras['spaceBytes']) : 512 * 1024 * 1024;
    if (path !== undefined && config.action === request.agent.Action.DOWNLOAD) {
      await localSpaceBudget.reserve(context.filesDir, path, bytes);
    }
    try {
      const task = await this.run((): Promise<request.agent.Task> => request.agent.create(context, config));
      if (path !== undefined && config.action === request.agent.Action.DOWNLOAD) { this.downloads.set(task.tid, { path, bytes }); }
      return task;
    } catch (error) {
      if (path !== undefined && config.action === request.agent.Action.DOWNLOAD) { localSpaceBudget.release(path); }
      throw error as Error;
    }
  }

  /** 进程恢复从任务记录重新预留剩余空间，不把旧进程的内存预留当作有效。 */
  async restoreDownloadSpace(context: common.UIAbilityContext, id: string, path: string, bytes: number, processed: number): Promise<void> {
    try { await localSpaceBudget.reserve(context.filesDir, path, Math.max(0, bytes - processed)); }
    catch (error) {
      await this.remove(id);
      throw error as Error;
    }
    this.downloads.set(id, { path, bytes });
  }

  getTask(context: common.UIAbilityContext, id: string): Promise<request.agent.Task> {
    return this.run((): Promise<request.agent.Task> => request.agent.getTask(context, id));
  }

  async show(id: string): Promise<request.agent.TaskInfo> {
    const info = await this.run((): Promise<request.agent.TaskInfo> => request.agent.show(id));
    this.updateSpace(id, info.progress);
    return info;
  }

  search(filter: request.agent.Filter): Promise<string[]> {
    return this.run((): Promise<string[]> => request.agent.search(filter));
  }

  async remove(id: string): Promise<void> {
    await this.run((): Promise<void> => request.agent.remove(id));
    const download = this.downloads.get(id);
    if (download !== undefined) { localSpaceBudget.release(download.path); this.downloads.delete(id); }
  }

  start(task: request.agent.Task): Promise<void> {
    return this.run((): Promise<void> => task.start());
  }

  stop(task: request.agent.Task): Promise<void> {
    return this.run((): Promise<void> => task.stop());
  }
  pause(task: request.agent.Task): Promise<void> { return this.run((): Promise<void> => task.pause()); }
  resume(task: request.agent.Task): Promise<void> { return this.run((): Promise<void> => task.resume()); }

  observe(task: request.agent.Task, listeners: TransferListeners): () => void {
    this.requireCapability();
    let active = true;
    const invoke = (action: () => void): void => {
      if (!active) { return; }
      try { action(); }
      catch (error) { listeners.error(transferFailure(error as Error) as Error); }
    };
    const response = (value: request.agent.HttpResponse): void => invoke((): void => listeners.response(value));
    const progress = (value: request.agent.Progress): void => invoke((): void => { this.updateSpace(task.tid, value); listeners.progress(value); });
    const completed = (value: request.agent.Progress): void => invoke((): void => { this.updateSpace(task.tid, value); listeners.completed(value); });
    const failed = (value: request.agent.Progress): void => invoke((): void => { this.updateSpace(task.tid, value); listeners.failed(value); });
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

  private updateSpace(id: string, progress: request.agent.Progress): void {
    const download = this.downloads.get(id);
    if (download === undefined) { return; }
    if ([request.agent.State.COMPLETED, request.agent.State.FAILED, request.agent.State.STOPPED, request.agent.State.REMOVED].includes(progress.state)) {
      localSpaceBudget.release(download.path); this.downloads.delete(id);
    } else { localSpaceBudget.advance(download.path, download.bytes - progress.processed); }
  }
}

export const sdkTransferAgent = new SdkTransferAgent();
