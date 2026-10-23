import { NasConnector } from '../../core/network/NasConnector';
import { NasTransferCancellation } from '../../core/network/NasTransferTransport';
import type { NasDownloadTarget, NasDownloadResult } from '../../core/network/NasTransferTransport';
import { NoteFolder, NotePage, NoteDetail, NoteAttachment, decodeNotebooks, decodeNoteTags, decodeNotes, decodeNoteDetail, assertNoteAttachment } from './NoteProtocol';

export class NoteRepository {
  constructor(private connector: NasConnector) {}
  notebooks(offset: number): Promise<NoteFolder[]> { return this.connector.readNotes('notebooks', '', offset, decodeNotebooks); }
  tags(offset: number): Promise<NoteFolder[]> { return this.connector.readNotes('tags', '', offset, decodeNoteTags); }
  list(offset: number): Promise<NotePage> { return this.connector.readNotes('list', '', offset, (data: Object): NotePage => decodeNotes(data, offset)); }
  detail(id: string): Promise<NoteDetail> { return this.connector.readNotes('detail', id, 0, (data: Object): NoteDetail => decodeNoteDetail(data, id)); }
  async download(attachment: NoteAttachment, target: NasDownloadTarget, cancellation: NasTransferCancellation): Promise<NasDownloadResult> {
    const before = await this.detail(attachment.noteId); cancellation.check(); assertNoteAttachment(before, attachment);
    return this.connector.downloadNoteAttachment(attachment.noteId, attachment.version, attachment.fileId, target, cancellation);
  }
}
