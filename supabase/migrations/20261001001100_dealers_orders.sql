-- ALKASU 0011 — Bayi sistemi, fiyat listeleri, siparişler ve teslimat
-- Kararlar: D-039..D-046 · Kurallar: BUSINESS_RULES §16-18

-- ---------------------------------------------------------------------------
-- 1) Rol kalıtımı: sevkiyat = depo + satış yetkileri (+ sipariş teslimi)
-- ---------------------------------------------------------------------------
create or replace function app.role_covers(p_role public.member_role, p_roles public.member_role[]) returns boolean
language sql immutable as $$
  select p_role = any(p_roles)
      or (p_role = 'sevkiyat' and p_roles && array['depo', 'satis']::public.member_role[])
$$;

create or replace function app.has_role(p_business uuid, variadic p_roles public.member_role[]) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(app.role_covers(app.role_in(p_business), p_roles), false)
$$;

create or replace function app.require_role(p_business uuid, variadic p_roles public.member_role[])
returns public.member_role
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r public.member_role;
begin
  if auth.uid() is null then
    raise exception 'Oturum açmanız gerekiyor' using errcode = '28000';
  end if;
  r := app.role_in(p_business);
  if r is null or not app.role_covers(r, p_roles) then
    raise exception 'Bu işlem için yetkiniz yok' using errcode = '42501';
  end if;
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- 2) Üyelik: bayi kullanıcısının bağlı olduğu müşteri, ilk girişte şifre değiştirme
-- ---------------------------------------------------------------------------
alter table public.memberships add column if not exists customer_id uuid references public.customers(id);
alter table public.memberships add column if not exists must_change_password boolean not null default false;
alter table public.memberships add column if not exists username text;
alter table public.memberships add constraint memberships_bayi_customer
  check (role <> 'bayi' or customer_id is not null) not valid;

create or replace function app.my_customer(p_business uuid) returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select m.customer_id from public.memberships m
   where m.business_id = p_business and m.user_id = auth.uid() and m.active and m.role = 'bayi'
$$;

-- ---------------------------------------------------------------------------
-- 3) Müşteri kanalı ve fiyat listesi
-- ---------------------------------------------------------------------------
alter table public.customers add column if not exists channel text not null default 'perakende'
  check (channel in ('perakende', 'kurumsal', 'bayi'));
alter table public.customers add column if not exists price_list text not null default 'perakende'
  check (price_list in ('perakende', 'bayi', 'palet'));
alter table public.customers add column if not exists regions text;
alter table public.customers add column if not exists default_assignee uuid;

-- Liste fiyatları (perakende fiyat product_units.price'ta kalır)
create table public.product_list_prices (
  unit_id      uuid not null references public.product_units(id),
  business_id  uuid not null references public.businesses(id),
  price_list   text not null check (price_list in ('bayi', 'palet')),
  price        numeric(14,2) not null check (price >= 0),
  updated_at   timestamptz not null default now(),
  primary key (unit_id, price_list)
);
alter table public.product_list_prices enable row level security;
create policy list_prices_select on public.product_list_prices for select to authenticated using (app.is_member(business_id));
create trigger list_prices_audit after insert or update on public.product_list_prices for each row execute function audit.tg_row();

alter table public.product_prices add column if not exists price_list text not null default 'perakende';
drop index if exists product_prices_unit;
create index product_prices_unit on public.product_prices(unit_id, price_list, valid_from desc);

-- Listeye göre güncel fiyat: liste fiyatı yoksa perakende
create or replace function app.unit_list_price(p_unit uuid, p_list text) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select case when coalesce(p_list, 'perakende') = 'perakende' then u.price
              else coalesce((select lp.price from public.product_list_prices lp
                              where lp.unit_id = u.id and lp.price_list = p_list), u.price) end
    from public.product_units u where u.id = p_unit
$$;

-- Perakende fiyat geçmişi: liste fiyatları aynı tabloda tutulduğundan filtrelenir
create or replace function app.unit_price_at(p_unit uuid, p_at timestamptz) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select price from public.product_prices
  where unit_id = p_unit and price_list = 'perakende' and valid_from <= p_at
  order by valid_from desc, id desc limit 1
$$;

-- Belirli andaki liste fiyatı (çevrimdışı doğrulama); listede kayıt yoksa perakende
create or replace function app.unit_price_at(p_unit uuid, p_at timestamptz, p_list text) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(
    (select price from public.product_prices where unit_id = p_unit and price_list = coalesce(p_list, 'perakende')
       and valid_from <= p_at order by valid_from desc, id desc limit 1),
    app.unit_price_at(p_unit, p_at))
$$;

create or replace function public.set_list_price(p_unit uuid, p_list text, p_price numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid; v_old numeric;
begin
  select business_id into v_bid from public.product_units where id = p_unit;
  if v_bid is null then raise exception 'Birim bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici');
  if p_list = 'perakende' then perform public.set_unit_price(p_unit, p_price); return; end if;
  if p_list not in ('bayi', 'palet') then raise exception 'Fiyat listesi geçersiz' using errcode = '22023'; end if;
  if p_price is not null and p_price < 0 then raise exception 'Fiyat negatif olamaz' using errcode = '22023'; end if;
  select price into v_old from public.product_list_prices where unit_id = p_unit and price_list = p_list;
  if p_price is null then
    delete from public.product_list_prices where unit_id = p_unit and price_list = p_list;
  else
    insert into public.product_list_prices(unit_id, business_id, price_list, price)
    values (p_unit, v_bid, p_list, round(p_price, 2))
    on conflict (unit_id, price_list) do update set price = excluded.price, updated_at = now();
  end if;
  if v_old is distinct from round(p_price, 2) then
    insert into public.product_prices(business_id, unit_id, price, created_by, source, price_list)
    values (v_bid, p_unit, round(p_price, 2), auth.uid(), 'manuel', p_list);
  end if;
end $$;

-- Fiyat listesi içe aktarma: rows = [{row, urun_kodu, birim?, perakende_fiyati?, bayi_fiyati?, palet_fiyati?}]
-- birim boşsa ürünün satışta kullanılan birimi (fiyatı olan en büyük birim)
create or replace function public.import_prices(p_business uuid, p_rows jsonb, p_dry_run boolean default true) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare r jsonb; v_errs jsonb := '[]'; v_unit uuid; v_n int := 0; f text; v_row int;
begin
  perform app.require_role(p_business, 'yonetici');
  for r in select * from jsonb_array_elements(p_rows) loop
    v_row := coalesce((r->>'row')::int, 0);
    select u.id into v_unit from public.product_units u join public.products p on p.id = u.product_id
     where p.business_id = p_business and lower(p.code) = lower(trim(r->>'urun_kodu')) and u.active
       and (case when app.blank(r->>'birim') then u.price is not null else lower(u.name) = lower(trim(r->>'birim')) end)
     order by u.factor desc limit 1;
    if v_unit is null then
      v_errs := v_errs || jsonb_build_object('row', v_row, 'field', 'urun_kodu', 'message', 'Ürün veya birim bulunamadı: ' || coalesce(r->>'urun_kodu', '') || ' ' || coalesce(r->>'birim', ''));
      continue;
    end if;
    foreach f in array array['perakende_fiyati', 'bayi_fiyati', 'palet_fiyati'] loop
      if not app.blank(r->>f) and coalesce(app.num(r->>f), -1) < 0 then
        v_errs := v_errs || jsonb_build_object('row', v_row, 'field', f, 'message', 'Geçerli bir tutar değil');
      end if;
    end loop;
    if not p_dry_run and jsonb_array_length(v_errs) = 0 then
      if not app.blank(r->>'perakende_fiyati') then perform public.set_list_price(v_unit, 'perakende', app.num(r->>'perakende_fiyati')); end if;
      if not app.blank(r->>'bayi_fiyati') then perform public.set_list_price(v_unit, 'bayi', app.num(r->>'bayi_fiyati')); end if;
      if not app.blank(r->>'palet_fiyati') then perform public.set_list_price(v_unit, 'palet', app.num(r->>'palet_fiyati')); end if;
    end if;
    v_n := v_n + 1;
  end loop;
  if jsonb_array_length(v_errs) > 0 and not p_dry_run then
    raise exception 'Fiyat listesinde hata var: %', v_errs using errcode = '22023';
  end if;
  return jsonb_build_object('ok', jsonb_array_length(v_errs) = 0, 'applied', not p_dry_run, 'errors', v_errs,
                            'warnings', '[]'::jsonb, 'summary', jsonb_build_object('rows', v_n));
end $$;

-- ---------------------------------------------------------------------------
-- 4) RLS: yeni roller
-- ---------------------------------------------------------------------------
drop policy if exists customers_select on public.customers;
create policy customers_select on public.customers for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis') or id = app.my_customer(business_id));
drop policy if exists customer_ledger_select on public.customer_ledger;
create policy customer_ledger_select on public.customer_ledger for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis') or customer_id = app.my_customer(business_id));
drop policy if exists container_ledger_select on public.container_ledger;
create policy container_ledger_select on public.container_ledger for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis') or customer_id = app.my_customer(business_id));
drop policy if exists customer_payments_select on public.customer_payments;
create policy customer_payments_select on public.customer_payments for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis') or customer_id = app.my_customer(business_id));

create or replace function app.can_see_sale(p_sale uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.sales s where s.id = p_sale
      and (app.is_admin(s.business_id)
           or (app.has_role(s.business_id, 'satis') and s.created_by = auth.uid())
           or (s.customer_id is not null and s.customer_id = app.my_customer(s.business_id)))
  )
$$;
drop policy if exists sales_select on public.sales;
create policy sales_select on public.sales for select to authenticated
  using (app.is_admin(business_id)
         or (app.has_role(business_id, 'satis') and created_by = auth.uid())
         or (customer_id is not null and customer_id = app.my_customer(business_id)));

-- Kullanıcı listesi: sipariş ataması için isimler (yönetici tümünü zaten görür)
create or replace function public.assignable_users(p_business uuid)
returns table(user_id uuid, display_name text, role public.member_role)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform app.require_role(p_business, 'yonetici', 'satis', 'depo', 'bayi');
  return query select m.user_id, m.display_name, m.role from public.memberships m
   where m.business_id = p_business and m.active and m.role in ('yonetici', 'satis', 'sevkiyat')
   order by m.display_name;
end $$;

-- ---------------------------------------------------------------------------
-- 5) Satış çekirdeği: liste fiyatı doğrulaması ve teslimat (güvenilir fiyat) desteği
-- ---------------------------------------------------------------------------
create or replace function app.complete_sale_core(p_business uuid, p jsonb, p_role public.member_role,
                                              p_trusted boolean default false) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role    public.member_role := p_role;          -- çağıran fonksiyon yetkiyi doğrular
  v_list    text := 'perakende';
  v_cur     numeric;
  v_id      uuid := (p->>'id')::uuid;
  v_loc     uuid := coalesce(nullif(p->>'location_id', '')::uuid, app.default_location(p_business));
  v_set     public.app_settings;
  v_sess    public.cash_sessions;
  v_cust    public.customers;
  v_offline boolean := coalesce((p->>'offline')::boolean, false);
  v_client  timestamptz := coalesce(nullif(p->>'client_created_at', '')::timestamptz, now());
  v_sold_at timestamptz;
  v_no      bigint;
  it        jsonb;
  pr        public.products;
  u         public.product_units;
  v_line    int := 0;
  v_qty     int;
  v_price   numeric;
  v_ldisc   numeric;
  v_gross   numeric := 0;
  v_ldisc_total numeric := 0;
  v_bill    numeric := coalesce(nullif(p->>'bill_discount', '')::numeric, 0);
  v_net_before_bill numeric;
  v_share   numeric;
  v_share_left numeric;
  v_goods_net numeric := 0;
  v_dep_total numeric := 0;
  v_grand   numeric;
  v_pay_total numeric := 0;
  v_cash    numeric := 0; v_pos numeric := 0; v_credit numeric := 0;
  v_given   numeric := nullif(p->>'cash_given', '')::numeric;
  v_balance numeric;
  v_limit_override boolean := false;
  v_offline_limit boolean := false;
  d         record;
  v_ret     int;
  v_cb      record;
  v_amt     numeric;
  rec       record;
  v_item_id uuid;
begin
  if v_id is null then raise exception 'Satış kimliği eksik' using errcode = '22023'; end if;

  -- S-02: aynı kimlikle tekrar gönderim
  if exists (select 1 from public.sales where id = v_id) then
    return (select jsonb_build_object('id', s.id, 'no', s.no, 'grand_total', s.grand_total,
                                      'change', s.change_given, 'duplicate', true)
              from public.sales s where s.id = v_id and s.business_id = p_business);
  end if;

  select * into v_set from public.app_settings where business_id = p_business;
  if jsonb_array_length(coalesce(p->'items', '[]')) = 0 then
    raise exception 'Sepet boş' using errcode = '22023';
  end if;
  if v_bill < 0 then raise exception 'İndirim negatif olamaz' using errcode = '22023'; end if;

  if nullif(p->>'customer_id', '') is not null then
    select * into v_cust from public.customers where id = (p->>'customer_id')::uuid and business_id = p_business;
    if v_cust.id is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
    if not v_cust.active then raise exception 'Müşteri pasif durumda' using errcode = 'P0001'; end if;
    v_list := coalesce(v_cust.price_list, 'perakende');   -- F-10: müşterinin fiyat listesi
  end if;

  v_sess := app.ensure_session(p_business, v_loc);
  v_sold_at := case when v_offline then least(v_client, now()) else now() end;
  v_no := app.next_number(p_business, 'satis');

  if to_regclass('pg_temp._sale_lines') is null then
  create temp table _sale_lines (
    line_no int, product_id uuid, unit_id uuid, unit_name text, factor int, qty int, base_qty int,
    unit_price numeric, line_gross numeric, line_discount numeric, share numeric default 0,
    line_net numeric, vat_rate smallint, deposit_amount numeric, empty_product_id uuid
  ) on commit drop;
  end if;
  truncate _sale_lines;

  -- 1) Kalemleri doğrula
  for it in select * from jsonb_array_elements(p->'items') loop
    v_line := v_line + 1;
    pr := app.product_in_business(p_business, (it->>'product_id')::uuid);
    if not pr.active then raise exception 'Pasif ürün satılamaz: % (S-06)', pr.name using errcode = 'P0001'; end if;
    if pr.is_container then raise exception 'Boş kap ürünü satılamaz: %', pr.name using errcode = 'P0001'; end if;
    select * into u from public.product_units where id = (it->>'unit_id')::uuid and product_id = pr.id;
    if u.id is null then raise exception 'Ürün birimi geçersiz: %', pr.name using errcode = '22023'; end if;
    if not u.active and not v_offline then raise exception 'Bu birim artık kullanılmıyor: % %', pr.name, u.name using errcode = 'P0001'; end if;

    v_qty   := (it->>'qty')::int;
    v_price := round((it->>'unit_price')::numeric, 2);
    v_ldisc := round(coalesce(nullif(it->>'line_discount', '')::numeric, 0), 2);
    if v_qty is null or v_qty <= 0 then raise exception 'Miktar geçersiz: %', pr.name using errcode = '22023'; end if;
    if v_price is null or v_price < 0 then raise exception 'Fiyat geçersiz: %', pr.name using errcode = '22023'; end if;

    if v_role <> 'yonetici' and not p_trusted then
      -- Satış personeli fiyatı değiştiremez; müşterinin fiyat listesi geçerlidir (F-10).
      -- Çevrimdışında satış anındaki fiyat da kabul edilir (C-02)
      v_cur := app.unit_list_price(u.id, v_list);
      if v_cur is null and app.unit_price_at(u.id, v_client, v_list) is null then
        raise exception 'Bu birim için satış fiyatı tanımlı değil: % %', pr.name, u.name using errcode = 'P0001';
      end if;
      if v_price is distinct from v_cur
         and not (v_offline and v_price = app.unit_price_at(u.id, v_client, v_list)) then
        raise exception 'Fiyat güncel değil: % % (güncel: %)', pr.name, u.name, v_cur using errcode = 'P0001';
      end if;
      if v_price = 0 then raise exception 'Sıfır fiyatlı satışı yalnızca yönetici yapabilir (F-07)' using errcode = '42501'; end if;
    end if;

    if v_ldisc < 0 or v_ldisc > round(v_qty * v_price, 2) then
      raise exception 'Satır indirimi geçersiz: %', pr.name using errcode = '22023';
    end if;

    insert into _sale_lines values (v_line, pr.id, u.id, u.name, u.factor, v_qty, v_qty * u.factor, v_price,
      round(v_qty * v_price, 2), v_ldisc, 0, null, pr.vat_rate, pr.deposit_amount, pr.empty_product_id);
    v_gross := v_gross + round(v_qty * v_price, 2);
    v_ldisc_total := v_ldisc_total + v_ldisc;
  end loop;

  -- 2) Fiş indirimini satırlara dağıt (F-05)
  v_net_before_bill := v_gross - v_ldisc_total;
  if v_bill > v_net_before_bill then raise exception 'Fiş indirimi tutarı aşıyor' using errcode = '22023'; end if;
  if v_bill > 0 then
    v_share_left := v_bill;
    for rec in select line_no, line_gross - line_discount as net from _sale_lines order by line_no loop
      if rec.line_no = v_line then
        v_share := v_share_left;
      else
        v_share := round(v_bill * rec.net / v_net_before_bill, 2);
        v_share_left := v_share_left - v_share;
      end if;
      update _sale_lines set share = v_share where line_no = rec.line_no;
    end loop;
  end if;
  update _sale_lines set line_net = line_gross - line_discount - share where true;  -- pg_safeupdate: WHERE zorunlu
  select coalesce(sum(line_net), 0) into v_goods_net from _sale_lines;

  -- F-06: indirim limiti
  if v_role <> 'yonetici' and not p_trusted and (v_ldisc_total + v_bill) > round(v_gross * v_set.max_discount_pct_satis / 100, 2) then
    raise exception 'İndirim limitinizi aşıyor (en fazla %%%). Yönetici onayı gerekir (F-06)',
      v_set.max_discount_pct_satis using errcode = '42501';
  end if;

  -- 3) Satış kaydı
  insert into public.sales(id, business_id, location_id, no, session_id, customer_id, goods_gross, discount_total,
                           goods_net, deposit_total, grand_total, sold_at, created_by, offline, late_sync, note)
  values (v_id, p_business, v_loc, v_no, v_sess.id, v_cust.id, v_gross, v_ldisc_total + v_bill,
          v_goods_net, 0, v_goods_net, v_sold_at, auth.uid(), v_offline,
          v_offline and v_client < v_sess.opened_at, nullif(trim(p->>'note'), ''));

  for rec in select l.*, coalesce(pc.avg_cost, 0) as avg_cost, coalesce(pc.has_cost, false) as has_cost
               from _sale_lines l left join public.product_costs pc on pc.product_id = l.product_id
              order by l.line_no loop
    insert into public.sale_items(sale_id, business_id, line_no, product_id, unit_id, unit_name, factor, qty, base_qty,
                                  unit_price, line_gross, line_discount, bill_discount_share, line_net, vat_rate)
    values (v_id, p_business, rec.line_no, rec.product_id, rec.unit_id, rec.unit_name, rec.factor, rec.qty, rec.base_qty,
            rec.unit_price, rec.line_gross, rec.line_discount, rec.share, rec.line_net, rec.vat_rate)
    returning id into v_item_id;
    insert into public.sale_item_costs(sale_item_id, business_id, unit_cost, total_cost, has_cost)
    values (v_item_id, p_business, rec.avg_cost, round(rec.avg_cost * rec.base_qty, 2), rec.has_cost);
  end loop;

  -- 4) Stok hareketleri (ürün sırasıyla: kilit sırası sabit, T-008)
  for rec in select product_id, sum(base_qty)::int as q from _sale_lines group by product_id order by product_id loop
    perform app.post_stock(p_business, v_loc, rec.product_id, -rec.q, 'satis', 'sale', v_id);
  end loop;

  -- 5) Depozito ve boş kap (D-03..D-06)
  for d in select product_id, sum(base_qty)::int as sold, max(deposit_amount) as dep, max(empty_product_id::text)::uuid as empty_id
             from _sale_lines where deposit_amount is not null group by product_id order by product_id loop
    select coalesce(max((x->>'empty_returned')::int), d.sold) into v_ret
      from jsonb_array_elements(coalesce(p->'deposits', '[]')) x where (x->>'product_id')::uuid = d.product_id;
    v_ret := coalesce(v_ret, d.sold);
    if v_ret < 0 then raise exception 'Boş kap sayısı geçersiz' using errcode = '22023'; end if;

    if d.sold - v_ret > 0 then
      v_amt := (d.sold - v_ret) * d.dep;                     -- müşteriden depozito alınır
    elsif d.sold - v_ret < 0 then
      v_amt := -app.deposit_refund_amount(p_business, v_cust.id, d.product_id, v_ret - d.sold);  -- fazla boş: depozito iadesi
    else
      v_amt := 0;
    end if;

    insert into public.sale_deposits(sale_id, business_id, product_id, sold_qty, empty_returned, net_containers, amount)
    values (v_id, p_business, d.product_id, d.sold, v_ret, d.sold - v_ret, v_amt);
    if d.sold - v_ret <> 0 then
      insert into public.container_ledger(business_id, customer_id, product_id, qty, amount, type, ref_type, ref_id, created_by)
      values (p_business, v_cust.id, d.product_id, d.sold - v_ret, v_amt, 'satis', 'sale', v_id, auth.uid());
    end if;
    if v_ret > 0 then
      perform app.post_stock(p_business, v_loc, d.empty_id, v_ret, 'bos_kap_giris', 'sale', v_id);
    end if;
    v_dep_total := v_dep_total + v_amt;
  end loop;
  -- Satılmayan ürün için gönderilmiş depozito satırı kabul edilmez
  if exists (select 1 from jsonb_array_elements(coalesce(p->'deposits', '[]')) x
              where not exists (select 1 from _sale_lines l where l.product_id = (x->>'product_id')::uuid
                                  and l.deposit_amount is not null)) then
    raise exception 'Boş kap bilgisi yalnızca satılan depozitolu ürünler için girilebilir' using errcode = '22023';
  end if;

  v_grand := v_goods_net + v_dep_total;
  if v_grand < 0 then
    raise exception 'Fiş toplamı negatif olamaz; fazla boş kap için "Depozito iadesi" işlemini kullanın' using errcode = '22023';
  end if;

  -- 6) Ödemeler (S-03)
  for it in select * from jsonb_array_elements(coalesce(p->'payments', '[]')) loop
    v_amt := round((it->>'amount')::numeric, 2);
    if v_amt is null or v_amt <= 0 then raise exception 'Ödeme tutarı geçersiz' using errcode = '22023'; end if;
    case it->>'method'
      when 'nakit' then v_cash := v_cash + v_amt;
      when 'pos' then v_pos := v_pos + v_amt;
      when 'veresiye' then v_credit := v_credit + v_amt;
      else raise exception 'Ödeme şekli geçersiz: %', it->>'method' using errcode = '22023';
    end case;
  end loop;
  v_pay_total := v_cash + v_pos + v_credit;
  if v_pay_total <> v_grand then
    raise exception 'Ödemeler toplamı (%) fiş toplamına (%) eşit değil (S-03)', v_pay_total, v_grand using errcode = '22023';
  end if;
  if v_given is not null and v_given < v_cash then
    raise exception 'Alınan nakit, nakit ödeme tutarından az olamaz' using errcode = '22023';
  end if;

  -- V-01..V-02: veresiye
  if v_credit > 0 then
    if v_cust.id is null then raise exception 'Veresiye için müşteri seçilmelidir (V-01)' using errcode = '22023'; end if;
    perform 1 from public.customers where id = v_cust.id for update;   -- aynı müşteriye eşzamanlı veresiye
    v_balance := app.customer_balance(v_cust.id);
    if not v_cust.unlimited_credit and v_balance + v_credit > v_cust.credit_limit then
      if v_offline or p_trusted then
        v_offline_limit := true;                    -- C-03 / teslimat: satış kaydedilir, yöneticiye uyarı
      elsif coalesce((p->>'limit_override')::boolean, false) and v_role = 'yonetici' then
        v_limit_override := true;
      else
        raise exception 'Veresiye limiti aşılıyor. Bakiye: %, limit: %, bu satış: % (V-02)',
          v_balance, v_cust.credit_limit, v_credit using errcode = 'P0001';
      end if;
    end if;
    insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
    values (p_business, v_cust.id, 'satis', v_credit, 'sale', v_id, auth.uid());
  end if;

  if v_cash > 0 then insert into public.sale_payments(sale_id, business_id, method, amount) values (v_id, p_business, 'nakit', v_cash); end if;
  if v_pos > 0 then insert into public.sale_payments(sale_id, business_id, method, amount) values (v_id, p_business, 'pos', v_pos); end if;
  if v_credit > 0 then insert into public.sale_payments(sale_id, business_id, method, amount) values (v_id, p_business, 'veresiye', v_credit); end if;
  perform app.post_cash(p_business, v_sess.id, 'satis', v_cash, 'sale', v_id);

  update public.sales set deposit_total = v_dep_total, grand_total = v_grand,
         cash_given = v_given, change_given = case when v_given is not null then v_given - v_cash end,
         limit_override = v_limit_override, offline_limit_exceeded = v_offline_limit
   where id = v_id;

  perform app.audit(p_business, case when v_limit_override then 'satis_limit_asimi' else 'satis' end,
                    'sales', v_id::text, null,
                    jsonb_build_object('no', v_no, 'grand_total', v_grand, 'customer_id', v_cust.id,
                                       'offline', v_offline, 'limit_override', v_limit_override,
                                       'offline_limit_exceeded', v_offline_limit));

  return jsonb_build_object('id', v_id, 'no', v_no, 'grand_total', v_grand, 'goods_net', v_goods_net,
                            'deposit_total', v_dep_total,
                            'change', case when v_given is not null then v_given - v_cash end,
                            'session_id', v_sess.id, 'duplicate', false,
                            'limit_override', v_limit_override, 'offline_limit_exceeded', v_offline_limit);
end $$;

create or replace function public.complete_sale(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_role public.member_role := app.require_role(p_business, 'yonetici', 'satis');
begin
  return app.complete_sale_core(p_business, p, v_role, false);
end $$;

-- ---------------------------------------------------------------------------
-- 6) Siparişler
-- ---------------------------------------------------------------------------
create table public.orders (
  id             uuid primary key,
  business_id    uuid not null references public.businesses(id),
  no             bigint not null,
  customer_id    uuid not null references public.customers(id),
  delivery_date  date not null default app.local_date(now()),
  assignee       uuid,                                  -- teslim edecek kullanıcı (auth user)
  status         text not null default 'acik' check (status in ('acik', 'teslim_edildi', 'iptal')),
  address        text,
  note           text,
  price_list     text not null default 'perakende',
  created_by     uuid,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  delivered_by   uuid,
  delivered_at   timestamptz,
  sale_id        uuid references public.sales(id),
  cancelled_by   uuid,
  cancelled_at   timestamptz,
  cancel_reason  text,
  unique (business_id, no)
);
create index orders_business_date on public.orders(business_id, delivery_date, status);
create index orders_assignee on public.orders(assignee) where status = 'acik';
create index orders_customer on public.orders(customer_id);

create table public.order_items (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references public.orders(id),
  business_id uuid not null references public.businesses(id),
  line_no     smallint not null,
  product_id  uuid not null references public.products(id),
  unit_id     uuid not null references public.product_units(id),
  qty         integer not null check (qty > 0),
  unit_price  numeric(14,2) not null check (unit_price >= 0)
);
create index order_items_order on public.order_items(order_id);

create trigger orders_touch before update on public.orders for each row execute function app.touch_updated_at();
create trigger orders_audit after insert or update on public.orders for each row execute function audit.tg_row();

alter table public.orders enable row level security;
alter table public.order_items enable row level security;
create policy orders_select on public.orders for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis') or customer_id = app.my_customer(business_id));
create policy order_items_select on public.order_items for select to authenticated
  using (exists (select 1 from public.orders o where o.id = order_id
                  and (app.has_role(o.business_id, 'yonetici', 'satis') or o.customer_id = app.my_customer(o.business_id))));

-- Sipariş oluştur / güncelle (yalnızca açık sipariş)
-- p = { id, customer_id, delivery_date?, assignee?, address?, note?, items: [{product_id, unit_id, qty, unit_price?}] }
create or replace function public.save_order(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role  public.member_role := app.require_role(p_business, 'yonetici', 'satis', 'bayi');
  v_id    uuid := (p->>'id')::uuid;
  o       public.orders;
  c       public.customers;
  it      jsonb;
  pr      public.products;
  u       public.product_units;
  v_price numeric;
  v_line  int := 0;
  v_assignee uuid := nullif(p->>'assignee', '')::uuid;
begin
  if v_id is null then raise exception 'Sipariş kimliği eksik' using errcode = '22023'; end if;
  select * into c from public.customers where id = (case when v_role = 'bayi' then app.my_customer(p_business)
                                                         else nullif(p->>'customer_id', '')::uuid end)
                                          and business_id = p_business;
  if c.id is null then raise exception 'Müşteri seçilmelidir' using errcode = '22023'; end if;
  if not c.active then raise exception 'Müşteri pasif durumda' using errcode = 'P0001'; end if;
  if jsonb_array_length(coalesce(p->'items', '[]')) = 0 then raise exception 'Siparişte ürün yok' using errcode = '22023'; end if;
  if v_assignee is not null and not exists (select 1 from public.memberships where business_id = p_business
                                              and user_id = v_assignee and active and role in ('yonetici', 'satis', 'sevkiyat')) then
    raise exception 'Atanan kişi geçersiz' using errcode = '22023';
  end if;
  if v_role = 'bayi' then v_assignee := null; end if;   -- bayi siparişini yönetici/sevkiyat atar

  select * into o from public.orders where id = v_id for update;
  if o.id is null then
    insert into public.orders(id, business_id, no, customer_id, delivery_date, assignee, address, note, price_list, created_by)
    values (v_id, p_business, app.next_number(p_business, 'siparis'), c.id,
            coalesce(nullif(p->>'delivery_date', '')::date, app.local_date(now())),
            coalesce(v_assignee, c.default_assignee),
            coalesce(nullif(trim(p->>'address'), ''), c.address), nullif(trim(p->>'note'), ''), c.price_list, auth.uid())
    returning * into o;
  else
    if o.business_id <> p_business then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
    if o.status <> 'acik' then raise exception 'Kapanmış sipariş değiştirilemez' using errcode = 'P0001'; end if;
    if v_role = 'bayi' and o.customer_id <> c.id then raise exception 'Bu sipariş size ait değil' using errcode = '42501'; end if;
    update public.orders set customer_id = c.id, price_list = c.price_list,
      delivery_date = coalesce(nullif(p->>'delivery_date', '')::date, delivery_date),
      assignee = case when v_role = 'bayi' then assignee else v_assignee end,
      address = nullif(trim(p->>'address'), ''), note = nullif(trim(p->>'note'), '')
     where id = v_id returning * into o;
    delete from public.order_items where order_id = v_id;
  end if;

  for it in select * from jsonb_array_elements(p->'items') loop
    v_line := v_line + 1;
    pr := app.product_in_business(p_business, (it->>'product_id')::uuid);
    if not pr.active or pr.is_container then raise exception 'Bu ürün siparişe eklenemez: %', pr.name using errcode = 'P0001'; end if;
    select * into u from public.product_units where id = (it->>'unit_id')::uuid and product_id = pr.id and active;
    if u.id is null then raise exception 'Ürün birimi geçersiz: %', pr.name using errcode = '22023'; end if;
    if coalesce((it->>'qty')::int, 0) <= 0 then raise exception 'Miktar geçersiz: %', pr.name using errcode = '22023'; end if;
    v_price := case when v_role = 'yonetici' and nullif(it->>'unit_price', '') is not null
                    then round((it->>'unit_price')::numeric, 2)
                    else app.unit_list_price(u.id, c.price_list) end;
    if v_price is null then raise exception 'Bu birimin fiyatı tanımlı değil: % %', pr.name, u.name using errcode = 'P0001'; end if;
    insert into public.order_items(order_id, business_id, line_no, product_id, unit_id, qty, unit_price)
    values (v_id, p_business, v_line, pr.id, u.id, (it->>'qty')::int, v_price);
  end loop;

  return jsonb_build_object('id', o.id, 'no', o.no, 'status', o.status);
end $$;

create or replace function public.assign_order(p_order uuid, p_assignee uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(o.business_id, 'yonetici', 'satis');
  if o.status <> 'acik' then raise exception 'Kapanmış sipariş değiştirilemez' using errcode = 'P0001'; end if;
  if p_assignee is not null and not exists (select 1 from public.memberships where business_id = o.business_id
                                             and user_id = p_assignee and active and role in ('yonetici', 'satis', 'sevkiyat')) then
    raise exception 'Atanan kişi geçersiz' using errcode = '22023';
  end if;
  update public.orders set assignee = p_assignee where id = p_order;
end $$;

create or replace function public.cancel_order(p_order uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders; v_role public.member_role;
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  v_role := app.require_role(o.business_id, 'yonetici', 'satis', 'bayi');
  if v_role = 'bayi' and o.customer_id is distinct from app.my_customer(o.business_id) then
    raise exception 'Bu sipariş size ait değil' using errcode = '42501';
  end if;
  if o.status <> 'acik' then raise exception 'Sipariş zaten kapanmış' using errcode = 'P0001'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'İptal nedeni zorunludur' using errcode = '22023'; end if;
  update public.orders set status = 'iptal', cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = trim(p_reason)
   where id = p_order;
end $$;

-- Teslimat: siparişi satışa dönüştürür (D-041). Atanan kişi veya yönetici kapatabilir.
-- p = { order_id, sale_id, items: [{order_item_id, qty}], deposits?: [{product_id, empty_returned}],
--       payments: [{method, amount}], cash_given?, note? }
create or replace function public.deliver_order(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role public.member_role := app.require_role(p_business, 'yonetici', 'satis');
  o      public.orders;
  v_items jsonb := '[]';
  oi     record;
  v_qty  int;
  v_res  jsonb;
begin
  select * into o from public.orders where id = (p->>'order_id')::uuid and business_id = p_business for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  if o.status = 'teslim_edildi' and o.sale_id = (p->>'sale_id')::uuid then
    return jsonb_build_object('order_id', o.id, 'sale_id', o.sale_id, 'duplicate', true);
  end if;
  if o.status <> 'acik' then raise exception 'Sipariş açık değil' using errcode = 'P0001'; end if;
  if v_role <> 'yonetici' and o.assignee is distinct from auth.uid() then
    raise exception 'Bu siparişi yalnızca atanan kişi veya yönetici kapatabilir' using errcode = '42501';
  end if;

  for oi in select * from public.order_items where order_id = o.id order by line_no loop
    select coalesce(max((x->>'qty')::int), oi.qty) into v_qty
      from jsonb_array_elements(coalesce(p->'items', '[]')) x where (x->>'order_item_id')::uuid = oi.id;
    v_qty := coalesce(v_qty, oi.qty);
    if v_qty < 0 then raise exception 'Teslim miktarı negatif olamaz' using errcode = '22023'; end if;
    if v_qty > 0 then
      v_items := v_items || jsonb_build_object('product_id', oi.product_id, 'unit_id', oi.unit_id, 'qty', v_qty, 'unit_price', oi.unit_price);
    end if;
  end loop;
  if jsonb_array_length(v_items) = 0 then
    raise exception 'Teslim edilen ürün yok; teslim edilmediyse siparişi iptal edin' using errcode = '22023';
  end if;

  v_res := app.complete_sale_core(p_business, jsonb_build_object(
    'id', p->>'sale_id', 'customer_id', o.customer_id, 'items', v_items,
    'deposits', coalesce(p->'deposits', '[]'), 'payments', coalesce(p->'payments', '[]'),
    'cash_given', p->'cash_given', 'note', coalesce(nullif(trim(p->>'note'), ''), 'Sipariş #' || o.no)), v_role, true);

  update public.orders set status = 'teslim_edildi', delivered_by = auth.uid(), delivered_at = now(),
         sale_id = (v_res->>'id')::uuid where id = o.id;
  perform app.audit(p_business, 'siparis_teslim', 'orders', o.id::text, null, v_res);
  return v_res || jsonb_build_object('order_id', o.id, 'order_no', o.no);
end $$;

-- ---------------------------------------------------------------------------
-- 7) Müşteri kartı: kanal, fiyat listesi, bölge, varsayılan sorumlu
-- ---------------------------------------------------------------------------
create or replace function public.upsert_customer(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role public.member_role := app.require_role(p_business, 'yonetici', 'satis');
  v_id   uuid := nullif(p->>'id', '')::uuid;
  v_code text := nullif(trim(p->>'code'), '');
  v_adm  boolean := v_role = 'yonetici';
begin
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Müşteri adı zorunludur' using errcode = '22023'; end if;
  if v_code is not null and exists (select 1 from public.customers where business_id = p_business
                                    and lower(code) = lower(v_code) and id is distinct from v_id) then
    raise exception 'Bu müşteri kodu zaten kullanılıyor: %', v_code using errcode = '23505';
  end if;
  if v_id is null then
    if v_code is null then v_code := 'M' || lpad(app.next_number(p_business, 'musteri')::text, 5, '0'); end if;
    insert into public.customers(business_id, code, name, phone, address, tax_no, note, credit_limit, unlimited_credit,
                                 channel, price_list, regions, default_assignee)
    values (p_business, v_code, trim(p->>'name'), nullif(trim(p->>'phone'), ''), nullif(trim(p->>'address'), ''),
            nullif(trim(p->>'tax_no'), ''), nullif(trim(p->>'note'), ''),
            case when v_adm then coalesce(nullif(p->>'credit_limit', '')::numeric, 0) else 0 end,
            case when v_adm then coalesce((p->>'unlimited_credit')::boolean, false) else false end,
            coalesce(nullif(p->>'channel', ''), 'perakende'),
            case when v_adm then coalesce(nullif(p->>'price_list', ''), 'perakende') else 'perakende' end,
            nullif(trim(p->>'regions'), ''), nullif(p->>'default_assignee', '')::uuid)
    returning id into v_id;
  else
    update public.customers set
      code = coalesce(v_code, code), name = trim(p->>'name'),
      phone = nullif(trim(p->>'phone'), ''), address = nullif(trim(p->>'address'), ''),
      tax_no = nullif(trim(p->>'tax_no'), ''), note = nullif(trim(p->>'note'), ''),
      credit_limit = case when v_adm then coalesce(nullif(p->>'credit_limit', '')::numeric, credit_limit) else credit_limit end,
      unlimited_credit = case when v_adm then coalesce((p->>'unlimited_credit')::boolean, unlimited_credit) else unlimited_credit end,
      active = case when v_adm then coalesce((p->>'active')::boolean, active) else active end,
      channel = coalesce(nullif(p->>'channel', ''), channel),
      price_list = case when v_adm then coalesce(nullif(p->>'price_list', ''), price_list) else price_list end,
      regions = case when p ? 'regions' then nullif(trim(p->>'regions'), '') else regions end,
      default_assignee = case when p ? 'default_assignee' then nullif(p->>'default_assignee', '')::uuid else default_assignee end
    where id = v_id and business_id = p_business;
    if not found then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  end if;
  return v_id;
end $$;

-- Bayi kendi özetini ve ekstresini görebilir
create or replace function app.require_customer_access(p_customer uuid) returns uuid
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_bid uuid;
begin
  select business_id into v_bid from public.customers where id = p_customer;
  if v_bid is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  if not app.has_role(v_bid, 'yonetici', 'satis') and p_customer is distinct from app.my_customer(v_bid) then
    raise exception 'Bu işlem için yetkiniz yok' using errcode = '42501';
  end if;
  return v_bid;
end $$;

create or replace function public.customer_summary(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.customers;
begin
  perform app.require_customer_access(p_customer);
  select * into c from public.customers where id = p_customer;
  return jsonb_build_object(
    'id', c.id, 'code', c.code, 'name', c.name, 'phone', c.phone, 'address', c.address,
    'credit_limit', c.credit_limit, 'unlimited_credit', c.unlimited_credit, 'channel', c.channel,
    'price_list', c.price_list, 'regions', c.regions,
    'balance', app.customer_balance(c.id),
    'containers', coalesce((select jsonb_agg(jsonb_build_object('product_id', b.product_id, 'product_name', pr.name,
                                                                'qty', b.qty, 'amount', b.amount))
                              from public.container_balances b join public.products pr on pr.id = b.product_id
                             where b.customer_id = c.id), '[]'::jsonb));
end $$;

create or replace function public.customer_statement(p_customer uuid, p_from date default null, p_to date default null)
returns table(at timestamptz, type text, description text, debit numeric, credit numeric, balance numeric, ref_type text, ref_id uuid)
language plpgsql stable security definer set search_path = public, pg_temp as $$
#variable_conflict use_column
begin
  perform app.require_customer_access(p_customer);
  return query
  with l as (
    select cl.*, sum(cl.amount) over (order by cl.created_at, cl.id) as running
      from public.customer_ledger cl where cl.customer_id = p_customer)
  select l.created_at, l.type,
         case l.type when 'satis' then 'Satış #' || coalesce((select no::text from public.sales where id = l.ref_id), '')
                     when 'tahsilat' then 'Tahsilat'
                     when 'tahsilat_iptal' then 'Tahsilat iptali'
                     when 'iade' then 'İade #' || coalesce((select no::text from public.returns where id = l.ref_id), '')
                     when 'iptal' then 'Satış iptali #' || coalesce((select no::text from public.sales where id = l.ref_id), '')
                     when 'depozito_mahsup' then 'Depozito iadesi (mahsup)'
                     when 'acilis' then 'Açılış bakiyesi' else l.type end,
         case when l.amount > 0 then l.amount end, case when l.amount < 0 then -l.amount end,
         l.running, l.ref_type, l.ref_id
    from l
   where (p_from is null or app.local_date(l.created_at) >= p_from) and (p_to is null or app.local_date(l.created_at) <= p_to)
   order by l.created_at, l.id;
end $$;

-- ---------------------------------------------------------------------------
-- 8) Kullanıcı yönetimi: kullanıcı adı, bağlı müşteri (bayi), ilk girişte şifre değiştirme
-- ---------------------------------------------------------------------------
drop function if exists public.add_member(uuid, uuid, public.member_role, text);
create or replace function public.add_member(p_business uuid, p_user uuid, p_role public.member_role, p_name text,
                                             p_customer uuid default null, p_username text default null,
                                             p_must_change boolean default false)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    perform app.require_role(p_business, 'yonetici');
  end if;
  if p_role = 'bayi' and (p_customer is null or not exists (select 1 from public.customers where id = p_customer and business_id = p_business)) then
    raise exception 'Bayi kullanıcısı bir bayi müşteri kartına bağlanmalıdır' using errcode = '22023';
  end if;
  insert into public.memberships(business_id, user_id, role, display_name, customer_id, username, must_change_password)
  values (p_business, p_user, p_role, trim(p_name), case when p_role = 'bayi' then p_customer end,
          nullif(lower(trim(p_username)), ''), p_must_change)
  on conflict (business_id, user_id) do update
    set role = excluded.role, display_name = excluded.display_name, active = true,
        customer_id = excluded.customer_id, username = coalesce(excluded.username, public.memberships.username),
        must_change_password = excluded.must_change_password
  returning id into v_id;
  return v_id;
end $$;

drop function if exists public.update_member(uuid, public.member_role, text, boolean);
create or replace function public.update_member(p_membership uuid, p_role public.member_role, p_name text, p_active boolean,
                                                p_customer uuid default null)
returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid;
begin
  select business_id into v_bid from public.memberships where id = p_membership;
  if v_bid is null then raise exception 'Kullanıcı bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici');
  if p_role = 'bayi' and p_customer is null then
    select customer_id into p_customer from public.memberships where id = p_membership;
    if p_customer is null then raise exception 'Bayi kullanıcısı bir bayi müşteri kartına bağlanmalıdır' using errcode = '22023'; end if;
  end if;
  update public.memberships set role = p_role, display_name = trim(p_name), active = p_active,
         customer_id = case when p_role = 'bayi' then p_customer end
   where id = p_membership;
end $$;

-- Şifre değiştirildi (ilk giriş zorunluluğunu kaldırır)
create or replace function public.password_changed() returns void
language sql security definer set search_path = public, pg_temp as $$
  update public.memberships set must_change_password = false where user_id = auth.uid() and must_change_password;
$$;

-- Yönetici bir kullanıcıya yeni geçici şifre verdiğinde (şifreyi sunucu service_role ile ayarlar)
create or replace function public.require_password_change(p_membership uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid;
begin
  select business_id into v_bid from public.memberships where id = p_membership;
  if v_bid is null then raise exception 'Kullanıcı bulunamadı' using errcode = 'P0002'; end if;
  if coalesce(auth.role(), '') <> 'service_role' then perform app.require_role(v_bid, 'yonetici'); end if;
  update public.memberships set must_change_password = true where id = p_membership;
end $$;

create or replace function public.my_context() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'business_id', b.id, 'business_name', b.name,
    'location_id', app.default_location(b.id),
    'membership_id', m.id, 'role', m.role, 'display_name', m.display_name,
    'customer_id', m.customer_id, 'must_change_password', m.must_change_password
  ) order by b.name), '[]'::jsonb)
  from public.memberships m join public.businesses b on b.id = m.business_id
  where m.user_id = auth.uid() and m.active
$$;

-- ---------------------------------------------------------------------------
-- 9) Ana sayfa özeti: yeni roller
-- ---------------------------------------------------------------------------
create or replace function public.dashboard(p_business uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_role public.member_role; v_today date := app.local_date(now()); d record; v jsonb; v_cust uuid;
begin
  v_role := app.require_role(p_business, 'yonetici', 'satis', 'depo', 'izleyici', 'bayi');
  v := jsonb_build_object('role', v_role, 'today', v_today);
  if v_role = 'bayi' then
    v_cust := app.my_customer(p_business);
    return v || jsonb_build_object(
      'balance', app.customer_balance(v_cust),
      'open_orders', (select count(*) from public.orders where customer_id = v_cust and status = 'acik'),
      'containers', (select coalesce(sum(qty), 0) from public.container_balances where customer_id = v_cust));
  end if;
  v := v || jsonb_build_object(
    'critical_count', (select count(*) from public.report_stock(p_business) s where s.status = 'kritik' and not s.is_container),
    'negative_count', (select count(*) from public.report_stock(p_business) s where s.status = 'negatif'),
    'orders_today', (select count(*) from public.orders where business_id = p_business and status = 'acik' and delivery_date <= v_today),
    'my_open_orders', (select count(*) from public.orders where business_id = p_business and status = 'acik' and assignee = auth.uid()));
  if v_role in ('yonetici', 'izleyici') then
    select * into d from public.report_daily_sales(p_business, v_today, v_today);
    v := v || jsonb_build_object('sales_count', d.sales_count, 'net_revenue', d.net_revenue, 'cash', d.cash, 'pos', d.pos,
                                 'credit', d.credit, 'deposit', d.deposit, 'gross_profit', d.gross_profit);
  end if;
  if v_role = 'yonetici' then
    v := v || jsonb_build_object(
      'receivables_total', (select coalesce(sum(amount), 0) from public.customer_ledger where business_id = p_business),
      'pending_purchases', (select count(*) from public.purchases where business_id = p_business and status = 'onay_bekliyor'),
      'open_return_requests', (select count(*) from public.return_requests where business_id = p_business and status = 'bekliyor'),
      'unassigned_orders', (select count(*) from public.orders where business_id = p_business and status = 'acik' and assignee is null),
      'offline_limit_alerts', (select count(*) from public.sales where business_id = p_business and offline_limit_exceeded
                                 and app.local_date(created_at) >= v_today - 7),
      'cash_session', public.cash_session_summary(p_business, null));
  end if;
  if v_role in ('satis', 'sevkiyat') then
    v := v || jsonb_build_object(
      'my_sales_count', (select count(*) from public.sales where business_id = p_business and created_by = auth.uid()
                           and status = 'tamamlandi' and app.local_date(sold_at) = v_today),
      'my_sales_total', (select coalesce(sum(grand_total), 0) from public.sales where business_id = p_business and created_by = auth.uid()
                           and status = 'tamamlandi' and app.local_date(sold_at) = v_today));
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- 10) Yetki listesi: RLS politikalarında kullanılan yeni yardımcılar
-- ---------------------------------------------------------------------------
create or replace function app.apply_grants() returns void
language plpgsql as $$
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
                           'app.role_covers(public.member_role, public.member_role[])'] loop
    if to_regprocedure(f) is not null then
      execute format('grant execute on function %s to authenticated', f);
    end if;
  end loop;
end $$;

select app.apply_grants();
