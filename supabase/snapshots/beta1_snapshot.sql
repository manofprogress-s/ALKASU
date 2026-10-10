-- BETA#1 veritabanı anlık görüntüsü (10.10.2026) — docs/RELEASES.md
-- public + audit şemalarındaki tüm tabloların ve kullanıcı/dosya kayıtlarının kopyası, aynı veritabanında
-- dışarıya açık OLMAYAN "snap_beta1" şemasına alınır. Yalnızca veritabanı sahibi okuyabilir.
-- Tekrar çalıştırılırsa hata verir (var olan anlık görüntünün üzerine yazılmaz).
begin;
create schema snap_beta1;
revoke all on schema snap_beta1 from public, anon, authenticated;
do $$
declare t record;
begin
  for t in select schemaname, tablename from pg_tables where schemaname in ('public', 'audit') order by 1, 2 loop
    execute format('create table snap_beta1.%I as table %I.%I', t.schemaname || '__' || t.tablename, t.schemaname, t.tablename);
  end loop;
  execute 'create table snap_beta1.auth__users as table auth.users';
  if to_regclass('storage.objects') is not null then
    execute 'create table snap_beta1.storage__objects as table storage.objects';
  end if;
end $$;
create table snap_beta1._meta as
  select now() as taken_at, 'BETA#1'::text as label, 'beta-1'::text as git_tag,
         (select max(version) from supabase_migrations.schema_migrations) as db_version;
revoke all on all tables in schema snap_beta1 from public, anon, authenticated;
commit;
select 'SONUC: tablo=' || (select count(*) from pg_tables where schemaname = 'snap_beta1')
    || ' musteri=' || (select count(*) from snap_beta1.public__customers)
    || ' urun=' || (select count(*) from snap_beta1.public__products)
    || ' surum=' || (select db_version from snap_beta1._meta) as sonuc;
