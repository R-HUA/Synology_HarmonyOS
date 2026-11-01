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

test('note detail navigation follows selection across window changes and closes when selection is cleared', () => {
  const page = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/notes/NoteStationPage.ets'), 'utf8');
  const body = page.match(/private selectionChanged\(\): void \{([\s\S]*?)\n  \}/)[1];
  const sync = vm.runInNewContext(ts.transpileModule(`(function() { ${body} })`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.None }
  }).outputText);
  const paths = [];
  let opened = 0;
  const state = { wide: false, onOpenDetail: () => { opened++; }, model: { selected: { id: 'note-one' } }, detailStack: {
    size: () => paths.length, clear: () => { paths.length = 0; }, pushPathByName: name => paths.push(name)
  } };
  sync.call(state); assert.deepEqual(paths, []); assert.equal(opened, 1);
  state.wide = true; sync.call(state); assert.deepEqual(paths, ['detail']);
  state.model.selected = { id: 'note-two' }; sync.call(state); assert.deepEqual(paths, ['detail']);
  state.wide = false; sync.call(state); assert.deepEqual(paths, []); assert.equal(opened, 2);
  state.wide = true; sync.call(state); assert.deepEqual(paths, ['detail']);
  state.model.selected = undefined; sync.call(state); assert.deepEqual(paths, []);
  const index = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/pages/Index.ets'), 'utf8');
  const wideBody = index.match(/private syncNoteLayout\(\): void \{([\s\S]*?)\n  \}/)[1];
  const widen = vm.runInNewContext(ts.transpileModule(`(function() { ${wideBody} })`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.None }
  }).outputText);
  const outerPaths = ['notes', 'note-detail'];
  const outer = { windowWidth: 839, packageDestination: 'note-detail', navStack: {
    getAllPathName: () => outerPaths, pop: () => outerPaths.pop()
  } };
  widen.call(outer); assert.deepEqual(outerPaths, ['notes', 'note-detail']);
  outer.windowWidth = 840; widen.call(outer);
  assert.deepEqual(outerPaths, ['notes']); assert.equal(outer.packageDestination, 'notes');
  widen.call(outer); assert.deepEqual(outerPaths, ['notes']);
});

test('pull refresh keeps list and detail activity separate and releases each indicator', async () => {
  const panes = ['NoteListPane.ets', 'NoteDetailPane.ets'].map(name => {
    const page = fs.readFileSync(path.join(__dirname, '../../entry/src/main/ets/features/notes', name), 'utf8');
    const body = page.match(/private async refresh\(\): Promise<void> \{([\s\S]*?)\n  \}/)[1];
    return vm.runInNewContext(ts.transpileModule(`(async function() { ${body} })`, {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.None }
    }).outputText);
  });
  for (let i = 0; i < panes.length; i++) {
    let finish; const calls = [], state = { refreshing: false, model: {
      [i ? 'refreshDetail' : 'refresh']: () => { calls.push('read'); return new Promise(resolve => { finish = resolve; }); }
    } };
    const pending = panes[i].call(state); assert.equal(state.refreshing, true);
    await panes[i].call(state); assert.deepEqual(calls, ['read']);
    finish(); await pending; assert.equal(state.refreshing, false);
    state.model[i ? 'refreshDetail' : 'refresh'] = async () => { throw Error('failed'); };
    await assert.rejects(panes[i].call(state), /failed/); assert.equal(state.refreshing, false);
  }
});

test('selecting a loaded note reads its body without refreshing the list', async () => {
  const { NoteModel } = load('NoteModel.ets'), model = new NoteModel(), calls = [];
  model.visible = true; model.loaded = true; model.items = [detail.item];
  model.repository = { async list() { calls.push('list'); throw Error('unexpected list refresh'); },
    async detail(id) { calls.push(id); return p.decodeNoteDetail(note, id); } };
  model.select(model.items[0]); await tick();
  assert.deepEqual(calls, ['note-id']); assert.equal(model.selected.id, 'note-id'); assert.equal(model.detailLoading, false);
  assert.equal(model.detail.bodyProvided, true); assert.equal(model.detail.body.blocks[0].spans[0].text, '正文');
  assert.equal(model.back(), true); assert.equal(model.selected, undefined); assert.equal(model.items.length, 1);
});

test('note lists use separate notebook and tag identities and title-only filtering', () => {
  assert.equal(p.decodeNotebooks({ notebooks: [{ object_id: 'book-id', title: '笔记本' }] })[0].id, 'book-id');
  const tags = p.decodeNoteTags({ tags: [{ tag_id: '标签@1024', title: '标签', items: ['note-id'] }] });
  assert.deepEqual(plain(tags[0]), { id: '标签@1024', title: '标签' });
  const page = p.decodeNotes({ notes: [note], total: 1 }, 0);
  assert.equal(p.filterNotes(page.items, 'book-id', '标签@1024', '示例', tags).length, 1);
  assert.equal(p.filterNotes(page.items, '', '', '正文', tags).length, 0);
  assert.equal(p.filterNotes(page.items, '', 'unknown-id', '', tags).length, 0);
  assert.throws(() => p.decodeNotes({ notes: [note, note] }, 0));
  assert.throws(() => p.decodeNoteDetail(note, 'other'));
  const missing = p.decodeNoteDetail({ object_id: 'empty', brief: '摘要不是正文' }, 'empty');
  assert.equal(missing.bodyProvided, false); assert.equal(missing.body.blocks.length, 0);
  assert.doesNotMatch(JSON.stringify(detail), /<p>|attachment":/);
});

test('notes accept direct list data and scalar tags without masking malformed records', () => {
  assert.equal(p.decodeNotebooks([{ object_id: 'book-id', title: '笔记本' }])[0].id, 'book-id');
  assert.equal(p.decodeNoteTags([{ tag_id: '标签@1024', title: '标签' }])[0].id, '标签@1024');
  for (const tag of [undefined, null, '', [], '标签', ['标签']]) {
    const page = p.decodeNotes([{ ...note, tag }], 0);
    assert.deepEqual(plain(page.items[0].tags), tag === '标签' || Array.isArray(tag) && tag.length ? ['标签'] : []);
    assert.equal(page.more, false);
  }
  assert.deepEqual(plain(p.decodeNoteDetail({ ...note, tag: '标签' }, note.object_id).item.tags), ['标签']);
  assert.equal(p.decodeNotes(Array.from({ length: 100 }, (_, i) => ({ ...note, object_id: String(i) })), 0).more, true);
  assert.throws(() => p.decodeNotes({}, 0), error => error.kind === dsm.NasErrorKind.Protocol);
  assert.throws(() => p.decodeNotes([{ ...note, tag: {} }], 0), error => error.kind === dsm.NasErrorKind.Protocol);
  assert.throws(() => p.decodeNotes([{ ...note, object_id: undefined }], 0), error => error.kind === dsm.NasErrorKind.Protocol);
  assert.throws(() => p.decodeNotes([note, note], 0), error => error.kind === dsm.NasErrorKind.Protocol);
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
  for (const name of ['SYNO.API.Auth', 'SYNO.DSM.Info', 'SYNO.FileStation.List', 'SYNO.NoteStation.Note', 'SYNO.NoteStation.Notebook', 'SYNO.NoteStation.Tag']) {
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

test('note refresh accepts the official tag_id and title catalog and filters notes by tag title', async () => {
  const f = await fixture();
  f.replies.push(ok({ notes: [note], total: 1 }), ok({ notebooks: [{ object_id: 'book-id', title: '笔记本' }] }),
    ok({ tags: [{ tag_id: '标签@1024', title: '标签', items: ['note-id'] }], offset: 0, total: 1 }));
  const { NoteModel } = load('NoteModel.ets'), model = new NoteModel();
  model.attach(f.connector, undefined, async () => {}); model.setVisible(true); await tick();
  assert.equal(model.loaded, true); assert.equal(model.loading, false);
  assert.equal(model.errorText, ''); assert.equal(model.notebookError, ''); assert.equal(model.tagError, '');
  assert.equal(model.tags[0].id, '标签@1024'); assert.equal(model.tags[0].title, '标签');
  assert.equal(p.filterNotes(model.items, '', model.tags[0].id, '', model.tags)[0].id, note.object_id);
  assert.equal(f.connector.capabilitySnapshots().find(x => x.feature === 'noteTags').state, 'available');
  assert.equal(f.calls.length, 4);
  assert.throws(() => p.decodeNoteTags({ tags: [{ title: '标签' }] }), x => x.kind === dsm.NasErrorKind.Protocol);
  assert.throws(() => p.decodeNoteTags({ tags: [{ tag_id: 'tag-id', title: '' }] }), x => x.kind === dsm.NasErrorKind.Protocol);
  model.reset();
});

test('direct note list envelopes reach the module decoder with exact identifiers and normal error classification', async () => {
  const f = await fixture();
  f.replies.push({ status: 200, text: '{"success":true,"data":[{"object_id":9007199254740993,"title":"笔记","tag":"标签"}]}' });
  const page = await f.connector.readNotes('list', '', 0, x => p.decodeNotes(x, 0));
  assert.equal(page.items[0].id, '9007199254740993'); assert.deepEqual(plain(page.items[0].tags), ['标签']);
  assert.equal(f.connector.capabilitySnapshots().find(x => x.feature === 'noteList').state, 'available');
  assert.equal(f.calls.length, 2);
  f.replies.push(ok([{ object_id: 'book-id', title: '笔记本' }]));
  assert.equal((await f.connector.readNotes('notebooks', '', 0, p.decodeNotebooks))[0].id, 'book-id');
  f.replies.push(ok([{ tag_id: '标签@1024', title: '标签' }]));
  assert.equal((await f.connector.readNotes('tags', '', 0, p.decodeNoteTags))[0].id, '标签@1024');
  f.replies.push(ok([note]));
  await assert.rejects(f.connector.readNotes('detail', note.object_id, 0, x => p.decodeNoteDetail(x, note.object_id)), error => error.kind === dsm.NasErrorKind.Protocol);
  const arrayReply = JSON.stringify({ success: true, data: [] });
  assert.throws(() => dsm.decodeNasResponse('SYNO.FileStation.List', 200, arrayReply), error => error.kind === dsm.NasErrorKind.Protocol);
  assert.throws(() => common.decodeReadOnlyResponse('SYNO.Docker.Container', 200, arrayReply), error => error.kind === dsm.NasErrorKind.Protocol);
  assert.throws(() => common.decodeReadOnlyResponse('SYNO.NoteStation.Note', 200, JSON.stringify({ success: false, error: { code: 105 }, data: [] })), error => error.kind === dsm.NasErrorKind.Permission);
  assert.throws(() => common.decodeReadOnlyResponse('SYNO.NoteStation.Note', 503, arrayReply), error => error.kind === dsm.NasErrorKind.Http);
});

test('note rejection rechecks primary authentication and preserves the account on network failure', async () => {
  for (const proof of ['valid', 'network', 'expired']) {
    const f = await fixture();
    f.replies.push(bad(107), proof === 'valid' ? ok({ model: 'test-nas' }) : proof === 'network' ? { status: 503, text: '' } : bad(106));
    await assert.rejects(f.connector.readNotes('list', '', 0, x => x), x => x.kind === (proof === 'expired' ? dsm.NasErrorKind.SessionExpired : proof === 'network' ? dsm.NasErrorKind.Http : dsm.NasErrorKind.Permission));
    assert.equal(f.connector.sessionSnapshot() !== undefined, proof !== 'expired');
    assert.equal(new URLSearchParams(f.calls.at(-1)[1]).get('api'), 'SYNO.DSM.Info');
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
  f.replies.push(ok({ model: 'test-nas' }));
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
