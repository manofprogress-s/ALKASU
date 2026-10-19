-- 19.10.2026: eski borçların cariye açılışı + açılış düzeltme (0030)
begin;
-- ALKASU 0030 — Eski sistem borçlarının cariye açılış bakiyesi olarak işlenmesi ve yöneticinin açılışı düzeltmesi/sıfırlaması
-- Kural: BUSINESS_RULES §27 (M-22) · Karar: D-088
-- Cari kayıtları değiştirilemez: düzeltme ve sıfırlama, aradaki farkı yeni bir "açılış" satırı olarak yazar (ekstrede görünür).

-- Toplu: legacy_debt'i olup henüz açılışı olmayan kartlara açılış yazar (tekrar çalıştırılırsa yeni kayıt açmaz)
create or replace function app.post_legacy_openings(p_business uuid, p_actor uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int; v_total numeric; v_check jsonb;
begin
  with ins as (
    insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, note, created_by)
    select c.business_id, c.id, 'acilis', c.legacy_debt, 'abone_borc', 'Eski sistem borcu (abone listesi)', p_actor
      from public.customers c
     where c.business_id = p_business and coalesce(c.legacy_debt, 0) <> 0
       and not exists (select 1 from public.customer_ledger l where l.customer_id = c.id and l.type = 'acilis')
    returning customer_id, amount
  )
  select count(*), coalesce(sum(amount), 0) into v_n, v_total from ins;
  -- ALKASU'da da satış/tahsilatı olan kartlar: aynı alımın iki kez sayılmadığını kontrol etmek için listelenir
  select coalesce(jsonb_agg(jsonb_build_object('code', c.code, 'name', c.name, 'legacy_debt', c.legacy_debt) order by c.name), '[]')
    into v_check
    from public.customers c
   where c.business_id = p_business and coalesce(c.legacy_debt, 0) <> 0
     and exists (select 1 from public.customer_ledger l where l.customer_id = c.id and l.type <> 'acilis');
  perform app.audit(p_business, 'eski_borc_acilis', 'customer_ledger', null, null,
                    jsonb_build_object('count', v_n, 'total', v_total, 'actor', p_actor));
  return jsonb_build_object('count', v_n, 'total', v_total, 'check', v_check);
end $$;

-- Yönetici: kartın açılış bakiyesini istenen tutara getirir (0 = sıfırla). Fark yeni açılış satırı olarak yazılır.
create or replace function public.set_opening_balance(p_business uuid, p_customer uuid, p_amount numeric, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_cur numeric; v_diff numeric;
begin
  perform app.require_role(p_business, 'yonetici');
  if not exists (select 1 from public.customers where id = p_customer and business_id = p_business) then
    raise exception 'Müşteri bulunamadı' using errcode = 'P0002';
  end if;
  if p_amount is null or abs(p_amount) > 100000000 then raise exception 'Geçersiz tutar' using errcode = '22023'; end if;
  select coalesce(sum(amount), 0) into v_cur from public.customer_ledger where customer_id = p_customer and type = 'acilis';
  v_diff := round(p_amount, 2) - v_cur;
  if v_diff <> 0 then
    insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, note, created_by)
    values (p_business, p_customer, 'acilis', v_diff, 'acilis_duzeltme',
            coalesce(nullif(trim(coalesce(p_note, '')), ''), case when p_amount = 0 then 'Açılış bakiyesi sıfırlandı' else 'Açılış bakiyesi düzeltildi' end),
            auth.uid());
    perform app.audit(p_business, 'acilis_duzeltme', 'customers', p_customer::text,
                      jsonb_build_object('acilis', v_cur), jsonb_build_object('acilis', round(p_amount, 2), 'not', p_note));
  end if;
  return jsonb_build_object('previous', v_cur, 'current', round(p_amount, 2));
end $$;

-- Kartın şu anki açılış toplamı (yönetici ekranı için)
create or replace function public.opening_balance(p_customer uuid) returns numeric
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_b uuid;
begin
  select business_id into v_b from public.customers where id = p_customer;
  if v_b is null then return null; end if;
  perform app.require_role(v_b, 'yonetici');
  return (select coalesce(sum(amount), 0) from public.customer_ledger where customer_id = p_customer and type = 'acilis');
end $$;

select app.apply_grants();
create temp table _r on commit drop as select app.post_legacy_openings((select id from public.businesses), null) as r;
select 'SONUC: adet=' || (r->>'count') || ' toplam=' || (r->>'total') || ' kontrol=' || jsonb_array_length(r->'check') || ' ' || coalesce((select string_agg((x->>'name') || ':' || (x->>'legacy_debt'), '; ') from jsonb_array_elements(r->'check') x), '') as sonuc from _r;
commit;
