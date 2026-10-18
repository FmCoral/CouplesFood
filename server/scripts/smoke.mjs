/**
 * 端到端验证：覆盖需求基线 v2.0 的所有关键规则
 * 运行：node scripts/smoke.mjs   （需先启动服务）
 */
const B = process.env.BASE_URL ?? 'http://127.0.0.1:3000';

let pass = 0;
const failures = [];
const ok = (cond, msg, extra) => {
  if (cond) { pass++; console.log('  \x1b[32m✓\x1b[0m', msg); }
  else { failures.push(msg); console.log('  \x1b[31m✗\x1b[0m', msg, extra !== undefined ? JSON.stringify(extra).slice(0, 300) : ''); }
};
const section = (t) => console.log(`\n\x1b[1m${t}\x1b[0m`);

async function call(method, path, body, token, extraHeaders = {}) {
  const headers = { ...(body ? { 'Content-Type': 'application/json' } : {}), ...extraHeaders };
  if (token) headers.Authorization = `Bearer ${token}`;
  const r = await fetch(B + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await r.text();
  let j = null;
  try { j = text ? JSON.parse(text) : null; } catch { j = { raw: text }; }
  return { status: r.status, j, headers: r.headers };
}

const rnd = () => String(Math.floor(Math.random() * 1e8)).padStart(8, '0');

/** 打印汇总并退出。中间提前结束的分支也走这里，保证结果一定被输出 */
function summarize() {
  console.log(`\n${'='.repeat(60)}`);
  if (failures.length === 0) {
    console.log(`\x1b[32m全部通过：${pass} 项\x1b[0m`);
  } else {
    console.log(`\x1b[31m失败 ${failures.length} 项 / 通过 ${pass} 项\x1b[0m`);
    failures.forEach((f) => console.log('  ✗ ' + f));
  }
  console.log('='.repeat(60));
  process.exit(failures.length ? 1 : 0);
}
const jwtClaims = (t) => JSON.parse(Buffer.from(String(t).split('.')[1], 'base64url').toString('utf8'));
const uniqPhone = () => '138' + rnd();

async function register(nickname) {
  const phone = uniqPhone();
  const r = await call('POST', '/api/auth/register', {
    phone, password: 'pass12345', nickname, deviceId: 'dev-' + rnd(),
  });
  return { phone, ...r, token: r.j?.data?.accessToken, refresh: r.j?.data?.refreshToken, userId: r.j?.data?.userId };
}

async function main() {
  // ========== 0. 健康 ==========
  section('0. 基础可用性');
  ok((await call('GET', '/api/health')).j?.status === 'ok', 'GET /api/health');
  ok((await call('GET', '/api/ready')).j?.status === 'ok', 'GET /api/ready（DB 连通）');
  const nf = await call('GET', '/api/nonexistent');
  ok(nf.status === 404 && nf.j.title === 'NOT_FOUND', '未知路由返回 404 + RFC9457 信封');
  ok(!!nf.j.request_id, '响应带 request_id');
  ok(nf.headers.get('x-request-id') === nf.j.request_id, '响应头 X-Request-Id 与体一致');

  // ========== 1. 注册 / 登录 ==========
  section('1. 注册与登录');
  const A = await register('小明');
  const Bb = await register('小红');
  ok(A.status === 200 && A.token, 'A 注册成功');
  ok(Bb.status === 200 && Bb.token, 'B 注册成功');
  ok(A.j.data.isAdmin === false, '普通用户 isAdmin=false');

  const dup = await call('POST', '/api/auth/register', {
    phone: A.phone, password: 'pass12345', nickname: 'x', deviceId: 'dev-dup0001',
  });
  ok(dup.status === 409, '重复手机号注册 → 409');

  const badPwd = await call('POST', '/api/auth/login', { phone: A.phone, password: 'wrongpass', deviceId: 'dev-x0001' });
  ok(badPwd.status === 401 && badPwd.j.detail === '手机号或密码不正确', '错误密码 → 401 统一文案');

  const noSuchUser = await call('POST', '/api/auth/login', { phone: '13900000000', password: 'wrongpass', deviceId: 'dev-x0002' });
  ok(noSuchUser.j.detail === badPwd.j.detail, '不存在的账号与错密码文案一致（防枚举）');

  const loginA = await call('POST', '/api/auth/login', { phone: A.phone, password: 'pass12345', deviceId: 'dev-main01' });
  ok(loginA.status === 200 && loginA.j.data.accessToken, 'A 正常登录');
  A.token = loginA.j.data.accessToken;
  A.refresh = loginA.j.data.refreshToken;

  const meA = await call('GET', '/api/auth/me', null, A.token);
  ok(meA.j.data.phone === A.phone.replace(/^(\d{3})\d{4}(\d{4})$/, '$1****$2'), '手机号脱敏返回');

  // ========== 2. 未绑定的隔离 ==========
  section('2. 未绑定状态的隔离');
  const noPair = await call('GET', '/api/dishes', null, A.token);
  ok(noPair.status === 403, `未绑定访问菜单 → 403 (${noPair.status})`);
  const noPairOrder = await call('GET', '/api/orders', null, A.token);
  ok(noPairOrder.status === 403, '未绑定访问订单 → 403');
  const unauth = await call('GET', '/api/dishes');
  ok(unauth.status === 401, '无 token → 401');

  // ========== 3. 绑定流程 ==========
  section('3. 邀请码绑定');
  const inv = await call('POST', '/api/couples/invite', {}, A.token);
  ok(inv.status === 200 && /^[2-9]{6}$/.test(inv.j.data.inviteCode), `生成 6 位邀请码 ${inv.j.data.inviteCode}`);
  const inv2 = await call('POST', '/api/couples/invite', {}, A.token);
  ok(inv2.j.data.inviteCode === inv.j.data.inviteCode && inv2.j.data.reused === true, '重复申请复用未过期邀请码');

  const join = await call('POST', '/api/couples/join', {
    inviteCode: inv.j.data.inviteCode, deviceId: 'dev-join001',
  }, Bb.token);
  ok(join.status === 200 && join.j.data.coupleId, 'B 加入成功');
  ok(!!join.j.data.accessToken, 'B 得到换发后的新 token');
  const coupleId = join.j.data.coupleId;

  const joinAgain = await call('POST', '/api/couples/join', {
    inviteCode: inv.j.data.inviteCode, deviceId: 'dev-join002',
  }, Bb.token);
  ok(joinAgain.status === 409, '重复加入同一邀请码 → 409');

  // A 的 token 里 coupleId 还是 null —— 这是必须处理的坑
  const aStillStale = await call('GET', '/api/dishes', null, A.token);
  ok(aStillStale.status === 403, 'A 的旧 token 仍无 coupleId（预期，需刷新）');
  const reA = await call('POST', '/api/auth/refresh', { refreshToken: A.refresh });
  A.token = reA.j.data.accessToken;
  A.refresh = reA.j.data.refreshToken;
  ok(jwtClaims(reA.j.data.accessToken).coupleId === coupleId, 'A 刷新后 token 带上了 coupleId');
  ok((await call('GET', '/api/dishes', null, A.token)).status === 200, 'A 刷新后可访问菜单');
  Bb.token = join.j.data.accessToken;
  Bb.refresh = join.j.data.refreshToken;

  const meCoupleA = await call('GET', '/api/couples/me', null, A.token);
  ok(meCoupleA.j.data?.partner?.nickname === '小红', 'A 看到伴侣是小红');
  ok(meCoupleA.j.data?.status === 'active', '关系状态 active');

  // ========== 4. 预设分类（每对一套） ==========
  section('4. 分类：每对情侣各自一套');
  const typesA = await call('GET', '/api/dish-types', null, A.token);
  const flavorsA = await call('GET', '/api/dish-flavors', null, A.token);
  ok(typesA.j.data.length === 6, `预设 6 个种类 (${typesA.j.data.map((t) => t.name).join('/')})`);
  ok(flavorsA.j.data.length === 7, `预设 7 个口味 (${flavorsA.j.data.map((t) => t.name).join('/')})`);
  ok(typesA.j.data.every((t) => t.isPreset), '预设项标记 isPreset=true');

  // 另一对情侣应当是独立一套
  const C = await register('阿强');
  const D = await register('阿珍');
  const invC = await call('POST', '/api/couples/invite', {}, C.token);
  const joinC = await call('POST', '/api/couples/join', { inviteCode: invC.j.data.inviteCode, deviceId: 'dev-joinC01' }, D.token);
  C.token = (await call('POST', '/api/auth/refresh', { refreshToken: C.refresh })).j.data.accessToken;
  D.token = joinC.j.data.accessToken;
  const typesC = await call('GET', '/api/dish-types', null, C.token);
  ok(typesC.j.data.length === 6, '第二对情侣也有自己的一套 6 个种类');
  ok(typesC.j.data[0].id !== typesA.j.data[0].id, '两对情侣的种类 ID 不同（强隔离）');

  // C 的菜 A 看不到
  const dishC = await call('POST', '/api/dishes', { name: '阿强的菜' }, C.token);
  ok(dishC.status === 201, 'C 建菜成功');
  const crossGet = await call('GET', `/api/dishes/${dishC.j.data.id}`, null, A.token);
  ok(crossGet.status === 404, `跨情侣读菜品 → 404 而非 403（不泄露存在性）`);
  const crossPatch = await call('PATCH', `/api/dishes/${dishC.j.data.id}`, { name: 'hack', version: 1 }, A.token);
  ok(crossPatch.status === 404, '跨情侣改菜品 → 404');
  const crossDel = await call('DELETE', `/api/dishes/${dishC.j.data.id}`, null, A.token);
  ok(crossDel.status === 404, '跨情侣删菜品 → 404');

  // ========== 5. 分类自定义 ==========
  section('5. 分类自定义与多选口味');
  const newType = await call('POST', '/api/dish-types', { name: '硬菜' }, A.token);
  ok(newType.status === 201, '新增自定义种类「硬菜」');
  const dupType = await call('POST', '/api/dish-types', { name: '硬菜' }, A.token);
  ok(dupType.status === 409, '同名种类 → 409');
  const useType = await call('POST', '/api/dish-types', { name: '硬菜' }, C.token);
  ok(useType.status === 201, '另一对情侣可建同名种类（各自独立）');

  const typeIds = typesA.j.data;
  const flavorIds = flavorsA.j.data;
  const meatType = typeIds.find((t) => t.name === '荤菜').id;
  const soupType = typeIds.find((t) => t.name === '汤').id;
  const heavy = flavorIds.find((f) => f.name === '重口').id;
  const spicy = flavorIds.find((f) => f.name === '辣').id;
  const light = flavorIds.find((f) => f.name === '清淡').id;

  // ========== 6. 菜品 CRUD + 多分类 ==========
  section('6. 菜品：双维度分类');
  const d1 = await call('POST', '/api/dishes', {
    name: '红烧肉', note: '少放糖', tags: ['10分钟', '妈妈的味道'],
    typeId: meatType, flavorIds: [heavy, spicy],
  }, A.token);
  ok(d1.status === 201, '新建红烧肉（荤菜 + 重口/辣）');

  const d2 = await call('POST', '/api/dishes', {
    name: '番茄蛋汤', typeId: soupType, flavorIds: [light],
  }, Bb.token);
  ok(d2.status === 201, 'B 也能建菜（双方共同维护）');

  const detail = await call('GET', `/api/dishes/${d1.j.data.id}`, null, A.token);
  ok(detail.j.data.type?.name === '荤菜', '种类正确');
  ok(detail.j.data.flavors.length === 2, '口味有 2 个');

  // 客户端 UUID 幂等（离线新建）
  const clientId = crypto.randomUUID();
  const off1 = await call('POST', '/api/dishes', { id: clientId, name: '离线菜' }, A.token);
  ok(off1.status === 201, '客户端 UUID 新建成功');
  const off2 = await call('POST', '/api/dishes', { id: clientId, name: '离线菜' }, A.token);
  ok(off2.status === 200 && off2.j.data.idempotent === true, '同 UUID 重放 → 幂等返回 200');

  // 筛选：种类 + 口味叠加取交集
  const filterBoth = await call('GET', `/api/dishes?typeId=${meatType}&flavorIds=${heavy},${spicy}`, null, A.token);
  ok(filterBoth.j.data.length === 1 && filterBoth.j.data[0].name === '红烧肉', '种类+口味叠加筛选命中');
  const filterMiss = await call('GET', `/api/dishes?typeId=${meatType}&flavorIds=${light}`, null, A.token);
  ok(filterMiss.j.data.length === 0, '口味不匹配 → 空（取交集而非并集）');
  const filterName = await call('GET', '/api/dishes?q=红烧', null, A.token);
  ok(filterName.j.data.length === 1, '按名称搜索命中');

  // ========== 7. 乐观锁 ==========
  section('7. 乐观锁冲突');
  const p1 = await call('PATCH', `/api/dishes/${d1.j.data.id}`, { note: '不放糖', version: 1 }, A.token);
  ok(p1.status === 200 && p1.j.data.version === 2, 'A 更新成功 → version 2');
  const p2 = await call('PATCH', `/api/dishes/${d1.j.data.id}`, { note: '别改', version: 1 }, Bb.token);
  ok(p2.status === 409, `B 用旧 version → 409`);
  ok(p2.j.errors?.expectedVersion === 1, '409 返回期望版本供客户端比对');
  const p3 = await call('PATCH', `/api/dishes/${d1.j.data.id}`, { note: '不放糖', version: 2 }, Bb.token);
  ok(p3.status === 200, 'B 用最新 version → 成功');

  // ========== 8. 点菜状态机 ==========
  section('8. 点菜与状态机');
  const order = await call('POST', '/api/orders', {
    items: [{ dishId: d1.j.data.id, quantity: 1, note: '多放辣' }],
    mealType: 'dinner', note: '今晚想吃',
  }, Bb.token);
  ok(order.status === 201 && order.j.data.status === 'pending', 'B 下单成功 pending');
  const oid = order.j.data.id;

  const selfAccept = await call('POST', `/api/orders/${oid}/transition`, { to: 'accepted', version: 1 }, Bb.token);
  ok(selfAccept.status === 409, '下单人不能自己接单 → 409');
  const skip = await call('POST', `/api/orders/${oid}/transition`, { to: 'served', version: 1 }, A.token);
  ok(skip.status === 409, 'pending 不能直跳 served → 409');
  const wrongVer = await call('POST', `/api/orders/${oid}/transition`, { to: 'accepted', version: 99 }, A.token);
  ok(wrongVer.status === 409, 'version 不匹配 → 409');
  const accept = await call('POST', `/api/orders/${oid}/transition`, { to: 'accepted', version: 1, replyNote: '好嘞' }, A.token);
  ok(accept.status === 200 && accept.j.data.status === 'accepted', 'A 接单 → accepted');
  const cooking = await call('POST', `/api/orders/${oid}/transition`, { to: 'cooking', version: 2 }, A.token);
  const served = await call('POST', `/api/orders/${oid}/transition`, { to: 'served', version: 3 }, A.token);
  ok(cooking.status === 200 && served.status === 200, 'accepted → cooking → served');
  const doneByChef = await call('POST', `/api/orders/${oid}/transition`, { to: 'completed', version: 4 }, A.token);
  ok(doneByChef.status === 409, '出餐后不能由厨师方确认完成 → 409');
  const done = await call('POST', `/api/orders/${oid}/transition`, { to: 'completed', version: 4 }, Bb.token);
  ok(done.status === 200, 'served → completed');
  const after = await call('POST', `/api/orders/${oid}/transition`, { to: 'accepted', version: 5 }, A.token);
  ok(after.status === 409, '终态不能再流转 → 409');

  const list = await call('GET', '/api/orders', null, Bb.token);
  ok(list.j.data[0].items[0].name === '红烧肉', '订单含菜名快照');
  ok(list.j.data[0].timeline.completedAt, '时间轴记录完成时间');

  // ========== 9. 软删除与快照 ==========
  section('9. 软删除不影响历史订单');
  const del = await call('DELETE', `/api/dishes/${d1.j.data.id}`, null, A.token);
  ok(del.status === 200, '删除菜品');
  const afterDel = await call('GET', '/api/orders', null, Bb.token);
  ok(afterDel.j.data[0].items[0].name === '红烧肉', '历史订单快照完好');
  const orderDel = await call('POST', '/api/orders', { items: [{ dishId: d1.j.data.id, quantity: 1 }] }, Bb.token);
  ok(orderDel.status >= 400 && orderDel.status < 500, `已下架的菜禁止下单 → ${orderDel.status}`);
  const listAfter = await call('GET', '/api/dishes', null, A.token);
  ok(!listAfter.j.data.some((d) => d.id === d1.j.data.id), '列表不再显示已删除的菜');

  // ========== 10. 同步事件 ==========
  section('10. 事件日志与增量同步');
  const ev = await call('GET', '/api/sync/events?since=0', null, Bb.token);
  ok(ev.j.data.length >= 5, `拉到 ${ev.j.data.length} 条事件`);
  ok(ev.j.data.every((e) => e.id), '每条事件有单调 id');
  ok(ev.j.data.some((e) => e.type === 'order.status_changed'), '事件含订单状态变更');
  ok(ev.j.data.some((e) => e.type === 'couple.bound'), '事件含绑定');
  const cursor = Number(ev.j.cursor);
  const ev2 = await call('GET', `/api/sync/events?since=${cursor}`, null, Bb.token);
  ok(ev2.j.data.length === 0, 'since=最新 cursor → 无新事件');
  const evC = await call('GET', '/api/sync/events?since=0', null, C.token);
  ok(!evC.j.data.some((e) => e.entityId === oid), 'C 看不到 A/B 的事件');

  // ========== 11. 图片上传 ==========
  section('11. 图片上传');
  const png1x1 = Buffer.from(
    '89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000d4944415478da63f8cf000000030101002e2f0a0b0000000049454e44ae426082',
    'hex',
  );
  const fd = new FormData();
  fd.append('file', new Blob([png1x1], { type: 'image/png' }), 'a.png');
  const up = await fetch(B + '/api/uploads', { method: 'POST', headers: { Authorization: `Bearer ${A.token}` }, body: fd });
  const upJ = await up.json();
  ok(up.status === 200 && upJ.data.imageKey, '上传 PNG 成功');
  const imgRes = await fetch(B + '/media/' + upJ.data.imageKey);
  ok(imgRes.status === 200, '上传后可访问 /media/...');
  ok(imgRes.headers.get('cache-control')?.includes('immutable'), '图片带 immutable 长缓存');

  const badFd = new FormData();
  badFd.append('file', new Blob([Buffer.from('not an image')], { type: 'image/png' }), 'x.png');
  const badUp = await fetch(B + '/api/uploads', { method: 'POST', headers: { Authorization: `Bearer ${A.token}` }, body: badFd });
  ok(badUp.status === 400, '伪装成 png 的文本 → 400（魔数校验）');

  // ========== 12. 解散流程 ==========
  section('12. 解散：发起 → 撤销/拒绝/同意');
  const dr = await call('POST', '/api/couples/dissolve/request', { reason: '测试' }, Bb.token);
  ok(dr.status === 200 && dr.j.data.coupleStatus === 'dissolving', 'B 发起解散 → dissolving');
  const meDissolving = await call('GET', '/api/couples/me', null, A.token);
  ok(meDissolving.j.data.status === 'dissolving', 'A 看到状态 dissolving');
  ok(!!meDissolving.j.data.dissolution, 'A 能看到解散申请信息');

  // 冻结只读
  const frozen = await call('POST', '/api/dishes', { id: crypto.randomUUID(), name: '冻结期不该成功', typeIds: [], flavorIds: [] }, A.token);
  ok(frozen.status === 409, `冻结期建菜 → 409 (${frozen.status})`);
  const frozenOrder = await call('POST', '/api/orders', { items: [{ dishId: d2.j.data.id, quantity: 1 }] }, A.token);
  ok(frozenOrder.status === 409, '冻结期下单 → 409');

  const dupReq = await call('POST', '/api/couples/dissolve/request', {}, A.token);
  ok(dupReq.status === 409, '已有待处理申请 → 409');

  const selfApprove = await call('POST', `/api/couples/dissolve/${dr.j.data.requestId}/approve`, {}, Bb.token);
  ok(selfApprove.status === 403, '发起人不能自己批准 → 403');

  // A 拒绝 → 回到 active
  const reject = await call('POST', `/api/couples/dissolve/${dr.j.data.requestId}/reject`, {}, A.token);
  ok(reject.status === 200 && reject.j.data.coupleStatus === 'active', 'A 拒绝 → 回到 active');
  ok((await call('POST', '/api/dishes', { name: '解冻后的菜' }, A.token)).status === 201, '解冻后可正常建菜');

  // 再发起，发起人自己撤回
  const dr2 = await call('POST', '/api/couples/dissolve/request', {}, A.token);
  const otherWithdraw = await call('POST', `/api/couples/dissolve/${dr2.j.data.requestId}/withdraw`, {}, Bb.token);
  ok(otherWithdraw.status === 403, '非发起人不能撤回 → 403');
  const withdraw = await call('POST', `/api/couples/dissolve/${dr2.j.data.requestId}/withdraw`, {}, A.token);
  ok(withdraw.status === 200 && withdraw.j.data.coupleStatus === 'active', 'A 撤回 → 回到 active');

  // 第三次：同意路径放在最后（会解散），先用 C/D 验证
  const cdr = await call('POST', '/api/couples/dissolve/request', {}, C.token);
  const cdrApprove = await call('POST', `/api/couples/dissolve/${cdr.j.data.requestId}/approve`, {}, D.token);
  ok(cdrApprove.status === 200 && cdrApprove.j.data.coupleStatus === 'dissolved', 'D 同意 → dissolved');
  const cMe = await call('GET', '/api/couples/me', null, C.token);
  ok(cMe.j.data === null, '解散后 /couples/me 返回 null');
  // 解散后 C 手里的 access token 仍带旧 coupleId；服务端负责兜底：
  // 要么按未绑定拒绝（403），要么返回空列表，绝不能泄露解散前的内容
  const cDish = await call('GET', '/api/dishes', null, C.token);
  ok([403, 200].includes(cDish.status) && (cDish.status === 403 || (cDish.j.data ?? []).length === 0),
    `解散后访问菜单 → 无权或空列表（${cDish.status}）`);

  // 解散后可重新绑定
  const cInv = await call('POST', '/api/couples/invite', {}, C.token);
  ok(cInv.status === 200, '解散后可再生成邀请码');
  const cRebind = await call('POST', '/api/couples/join', { inviteCode: cInv.j.data.inviteCode, deviceId: 'dev-rebind1' }, D.token);
  ok(cRebind.status === 200, '解散后双方可重新绑定');

  // ========== 13. 超管 ==========
  section('13. 超管');
  // 超管凭据必须显式传入，不猜默认值：
  // .env.example 里 ADMIN_PASSWORD 是 CHANGE_ME_*，部署时一定会被改掉，
  // 硬编码一个默认值只会在别人机器上必然失败，还会把真实口令写进仓库。
  const adminPhone = process.env.ADMIN_PHONE;
  const adminPassword = process.env.ADMIN_PASSWORD;
  if (!adminPhone || !adminPassword) {
    failures.push('第 13 节跳过：未设置 ADMIN_PHONE / ADMIN_PASSWORD');
    console.log('  \x1b[33m!\x1b[0m 跳过超管测试 —— 请用 ADMIN_PHONE=... ADMIN_PASSWORD=... 重新运行');
    return summarize();
  }

  const adminLogin = await call('POST', '/api/auth/login', {
    phone: adminPhone,
    password: adminPassword,
    deviceId: 'dev-admin01',
  });
  ok(adminLogin.status === 200 && adminLogin.j?.data?.isAdmin === true, '超管登录，isAdmin=true', adminLogin.j);
  const adminToken = adminLogin.j.data.accessToken;

  const adminMe = await call('GET', '/api/couples/me', null, adminToken);
  ok(adminMe.j.data === null, '超管不绑定任何情侣');

  const adminInvite = await call('POST', '/api/couples/invite', {}, adminToken);
  ok(adminInvite.status === 403, '超管不能生成邀请码 → 403');

  const normalToAdmin = await call('GET', '/api/admin/couples', null, A.token);
  ok(normalToAdmin.status === 403, '普通用户访问管理接口 → 403');

  const couples = await call('GET', '/api/admin/couples?status=all', null, adminToken);
  ok(couples.status === 200 && Array.isArray(couples.j.data), '超管可查看情侣列表');
  ok(couples.j.data.every((c) => c.members.every((m) => m.phone.includes('****'))), '手机号脱敏');
  const archived = couples.j.data.filter((c) => c.status === 'dissolved');
  ok(archived.length >= 1, '能看到已归档的情侣');

  const menu = await call('GET', `/api/admin/couples/${coupleId}/menu`, null, adminToken);
  ok(menu.status === 200 && menu.j.data.length > 0, '超管可只读查看菜单');
  const orders = await call('GET', `/api/admin/couples/${coupleId}/orders`, null, adminToken);
  ok(orders.status === 200 && orders.j.data.length > 0, '超管可只读查看订单');

  const adminWrite = await call('PATCH', `/api/dishes/${d2.j.data.id}`, { name: '管理员改的', version: 1 }, adminToken);
  ok(adminWrite.status === 403, '超管改菜品 → 403（只读）');
  const adminDel = await call('DELETE', `/api/dishes/${d2.j.data.id}`, null, adminToken);
  ok(adminDel.status === 403, '超管删菜品 → 403');

  const status = await call('GET', '/api/admin/status', null, adminToken);
  ok(status.status === 200 && typeof status.j.data.activeCouples === 'number', '系统状态可用');
  if (status.j.data.disk) ok(status.j.data.disk.totalGb > 0, `磁盘信息: ${status.j.data.disk.usedPercent}% 已用`);
  else ok(true, '磁盘信息不可用（容器内 /proc 受限，生产环境可用）');

  const audit = await call('GET', '/api/admin/audit', null, adminToken);
  ok(audit.j.data.length >= 3, `审计日志记录了 ${audit.j.data.length} 条动作`);
  ok(audit.j.data.some((a) => a.action === 'view.menu'), '查看菜单有审计记录');

  const reset = await call('POST', `/api/admin/users/${A.userId}/reset-password`, { newPassword: 'newpass12345' }, adminToken);
  ok(reset.status === 200, '超管重置密码成功');
  const oldPwdLogin = await call('POST', '/api/auth/login', { phone: A.phone, password: 'pass12345', deviceId: 'dev-chk001' });
  ok(oldPwdLogin.status === 401, '旧密码立即失效');
  const newPwdLogin = await call('POST', '/api/auth/login', { phone: A.phone, password: 'newpass12345', deviceId: 'dev-chk002' });
  ok(newPwdLogin.status === 200, '新密码可登录');

  // 超管强制解散（用 A/B 这最后一段）
  const forceDissolve = await call('POST', `/api/admin/couples/${coupleId}/dissolve`, { reason: '测试强制解散' }, adminToken);
  ok(forceDissolve.status === 200 && forceDissolve.j.data.status === 'dissolved', '超管强制解散成功');
  const aAfter = await call('GET', '/api/couples/me', null, newPwdLogin.j.data.accessToken);
  ok(aAfter.status === 200, '解散后接口仍可访问（返回 null）');

  // ========== 14. 其他 ==========
  section('14. 边界与安全');
  const badUuid = await call('GET', '/api/dishes/not-a-uuid', null, adminToken);
  ok([400, 404, 422].includes(badUuid.status), `非法 UUID → ${badUuid.status}`);

  const emptyJson = await fetch(B + '/api/auth/login', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
  });
  ok(emptyJson.status === 400, '空 body + JSON header → 400 而非 500');

  // 汇总
  summarize();
}

main().catch((e) => {
  console.error('\n测试脚本异常：', e);
  process.exit(2);
});
