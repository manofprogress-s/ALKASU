-- ALKASU 0039 — Giderler sekmesi + aylık/haftalık gelir-gider (kâr) raporu
-- Kural: BUSINESS_RULES K-11..K-14, GG-01..GG-03, F-29 · Karar: D-099 (kullanıcı isteği 22.10)
--  * Personel (sevkiyat/satış/depo) gider girebilir; maaş, kira ve vergi/SGK yalnızca yönetici (kısıtlı kategori).
--  * Personel yalnızca kendi girdiği giderleri görür; toplamları ve raporu yalnızca yönetici görür.
--  * Gelir = tamamlanan satışların ürün tutarı (depozito hariç) − iadeler; fatura kesilmiş/kesilmemiş ayrımı.
--  * Gider = mal kabul (onaylı, alış fiyatı × miktar) + işletme giderleri.
--  * Brüt kâr = gelir − mal alımı; net kâr = brüt kâr − işletme giderleri. Tutarlar KDV dahil.
--  * Logo bağlantısı kurulana kadar İşbaşı'nda elle kesilen fatura "kesildi" olarak işaretlenebilir.

-- ---------------------------------------------------------------- kategoriler
alter table public.expense_categories add column if not exists restricted boolean not null default false;  -- yalnızca yönetici
alter table public.expense_categories add column if not exists code text;                                  -- sistem kategorisi

update public.expense_categories set name = 'Personel maaşları', code = 'maas', restricted = true, sort = 1 where name = 'Personel';
update public.expense_categories set code = 'kira', restricted = true, sort = 2 where name = 'Kira';
update public.expense_categories set name = 'Araç masrafları', code = 'arac', sort = 3 where name = 'Araç bakım';
update public.expense_categories set code = 'yakit', sort = 4 where name = 'Yakıt';
update public.expense_categories set code = 'enerji', sort = 5 where name = 'Elektrik/Su/Doğalgaz';
update public.expense_categories set name = 'Sarf malzeme', code = 'sarf', sort = 6 where name = 'Kırtasiye/Sarf';
update public.expense_categories set code = 'yemek', sort = 8 where name = 'Yemek';
update public.expense_categories set code = 'vergi', restricted = true, sort = 9 where name = 'Vergi/SGK';
update public.expense_categories set code = 'diger', sort = 10 where name = 'Diğer';
insert into public.expense_categories(business_id, name, code, sort)
select b.id, 'Temizlik malzemesi', 'temizlik', 7 from public.businesses b
 where not exists (select 1 from public.expense_categories c where c.business_id = b.id and lower(c.name) = lower('Temizlik malzemesi'));

create or replace function app.tg_business_defaults() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.expense_categories(business_id, name, code, restricted, sort)
  select new.id, x.name, x.code, x.restricted, x.ord
    from (values ('Personel maaşları', 'maas', true, 1), ('Kira', 'kira', true, 2), ('Araç masrafları', 'arac', false, 3),
                 ('Yakıt', 'yakit', false, 4), ('Elektrik/Su/Doğalgaz', 'enerji', false, 5), ('Sarf malzeme', 'sarf', false, 6),
                 ('Temizlik malzemesi', 'temizlik', false, 7), ('Yemek', 'yemek', false, 8), ('Vergi/SGK', 'vergi', true, 9),
                 ('Diğer', 'diger', false, 10)) as x(name, code, restricted, ord);
  return new;
end $$;

-- Kategori ekleme/düzenleme: kısıtlı (yalnızca yönetici) işaretlenebilir
drop function if exists public.upsert_expense_category(uuid, text, uuid, boolean);
create or replace function public.upsert_expense_category(p_business uuid, p_name text, p_id uuid default null, p_active boolean default true,
                                                          p_restricted boolean default false)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  perform app.require_role(p_business, 'yonetici');
  if coalesce(trim(p_name), '') = '' then raise exception 'Kategori adı boş olamaz' using errcode = '22023'; end if;
  if exists (select 1 from public.expense_categories where business_id = p_business and lower(name) = lower(trim(p_name))
             and id is distinct from p_id) then
    raise exception 'Bu adla bir kategori zaten var' using errcode = '23505';
  end if;
  if p_id is null then
    insert into public.expense_categories(business_id, name, active, restricted, sort)
    values (p_business, trim(p_name), p_active, coalesce(p_restricted, false), 100) returning id into v_id;
  else
    update public.expense_categories set name = trim(p_name), active = p_active, restricted = coalesce(p_restricted, restricted)
     where id = p_id and business_id = p_business returning id into v_id;
  end if;
  return v_id;
end $$;

drop policy if exists expense_categories_select on public.expense_categories;
create policy expense_categories_select on public.expense_categories for select to authenticated
  using (app.is_admin(business_id) or (not restricted and app.has_role(business_id, 'satis', 'depo')));

-- ---------------------------------------------------------------- giderler
alter table public.expenses add column if not exists payee text check (length(payee) <= 120);   -- kime ödendi (personel adı, firma)
create index if not exists expenses_created_by on public.expenses(created_by, created_at desc);

drop policy if exists expenses_select on public.expenses;
create policy expenses_select on public.expenses for select to authenticated
  using (app.is_admin(business_id) or (created_by = auth.uid() and app.has_role(business_id, 'satis', 'depo')));

-- p = { id, category_id, expense_date?, amount, method: kasa|banka, description?, payee? }
create or replace function public.add_expense(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id   uuid := (p->>'id')::uuid;
  v_amt  numeric := round((p->>'amount')::numeric, 2);
  v_loc  uuid := app.default_location(p_business);
  v_date date := coalesce(nullif(p->>'expense_date', '')::date, app.local_date(now()));
  v_role public.member_role;
  v_cat  public.expense_categories;
  v_sess public.cash_sessions;
begin
  v_role := app.require_role(p_business, 'yonetici', 'satis', 'depo');
  if v_id is null then raise exception 'Kayıt kimliği eksik' using errcode = '22023'; end if;
  if exists (select 1 from public.expenses where id = v_id) then return v_id; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'Tutar sıfırdan büyük olmalıdır' using errcode = '22023'; end if;
  if v_amt > 10000000 then raise exception 'Tutar çok büyük; lütfen kontrol edin' using errcode = '22023'; end if;
  if coalesce(p->>'method', '') not in ('kasa', 'banka') then raise exception 'Ödeme şekli geçersiz' using errcode = '22023'; end if;
  select * into v_cat from public.expense_categories where id = (p->>'category_id')::uuid and business_id = p_business;
  if v_cat.id is null then raise exception 'Gider kategorisi bulunamadı' using errcode = 'P0002'; end if;
  if not v_cat.active then raise exception 'Bu gider kategorisi kullanımda değil' using errcode = '22023'; end if;
  if v_cat.restricted and v_role <> 'yonetici' then
    raise exception '"%" giderini yalnızca yönetici girebilir', v_cat.name using errcode = '42501';
  end if;
  if v_date > app.local_date(now()) then raise exception 'İleri tarihli gider girilemez' using errcode = '22023'; end if;
  if v_role <> 'yonetici' and v_date < app.local_date(now()) - 31 then
    raise exception 'Personel en fazla 1 ay öncesine gider girebilir; daha eskisi için yöneticiye başvurun' using errcode = '22023';
  end if;
  if p->>'method' = 'kasa' then v_sess := app.ensure_session(p_business, v_loc); end if;
  insert into public.expenses(id, business_id, location_id, category_id, expense_date, amount, method, description, payee, session_id, created_by)
  values (v_id, p_business, v_loc, v_cat.id, v_date, v_amt, p->>'method',
          nullif(trim(p->>'description'), ''), nullif(trim(p->>'payee'), ''), v_sess.id, auth.uid());
  if p->>'method' = 'kasa' then
    perform app.post_cash(p_business, v_sess.id, 'gider', -v_amt, 'expense', v_id,
                          coalesce(nullif(trim(p->>'description'), ''), v_cat.name));
  end if;
  return v_id;
end $$;

-- İptal: yönetici her zaman; personel yalnızca kendi girdiğini aynı gün
create or replace function public.cancel_expense(p_expense uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.expenses; v_sess public.cash_sessions; v_role public.member_role;
begin
  select * into e from public.expenses where id = p_expense for update;
  if e.id is null then raise exception 'Gider bulunamadı' using errcode = 'P0002'; end if;
  v_role := app.require_role(e.business_id, 'yonetici', 'satis', 'depo');
  if v_role <> 'yonetici' and (e.created_by is distinct from auth.uid() or app.local_date(e.created_at) <> app.local_date(now())) then
    raise exception 'Bu gideri yalnızca yönetici iptal edebilir (personel kendi girdiğini aynı gün iptal edebilir)' using errcode = '42501';
  end if;
  if e.status <> 'gecerli' then raise exception 'Gider zaten iptal edilmiş' using errcode = 'P0001'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'İptal nedeni zorunludur' using errcode = '22023'; end if;
  if e.method = 'kasa' then
    v_sess := app.ensure_session(e.business_id, e.location_id);
    perform app.post_cash(e.business_id, v_sess.id, 'duzeltme', e.amount, 'expense_cancel', e.id, 'Gider iptali');
  end if;
  update public.expenses set status = 'iptal', cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = trim(p_reason)
   where id = e.id;
end $$;

-- ---------------------------------------------------------------- fatura: İşbaşı'nda elle kesildi
create index if not exists invoices_logo_no on public.invoices(business_id, logo_invoice_no) where logo_invoice_no is not null;

create or replace function public.invoice_action(p_business uuid, p_invoice uuid, p_action text, p_note text default null) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare inv public.invoices; v jsonb; v_errors int;
begin
  perform app.require_role(p_business, 'yonetici');
  select * into inv from public.invoices where id = p_invoice and business_id = p_business for update;
  if inv.id is null then raise exception 'Fatura kaydı bulunamadı' using errcode = 'P0002'; end if;

  if p_action in ('yenile', 'hazirla') then
    if inv.status <> 'taslak' then raise exception 'Yalnızca taslak güncellenebilir / gönderime hazırlanabilir' using errcode = '22023'; end if;
    v := app.sale_invoice_data(inv.sale_id);
    select count(*) into v_errors from jsonb_array_elements(v->'issues') x where x->>'level' = 'error';
    if p_action = 'hazirla' and v_errors > 0 then
      raise exception 'Eksik bilgi var (% hata): önce düzeltin', v_errors using errcode = '22023';
    end if;
    update public.invoices set customer = v->'customer', lines = v->'lines', totals = v->'totals', issues = v->'issues',
           status = case when p_action = 'hazirla' then 'hazir' else status end,
           prepared_by = case when p_action = 'hazirla' then auth.uid() else prepared_by end,
           prepared_at = case when p_action = 'hazirla' then now() else prepared_at end
     where id = inv.id;
  elsif p_action = 'taslaga' then
    if inv.status <> 'hazir' then raise exception 'Yalnızca gönderime hazır kayıt taslağa alınabilir' using errcode = '22023'; end if;
    update public.invoices set status = 'taslak', prepared_by = null, prepared_at = null where id = inv.id;
  elsif p_action = 'iptal' then
    if inv.status not in ('taslak', 'hazir', 'hatali') then
      raise exception 'Gönderilmiş fatura buradan iptal edilemez; Logo İşbaşı üzerinden iptal/iade yapılır' using errcode = '22023';
    end if;
    if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'İptal nedeni yazın' using errcode = '22023'; end if;
    update public.invoices set status = 'iptal', cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = trim(p_note) where id = inv.id;
  elsif p_action = 'elle_kesildi' then
    -- F-29: Logo bağlantısı yokken fatura İşbaşı ekranından kesildiyse resmî numarasıyla işaretlenir (hiçbir yere gönderim yapılmaz)
    if inv.status not in ('taslak', 'hazir', 'hatali') then
      raise exception 'Bu kayıt zaten kesilmiş veya iptal edilmiş' using errcode = '22023';
    end if;
    if length(trim(coalesce(p_note, ''))) < 3 then raise exception 'İşbaşı''ndaki fatura numarasını yazın' using errcode = '22023'; end if;
    if exists (select 1 from public.invoices where business_id = p_business and logo_invoice_no = trim(p_note)
                and status <> 'iptal' and id <> inv.id) then
      raise exception 'Bu fatura numarası başka bir satışa işlenmiş' using errcode = '23505';
    end if;
    update public.invoices set status = 'resmilesti', logo_invoice_no = trim(p_note), environment = 'canli', sent_at = now(),
           gib_status = 'elle'
     where id = inv.id;
  else
    raise exception 'Geçersiz işlem' using errcode = '22023';
  end if;
  insert into public.invoice_events(invoice_id, business_id, user_id, event, detail)
  values (inv.id, p_business, auth.uid(), p_action, case when p_note is not null then jsonb_build_object('note', left(p_note, 500)) end);
  return (select status from public.invoices where id = inv.id);
end $$;

-- ---------------------------------------------------------------- gelir-gider raporu
-- p_grain: 'ay' | 'hafta' (hafta pazartesi başlar; dönem aralığa kırpılır). Yalnızca yönetici (G-18).
create or replace function public.profit_report(p_business uuid, p_from date, p_to date, p_grain text default 'ay')
returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v jsonb;
begin
  perform app.require_role(p_business, 'yonetici');
  if p_from is null or p_to is null or p_to < p_from then raise exception 'Tarih aralığı geçersiz' using errcode = '22023'; end if;
  if p_to - p_from > 800 then raise exception 'En fazla 2 yıllık aralık seçilebilir' using errcode = '22023'; end if;
  if p_grain not in ('ay', 'hafta') then raise exception 'Dönem türü geçersiz' using errcode = '22023'; end if;

  with days as (
    select d::date as day,
           greatest(p_from, case when p_grain = 'ay' then date_trunc('month', d) else date_trunc('week', d) end::date) as ps
      from generate_series(p_from, p_to, interval '1 day') d),
  periods as (select ps, max(day) as pe from days group by ps),
  sl as (   -- satışlar: ürün tutarı (depozito hariç), fatura durumu
    select dd.ps,
           sum(sa.goods_net) filter (where inv.ok) as invoiced,
           sum(sa.goods_net) filter (where not inv.ok) as uninvoiced,
           count(*) as n,
           sum((select coalesce(sum(c.total_cost), 0) from public.sale_items i join public.sale_item_costs c on c.sale_item_id = i.id
                 where i.sale_id = sa.id)) as cost
      from public.sales sa
      join days dd on dd.day = app.local_date(sa.sold_at)
      cross join lateral (select exists (select 1 from public.invoices x where x.sale_id = sa.id
                                          and x.status in ('gonderildi', 'resmilesti')) as ok) inv
     where sa.business_id = p_business and sa.status = 'tamamlandi'
       and sa.sold_at >= (p_from::timestamp at time zone 'Europe/Istanbul')
       and sa.sold_at < ((p_to + 1)::timestamp at time zone 'Europe/Istanbul')
     group by dd.ps),
  rt as (   -- iadeler (iade tarihinde düşülür)
    select dd.ps, sum(ri.refund_amount) as refund, sum(rc.total_cost) as rcost
      from public.returns re
      join days dd on dd.day = app.local_date(re.created_at)
      join public.return_items ri on ri.return_id = re.id
      left join public.return_item_costs rc on rc.return_item_id = ri.id
     where re.business_id = p_business
     group by dd.ps),
  pu as (   -- mal kabul (onaylı) — alış fiyatı × miktar, belge tarihinde
    select dd.ps, sum(pc.line_total) as amount, count(distinct p.id) as n
      from public.purchases p
      join days dd on dd.day = p.doc_date
      join public.purchase_items pi on pi.purchase_id = p.id
      join public.purchase_item_costs pc on pc.purchase_item_id = pi.id
     where p.business_id = p_business and p.status = 'onaylandi'
     group by dd.ps),
  ex as (
    select dd.ps, sum(e.amount) as amount
      from public.expenses e join days dd on dd.day = e.expense_date
     where e.business_id = p_business and e.status = 'gecerli'
     group by dd.ps),
  exc as (
    select x.ps, jsonb_object_agg(x.name, x.amount order by x.sort) as cats
      from (select dd.ps, c.name, min(c.sort) as sort, sum(e.amount) as amount
              from public.expenses e join days dd on dd.day = e.expense_date
              join public.expense_categories c on c.id = e.category_id
             where e.business_id = p_business and e.status = 'gecerli'
             group by dd.ps, c.name) x
     group by x.ps),
  res as (
    select pr.ps, pr.pe,
           coalesce(sl.invoiced, 0) as inv, coalesce(sl.uninvoiced, 0) as uninv, coalesce(sl.n, 0) as n,
           coalesce(rt.refund, 0) as refund,
           coalesce(pu.amount, 0) as purchases, coalesce(pu.n, 0) as pn,
           coalesce(ex.amount, 0) as expenses, coalesce(exc.cats, '{}'::jsonb) as cats,
           coalesce(sl.cost, 0) - coalesce(rt.rcost, 0) as cogs
      from periods pr
      left join sl on sl.ps = pr.ps left join rt on rt.ps = pr.ps left join pu on pu.ps = pr.ps
      left join ex on ex.ps = pr.ps left join exc on exc.ps = pr.ps)
  select jsonb_build_object(
    'periods', coalesce(jsonb_agg(jsonb_build_object(
        'start', r.ps, 'end', r.pe, 'sales_count', r.n,
        'income_invoiced', r.inv, 'income_uninvoiced', r.uninv, 'returns', r.refund,
        'income', r.inv + r.uninv - r.refund,
        'purchases', r.purchases, 'purchase_count', r.pn,
        'expenses', r.expenses, 'expense_categories', r.cats,
        'total_cost', r.purchases + r.expenses,
        'gross_profit', r.inv + r.uninv - r.refund - r.purchases,
        'net_profit', r.inv + r.uninv - r.refund - r.purchases - r.expenses,
        'cogs', r.cogs) order by r.ps), '[]'::jsonb),
    'pending_purchases', (select count(*) from public.purchases p where p.business_id = p_business and p.status = 'onay_bekliyor'
                            and p.doc_date between p_from and p_to))
    into v
    from res r;
  return v;
end $$;

select app.apply_grants();
