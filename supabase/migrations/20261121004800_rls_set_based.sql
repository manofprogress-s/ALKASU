-- ALKASU 0048 — Yetki kontrolü satır başına değil sorgu başına (D-108)
-- Ölçüm (12.000 müşteri, 30.000 satış): RLS politikaları app.has_role(business_id, …) / app.my_customer(business_id)
-- fonksiyonlarını HER SATIR için çağırıyordu (~60 µs/satır). Müşteri sayımı 760 ms, 100 kartın bakiyesi 3.650 ms.
-- Çözüm: kullanıcının yetkili olduğu işletmeler ve bağlı müşteri kartları bir kez hesaplanır, satırlar bu kümeyle
-- karşılaştırılır (Postgres alt sorguyu bir kez çalıştırır). Kurallar aynıdır; yalnızca değerlendirme biçimi değişir.
--   app.has_role(X, VARIADIC ARRAY[r])  →  (X IN (SELECT unnest(app.role_businesses(ARRAY[r]))))
--   app.is_admin(X)                     →  (X IN (SELECT unnest(app.role_businesses(ARRAY['yonetici']))))
--   … = app.my_customer(X)              →  … IN (SELECT unnest(app.my_customer_ids()))
-- my_customer_ids tüm işletmelerdeki kartları döndürür; müşteri kimliği tek işletmeye ait olduğundan sonuç aynıdır.
-- Yeni politikalar bu biçimde yazılmalıdır (D-108).

-- Kullanıcının verilen rollerden birine (role_covers: sevkiyat ⊇ satış, depo) sahip olduğu işletmeler
create or replace function app.role_businesses(p_roles public.member_role[]) returns uuid[]
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(array_agg(m.business_id), '{}')
    from public.memberships m
   where m.user_id = auth.uid() and m.active and app.role_covers(m.role, p_roles)
$$;

-- Kullanıcının bayi/müşteri olarak bağlı olduğu müşteri kartları
create or replace function app.my_customer_ids() returns uuid[]
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(array_agg(m.customer_id), '{}')
    from public.memberships m
   where m.user_id = auth.uid() and m.active and m.role in ('bayi', 'musteri') and m.customer_id is not null
$$;

create or replace function app.apply_grants()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
declare f text;
begin
  execute 'revoke all on all tables in schema public from anon, authenticated';
  execute 'grant select on all tables in schema public to authenticated';
  execute 'revoke all on all sequences in schema public from anon, authenticated';
  execute 'revoke execute on all functions in schema public from public, anon';
  execute 'grant execute on all functions in schema public to authenticated, service_role';
  execute 'revoke all on all tables in schema audit from anon, authenticated';
  execute 'grant usage on schema audit to authenticated';
  execute 'grant select on audit.log to authenticated';
  execute 'revoke execute on all functions in schema app from public, anon, authenticated';
  foreach f in array array['app.uid()', 'app.role_in(uuid)', 'app.is_member(uuid)',
                           'app.has_role(uuid, public.member_role[])', 'app.is_admin(uuid)',
                           'app.local_date(timestamptz)', 'app.can_see_sale(uuid)', 'app.my_customer(uuid)',
                           'app.role_covers(public.member_role, public.member_role[])',
                           'app.is_staff(uuid)', 'app.my_price_list(uuid)', 'app.customer_owner(uuid)',
                           'app.role_businesses(public.member_role[])', 'app.my_customer_ids()'] loop
    if to_regprocedure(f) is not null then
      execute format('grant execute on function %s to authenticated', f);
    end if;
  end loop;
  if to_regprocedure('public.public_catalog()') is not null then
    execute 'grant execute on function public.public_catalog() to anon';
  end if;
end $function$;

-- Tüm politikaları yeniden yaz (USING ve WITH CHECK)
do $$
declare r record; v_q text; v_c text; v_n int := 0;
begin
  for r in select schemaname, tablename, policyname, qual, with_check from pg_policies
            where schemaname in ('public', 'audit')
              and (coalesce(qual, '') || coalesce(with_check, '')) ~ 'app\.(has_role|is_admin|my_customer)\(' loop
    v_q := r.qual; v_c := r.with_check;
    v_q := regexp_replace(v_q, 'app\.has_role\(([a-z_.]+), VARIADIC (ARRAY\[[^]]*\])\)', '(\1 IN ( SELECT unnest(app.role_businesses(\2))))', 'g');
    v_q := regexp_replace(v_q, 'app\.is_admin\(([a-z_.]+)\)', '(\1 IN ( SELECT unnest(app.role_businesses(ARRAY[''yonetici''::member_role]))))', 'g');
    v_q := regexp_replace(v_q, ' = app\.my_customer\(([a-z_.]+)\)', ' IN ( SELECT unnest(app.my_customer_ids()))', 'g');
    v_c := regexp_replace(v_c, 'app\.has_role\(([a-z_.]+), VARIADIC (ARRAY\[[^]]*\])\)', '(\1 IN ( SELECT unnest(app.role_businesses(\2))))', 'g');
    v_c := regexp_replace(v_c, 'app\.is_admin\(([a-z_.]+)\)', '(\1 IN ( SELECT unnest(app.role_businesses(ARRAY[''yonetici''::member_role]))))', 'g');
    v_c := regexp_replace(v_c, ' = app\.my_customer\(([a-z_.]+)\)', ' IN ( SELECT unnest(app.my_customer_ids()))', 'g');
    if (coalesce(v_q, '') || coalesce(v_c, '')) ~ 'app\.(has_role|is_admin|my_customer)\(' then
      raise exception 'Politika dönüştürülemedi: %.% → %', r.tablename, r.policyname, coalesce(v_q, v_c);
    end if;
    if v_q is not null then execute format('alter policy %I on %I.%I using (%s)', r.policyname, r.schemaname, r.tablename, v_q); end if;
    if v_c is not null then execute format('alter policy %I on %I.%I with check (%s)', r.policyname, r.schemaname, r.tablename, v_c); end if;
    v_n := v_n + 1;
  end loop;
  raise notice 'RLS: % politika yeniden yazıldı', v_n;
end $$;

-- Müşterinin kap bakiyesi (müşteri kartı, satış ekranı araması): müşteri kimliğiyle doğrudan indeks
create index if not exists container_ledger_cust on public.container_ledger(customer_id, product_id);

-- Faturalar sekme sayıları: tüm faturaları okumadan (1.000 satır sınırı yok)
create or replace function public.invoice_status_counts(p_business uuid)
returns table(status text, n bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.require_role(p_business, 'yonetici');
  return query select i.status::text, count(*) from public.invoices i where i.business_id = p_business group by i.status;
end $$;

select app.apply_grants();
