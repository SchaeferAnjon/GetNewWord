-- GetNewWord · 账号 + 词库多设备同步（设计见 docs/sync-design.md）
-- 共用 Supabase 项目 blsbkqreuhgvksphsvaw；表放在独立的 schema getnewword 里。
-- 幂等：整份在 SQL Editor 执行即可，重复执行无副作用。
-- 执行后还要在 Dashboard → Project Settings → Data API → Exposed schemas 加上 getnewword。
--
-- 约定：
-- - 主键 = 客户端 SwiftData 模型的 UUID，客户端生成；表之间不设外键（同步顺序无关，引用悬空时客户端置空）。
-- - 删除一律软删（deleted_at），客户端据此删本地。
-- - updated_at 由触发器用服务端时钟写，客户端只拿它当增量拉取游标，不参与冲突判断。

create schema if not exists getnewword;
grant usage on schema getnewword to authenticated, service_role;

create or replace function getnewword.touch_updated_at() returns trigger
language plpgsql as $$
begin
  new.updated_at := clock_timestamp();
  return new;
end $$;

create table if not exists getnewword.categories (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  icon text not null default 'folder',
  color_hex text not null default '#808080',
  parent_id uuid,
  deleted_at timestamptz,
  updated_at timestamptz not null default clock_timestamp()
);

create table if not exists getnewword.words (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  word text not null,
  phonetic text,
  language text not null,
  meaning text not null,
  context_meaning text,
  context_sentence text not null default '',
  context_translation text not null default '',
  translation_keyword text,
  lookup_count int not null default 1,
  analysis_note text not null default '',
  grammar text,
  collocations_text text,
  examples_text text,
  mnemonic text,
  etymology text,
  difficulty text not null,
  tags text[] not null default '{}',
  created_at timestamptz not null,
  review_count int not null default 0,
  anki_note_id bigint,
  sync_status text not null,
  is_archived boolean not null default false,
  category_id uuid,
  deleted_at timestamptz,
  updated_at timestamptz not null default clock_timestamp()
);

create table if not exists getnewword.contexts (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  word_id uuid,
  sentence text not null,
  translation text not null default '',
  note text not null default '',
  created_at timestamptz not null,
  deleted_at timestamptz,
  updated_at timestamptz not null default clock_timestamp()
);

create table if not exists getnewword.snippets (
  id uuid primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null,
  content text not null,
  source_context text not null default '',
  tags text[] not null default '{}',
  domain text not null default '',
  created_at timestamptz not null,
  is_archived boolean not null default false,
  sync_status text not null,
  anki_note_id bigint,
  category_id uuid,
  related_word_ids uuid[] not null default '{}',
  deleted_at timestamptz,
  updated_at timestamptz not null default clock_timestamp()
);

do $$
declare t text;
begin
  foreach t in array array['categories', 'words', 'contexts', 'snippets'] loop
    execute format('create index if not exists %1$s_user_updated_idx on getnewword.%1$s (user_id, updated_at)', t);
    execute format('drop trigger if exists %1$s_touch on getnewword.%1$s', t);
    execute format('create trigger %1$s_touch before insert or update on getnewword.%1$s for each row execute function getnewword.touch_updated_at()', t);
    execute format('alter table getnewword.%1$s enable row level security', t);
    execute format('drop policy if exists "%1$s_select_own" on getnewword.%1$s', t);
    execute format('create policy "%1$s_select_own" on getnewword.%1$s for select using (auth.uid() = user_id)', t);
    execute format('drop policy if exists "%1$s_insert_own" on getnewword.%1$s', t);
    execute format('create policy "%1$s_insert_own" on getnewword.%1$s for insert with check (auth.uid() = user_id)', t);
    execute format('drop policy if exists "%1$s_update_own" on getnewword.%1$s', t);
    execute format('create policy "%1$s_update_own" on getnewword.%1$s for update using (auth.uid() = user_id) with check (auth.uid() = user_id)', t);
    execute format('drop policy if exists "%1$s_delete_own" on getnewword.%1$s', t);
    execute format('create policy "%1$s_delete_own" on getnewword.%1$s for delete using (auth.uid() = user_id)', t);
    execute format('grant select, insert, update, delete on getnewword.%1$s to authenticated', t);
    execute format('grant all on getnewword.%1$s to service_role', t);
    -- Realtime：另一台设备改动时客户端秒级收到通知（RLS 同样生效）
    if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'getnewword' and tablename = t) then
      execute format('alter publication supabase_realtime add table getnewword.%1$s', t);
    end if;
  end loop;
end $$;
