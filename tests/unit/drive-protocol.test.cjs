const { test } = require('node:test');
const assert = require('node:assert/strict');
const { NasFailure, NasErrorKind: K } = require('../../work/core-build/domain/DsmProtocol.js');
const {
  decodeDrivePage, decodeDriveEntry, decodeDriveEntryList, decodeDriveResponse, driveListFields,
  drivePathExpression, precisionSafeDriveJson, relabelDriveFailure, unknownDriveEntryKeys,
  validateDriveFileId, DRIVE_ENTRY_KEYS, DRIVE_PAGE_SIZE, DriveEntryKind, DriveSortBy, DriveSortDirection,
  DriveSpace,
} = require('../../work/core-build/domain/DriveProtocol.js');
const { DriveAdapter } = require('../../work/core-build/network/DriveAdapter.js');

const FILE_ID = '976700457026108129';
const ROOT_ID = '821014439470870977';

function isKind(kind) { return (error) => error instanceof NasFailure && error.kind === kind; }
const isProtocol = isKind(K.Protocol);

/** 按实测 40 键形状构造完整条目；数值与时间都取合法值。 */
function entryFixture(overrides = {}) {
  return {
    access_time: 1700000005, adv_shared: false, app_properties: { type: 'text/plain' },
    capabilities: { can_comment: false, can_delete: true, can_download: true, can_encrypt: false,
      can_organize: true, can_preview: true, can_read: true, can_rename: true, can_share: true,
      can_sync: false, can_write: false },
    change_id: 12, change_time: 1700000002, content_snippet: 'snippet', content_type: 'text/plain',
    created_time: 1600000000, disable_download: false, display_path: 'mydrive/report.docx',
    dsm_path: '/home/report.docx', enable_watermark: false, encrypted: false, file_id: FILE_ID,
    force_watermark_download: false, hash: 'abc123', image_metadata: { time: 1700000003 }, labels: [],
    max_id: 99, modified_time: 1700000004, name: 'report.docx',
    owner: { display_name: '张三', name: 'rhua', nickname: 'rh', uid: 7 },
    parent_id: ROOT_ID, path: '/mydrive/report.docx', permanent_link: 'https://example.invalid/x',
    properties: {}, removed: false, revisions: 3, shared: true, shared_with: [], size: 2048,
    starred: true, support_remote: false, sync_id: 5, sync_to_device: false, transient: false,
    type: 'file', version_id: 4, watermark_version: 0,
    ...overrides,
  };
}

test('driveListFields encodes values exactly like the captured Drive Web UI requests', () => {
  const fields = driveListFields({ space: DriveSpace.MyDrive }, 0);
  assert.deepEqual(fields, [
    { name: 'path', content: '"/mydrive"' },
    { name: 'offset', content: '0' },
    { name: 'limit', content: String(DRIVE_PAGE_SIZE) },
    { name: 'sort_by', content: '"name"' },
    { name: 'sort_direction', content: '"asc"' },
  ]);
  // 分页偏移是裸数字，path / sort_* 是带引号的 JSON 字符串；混用会被服务端判 103。
  const paged = driveListFields({ space: DriveSpace.MyDrive, fileId: ROOT_ID }, 400,
    DriveSortBy.ModifiedTime, DriveSortDirection.Descending);
  assert.deepEqual(paged.map((row) => row.content),
    ['"id:' + ROOT_ID + '"', '400', String(DRIVE_PAGE_SIZE), '"modified_time"', '"desc"']);
});

test('drivePathExpression never invents a path form the server rejects', () => {
  assert.equal(drivePathExpression({ space: DriveSpace.MyDrive }), '/mydrive');
  assert.equal(drivePathExpression({ space: DriveSpace.MyDrive, fileId: ROOT_ID }), 'id:' + ROOT_ID);
  assert.equal(drivePathExpression({ space: DriveSpace.TeamFolder, fileId: ROOT_ID }), 'id:' + ROOT_ID);
  // 团队文件夹没有虚拟根（/team-folders 实测返回 1000），必须在取到 id 之后才请求。
  assert.throws(() => drivePathExpression({ space: DriveSpace.TeamFolder }), isKind(K.InvalidInput));
  assert.throws(() => drivePathExpression({ space: DriveSpace.MyDrive, fileId: '../etc' }), isKind(K.InvalidInput));
});

test('validateDriveFileId only accepts plain digit ids', () => {
  assert.equal(validateDriveFileId(FILE_ID), FILE_ID);
  for (const bad of ['', 'id:1', '1a', '-1', '1 2', '1'.repeat(21), '1/2']) {
    assert.throws(() => validateDriveFileId(bad), isKind(K.InvalidInput), bad);
  }
});

test('precisionSafeDriveJson keeps out-of-range integer ids intact', () => {
  const text = '{"file_id":976700457026108129,"parent_id":821014439470870977,"total":11,"size":2048}';
  const hardened = precisionSafeDriveJson(text);
  assert.equal(hardened, '{"file_id":"976700457026108129","parent_id":"821014439470870977","total":11,"size":2048}');
  assert.deepEqual(JSON.parse(hardened), { file_id: '976700457026108129', parent_id: '821014439470870977', total: 11, size: 2048 });
  // 没有需要保精度的字段时原样返回，不引入额外解析开销，也不改动字节。
  const plain = '{"file_id":"123","total":1}';
  assert.equal(precisionSafeDriveJson(plain), plain);
});

test('decodeDriveResponse preserves an oversized numeric id end to end', () => {
  // JSON.parse 会把 976700457026108129 舍入成 976700457026108100，取错 ID 会指向别的对象。
  const text = '{"success":true,"data":{"total":1,"items":[{"file_id":976700457026108129,"parent_id":821014439470870977,"name":"a.md","type":"file"}]}}';
  const data = decodeDriveResponse('SYNO.SynologyDrive.Files', 200, text);
  assert.equal(decodeDriveEntry(data.items[0]).fileId, '976700457026108129');
});

test('decodeDriveEntry reads only whitelisted fields and reports drift separately', () => {
  const entry = decodeDriveEntry(entryFixture());
  assert.equal(entry.fileId, FILE_ID);
  assert.equal(entry.name, 'report.docx');
  assert.equal(entry.kind, DriveEntryKind.File);
  assert.equal(entry.sizeBytes, 2048);
  assert.equal(entry.parentId, ROOT_ID);
  assert.equal(entry.starred, true);
  assert.equal(entry.shared, true);
  assert.equal(entry.revisionCount, 3);
  assert.equal(entry.modifiedAt, 1700000004);
  assert.equal(entry.displayPath, 'mydrive/report.docx');
  assert.deepEqual(entry.owner, { displayName: '张三', name: 'rhua', nickname: 'rh', uid: '7' });
  assert.equal(entry.capabilities.canRename, true);
  assert.equal(entry.capabilities.canWrite, false);
  // 白名单外的字段既不进入模型，也不会让解码失败。
  assert.deepEqual(unknownDriveEntryKeys(entryFixture()), []);
  assert.deepEqual(unknownDriveEntryKeys(entryFixture({ future_field: 1, another: 'x' })).sort(),
    ['another', 'future_field']);
  assert.equal(DRIVE_ENTRY_KEYS.length, 40);
  assert.ok(DRIVE_ENTRY_KEYS.includes('file_id') && DRIVE_ENTRY_KEYS.includes('capabilities'));
});

test('decodeDriveEntry treats missing capabilities as "no action" instead of guessing', () => {
  const entry = decodeDriveEntry({ file_id: FILE_ID, name: 'a', type: 'file' });
  assert.equal(entry.capabilities.canRead, true);
  assert.equal(entry.capabilities.canDelete, false);
  assert.equal(entry.capabilities.canShare, false);
  assert.equal(entry.sizeBytes, undefined);
  assert.equal(entry.owner, undefined);
});

test('decodeDriveEntry folds dir and folder into one kind and rejects unknown kinds', () => {
  assert.equal(decodeDriveEntry(entryFixture({ type: 'dir' })).kind, DriveEntryKind.Folder);
  assert.equal(decodeDriveEntry(entryFixture({ type: 'folder' })).kind, DriveEntryKind.Folder);
  assert.throws(() => decodeDriveEntry(entryFixture({ type: 'symlink' })), isProtocol);
  assert.throws(() => decodeDriveEntry(entryFixture({ type: undefined })), isProtocol);
});

test('decodeDriveEntry rejects malformed required and optional fields', () => {
  for (const bad of [{ file_id: undefined }, { file_id: 'id:1' }, { name: '' }, { name: 5 }]) {
    assert.throws(() => decodeDriveEntry(entryFixture(bad)), isProtocol, JSON.stringify(bad));
  }
  for (const bad of [{ size: -1 }, { size: 1.5 }, { revisions: '3' }, { modified_time: -1 },
    { starred: 'yes' }, { capabilities: { can_read: 'true' } }, { owner: { uid: 'x' } }, { path: 7 }]) {
    assert.throws(() => decodeDriveEntry(entryFixture(bad)), isProtocol, JSON.stringify(bad));
  }
  assert.throws(() => decodeDriveEntry(null), isProtocol);
  assert.throws(() => decodeDriveEntry([]), isProtocol);
});

test('decodeDrivePage enforces the pagination contract the server actually returns', () => {
  const items = [entryFixture(), entryFixture({ file_id: '2', name: 'b' })];
  assert.deepEqual(decodeDrivePage({ total: 2, items }, 0, DRIVE_PAGE_SIZE),
    { items: decodeDriveEntryList({ items }), total: 2, offset: 0 });
  // 响应里没有 offset（实测只回 items/total），以请求参数为准。
  assert.equal(decodeDrivePage({ total: 2, items }, 0, DRIVE_PAGE_SIZE).offset, 0);
  // total 是分页唯一依据，缺失或非法必须显式失败，不能假装"没有更多"。
  for (const bad of [{ items }, { total: -1, items }, { total: 1.5, items }, { total: '2', items }]) {
    assert.throws(() => decodeDrivePage(bad, 0, DRIVE_PAGE_SIZE), isProtocol, JSON.stringify(bad));
  }
});

test('decodeDrivePage rejects over-long, out-of-range, empty-but-not-last and duplicate pages', () => {
  const wide = Array.from({ length: 3 }, (_, index) => entryFixture({ file_id: String(index + 1) }));
  assert.throws(() => decodeDrivePage({ total: 3, items: wide }, 0, 2), isProtocol);
  assert.throws(() => decodeDrivePage({ total: 3, items: wide }, 2, 4), isProtocol);
  assert.throws(() => decodeDrivePage({ total: 9, items: [] }, 0, 4), isProtocol);
  assert.throws(() => decodeDrivePage({ total: 2, items: [entryFixture(), entryFixture()] }, 0, 4), isProtocol);
  assert.throws(() => decodeDrivePage({ total: 1, items: undefined }, 0, 4), isProtocol);
});

test('decodeDriveEntryList serves the ancestor chain, which has no pagination fields', () => {
  const items = [entryFixture({ type: 'dir', file_id: ROOT_ID, name: '我的文件' }), entryFixture()];
  assert.equal(decodeDriveEntryList({ items }).length, 2);
  assert.throws(() => decodeDriveEntryList({}), isProtocol);
  assert.throws(() => decodeDriveEntryList({ items: {} }), isProtocol);
});

test('relabelDriveFailure replaces generic DSM wording with the measured Drive semantics', () => {
  // 103 实测不是"接口不存在"（shared_with_me 补全参数后返回 200），必须改口。
  const unsupported = relabelDriveFailure(new NasFailure(K.Unsupported, 'generic', 103));
  assert.equal(unsupported.kind, K.Unsupported);
  assert.match(unsupported.message, /参数不完整或方法名不对/);
  // 120 在通用映射里落到 Server，105 落到 Permission；真实含义都是 Drive 特有的，都要改口。
  assert.equal(relabelDriveFailure(new NasFailure(K.Permission, 'generic', 105)).kind, K.Permission);
  assert.match(relabelDriveFailure(new NasFailure(K.Server, 'generic', 120)).message, /日志/);
  const path = relabelDriveFailure(new NasFailure(K.Server, 'generic', 1000));
  assert.equal(path.kind, K.InvalidInput);
  assert.match(path.message, /团队文件夹/);
  // 传输层错误不作为业务码解释，避免把 HTTP 103/105 误认成 Drive 错误码。
  const http = new NasFailure(K.Http, '服务器 HTTP 请求失败（103）。', 103);
  assert.equal(relabelDriveFailure(http), http);
  // 其它错误原样透传，不吞掉已有语义。
  const other = new NasFailure(K.SessionExpired, '登录已失效，请重新登录。', 106);
  assert.equal(relabelDriveFailure(other), other);
  assert.equal(relabelDriveFailure('not-an-error'), 'not-an-error');
});

/** 假服务端的总条目数：要大于两页，才能让"请求第二页"是合法调用。 */
const FAKE_TOTAL = 401;

function fakeKernel(options = {}) {
  const calls = [];
  const kernel = {
    calls,
    supportsDriveApi: () => options.supported !== false,
    requestDrive: async (api, version, method, fields) => {
      calls.push({ api, version, method, fields });
      if (options.reply !== undefined) { return options.reply; }
      // 与真实服务端一样按 offset 返页。请求越界页属于调用方错误，
      // decodeDrivePage 会按分页契约拒绝，因此测试只请求合法页。
      const offset = Number(fields.find((row) => row.name === 'offset').content);
      const items = offset < FAKE_TOTAL
        ? [entryFixture(offset === 0 ? {} : { file_id: String(offset + 1), name: 'page-' + String(offset) })] : [];
      return { total: FAKE_TOTAL, items };
    },
    readDriveFeature: async (feature, read) => {
      calls.push({ feature });
      return read();
    },
  };
  return kernel;
}

test('DriveAdapter gates availability on the discovered Files api version', () => {
  assert.equal(new DriveAdapter(fakeKernel()).available(), true);
  assert.equal(new DriveAdapter(fakeKernel({ supported: false })).available(), false);
});

test('DriveAdapter requests the verified api version and version-2 list method', async () => {
  const kernel = fakeKernel();
  const adapter = new DriveAdapter(kernel);
  const result = await adapter.list({ space: DriveSpace.MyDrive });
  assert.equal(result.total, FAKE_TOTAL);
  assert.equal(result.items[0].fileId, FILE_ID);
  const call = kernel.calls.find((row) => row.method === 'list');
  assert.equal(call.api, 'SYNO.SynologyDrive.Files');
  assert.equal(call.version, 2);
  assert.deepEqual(call.fields.map((row) => row.name), ['path', 'offset', 'limit', 'sort_by', 'sort_direction']);
  // 第一页代表"这个来源可用"，要登记到能力状态机；后续页不必重复登记。
  assert.equal(kernel.calls.filter((row) => row.feature !== undefined).length, 1);
  assert.equal(kernel.calls[0].feature, 'driveBrowse');
  await adapter.list({ space: DriveSpace.MyDrive }, DRIVE_PAGE_SIZE);
  assert.equal(kernel.calls.filter((row) => row.feature !== undefined).length, 1);
});

test('DriveAdapter refuses non-aligned offsets instead of overlapping pages', async () => {
  const adapter = new DriveAdapter(fakeKernel());
  for (const offset of [-1, 1, DRIVE_PAGE_SIZE / 2, 1.5]) {
    await assert.rejects(() => adapter.list({ space: DriveSpace.MyDrive }, offset), isKind(K.InvalidInput));
  }
});

test('DriveAdapter surfaces the kernel failure untouched so callers see one error model', async () => {
  const failure = new NasFailure(K.Permission, '当前账号没有读取这部分 Drive 数据的权限（105）。', 105);
  const kernel = fakeKernel({ reply: undefined });
  kernel.requestDrive = async () => { throw failure; };
  const adapter = new DriveAdapter(kernel);
  await assert.rejects(() => adapter.list({ space: DriveSpace.MyDrive }), (error) => error === failure);
});
