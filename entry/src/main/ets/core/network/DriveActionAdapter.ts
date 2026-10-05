import { NasErrorKind, NasFailure } from '../domain/DsmProtocol';
import { DRIVE_FILES_API, DriveEntryKind } from '../domain/DriveProtocol';
import type { DriveAncestor } from '../domain/DriveProtocol';
import type { NasFormField } from '../domain/DsmProtocol';
import { driveActionFields, decodeDrivePreflight, decodeDriveActionStart, decodeDriveActionStatus,
  DRIVE_TASKS_API, validateDriveTaskId } from '../domain/DriveActionProtocol';
import type { DriveActionInput, DriveActionStatus } from '../domain/DriveActionProtocol';
import { DriveAdapter } from './DriveAdapter';
import type { DriveKernelPort } from './DriveAdapter';

export class DriveActionAdapter {
  constructor(private kernel: DriveKernelPort) {}
  available(): boolean { return this.kernel.supportsDriveApi(DRIVE_FILES_API, 2) && this.kernel.supportsDriveApi(DRIVE_TASKS_API, 1); }
  async preflight(input: DriveActionInput): Promise<number> {
    const fields: NasFormField[] = driveActionFields(input, true);
    if (input.action !== 'move' && input.action !== 'copy' || input.target === undefined) {
      throw new NasFailure(NasErrorKind.InvalidInput, '请选择移动或复制的目标文件夹。');
    }
    if (input.entry.kind === DriveEntryKind.Folder) {
      const ancestors: DriveAncestor[] = await new DriveAdapter(this.kernel).ancestors(input.target);
      if (ancestors.some((entry: DriveAncestor): boolean => entry.fileId === input.entry.fileId)) {
        throw new NasFailure(NasErrorKind.InvalidInput, '不能将文件夹移动或复制到自身的子文件夹。');
      }
    }
    return decodeDrivePreflight(await this.kernel.requestDrive(DRIVE_FILES_API, 2, input.action, fields));
  }
  async start(input: DriveActionInput): Promise<string | undefined> {
    const method = input.action === 'rename' ? 'update' : input.action;
    return decodeDriveActionStart(await this.kernel.requestDrive(DRIVE_FILES_API, 2, method, driveActionFields(input)), input);
  }
  async status(taskId: string): Promise<DriveActionStatus> {
    return decodeDriveActionStatus(await this.kernel.requestDrive(DRIVE_TASKS_API, 1, 'get',
      [{ name: 'task_id', content: JSON.stringify(validateDriveTaskId(taskId)) }]), taskId);
  }
}
