-- ANLIK GÖRÜNTÜDEN GERİ DÖNÜŞ — docs/RELEASES.md "Geri dönüş" bölümünü okumadan çalıştırmayın.
-- public şemasındaki TÜM veriyi seçilen anlık görüntüdeki haline döndürür (anlık görüntüden sonra girilen
-- satış, sipariş, müşteri vb. SİLİNİR). audit (işlem geçmişi) ve auth (kullanıcılar) olduğu gibi kalır.
-- Önce yeni bir anlık görüntü alın (snapshot betiğini yeni şema adıyla), sonra bunu çalıştırın.
-- Şema daha yeni olabilir: yalnızca iki tarafta da bulunan sütunlar taşınır; sonradan eklenen tablolar boşaltılır.
begin;
set local session_replication_role = replica;   -- tetikleyiciler (değiştirilemez kayıt, işlem geçmişi) devre dışı
do $$
declare
  v_snap constant text := 'snap_beta1';          -- ← geri dönülecek anlık görüntü
  t record; v_cols text; v_n bigint; v_total bigint := 0;
begin
  if to_regnamespace(v_snap) is null then raise exception 'Anlık görüntü bulunamadı: %', v_snap; end if;
  execute (select 'truncate table ' || string_agg(format('public.%I', tablename), ', ') || ' cascade'
             from pg_tables where schemaname = 'public');
  for t in select tablename from pg_tables where schemaname = 'public' order by tablename loop
    if to_regclass(format('%I.%I', v_snap, 'public__' || t.tablename)) is null then continue; end if;
    select string_agg(format('%I', a.attname), ', ' order by a.attnum) into v_cols
      from pg_attribute a
     where a.attrelid = format('public.%I', t.tablename)::regclass and a.attnum > 0 and not a.attisdropped and a.attgenerated = ''
       and exists (select 1 from pg_attribute s where s.attrelid = format('%I.%I', v_snap, 'public__' || t.tablename)::regclass
                    and s.attname = a.attname and s.attnum > 0 and not s.attisdropped);
    execute format('insert into public.%I (%s) overriding system value select %s from %I.%I',
                   t.tablename, v_cols, v_cols, v_snap, 'public__' || t.tablename);
    get diagnostics v_n = row_count;
    v_total := v_total + v_n;
  end loop;
  -- Sayaçlar (sequence) en büyük değerin ilerisinde kalsın
  for t in select s.relname as seq, tc.relname as tbl, a.attname as col
             from pg_class s join pg_depend d on d.objid = s.oid and d.deptype in ('a', 'i')
             join pg_class tc on tc.oid = d.refobjid join pg_attribute a on a.attrelid = tc.oid and a.attnum = d.refobjsubid
             join pg_namespace n on n.oid = tc.relnamespace
            where s.relkind = 'S' and n.nspname = 'public' loop
    execute format('select setval(%L, greatest(coalesce((select max(%I) from public.%I), 0), 1))', 'public.' || t.seq, t.col, t.tbl);
  end loop;
  raise notice 'Geri yüklenen satır: %', v_total;
end $$;
commit;
select 'SONUC: musteri=' || (select count(*) from public.customers) || ' urun=' || (select count(*) from public.products)
    || ' satis=' || (select count(*) from public.sales) || ' siparis=' || (select count(*) from public.orders) as sonuc;
