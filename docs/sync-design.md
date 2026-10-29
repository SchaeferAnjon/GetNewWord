# GetNewWord 账号登录 + 词库多设备同步（2026-09-14）

目标：两台 Mac 登录同一个账号后，GetNewWord 的单词、语境、知识片段、分类保持一致。未登录时 app 行为与现在完全相同。

## 1. 选型

| 决定 | 选择 | 理由 |
|---|---|---|
| 账号平台 | 共用 Supabase 项目 `blsbkqreuhgvksphsvaw`，Google 登录 | 托管的登录和 Postgres，行级权限按 user_id 隔离 |
| 表位置 | 独立 schema `getnewword`（categories / words / contexts / snippets） | 和同一个项目里别的表分开 |
| 客户端 | 手写 REST（Auth PKCE + PostgREST），不引 supabase-swift | 项目零 SPM 依赖；用到的接口只有 4 个 |
| 回调 | `ASWebAuthenticationSession`，scheme `getnewword://auth-callback` | 不需要注册 URL Type，不需要本地端口 |
| 会话存储 | Keychain（`com.getnewword.app` / `supabase_session`） | 与现有 API key 同处 |
| 本地模型 | **不改 SwiftData 模型** | 避免模型迁移风险；变更检测靠「快照哈希」而不是给 20 多处增删改代码加 dirty 标记 |
| entitlements | 暂不接 | 该表尚未建成；GetNewWord 目前免费 |
| 文件（音频/截图） | 首版不同步 | 音频启动时 `backfillAudio` 会自动补下；截图只是来源展示，路径在另一台无效，拉下来时不覆盖本地路径 |

## 2. 表结构

见 `supabase/getnewword-schema.sql`。要点：

- 主键就是本地模型的 `id: UUID`；每行带 `user_id`（默认 `auth.uid()`），RLS 四条策略 `auth.uid() = user_id`。
- 删除是软删：`deleted_at` 非空即墓碑。
- `updated_at` 由触发器写服务端时钟（`clock_timestamp()`），只用作增量拉取游标。
- 关系用 id 列（`category_id`、`parent_id`、`word_id`、`related_word_ids`），不设外键，客户端找不到引用就置空。

## 3. 同步算法

本地旁路状态文件 `~/Library/Application Support/GetNewWord/sync-state-<userId>.json`：

```
cursor: 服务端 updated_at 游标
known:  { "<表>/<uuid>": "<上次同步时的内容哈希>" }
unconfirmedAnki: [anki_note_id…]   // 从云端拉来、本机 Anki 还没见过的卡
```

一次同步（串行，互斥）：

1. **拉**：四张表各 `GET ?updated_at=gt.<cursor-5s>&order=updated_at`（重叠 5 秒防止并发提交漏行，应用是幂等的）。
   - 墓碑 → 删本地同 id 记录，移出 `known`。
   - 新行 / 变更行 → 写入本地（远端优先），`known[id] = 远端内容哈希`。
   - 本地音频/截图路径不被远端覆盖。
2. **收敛**：拉完跑已有的 `mergeDuplicateWords`（同词同语言保留 createdAt 最早的一条，语境并入）和新增的分类去重（同父同名保留 uuid 最小的）。两台用同样的确定性规则，结果一致。
3. **推**：扫描本地全部记录，算内容哈希：
   - 不在 `known` 或哈希变了 → upsert（`Prefer: resolution=merge-duplicates`）。
   - 在 `known` 但本地已不存在 → 推墓碑（`deleted_at = now()`）。
   - 成功后更新 `known`，游标推进到响应里最大的 `updated_at`。

**冲突规则**：记录级「远端优先」——同一条记录两台都改过、且本机还没推，拉取时远端覆盖本地。两台都是改动后几秒内就推，这种冲突只在离线编辑同一条时发生，代价是丢掉较晚同步那台的那次编辑。

**触发时机**：登录后立即一次；`ModelContext.didSave` 后防抖 3 秒；app 回到前台；Supabase Realtime 收到四张表任一变更后 1 秒（`CloudRealtime`，Phoenix WebSocket，RLS 只推本账号的行，断线指数退避重连并先补拉）；每 60 秒兜底。

**首次登录**：`known` 为空 → 先拉云端全部，再按上面规则合并，最后把本地所有记录推上去。两台已有的同词会在第 2 步合并。

**登出**：删除会话和该账号的 `sync-state` 文件，本地数据保留（登录别的账号会把这些数据推到那个账号，登出确认框里说明）。

## 4. 与 Anki 的交互

- `anki_note_id`、`sync_status` 随单词同步。A 机推过 Anki 的词到 B 机后是 `synced` 状态，B 机不会再做一张卡。两台 Anki 通过 AnkiWeb 共享同一套 note id。
- **反向清理的保护**：`pruneDeletedNotes` 会把「Anki 里找不到卡」的词当作用户删卡而删本地。B 机的 Anki 可能还没和 AnkiWeb 同步到这张卡，直接删会连带推墓碑、两台都丢词。所以从云端拉来的 `anki_note_id` 先进 `unconfirmedAnki`，本机 Anki 查到这张卡后才移出；清理只针对已确认的卡。
- 残留风险：词在两台都处于 `not_synced` 且两台 Anki 都开着时，可能各做一张卡。实际中保存单词后会立刻推 Anki，窗口只有几秒。

## 5. 界面

设置里新增「账号」页：未登录显示「用 Google 登录」；登录后显示邮箱、上次同步时间和结果、「立即同步」「退出登录」。主窗口不改。

## 5.1 只给会员（2026-10-29）

多台 Mac 同步是会员功能，卡在 Supabase 里，改 app 绕不过（会员后台规格 docs/multi-product.md §4.9）：

- `supabase/getnewword-sync-access.sql`：表 `getnewword.sync_access`（谁的同步开到哪天）、函数 `sync_allowed()`、四张表各一条限制性 RLS、会员后台用 HMAC 签名调的 `set_sync_access()`。不是会员的账号读到 0 行、写回 42501，Realtime 也收不到。
- app：账号页只有会员能点「用 Google 登录」；登录后（或登录着成了会员）调会员后台 `POST /v1/getnewword/sync/link`，后台去 Supabase 打开这个账号。每轮同步前问一次 `POST /rest/v1/rpc/sync_allowed`（10 分钟内用上次的结果）：false 就不拉不推，页上写「多台 Mac 同步是会员功能，本机词库不受影响」；PostgREST 回 403 / 42501 时停同步、查一次会员状态。函数还不存在（SQL 没执行，回 404）时照旧同步。
- 会员到期后云端的词不删；再成会员从原来的游标接着同步。

## 6. 需要手动配置的地方（一次性）

1. Supabase SQL Editor 执行 `supabase/getnewword-schema.sql`（我用 service 连接串直接执行）。
2. Dashboard → Data API → Exposed schemas 加 `getnewword`。
3. Dashboard → Authentication → URL Configuration → Redirect URLs 加 `getnewword://auth-callback`。

## 7. 实施步骤与验证

1. 建表 + 配置（上面 3 项）→ 用 anon key 调 PostgREST 确认 schema 可见、未登录读不到数据。
2. `SupabaseAuth`：PKCE 登录、刷新、Keychain → 本机登录拿到 user id。
3. `CloudSyncService`：DTO 映射、拉/推/墓碑/游标 → 本机首次上传，数据库行数与本地一致。
4. 接入触发器、Anki 保护、设置页 → 两台登录同一账号，一台加词/删词，另一台 1 分钟内出现/消失。
