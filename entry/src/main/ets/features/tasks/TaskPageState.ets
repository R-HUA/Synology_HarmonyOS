import { TaskFilter, TaskScope } from '../../core/domain/TaskPresentation';

/** 页面只保存自己的浏览状态，不复制任务记录。 */
@ObservedV2
export class TaskPageState {
  @Trace filter: TaskFilter = 'all';
  @Trace categoryIndex: number = 0;
  @Trace focusKey: string = '';
  @Trace focusRevision: number = 0;
  scope: TaskScope;
  constructor(scope: TaskScope = 'root') { this.scope = scope; }

  /** 新任务可能立即结束，定位时先还原全部筛选。 */
  locate(key: string): void {
    this.filter = 'all';
    this.focusKey = key;
    this.focusRevision++;
  }
}
