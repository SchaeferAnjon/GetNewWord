-- GetNewWord · 多台 Mac 同步只给会员（会员后台规格：meetcaption-server 的 docs/multi-product.md §4.9）
-- 会员后台用 HMAC 签名调 getnewword.set_sync_access，写「某个用户的同步开到哪天」；四张同步表加限制性 RLS，
-- 只放行 until 还没到的用户。改 app 绕不过：读回空、写回 42501，Realtime 也按 RLS 过滤。
-- 后台手里的密钥只能做这一件事，不碰共用项目的 JWT 密钥和 service_role。
--
-- 怎么执行（由维护者在 Supabase SQL Editor 里执行，先在测试项目上跑通，再在正式项目 blsbkqreuhgvksphsvaw）：
-- 1. 先执行过 getnewword-schema.sql（四张表在 getnewword schema 里）。
-- 2. 在 Vault 里放签名密钥，和会员后台 dispatch env 的 GETNEWWORD_SYNC_HMAC 是同一个值（值不要写进这个文件）：
--      select vault.create_secret('<GETNEWWORD_SYNC_HMAC 的值>', 'getnewword_sync_hmac', 'GetNewWord 同步资格签名');
-- 3. 执行这整份。幂等：重复执行无副作用；限制性策略只加不改现有的 auth.uid() = user_id 策略。
-- 4. 给已经在用同步的账号（维护者自己）开到 2099 年：见文件末尾，把邮箱换成登录用的。
--    手动开的写在 grant_until，会员后台的推送只改 until，以后这个账号绑了会员授权也盖不掉它。
-- 5. 跑文件末尾的自检，几项都应该是 true。
--
-- 回滚（同步不再限会员）：
--   do $$ declare t text; begin foreach t in array array['categories','words','contexts','snippets'] loop
--     execute format('drop policy if exists "%1$s_members_only" on getnewword.%1$s', t); end loop; end $$;

create extension if not exists pgcrypto with schema extensions;

-- 谁的同步开到什么时候。只有下面两个 security definer 函数读写它，anon / authenticated 直接碰不到
create table if not exists getnewword.sync_access (
  user_id uuid primary key references auth.users(id) on delete cascade,
  -- 会员后台推来的：这个用户绑的会员授权里最晚的到期，0 点（1970）= 关
  until timestamptz not null,
  -- 维护者手动开的（自己的账号开到 2099）：会员后台不碰它
  grant_until timestamptz,
  -- 上次接受的签名时间戳（秒）：重放旧签名不能把新的设置改回去
  last_ts bigint not null default 0,
  updated_at timestamptz not null default now()
);
alter table getnewword.sync_access add column if not exists grant_until timestamptz;
alter table getnewword.sync_access enable row level security;
revoke all on getnewword.sync_access from anon, authenticated;

-- 当前登录的用户能不能同步。四张表的限制性策略用它；app 也直接调它（POST /rest/v1/rpc/sync_allowed）决定要不要同步
create or replace function getnewword.sync_allowed() returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from getnewword.sync_access a where a.user_id = auth.uid() and greatest(a.until, a.grant_until) > now())
$$;
revoke all on function getnewword.sync_allowed() from public;
grant execute on function getnewword.sync_allowed() to authenticated;

-- 会员后台调：p_sig = hex(hmac_sha256(密钥, "<p_user>|<p_until>|<p_ts>"))；p_until 是秒，0 = 关；
-- p_ts 和数据库时间相差不超过 300 秒，且比这个用户上次的大
create or replace function getnewword.set_sync_access(p_user uuid, p_until bigint, p_ts bigint, p_sig text) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_secret text;
  v_last bigint;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets where name = 'getnewword_sync_hmac' limit 1;
  if v_secret is null or v_secret = '' then
    raise exception 'getnewword_sync_hmac is not in Vault' using errcode = '28000';
  end if;
  if p_user is null or p_until is null or p_ts is null or p_sig is null
     or lower(p_sig) <> encode(extensions.hmac(p_user::text || '|' || p_until::text || '|' || p_ts::text, v_secret, 'sha256'), 'hex') then
    raise exception 'bad signature' using errcode = '28000';
  end if;
  if abs(extract(epoch from now()) - p_ts) > 300 then
    raise exception 'timestamp too far from now' using errcode = '28000';
  end if;
  select a.last_ts into v_last from getnewword.sync_access a where a.user_id = p_user for update;
  if v_last is not null and p_ts <= v_last then
    raise exception 'timestamp not newer than the last one' using errcode = '28000';
  end if;
  insert into getnewword.sync_access (user_id, until, last_ts, updated_at)
  values (p_user, to_timestamp(p_until), p_ts, now())
  on conflict (user_id) do update set until = excluded.until, last_ts = excluded.last_ts, updated_at = now();
end $$;
revoke all on function getnewword.set_sync_access(uuid, bigint, bigint, text) from public;
grant execute on function getnewword.set_sync_access(uuid, bigint, bigint, text) to anon;
-- 会员后台用 anon key 调它：anon 要能进 getnewword 这个 schema（这个 schema 里没有表授权给 anon，进来也只能调上面这个函数）
grant usage on schema getnewword to anon;

-- 四张同步表：限制性策略和现有的 auth.uid() = user_id 是「且」的关系；写成 (select …) 让每条语句只算一次
do $$
declare t text;
begin
  foreach t in array array['categories', 'words', 'contexts', 'snippets'] loop
    execute format('drop policy if exists "%1$s_members_only" on getnewword.%1$s', t);
    execute format('create policy "%1$s_members_only" on getnewword.%1$s as restrictive for all to authenticated '
                   'using ((select getnewword.sync_allowed())) with check ((select getnewword.sync_allowed()))', t);
  end loop;
end $$;

-- 已经在用同步的账号开到 2099 年（把邮箱换成登录用的再执行这一段）。写在 grant_until：
-- 会员后台的推送只改 until，这个账号以后在 app 里绑了会员授权、会员到期，2099 都还在。
-- insert into getnewword.sync_access (user_id, until, grant_until)
-- select id, to_timestamp(0), '2099-01-01 00:00:00+00' from auth.users where email = '<登录用的邮箱>'
-- on conflict (user_id) do update set grant_until = excluded.grant_until;

-- 自检：每一项都应该是 true
-- select
--   encode(extensions.hmac('00000000-0000-4000-8000-000000000001|1798761600|1793232000', 'test-secret', 'sha256'), 'hex')
--     = '3b825c53dd0f83142f9d48ddb01eb99ae435e5f1f03b2e5bf90dc08adcf6c057' as vector_1,
--   encode(extensions.hmac('00000000-0000-4000-8000-000000000001|0|1793232060', 'test-secret', 'sha256'), 'hex')
--     = '3799b95a26af6cbbe49b3e986c315b5f0cd76834c40557fe200fde7c8583014f' as vector_2,
--   (select count(*) from pg_policies where schemaname = 'getnewword' and policyname like '%_members_only' and permissive = 'RESTRICTIVE') = 4 as policies,
--   exists (select 1 from vault.decrypted_secrets where name = 'getnewword_sync_hmac') as secret_in_vault,
--   not has_table_privilege('anon', 'getnewword.sync_access', 'select') as anon_cannot_read,
--   (select count(*) from getnewword.sync_access where grant_until > now()) >= 1 as owner_granted;
