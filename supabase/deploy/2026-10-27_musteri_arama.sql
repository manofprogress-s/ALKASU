-- Canlı: sipariş müşteri araması (0045, M-28, D-104). Müşteri verisi değişmez; türetilmiş arama sütunları eklenir.
begin;
-- ALKASU 0045 — Sipariş ekranında müşteri araması sunucuda (M-28 · D-104)
-- Sorun: sipariş formu tüm aktif müşterileri tek sorguyla tarayıcıya yüklüyordu; API en fazla 1.000 satır döndürdüğü için
-- 1.216 müşteriden ada göre 1.000'inciden sonrakiler (Ser…, Ş, T, U, V, Y, Z) hiç aranamıyordu. Ayrıca eşleşme yalnızca
-- bitişik metin içinde arıyordu (noktalama, kelime sırası, baş harfler eşleşmiyordu) ve sonuçlar sıralanmadan ilk 8 kesiliyordu.
-- Çözüm: arama sunucuda, sıralı ve sınırlı. Müşteri verisi değişmez.

-- Arama normu: Türkçe küçük harf, şapkasız, ı/İ → i; harf ve rakam dışı her şey tek boşluk
create or replace function app.search_norm(p text) returns text
language sql immutable as $$
  select trim(regexp_replace(app.tr_key(coalesce(p, '')), '[^a-z0-9]+', ' ', 'g'))
$$;

-- Kelimelerin baş harfleri: "turkiye jokey kulubu" → "tjk"
create or replace function app.initials(p_norm text) returns text
language sql immutable as $$
  select coalesce(string_agg(left(w, 1), '' order by i), '')
    from unnest(string_to_array(nullif(p_norm, ''), ' ')) with ordinality as t(w, i)
$$;

-- Türetilmiş arama alanları (müşteri verisi değişmez; ad değişince otomatik güncellenir)
alter table public.customers add column if not exists name_norm text generated always as (app.search_norm(name)) stored;
alter table public.customers add column if not exists name_initials text generated always as (app.initials(app.search_norm(name))) stored;

-- Sıra: 0 tam ad / kod · 1 ad sorguyla başlıyor · 2 bir kelime sorguyla başlıyor veya baş harfler · 3 içeriyor / telefon
create or replace function public.search_order_customers(p_business uuid, p_q text, p_limit integer default 10)
returns table(id uuid, code text, name text, address text, price_list text, default_assignee uuid, owner_dealer_id uuid,
              special_prices jsonb, match_rank integer, total bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare
  v_k  text := app.search_norm(p_q);
  v_kc text := replace(app.search_norm(p_q), ' ', '');
  v_w  text[] := string_to_array(nullif(app.search_norm(p_q), ''), ' ');
  v_d  text := regexp_replace(regexp_replace(coalesce(p_q, ''), '\D', '', 'g'), '^(90|0)', '');
begin
  perform app.require_role(p_business, 'yonetici', 'satis');   -- müşteri listesini gören roller (sevkiyat dahil)
  if v_k = '' then return; end if;
  return query
  with c as (
    select cu.id, cu.code, cu.name, cu.address, cu.price_list, cu.default_assignee, cu.owner_dealer_id, cu.phone,
           cu.name_norm as n, lower(cu.code) as nc, cu.name_initials as ini
      from public.customers cu
     where cu.business_id = p_business and cu.active),
  m as (
    select c.*,
           case when c.n = v_k or c.nc = v_k or replace(c.n, ' ', '') = v_kc then 0
                when c.n like v_k || '%' then 1
                when (' ' || c.n) like '% ' || v_k || '%' or (length(v_kc) >= 2 and c.ini like v_kc || '%') then 2
                else 3 end as r
      from c
     where (select bool_and((' ' || c.n || ' ' || c.nc) like '%' || x || '%') from unnest(v_w) x)          -- tüm kelimeler, her sırada
        or (length(v_kc) >= 2 and replace(c.n, ' ', '') like '%' || v_kc || '%')                           -- "y.k." / "y k" / "yk"
        or (length(v_kc) >= 2 and c.ini like v_kc || '%')                                                    -- baş harfler
        or (length(v_d) >= 4 and regexp_replace(coalesce(c.phone, ''), '\D', '', 'g') like '%' || v_d || '%'))
  select m.id, m.code, m.name, m.address, m.price_list, m.default_assignee, m.owner_dealer_id,
         coalesce((select jsonb_object_agg(cp.unit_id, cp.price) from public.customer_prices cp where cp.customer_id = m.id), '{}'::jsonb),
         m.r, count(*) over ()
    from m
   order by m.r, m.name, m.code
   limit least(greatest(coalesce(p_limit, 10), 1), 30);
end $$;

select app.apply_grants();

select 'SONUC: aktif=' || (select count(*) from public.customers where active) || ' | sercan=' || (select count(*) from public.customers c where c.active and c.name_norm like 'sercan murat%') || ' | tjk_ornek=' || coalesce((select string_agg(name, ', ') from (select name from public.customers where active and name_initials like 'tjk%' limit 3) z), '-') as sonuc;
commit;
