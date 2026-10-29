const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(path.join(process.env.HARMONY_SDK_ROOT || 'D:/Program Files/DevEco Studio/sdk/default', 'openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const dsm = require('../../work/core-build/domain/DsmProtocol.js');
const common = require('../../work/core-build/domain/ReadOnlyProtocol.js');
const transfers = require('../../work/core-build/network/NasTransferTransport.js');
const { NasConnector } = require('../../work/core-build/network/NasConnector.js');
const tick = () => new Promise(resolve => setImmediate(resolve));
const plain = value => JSON.parse(JSON.stringify(value));
function load(name, ports = {}) {
  const source = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/notes', name), 'utf8').replace(/^@ObservedV2\s*$/gm, '').replace(/@Trace\s+/g, '');
  const module = { exports: {} };
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText, {
    module, exports: module.exports, Date, Error, require(id) {
      if (id.endsWith('/DsmProtocol')) return dsm;
      if (id.endsWith('/ReadOnlyProtocol')) return common;
      if (id.endsWith('/NasTransferTransport')) return transfers;
      if (id === '@kit.PerformanceAnalysisKit') return { hilog: { error() {} } };
      if (id === '@kit.CoreFileKit') return ports.files || {};
      if (id === '@kit.ArkTS') return { util: { generateRandomUUID: () => '00000000-0000-4000-8000-000000000000' } };
      if (id === '../transfers/TransferQueueFiles') return { copyTransferFile: ports.copy || (async () => {}) };
      if (id.startsWith('./')) return load(id.slice(2) + (id.endsWith('Store') ? '.ets' : '.ts'), ports);
      throw Error(id);
    }
  }); return module.exports;
}
const p = load('NoteProtocol.ts');
const note = { object_id: 'note-id', parent_id: 'book-id', title: '示例', tag: ['标签'], ver: 'version-1', content: '<p>正文</p>',
  attachment: { 'file-id': { name: 'image.png', size: 4, type: 'image/png', ref: 'image-ref' } } };
const detail = p.decodeNoteDetail(note, note.object_id), attachment = detail.attachments[0];
const ok = data => ({ status: 200, text: JSON.stringify({ success: true, data }) });
const bad = code => ({ status: 200, text: JSON.stringify({ success: false, error: { code } }) });

test('note lists use separate notebook and tag identities and title-only filtering', () => {
  assert.equal(p.decodeNotebooks({ notebooks: [{ object_id: 'book-id', title: '笔记本' }] })[0].id, 'book-id');
  assert.equal(p.decodeNoteTags({ tags: [{ tag_name: '标签', note_count: 1 }] })[0].id, '标签');
  const page = p.decodeNotes({ notes: [note], total: 1 }, 0);
  assert.equal(p.filterNotes(page.items, 'book-id', '标签', '示例').length, 1);
  assert.equal(p.filterNotes(page.items, '', '', '正文').length, 0);
  assert.throws(() => p.decodeNotes({ notes: [note, note] }, 0));
  assert.throws(() => p.decodeNoteDetail(note, 'other'));
  const missing = p.decodeNoteDetail({ object_id: 'empty', brief: '摘要不是正文' }, 'empty');
  assert.equal(missing.bodyProvided, false); assert.equal(missing.body.blocks.length, 0);
  assert.doesNotMatch(JSON.stringify(detail), /<p>|attachment":/);
});

test('native note blocks preserve basic formats and reject unsafe links or external image loads', () => {
  const body = p.parseNoteBody('<h2>标题</h2><p>普通 <strong>加粗</strong> <em>斜体</em> <a href="https://example.test/a">链接</a> <a href="javascript:alert(1)">无效</a></p><ol><li>第一项</li><li>第二项</li></ol><img ref="image-ref" src="https://private.example/image"><img src="https://remote.example/a" alt="外链图片"><table><tr><td>复杂内容</td></tr></table><script>secret()</script>', detail.attachments);
  const spans = body.blocks.flatMap(x => x.spans), text = spans.map(x => x.text).join('');
  assert.equal(body.blocks[0].kind, 'heading'); assert.ok(spans.some(x => x.bold && x.text === '加粗'));
  assert.ok(spans.some(x => x.italic && x.text === '斜体')); assert.ok(spans.some(x => x.href === 'https://example.test/a'));
  assert.ok(spans.filter(x => x.text === '无效').every(x => x.href === ''));
  assert.match(text, /1\. 第一项/); assert.match(text, /2\. 第二项/); assert.match(text, /复杂内容/); assert.doesNotMatch(text, /secret/);
  assert.equal(body.blocks.filter(x => x.kind === 'image').length, 1); assert.equal(body.complex, true);
  assert.doesNotMatch(JSON.stringify(body), /private.example|remote.example|javascript/);
  assert.equal(p.noteLink('file:///private'), '');
});

test('attachment ownership includes note, file, version and metadata', () => {
  p.assertNoteAttachment(detail, attachment);
  for (const changed of [{ ...attachment, noteId: 'other' }, { ...attachment, version: 'other' }, { ...attachment, fileId: 'other' }, { ...attachment, bytes: 8 }]) {
    assert.throws(() => p.assertNoteAttachment(detail, changed));
  }
  assert.notEqual(p.noteAttachmentKey(attachment), p.noteAttachmentKey({ ...attachment, noteId: 'other' }));
});

async function fixture(binary) {
  const calls = [], replies = [], descriptors = {};
  for (const name of ['SYNO.API.Auth', 'SYNO.FileStation.List', 'SYNO.NoteStation.Note', 'SYNO.NoteStation.Notebook', 'SYNO.NoteStation.Tag']) {
    descriptors[name] = { path: 'entry.cgi', minVersion: 1, maxVersion: 99, requestFormat: 'JSON' };
  }
  const connector = new NasConnector({ async post(...args) { calls.push(args); assert.ok(replies.length, 'missing reply'); return replies.shift(); },
    transfers: binary ? { download: binary } : undefined, close() {} });
  replies.push(ok(descriptors)); await connector.discover('https://nas.example');
  connector.restoreSession({ sid: 'main-sid', synoToken: 'main-token' });
  return { connector, calls, replies };
}

test('notes share the primary session and keep their fixed read methods', async () => {
  const f = await fixture(); assert.equal(f.calls.length, 1);
  f.replies.push(ok({ notes: [note] })); await f.connector.readNotes('list', '', 0, x => p.decodeNotes(x, 0));
  assert.equal(f.calls.at(-1)[2].sid, 'main-sid'); assert.equal(new URLSearchParams(f.calls.at(-1)[1]).get('version'), '3');
  assert.equal(f.connector.capabilitySnapshots().find(x => x.feature === 'noteDetail').state, 'unverified');
  f.replies.push(ok(note)); await f.connector.readNotes('detail', note.object_id, 0, x => p.decodeNoteDetail(x, note.object_id));
  assert.equal(JSON.parse(new URLSearchParams(f.calls.at(-1)[1]).get('object_id')), note.object_id);
  f.replies.push(ok({ notebooks: [] })); await f.connector.readNotes('notebooks', '', 0, p.decodeNotebooks);
  assert.equal(new URLSearchParams(f.calls.at(-1)[1]).get('version'), '2');
  await assert.rejects(f.connector.readNotes('set', note.object_id, 0, x => x));
  assert.doesNotMatch(f.calls.map(x => x[1]).join(' '), /method=(?:init|set|create|delete|edit|check)/);
});

test('note rejection rechecks primary authentication and preserves the account on network failure', async () => {
  for (const proof of ['valid', 'network', 'expired']) {
    const f = await fixture();
    f.replies.push(bad(107), proof === 'valid' ? ok({ synotoken: 'main-token' }) : proof === 'network' ? { status: 503, text: '' } : bad(106));
    await assert.rejects(f.connector.readNotes('list', '', 0, x => x), x => x.kind === (proof === 'expired' ? dsm.NasErrorKind.SessionExpired : proof === 'network' ? dsm.NasErrorKind.Http : dsm.NasErrorKind.Permission));
    assert.equal(f.connector.sessionSnapshot() !== undefined, proof !== 'expired');
  }
});

test('binary attachment read uses note identity, raw download and primary authorization', async () => {
  let request;
  const f = await fixture(async (input, target, control, validate) => {
    request = input; validate({ status: 200, contentType: 'image/png', contentLength: '4', contentDisposition: 'attachment', bytes: 4, prefixText: 'data' });
    return { path: target.directory + '/file', bytes: 4, discard() {} };
  });
  const result = await f.connector.downloadNoteAttachment(attachment.noteId, attachment.version, attachment.fileId,
    { directory: '/cache/uuid', maximumBytes: 100, expectedBytes: 4 }, new transfers.NasTransferCancellation());
  assert.equal(result.bytes, 4); assert.equal(request.session.sid, 'main-sid'); assert.equal(request.method, 'POST');
  const fields = Object.fromEntries(request.fields.map(x => [x.name, x.content]));
  assert.equal(fields.api, 'SYNO.NoteStation.Note'); assert.equal(fields.ver, JSON.stringify(attachment.version));
  assert.equal(JSON.parse(fields.file_id), attachment.fileId); assert.equal(JSON.parse(fields.mode), 'download');
  assert.equal('path' in fields, false); assert.equal('_sid' in fields, false);
});

test('missing or rejected attachment authorization cannot invalidate the main session', async () => {
  let reads = 0;
  const f = await fixture(async (_input, _target, _control, validate) => {
    reads++; validate({ status: 200, contentType: 'application/octet-stream', contentLength: '', contentDisposition: '', bytes: 42,
      prefixText: '{"success":false,"error":{"code":107}}' });
  });
  const download = () => f.connector.downloadNoteAttachment('note', 'version', 'file', { directory: '/cache/uuid', maximumBytes: 100 }, new transfers.NasTransferCancellation());
  f.replies.push(ok({ synotoken: 'main-token' }));
  await assert.rejects(download(), x => x.kind === dsm.NasErrorKind.Permission); assert.equal(reads, 1);
  assert.equal(f.connector.sessionSnapshot().sid, 'main-sid');
});

test('note model preserves successful reads, clears credentials and rejects hidden or cross-account callbacks', async () => {
  const { NoteModel } = load('NoteModel.ets'), model = new NoteModel(); let resolve;
  model.repository = { list: async () => p.decodeNotes({ notes: [note] }, 0), notebooks: async () => { throw Error('denied'); }, tags: async () => [] };
  model.setVisible(true); await tick(); assert.equal(model.loaded, true); assert.equal(model.items.length, 1); assert.ok(model.notebookError);
  const checked = model.checkedAt;
  model.repository.list = async () => { throw new dsm.NasFailure(dsm.NasErrorKind.Network, '断网'); };
  await model.refresh(); assert.equal(model.items.length, 1); assert.equal(model.checkedAt, checked);
  model.repository.detail = () => new Promise(done => { resolve = done; }); model.select(detail.item); model.setVisible(false);
  resolve(detail); await tick(); assert.equal(model.detail, undefined);
  model.reset(); assert.equal(model.items.length, 0);
});

test('attachment download failures and account switches clean private files while exports remain outside ownership', async () => {
  const removed = [], exported = []; let fail = true;
  const ports = { files: { fileIo: { async listFile() { return []; }, async rmdir(dir) { removed.push(dir); }, async unlink(uri) { removed.push(uri); } },
    picker: { DocumentSaveOptions: class {}, DocumentViewPicker: class { async save() { return ['user://saved.png']; } } } },
    async copy(source, destination, bytes, current, isExport) { current(); assert.equal(isExport, true); exported.push(destination); } };
  const { NoteAttachmentStore } = load('NoteAttachmentStore.ets', ports), store = new NoteAttachmentStore();
  const repository = { async download(item, target) {
    target.onDirectoryCreated(); if (fail) throw new dsm.NasFailure(dsm.NasErrorKind.Network, '断网');
    return { path: target.directory + '/file', bytes: 4 };
  }, async detail() { return detail; } };
  store.attach({ cacheDir: '/cache' }, repository, async () => {}); await store.tail;
  await store.download(attachment); assert.equal(store.files.length, 0); assert.equal(removed.length, 1); assert.match(store.errorText, /断网/);
  fail = false; await store.download(attachment); assert.equal(store.files.length, 1);
  await store.save(attachment); assert.deepEqual(exported, ['user://saved.png']);
  store.reset(); await store.tail; assert.equal(store.files.length, 0); assert.equal(removed.includes('user://saved.png'), false);
  let complete; repository.download = async (item, target) => { target.onDirectoryCreated(); return new Promise(resolve => { complete = () => resolve({ path: target.directory + '/file', bytes: 4 }); }); };
  store.attach({ cacheDir: '/cache' }, repository, async () => {}); await store.tail;
  const pending = store.download(attachment); await tick(); store.reset(); complete(); await pending; await store.tail;
  assert.equal(store.files.length, 0); assert.equal(store.path(attachment), '');
});
