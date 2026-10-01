import { decodeCapabilities, decodeNasFileInfo, decodeNasFilePage, decodeNasResponse, decodeNasSession, encodeNasForm,
  NasApiDescriptor, NasErrorKind, NasFailure, NasFileInfo, NasFilePage, NasFormField, NasLoginSession,
  normalizeNasOrigin, selectNasApi, validateLogicalPath } from '../domain/DsmProtocol';

export interface NasHttpReply { status: number; text: string; }
export interface NasTransferPlan { address: string; fields: NasFormField[]; session: NasLoginSession; }
export interface NasTransport {
  post(address: string, body: string, session?: NasLoginSession): Promise<NasHttpReply>;
  close(): void;
}

export const NAS_DISCOVERY_QUERY = 'SYNO.API.Auth,SYNO.FileStation.List,SYNO.FileStation.Info,' +
  'SYNO.FileStation.Upload,SYNO.FileStation.Download,SYNO.Foto.Browse.Item,SYNO.FotoTeam.Browse.Item';

export class NasConnector {
  private origin: string = '';
  private capabilities: NasApiDescriptor[] = [];
  private session: NasLoginSession | undefined = undefined;
  private generation: number = 0;
  private disposed: boolean = false;
  private authenticating: boolean = false;
  constructor(private transport: NasTransport) {}

  async discover(address: string): Promise<NasApiDescriptor[]> {
    this.ensureOpen();
    if (this.origin.length > 0) { throw new NasFailure(NasErrorKind.InvalidInput, '请先断开当前连接。'); }
    this.origin = normalizeNasOrigin(address);
    const ticket = this.generation;
    const reply = await this.transport.post(this.origin + '/webapi/query.cgi', encodeNasForm([
      { name: 'api', content: 'SYNO.API.Info' }, { name: 'version', content: '1' },
      { name: 'method', content: 'query' }, { name: 'query', content: NAS_DISCOVERY_QUERY }
    ]));
    this.ensureCurrent(ticket);
    this.capabilities = decodeCapabilities(decodeNasResponse('SYNO.API.Info', reply.status, reply.text));
    selectNasApi(this.capabilities, 'SYNO.API.Auth', [6]);
    selectNasApi(this.capabilities, 'SYNO.FileStation.List', [2]);
    return this.capabilities.slice();
  }

  async login(account: string, password: string, otp: string): Promise<void> {
    this.ensureOpen();
    if (account.trim().length === 0 || password.length === 0) { throw new NasFailure(NasErrorKind.InvalidInput, '请输入账号和密码。'); }
    if (otp.length > 0 && !/^[0-9]{6}$/.test(otp)) { throw new NasFailure(NasErrorKind.InvalidInput, '动态码应为 6 位数字。'); }
    if (this.authenticating || this.session !== undefined) { throw new NasFailure(NasErrorKind.InvalidInput, '当前正在登录或已经登录。'); }
    const fields: NasFormField[] = [
      { name: 'account', content: account.trim() }, { name: 'passwd', content: password },
      { name: 'session', content: 'FileStation' }, { name: 'format', content: 'sid' },
      { name: 'enable_syno_token', content: 'yes' }
    ];
    if (otp.length > 0) { fields.push({ name: 'otp_code', content: otp }); }
    this.authenticating = true;
    try { this.session = decodeNasSession(await this.call('SYNO.API.Auth', 6, 'login', fields)); }
    finally { this.authenticating = false; }
  }

  async list(path: string, offset: number = 0): Promise<NasFilePage> {
    this.ensureOpen();
    if (this.session === undefined) { throw new NasFailure(NasErrorKind.SessionExpired, '请先登录 NAS。'); }
    if (!Number.isSafeInteger(offset) || offset < 0) { throw new NasFailure(NasErrorKind.InvalidInput, '分页位置不正确。'); }
    const api = selectNasApi(this.capabilities, 'SYNO.FileStation.List', [2]);
    const fields: NasFormField[] = [
      { name: 'offset', content: offset.toString() }, { name: 'limit', content: '100' },
      { name: 'sort_by', content: api.jsonParameters ? JSON.stringify('name') : 'name' },
      { name: 'sort_direction', content: api.jsonParameters ? JSON.stringify('asc') : 'asc' },
      { name: 'additional', content: JSON.stringify(['size']) }
    ];
    if (path.length > 0) {
      validateLogicalPath(path);
      fields.push({ name: 'folder_path', content: api.jsonParameters ? JSON.stringify(path) : path });
    }
    const data = await this.call('SYNO.FileStation.List', 2, path.length === 0 ? 'list_share' : 'list', fields);
    return decodeNasFilePage(data, path.length === 0, offset, 100);
  }

  async getFileInfo(path: string): Promise<NasFileInfo> {
    this.requireSession();
    validateLogicalPath(path);
    const data = await this.call('SYNO.FileStation.List', 2, 'getinfo', [
      { name: 'path', content: JSON.stringify([path]) },
      { name: 'additional', content: JSON.stringify(['size']) }
    ]);
    return decodeNasFileInfo(data, path);
  }

  /** 文件字段由传输层追加在末尾；不提供覆盖参数，重名交由 DSM 明确拒绝。 */
  transferUploadPlan(directory: string): NasTransferPlan {
    const session = this.requireSession();
    validateLogicalPath(directory);
    const api = selectNasApi(this.capabilities, 'SYNO.FileStation.Upload', [2]);
    return { address: this.origin + '/webapi/' + api.path, session: session, fields: [
      { name: 'api', content: api.name }, { name: 'version', content: '2' },
      { name: 'method', content: 'upload' },
      // 上传 multipart 的 path 是原始标量，不能沿用普通表单的 JSON 引号。
      { name: 'path', content: directory },
      { name: 'create_parents', content: 'false' }
    ] };
  }

  transferDownloadPlan(filePath: string): NasTransferPlan {
    const session = this.requireSession();
    validateLogicalPath(filePath);
    const api = selectNasApi(this.capabilities, 'SYNO.FileStation.Download', [2]);
    return { address: this.origin + '/webapi/' + api.path, session: session, fields: [
      { name: 'api', content: api.name }, { name: 'version', content: '2' },
      { name: 'method', content: 'download' },
      { name: 'path', content: JSON.stringify([filePath]) },
      { name: 'mode', content: api.jsonParameters ? JSON.stringify('download') : 'download' }
    ] };
  }

  restoreSession(session: NasLoginSession): void {
    this.ensureOpen();
    selectNasApi(this.capabilities, 'SYNO.API.Auth', [6]);
    if (this.authenticating || this.session !== undefined) { throw new NasFailure(NasErrorKind.InvalidInput, '当前正在登录或已经登录。'); }
    const data: Record<string, Object> = { sid: session.sid };
    if (session.synoToken.length > 0) { data['synotoken'] = session.synoToken; }
    this.session = decodeNasSession(data);
  }

  sessionSnapshot(): NasLoginSession | undefined {
    this.ensureOpen();
    return this.session === undefined ? undefined : { sid: this.session.sid, synoToken: this.session.synoToken };
  }

  async logout(): Promise<void> {
    const oldSession = this.session;
    this.session = undefined;
    this.generation++;
    if (this.disposed || oldSession === undefined) { this.close(); return; }
    try {
      const api = selectNasApi(this.capabilities, 'SYNO.API.Auth', [6]);
      const fields: NasFormField[] = [
        { name: 'api', content: api.name }, { name: 'version', content: '6' },
        { name: 'method', content: 'logout' }, { name: 'session', content: 'FileStation' }
      ];
      const reply = await this.transport.post(this.origin + '/webapi/' + api.path, encodeNasForm(fields), oldSession);
      decodeNasResponse(api.name, reply.status, reply.text);
    } finally { this.close(); }
  }

  close(): void {
    if (this.disposed) { return; }
    this.disposed = true;
    this.generation++;
    this.session = undefined;
    this.capabilities = [];
    this.transport.close();
  }

  private async call(name: string, version: number, method: string, parameters: NasFormField[]): Promise<Record<string, Object>> {
    this.ensureOpen();
    const ticket = this.generation;
    const api = selectNasApi(this.capabilities, name, [version]);
    const fields: NasFormField[] = [
      { name: 'api', content: name }, { name: 'version', content: version.toString() },
      { name: 'method', content: method }
    ];
    for (const parameter of parameters) { fields.push(parameter); }
    // 认证参数交由传输层发送 Cookie 和 CSRF 请求头，不进入 URL 或业务表单。
    const reply = await this.transport.post(this.origin + '/webapi/' + api.path, encodeNasForm(fields), this.session);
    this.ensureCurrent(ticket);
    try { return decodeNasResponse(name, reply.status, reply.text); }
    catch (error) {
      if (error instanceof NasFailure && error.kind === NasErrorKind.SessionExpired) {
        this.session = undefined;
        this.generation++;
      }
      throw error;
    }
  }

  private ensureOpen(): void {
    if (this.disposed) { throw new NasFailure(NasErrorKind.Cancelled, '连接已关闭。'); }
  }
  private requireSession(): NasLoginSession {
    this.ensureOpen();
    if (this.session === undefined) { throw new NasFailure(NasErrorKind.SessionExpired, '请先登录 NAS。'); }
    return { sid: this.session.sid, synoToken: this.session.synoToken };
  }
  private ensureCurrent(ticket: number): void {
    this.ensureOpen();
    if (ticket !== this.generation) { throw new NasFailure(NasErrorKind.Cancelled, '连接已切换。'); }
  }
}
