-- GetNewWord · 知识片段的「问题」（Anki 知识卡正面的那一问）
-- 幂等：在 SQL Editor 里执行即可，重复执行无副作用。
-- 没跑这份时 App 照常同步：拉取时没有这一列就当没有问题，推送时查到没有这一列就不带它；跑完后下次推送起自动带上。
-- 不用改 RLS：getnewword-sync-access.sql 的策略按行判断，不按列。

alter table getnewword.snippets add column if not exists question text;

-- 让 PostgREST 马上认出新列
notify pgrst, 'reload schema';
