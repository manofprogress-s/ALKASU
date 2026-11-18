-- ALKASU 0047 — Bayi araması: bayi kullanıcısının kullanıcı adı da aranır (M-29 · D-105)
-- Canlıda bayi kullanıcılarının görünen adı yalnızca soyad ("Yıldız", "SAĞLAM"), kullanıcı adı ad ("huseyin", "ibrahim").
-- Bu yüzden "hüseyin yıldız" Yıldız Ticaret'i bulmuyor, İBRAHİM SAĞLAM ev kartında bayi uyarısı çıkmıyordu.

create or replace function public.search_customers(p_business uuid, p_q text, p_limit integer default 10)
returns table(id uuid, code text, name text, address text, phone text, channel text, price_list text, default_assignee uuid,
              owner_dealer_id uuid, credit_limit numeric, unlimited_credit boolean, balance numeric,
              special_prices jsonb, deposits jsonb, containers jsonb, dealer_hint jsonb, match_rank integer, total bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
declare
  v_k  text := app.search_norm(p_q);
  v_kc text := replace(app.search_norm(p_q), ' ', '');
  v_w  text[] := string_to_array(nullif(app.search_norm(p_q), ''), ' ');
  v_d  text := regexp_replace(regexp_replace(coalesce(p_q, ''), '\D', '', 'g'), '^(90|0)', '');
begin
  perform app.require_role(p_business, 'yonetici', 'satis');   -- satış ve sipariş yapan personel (sevkiyat dahil)
  if v_k = '' then return; end if;
  return query
  with dl as (   -- bayi kartları: ad + resmî unvan + bayi kullanıcılarının adı ve kullanıcı adı
    select cu.id, cu.code, cu.name,
           right(regexp_replace(coalesce(cu.phone, ''), '\D', '', 'g'), 10) as ph,
           app.search_norm(concat_ws(' ', cu.name, cu.legal_title,
             (select string_agg(concat_ws(' ', mb.display_name, mb.username), ' ') from public.memberships mb
               where mb.business_id = p_business and mb.customer_id = cu.id and mb.active))) as hay
      from public.customers cu
     where cu.business_id = p_business and cu.active and cu.channel = 'bayi'),
  c as (
    select cu.id, cu.code, cu.name, cu.address, cu.phone, cu.channel::text as channel, cu.price_list, cu.default_assignee,
           cu.owner_dealer_id, cu.credit_limit, cu.unlimited_credit,
           cu.name_norm as n, lower(cu.code) as nc, cu.name_initials as ini,
           coalesce((select dl.hay from dl where dl.id = cu.id), '') as extra
      from public.customers cu
     where cu.business_id = p_business and cu.active),
  m as (
    select c.*,
           case when c.n = v_k or c.nc = v_k or replace(c.n, ' ', '') = v_kc then 0
                when c.n like v_k || '%' then 1
                when (' ' || c.n) like '% ' || v_k || '%' or (length(v_kc) >= 2 and c.ini like v_kc || '%') then 2
                else 3 end as r
      from c
     where (select bool_and((' ' || c.n || ' ' || c.nc || ' ' || c.extra) like '%' || x || '%') from unnest(v_w) x)
        or (length(v_kc) >= 2 and replace(c.n, ' ', '') like '%' || v_kc || '%')
        or (length(v_kc) >= 2 and c.ini like v_kc || '%')
        or (length(v_d) >= 4 and regexp_replace(coalesce(c.phone, ''), '\D', '', 'g') like '%' || v_d || '%')),
  t as (
    select m.*, count(*) over () as cnt from m
     order by (m.channel = 'bayi') desc, m.r, m.name, m.code
     limit least(greatest(coalesce(p_limit, 10), 1), 30))
  select t.id, t.code, t.name, t.address, t.phone, t.channel, t.price_list, t.default_assignee, t.owner_dealer_id,
         t.credit_limit, t.unlimited_credit,
         coalesce((select sum(l.amount) from public.customer_ledger l where l.customer_id = t.id), 0)::numeric(14,2),
         coalesce((select jsonb_object_agg(cp.unit_id, cp.price) from public.customer_prices cp where cp.customer_id = t.id), '{}'::jsonb),
         coalesce((select jsonb_object_agg(cd.product_id, cd.amount) from public.customer_deposits cd where cd.customer_id = t.id), '{}'::jsonb),
         coalesce((select jsonb_agg(jsonb_build_object('product_id', x.product_id, 'qty', x.qty, 'amount', x.amount))
                     from (select cl.product_id, sum(cl.qty)::int as qty, sum(cl.amount)::numeric(14,2) as amount
                             from public.container_ledger cl where cl.customer_id = t.id
                            group by cl.product_id having sum(cl.qty) <> 0 or sum(cl.amount) <> 0) x), '[]'::jsonb),
         case when t.channel <> 'bayi' then (
           select jsonb_build_object('id', dl.id, 'code', dl.code, 'name', dl.name) from dl
            where (length(dl.ph) = 10 and dl.ph = right(regexp_replace(coalesce(t.phone, ''), '\D', '', 'g'), 10))
               or (exists (select 1 from unnest(string_to_array(t.n, ' ')) w where length(w) >= 3)
                   and not exists (select 1 from unnest(string_to_array(t.n, ' ')) w
                                    where length(w) >= 3 and (' ' || dl.hay || ' ') not like '% ' || w || ' %'))
            order by dl.name limit 1) end,
         t.r, t.cnt
    from t
   order by (t.channel = 'bayi') desc, t.r, t.name, t.code;
end $$;

select app.apply_grants();
