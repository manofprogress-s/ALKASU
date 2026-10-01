-- ALKASU 0004 — Müşteri, veresiye, kasa oturumu, satış, depozito, iptal, iade, tahsilat
-- Kurallar: S-01..S-08, F-04..F-07, M-04, D-03..D-08, V-01..V-05, I-01..I-07, K-02, K-07, K-08, C-02, C-03

-- ---------------------------------------------------------------------------
-- Müşteriler
-- ---------------------------------------------------------------------------
create table public.customers (
  id               uuid primary key default gen_random_uuid(),
  business_id      uuid not null references public.businesses(id),
  code             text not null,
  name             text not null check (length(trim(name)) > 0),
  phone            text,
  address          text,
  tax_no           text,
  credit_limit     numeric(14,2) not null default 0 check (credit_limit >= 0),
  unlimited_credit boolean not null default false,
  note             text,
  active           boolean not null default true,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
create unique index customers_code on public.customers(business_id, lower(code));
create index customers_name on public.customers(business_id, lower(name));
create trigger customers_touch before update on public.customers for each row execute function app.touch_updated_at();
create trigger customers_audit after insert or update on public.customers for each row execute function audit.tg_row();

-- Veresiye cari hareketleri: amount > 0 müşterinin borcu artar
create table public.customer_ledger (
  id           bigint generated always as identity primary key,
  business_id  uuid not null references public.businesses(id),
  customer_id  uuid not null references public.customers(id),
  type         text not null check (type in ('acilis','satis','tahsilat','tahsilat_iptal','iade','iptal','depozito_mahsup')),
  amount       numeric(14,2) not null check (amount <> 0),
  ref_type     text,
  ref_id       uuid,
  note         text,
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index customer_ledger_customer on public.customer_ledger(customer_id, created_at);
create trigger customer_ledger_immutable before update or delete on public.customer_ledger
  for each row execute function app.tg_immutable();

-- Müşterideki kaplar ve ödenmiş depozito. customer_id null = kayıtsız (perakende) müşteri havuzu (D-06)
create table public.container_ledger (
  id           bigint generated always as identity primary key,
  business_id  uuid not null references public.businesses(id),
  customer_id  uuid references public.customers(id),
  product_id   uuid not null references public.products(id),   -- depozitolu (dolu) ürün
  qty          integer not null check (qty <> 0),               -- + müşterideki kap artar
  amount       numeric(14,2) not null default 0,                -- + müşteriden alınan depozito
  type         text not null check (type in ('acilis','satis','iade','iptal','kayip')),
  ref_type     text,
  ref_id       uuid,
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index container_ledger_customer on public.container_ledger(business_id, customer_id, product_id);
create trigger container_ledger_immutable before update or delete on public.container_ledger
  for each row execute function app.tg_immutable();

-- ---------------------------------------------------------------------------
-- Kasa oturumu (gün) ve kasa hareketleri
-- ---------------------------------------------------------------------------
create table public.cash_sessions (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses(id),
  location_id   uuid not null references public.locations(id),
  no            bigint not null,
  status        text not null default 'acik' check (status in ('acik', 'kapali')),
  opened_at     timestamptz not null default now(),
  opened_by     uuid,
  opening_cash  numeric(14,2) not null default 0,
  closed_at     timestamptz,
  closed_by     uuid,
  expected_cash numeric(14,2),
  counted_cash  numeric(14,2),
  cash_diff     numeric(14,2),
  diff_note     text,
  pos_expected  numeric(14,2),
  pos_slip      numeric(14,2),
  pos_diff      numeric(14,2),
  carry_over    numeric(14,2),
  unique (business_id, no)
);
create unique index cash_sessions_one_open on public.cash_sessions(location_id) where status = 'acik';

create table public.cash_movements (
  id           bigint generated always as identity primary key,
  business_id  uuid not null references public.businesses(id),
  session_id   uuid not null references public.cash_sessions(id),
  type         text not null check (type in ('satis','satis_iptal','iade','tahsilat','tahsilat_iptal',
                                             'depozito_iade','gider','giris','cikis','gun_sonu_teslim','duzeltme')),
  amount       numeric(14,2) not null check (amount <> 0),   -- + kasaya giren
  ref_type     text,
  ref_id       uuid,
  note         text,
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index cash_movements_session on public.cash_movements(session_id);
create trigger cash_movements_immutable before update or delete on public.cash_movements
  for each row execute function app.tg_immutable();

-- K-06: kapalı oturum değiştirilemez
create or replace function app.tg_session_closed_lock() returns trigger
language plpgsql as $$
begin
  if old.status = 'kapali' then
    raise exception 'Kapanmış kasa günü değiştirilemez (K-06)' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger cash_sessions_lock before update on public.cash_sessions
  for each row execute function app.tg_session_closed_lock();

create or replace function app.tg_cash_mov_session_open() returns trigger
language plpgsql as $$
begin
  if (select status from public.cash_sessions where id = new.session_id) <> 'acik' then
    raise exception 'Kapanmış kasa gününe hareket yazılamaz (K-06)' using errcode = 'P0001';
  end if;
  return new;
end $$;
create trigger cash_movements_open before insert on public.cash_movements
  for each row execute function app.tg_cash_mov_session_open();

-- K-02: açık kasa gününü getir, yoksa aç (tek seferde: advisory lock, T-008)
create or replace function app.ensure_session(p_business uuid, p_location uuid) returns public.cash_sessions
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.cash_sessions; v_open numeric;
begin
  perform pg_advisory_xact_lock(hashtext('cash_session:' || p_location::text));
  select * into s from public.cash_sessions where location_id = p_location and status = 'acik';
  if s.id is not null then return s; end if;
  select carry_over into v_open from public.cash_sessions
   where location_id = p_location and status = 'kapali' order by closed_at desc limit 1;
  insert into public.cash_sessions(business_id, location_id, no, opening_cash, opened_by)
  values (p_business, p_location, app.next_number(p_business, 'kasa'), coalesce(v_open, 0), auth.uid())
  returning * into s;
  return s;
end $$;

create or replace function app.post_cash(p_business uuid, p_session uuid, p_type text, p_amount numeric,
                                         p_ref_type text, p_ref uuid, p_note text default null) returns void
language sql security definer set search_path = public, pg_temp as $$
  insert into public.cash_movements(business_id, session_id, type, amount, ref_type, ref_id, note, created_by)
  select p_business, p_session, p_type, p_amount, p_ref_type, p_ref, p_note, auth.uid()
  where p_amount <> 0;
$$;

create or replace function app.customer_balance(p_customer uuid) returns numeric
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(amount), 0) from public.customer_ledger where customer_id = p_customer
$$;

-- Kap bakiyesi (qty, amount); p_customer null = perakende havuzu
create or replace function app.container_balance(p_business uuid, p_customer uuid, p_product uuid,
                                                 out qty integer, out amount numeric)
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(sum(c.qty), 0)::int, coalesce(sum(c.amount), 0)
    from public.container_ledger c
   where c.business_id = p_business and c.product_id = p_product
     and c.customer_id is not distinct from p_customer
$$;

-- Kap iadesinde geri verilecek depozito: ödenen ortalama üzerinden
create or replace function app.deposit_refund_amount(p_business uuid, p_customer uuid, p_product uuid, p_qty integer)
returns numeric
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare b record;
begin
  select * into b from app.container_balance(p_business, p_customer, p_product);
  if b.qty < p_qty then
    raise exception 'Müşterinin elinde bu kadar kap görünmüyor (elinde: %, iade: %)', b.qty, p_qty using errcode = 'P0001';
  end if;
  if b.qty = p_qty then return b.amount; end if;
  return round(b.amount * p_qty / b.qty, 2);
end $$;

-- ---------------------------------------------------------------------------
-- Satış
-- ---------------------------------------------------------------------------
create table public.sales (
  id                uuid primary key,                     -- istemci üretir (S-02)
  business_id       uuid not null references public.businesses(id),
  location_id       uuid not null references public.locations(id),
  no                bigint not null,
  session_id        uuid not null references public.cash_sessions(id),
  customer_id       uuid references public.customers(id),
  status            text not null default 'tamamlandi' check (status in ('tamamlandi', 'iptal')),
  goods_gross       numeric(14,2) not null,
  discount_total    numeric(14,2) not null default 0,
  goods_net         numeric(14,2) not null,
  deposit_total     numeric(14,2) not null default 0,
  grand_total       numeric(14,2) not null,
  cash_given        numeric(14,2),
  change_given      numeric(14,2),
  sold_at           timestamptz not null,
  created_at        timestamptz not null default now(),
  created_by        uuid,
  offline           boolean not null default false,
  late_sync         boolean not null default false,
  limit_override    boolean not null default false,
  offline_limit_exceeded boolean not null default false,
  note              text,
  cancelled_at      timestamptz,
  cancelled_by      uuid,
  cancel_reason     text,
  unique (business_id, no)
);
create index sales_business_sold on public.sales(business_id, sold_at desc);
create index sales_session on public.sales(session_id);
create index sales_customer on public.sales(customer_id);
create index sales_created_by on public.sales(created_by, sold_at desc);

create table public.sale_items (
  id                  uuid primary key default gen_random_uuid(),
  sale_id             uuid not null references public.sales(id),
  business_id         uuid not null references public.businesses(id),
  line_no             smallint not null,
  product_id          uuid not null references public.products(id),
  unit_id             uuid not null references public.product_units(id),
  unit_name           text not null,
  factor              integer not null,
  qty                 integer not null check (qty > 0),
  base_qty            integer not null check (base_qty > 0),
  unit_price          numeric(14,2) not null check (unit_price >= 0),
  line_gross          numeric(14,2) not null,
  line_discount       numeric(14,2) not null default 0,
  bill_discount_share numeric(14,2) not null default 0,
  line_net            numeric(14,2) not null,
  vat_rate            smallint not null
);
create index sale_items_sale on public.sale_items(sale_id);
create index sale_items_product on public.sale_items(product_id);

-- 🔒 satış anındaki maliyet (F-04, M-04)
create table public.sale_item_costs (
  sale_item_id uuid primary key references public.sale_items(id),
  business_id  uuid not null references public.businesses(id),
  unit_cost    numeric(14,4) not null,   -- temel birim başına
  total_cost   numeric(14,2) not null,
  has_cost     boolean not null
);

create table public.sale_deposits (
  id              uuid primary key default gen_random_uuid(),
  sale_id         uuid not null references public.sales(id),
  business_id     uuid not null references public.businesses(id),
  product_id      uuid not null references public.products(id),
  sold_qty        integer not null,     -- temel birimde satılan dolu
  empty_returned  integer not null check (empty_returned >= 0),
  net_containers  integer not null,     -- + müşteride kalan
  amount          numeric(14,2) not null  -- + alınan, − iade edilen depozito
);
create index sale_deposits_sale on public.sale_deposits(sale_id);

create table public.sale_payments (
  id           uuid primary key default gen_random_uuid(),
  sale_id      uuid not null references public.sales(id),
  business_id  uuid not null references public.businesses(id),
  method       text not null check (method in ('nakit', 'pos', 'veresiye')),
  amount       numeric(14,2) not null check (amount > 0)
);
create index sale_payments_sale on public.sale_payments(sale_id);

-- ---------------------------------------------------------------------------
-- İade
-- ---------------------------------------------------------------------------
create table public.returns (
  id            uuid primary key,
  business_id   uuid not null references public.businesses(id),
  location_id   uuid not null references public.locations(id),
  no            bigint not null,
  sale_id       uuid not null references public.sales(id),
  session_id    uuid not null references public.cash_sessions(id),
  reason        text not null,
  total_refund  numeric(14,2) not null,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  unique (business_id, no)
);
create index returns_sale on public.returns(sale_id);

create table public.return_items (
  id             uuid primary key default gen_random_uuid(),
  return_id      uuid not null references public.returns(id),
  business_id    uuid not null references public.businesses(id),
  sale_item_id   uuid not null references public.sale_items(id),
  product_id     uuid not null references public.products(id),
  qty            integer not null check (qty > 0),     -- satış biriminde
  base_qty       integer not null check (base_qty > 0),
  condition      text not null check (condition in ('saglam', 'kusurlu')),
  refund_amount  numeric(14,2) not null
);
create index return_items_sale_item on public.return_items(sale_item_id);

create table public.return_item_costs (
  return_item_id uuid primary key references public.return_items(id),
  business_id    uuid not null references public.businesses(id),
  unit_cost      numeric(14,4) not null,
  total_cost     numeric(14,2) not null
);

create table public.return_payments (
  id           uuid primary key default gen_random_uuid(),
  return_id    uuid not null references public.returns(id),
  business_id  uuid not null references public.businesses(id),
  method       text not null check (method in ('nakit', 'pos', 'veresiye')),
  amount       numeric(14,2) not null check (amount > 0)
);

create table public.return_requests (
  id            uuid primary key,
  business_id   uuid not null references public.businesses(id),
  sale_id       uuid not null references public.sales(id),
  items         jsonb not null,
  reason        text not null,
  status        text not null default 'bekliyor' check (status in ('bekliyor', 'onaylandi', 'reddedildi')),
  requested_by  uuid,
  requested_at  timestamptz not null default now(),
  decided_by    uuid,
  decided_at    timestamptz,
  decision_note text,
  return_id     uuid references public.returns(id)
);
create index return_requests_open on public.return_requests(business_id) where status = 'bekliyor';

-- ---------------------------------------------------------------------------
-- Tahsilat ve depozito iadesi
-- ---------------------------------------------------------------------------
create table public.customer_payments (
  id            uuid primary key,
  business_id   uuid not null references public.businesses(id),
  customer_id   uuid not null references public.customers(id),
  session_id    uuid not null references public.cash_sessions(id),
  method        text not null check (method in ('nakit', 'pos')),
  amount        numeric(14,2) not null check (amount > 0),
  note          text,
  status        text not null default 'gecerli' check (status in ('gecerli', 'iptal')),
  created_by    uuid,
  created_at    timestamptz not null default now(),
  cancelled_by  uuid,
  cancelled_at  timestamptz,
  cancel_reason text,
  cancel_session_id uuid references public.cash_sessions(id)
);
create index customer_payments_customer on public.customer_payments(customer_id, created_at desc);

create table public.container_returns (
  id             uuid primary key,
  business_id    uuid not null references public.businesses(id),
  location_id    uuid not null references public.locations(id),
  session_id     uuid references public.cash_sessions(id),
  customer_id    uuid references public.customers(id),
  product_id     uuid not null references public.products(id),
  qty            integer not null check (qty > 0),
  kind           text not null check (kind in ('iade', 'kayip')),
  refund_method  text check (refund_method in ('nakit', 'veresiye')),
  amount         numeric(14,2) not null,
  note           text,
  created_by     uuid,
  created_at     timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Görünümler (RLS'e tabi: security_invoker)
-- ---------------------------------------------------------------------------
create view public.customer_balances with (security_invoker = true) as
  select c.id as customer_id, c.business_id, coalesce(sum(l.amount), 0)::numeric(14,2) as balance
    from public.customers c left join public.customer_ledger l on l.customer_id = c.id
   group by c.id, c.business_id;

create view public.container_balances with (security_invoker = true) as
  select business_id, customer_id, product_id, sum(qty)::int as qty, sum(amount)::numeric(14,2) as amount
    from public.container_ledger group by business_id, customer_id, product_id
  having sum(qty) <> 0 or sum(amount) <> 0;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.customers         enable row level security;
alter table public.customer_ledger   enable row level security;
alter table public.container_ledger  enable row level security;
alter table public.cash_sessions     enable row level security;
alter table public.cash_movements    enable row level security;
alter table public.sales             enable row level security;
alter table public.sale_items        enable row level security;
alter table public.sale_item_costs   enable row level security;
alter table public.sale_deposits     enable row level security;
alter table public.sale_payments     enable row level security;
alter table public.returns           enable row level security;
alter table public.return_items      enable row level security;
alter table public.return_item_costs enable row level security;
alter table public.return_payments   enable row level security;
alter table public.return_requests   enable row level security;
alter table public.customer_payments enable row level security;
alter table public.container_returns enable row level security;

create policy customers_select on public.customers for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis'));
create policy customer_ledger_select on public.customer_ledger for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis'));
create policy container_ledger_select on public.container_ledger for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis'));
create policy cash_sessions_select on public.cash_sessions for select to authenticated
  using (app.is_admin(business_id));
create policy cash_movements_select on public.cash_movements for select to authenticated
  using (app.is_admin(business_id));

-- S-08: satış personeli yalnızca kendi satışlarını görür
create or replace function app.can_see_sale(p_sale uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from public.sales s where s.id = p_sale
      and (app.is_admin(s.business_id) or (app.has_role(s.business_id, 'satis') and s.created_by = auth.uid()))
  )
$$;

create policy sales_select on public.sales for select to authenticated
  using (app.is_admin(business_id) or (app.has_role(business_id, 'satis') and created_by = auth.uid()));
create policy sale_items_select on public.sale_items for select to authenticated using (app.can_see_sale(sale_id));
create policy sale_deposits_select on public.sale_deposits for select to authenticated using (app.can_see_sale(sale_id));
create policy sale_payments_select on public.sale_payments for select to authenticated using (app.can_see_sale(sale_id));
create policy sale_item_costs_select on public.sale_item_costs for select to authenticated using (app.is_admin(business_id));
create policy returns_select on public.returns for select to authenticated using (app.can_see_sale(sale_id));
create policy return_items_select on public.return_items for select to authenticated
  using (app.can_see_sale((select r.sale_id from public.returns r where r.id = return_id)));
create policy return_payments_select on public.return_payments for select to authenticated
  using (app.can_see_sale((select r.sale_id from public.returns r where r.id = return_id)));
create policy return_item_costs_select on public.return_item_costs for select to authenticated using (app.is_admin(business_id));
create policy return_requests_select on public.return_requests for select to authenticated
  using (app.is_admin(business_id) or requested_by = auth.uid());
create policy customer_payments_select on public.customer_payments for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis'));
create policy container_returns_select on public.container_returns for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis'));

-- ---------------------------------------------------------------------------
-- RPC: müşteri kartı. Kredi limitini yalnızca yönetici belirler.
-- p = { id?, code?, name, phone?, address?, tax_no?, note?, credit_limit?, unlimited_credit?, active? }
-- ---------------------------------------------------------------------------
create or replace function public.upsert_customer(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role public.member_role := app.require_role(p_business, 'yonetici', 'satis');
  v_id   uuid := nullif(p->>'id', '')::uuid;
  v_code text := nullif(trim(p->>'code'), '');
  v_old  public.customers;
begin
  if coalesce(trim(p->>'name'), '') = '' then raise exception 'Müşteri adı zorunludur' using errcode = '22023'; end if;
  if v_id is null then
    if v_code is null then v_code := 'M' || lpad(app.next_number(p_business, 'musteri')::text, 5, '0'); end if;
    if exists (select 1 from public.customers where business_id = p_business and lower(code) = lower(v_code)) then
      raise exception 'Bu müşteri kodu zaten kullanılıyor: %', v_code using errcode = '23505';
    end if;
    insert into public.customers(business_id, code, name, phone, address, tax_no, note, credit_limit, unlimited_credit)
    values (p_business, v_code, trim(p->>'name'), nullif(trim(p->>'phone'), ''), nullif(trim(p->>'address'), ''),
            nullif(trim(p->>'tax_no'), ''), nullif(trim(p->>'note'), ''),
            case when v_role = 'yonetici' then coalesce(nullif(p->>'credit_limit', '')::numeric, 0) else 0 end,
            case when v_role = 'yonetici' then coalesce((p->>'unlimited_credit')::boolean, false) else false end)
    returning id into v_id;
  else
    select * into v_old from public.customers where id = v_id and business_id = p_business for update;
    if v_old.id is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
    if v_code is not null and exists (select 1 from public.customers where business_id = p_business
                                      and lower(code) = lower(v_code) and id <> v_id) then
      raise exception 'Bu müşteri kodu zaten kullanılıyor: %', v_code using errcode = '23505';
    end if;
    update public.customers set
      code = coalesce(v_code, code), name = trim(p->>'name'),
      phone = nullif(trim(p->>'phone'), ''), address = nullif(trim(p->>'address'), ''),
      tax_no = nullif(trim(p->>'tax_no'), ''), note = nullif(trim(p->>'note'), ''),
      credit_limit = case when v_role = 'yonetici' then coalesce(nullif(p->>'credit_limit', '')::numeric, credit_limit) else credit_limit end,
      unlimited_credit = case when v_role = 'yonetici' then coalesce((p->>'unlimited_credit')::boolean, unlimited_credit) else unlimited_credit end,
      active = case when v_role = 'yonetici' then coalesce((p->>'active')::boolean, active) else active end
    where id = v_id;
  end if;
  return v_id;
end $$;

-- Satış ekranı için müşteri özeti (Y-03)
create or replace function public.customer_summary(p_customer uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.customers;
begin
  select * into c from public.customers where id = p_customer;
  if c.id is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(c.business_id, 'yonetici', 'satis');
  return jsonb_build_object(
    'id', c.id, 'code', c.code, 'name', c.name, 'phone', c.phone, 'address', c.address,
    'credit_limit', c.credit_limit, 'unlimited_credit', c.unlimited_credit,
    'balance', app.customer_balance(c.id),
    'containers', coalesce((select jsonb_agg(jsonb_build_object('product_id', b.product_id, 'product_name', pr.name,
                                                                'qty', b.qty, 'amount', b.amount))
                              from public.container_balances b join public.products pr on pr.id = b.product_id
                             where b.customer_id = c.id), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- RPC: satışı tamamla (S-01: tek işlem, S-02: idempotent)
-- p = {
--   id: uuid, customer_id?, client_created_at?, offline?: bool, note?,
--   items: [{ product_id, unit_id, qty, unit_price, line_discount? }],
--   bill_discount?: number,
--   deposits?: [{ product_id, empty_returned }],   -- depozitolu ürünlerde getirilen boş (varsayılan: satılan adet)
--   payments: [{ method: nakit|pos|veresiye, amount }],
--   cash_given?: number, limit_override?: bool
-- }
-- ---------------------------------------------------------------------------
create or replace function public.complete_sale(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role    public.member_role := app.require_role(p_business, 'yonetici', 'satis');
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

    if v_role <> 'yonetici' then
      -- Satış personeli fiyatı değiştiremez; çevrimdışında satış anındaki fiyat da kabul edilir (C-02)
      if u.price is null and app.unit_price_at(u.id, v_client) is null then
        raise exception 'Bu birim için satış fiyatı tanımlı değil: % %', pr.name, u.name using errcode = 'P0001';
      end if;
      if v_price is distinct from u.price
         and not (v_offline and v_price = app.unit_price_at(u.id, v_client)) then
        raise exception 'Fiyat güncel değil: % % (güncel: %)', pr.name, u.name, u.price using errcode = 'P0001';
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
  if v_role <> 'yonetici' and (v_ldisc_total + v_bill) > round(v_gross * v_set.max_discount_pct_satis / 100, 2) then
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
      if v_offline then
        v_offline_limit := true;                                           -- C-03
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

-- ---------------------------------------------------------------------------
-- RPC: satış iptali (I-01) — yalnızca yönetici, kasa günü açıkken, iadesi yoksa
-- ---------------------------------------------------------------------------
create or replace function public.cancel_sale(p_sale uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.sales; r record;
begin
  select * into s from public.sales where id = p_sale for update;
  if s.id is null then raise exception 'Satış bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(s.business_id, 'yonetici');
  if coalesce(trim(p_reason), '') = '' then raise exception 'İptal nedeni zorunludur (I-05)' using errcode = '22023'; end if;
  if s.status <> 'tamamlandi' then raise exception 'Satış zaten iptal edilmiş' using errcode = 'P0001'; end if;
  if (select status from public.cash_sessions where id = s.session_id) <> 'acik' then
    raise exception 'Kasa günü kapandığı için satış iptal edilemez; iade işlemi yapın (I-01)' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.returns where sale_id = p_sale) then
    raise exception 'İadesi yapılmış satış iptal edilemez' using errcode = 'P0001';
  end if;

  for r in select product_id, location_id, sum(qty)::int as q from public.stock_movements
            where ref_type = 'sale' and ref_id = p_sale group by product_id, location_id order by product_id loop
    perform app.post_stock(s.business_id, r.location_id, r.product_id, -r.q, 'satis_iptal', 'sale_cancel', p_sale);
  end loop;
  insert into public.container_ledger(business_id, customer_id, product_id, qty, amount, type, ref_type, ref_id, created_by)
  select business_id, customer_id, product_id, -qty, -amount, 'iptal', 'sale_cancel', p_sale, auth.uid()
    from public.container_ledger where ref_type = 'sale' and ref_id = p_sale;
  insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
  select business_id, customer_id, 'iptal', -amount, 'sale_cancel', p_sale, auth.uid()
    from public.customer_ledger where ref_type = 'sale' and ref_id = p_sale;
  insert into public.cash_movements(business_id, session_id, type, amount, ref_type, ref_id, created_by)
  select business_id, session_id, 'satis_iptal', -amount, 'sale_cancel', p_sale, auth.uid()
    from public.cash_movements where ref_type = 'sale' and ref_id = p_sale;

  update public.sales set status = 'iptal', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = trim(p_reason)
   where id = p_sale;
  perform app.audit(s.business_id, 'satis_iptal', 'sales', p_sale::text,
                    jsonb_build_object('status', 'tamamlandi'), jsonb_build_object('status', 'iptal', 'reason', p_reason));
end $$;

-- ---------------------------------------------------------------------------
-- RPC: iade (I-02..I-07) — yönetici
-- p = { id, sale_id, reason, request_id?,
--       items: [{ sale_item_id, qty, condition: saglam|kusurlu }],
--       refunds?: [{ method: nakit|pos|veresiye, amount }] }   -- verilmezse I-04 dağılımı
-- ---------------------------------------------------------------------------
create or replace function public.create_return(p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id    uuid := (p->>'id')::uuid;
  s       public.sales;
  v_sess  public.cash_sessions;
  v_no    bigint;
  it      jsonb;
  si      public.sale_items;
  v_prev  int;
  v_prev_amt numeric;
  v_qty   int;
  v_amt   numeric;
  v_total numeric := 0;
  v_ri    uuid;
  v_cost  numeric;
  v_left  numeric;
  v_avail numeric;
  m       text;
  v_cash numeric := 0; v_pos numeric := 0; v_credit numeric := 0;
begin
  if v_id is null then raise exception 'İade kimliği eksik' using errcode = '22023'; end if;
  if exists (select 1 from public.returns where id = v_id) then
    return (select jsonb_build_object('id', id, 'no', no, 'total_refund', total_refund, 'duplicate', true)
              from public.returns where id = v_id);
  end if;
  select * into s from public.sales where id = (p->>'sale_id')::uuid for update;
  if s.id is null then raise exception 'Satış bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(s.business_id, 'yonetici');
  if s.status <> 'tamamlandi' then raise exception 'İptal edilmiş satış iade edilemez' using errcode = 'P0001'; end if;
  if coalesce(trim(p->>'reason'), '') = '' then raise exception 'İade nedeni zorunludur (I-05)' using errcode = '22023'; end if;
  if jsonb_array_length(coalesce(p->'items', '[]')) = 0 then raise exception 'İade edilecek kalem seçilmedi' using errcode = '22023'; end if;

  v_sess := app.ensure_session(s.business_id, s.location_id);     -- I-06: bugünün kasası
  v_no := app.next_number(s.business_id, 'iade');
  insert into public.returns(id, business_id, location_id, no, sale_id, session_id, reason, total_refund, created_by)
  values (v_id, s.business_id, s.location_id, v_no, s.id, v_sess.id, trim(p->>'reason'), 0, auth.uid());

  for it in select * from jsonb_array_elements(p->'items') loop
    select * into si from public.sale_items where id = (it->>'sale_item_id')::uuid and sale_id = s.id;
    if si.id is null then raise exception 'Satış kalemi bulunamadı' using errcode = 'P0002'; end if;
    v_qty := (it->>'qty')::int;
    if v_qty is null or v_qty <= 0 then raise exception 'İade miktarı geçersiz' using errcode = '22023'; end if;
    if coalesce(it->>'condition', '') not in ('saglam', 'kusurlu') then
      raise exception 'Ürün durumu seçilmelidir: sağlam / kusurlu (I-03)' using errcode = '22023';
    end if;
    select coalesce(sum(qty), 0), coalesce(sum(refund_amount), 0) into v_prev, v_prev_amt
      from public.return_items where sale_item_id = si.id;
    if v_qty > si.qty - v_prev then
      raise exception 'İade miktarı kalan miktarı aşıyor (satılan: %, önceden iade: %) (I-02)', si.qty, v_prev using errcode = 'P0001';
    end if;
    -- Kalanın tamamı iade ediliyorsa kuruş farkı kalmasın
    if v_qty = si.qty - v_prev then v_amt := si.line_net - v_prev_amt;
    else v_amt := round(si.line_net * v_qty / si.qty, 2); end if;

    insert into public.return_items(return_id, business_id, sale_item_id, product_id, qty, base_qty, condition, refund_amount)
    values (v_id, s.business_id, si.id, si.product_id, v_qty, v_qty * si.factor, it->>'condition', v_amt)
    returning id into v_ri;
    select unit_cost into v_cost from public.sale_item_costs where sale_item_id = si.id;
    insert into public.return_item_costs(return_item_id, business_id, unit_cost, total_cost)
    values (v_ri, s.business_id, coalesce(v_cost, 0), round(coalesce(v_cost, 0) * v_qty * si.factor, 2));

    perform app.post_stock(s.business_id, s.location_id, si.product_id, v_qty * si.factor, 'iade', 'return', v_id);
    if it->>'condition' = 'kusurlu' then
      perform app.post_stock(s.business_id, s.location_id, si.product_id, -(v_qty * si.factor), 'iade_fire', 'return', v_id);
      insert into public.waste_records(id, business_id, location_id, product_id, unit_id, qty, base_qty, reason, note, created_by)
      values (gen_random_uuid(), s.business_id, s.location_id, si.product_id, si.unit_id, v_qty, v_qty * si.factor,
              'iade_kusurlu', 'İade no ' || v_no, auth.uid());
    end if;
    v_total := v_total + v_amt;
  end loop;

  -- Para iadesi dağılımı
  if p ? 'refunds' and jsonb_array_length(p->'refunds') > 0 then
    for it in select * from jsonb_array_elements(p->'refunds') loop
      v_amt := round((it->>'amount')::numeric, 2);
      if v_amt is null or v_amt <= 0 then raise exception 'İade tutarı geçersiz' using errcode = '22023'; end if;
      case it->>'method'
        when 'nakit' then v_cash := v_cash + v_amt;
        when 'pos' then v_pos := v_pos + v_amt;
        when 'veresiye' then v_credit := v_credit + v_amt;
        else raise exception 'Ödeme şekli geçersiz' using errcode = '22023';
      end case;
    end loop;
    if v_cash + v_pos + v_credit <> v_total then
      raise exception 'İade ödemeleri toplamı (%) iade tutarına (%) eşit değil', v_cash + v_pos + v_credit, v_total using errcode = '22023';
    end if;
  else
    -- I-04: önce veresiye, sonra POS, sonra nakit (orijinal ödemeden önceki iadeler düşülerek)
    v_left := v_total;
    foreach m in array array['veresiye', 'pos'] loop
      select coalesce(sum(amount), 0) into v_avail from public.sale_payments where sale_id = s.id and method = m;
      v_avail := v_avail - coalesce((select sum(rp.amount) from public.return_payments rp join public.returns r on r.id = rp.return_id
                                      where r.sale_id = s.id and rp.method = m), 0);
      v_amt := greatest(least(v_left, v_avail), 0);
      if m = 'veresiye' then v_credit := v_amt; else v_pos := v_amt; end if;
      v_left := v_left - v_amt;
    end loop;
    v_cash := v_left;
  end if;

  if v_credit > 0 and s.customer_id is null then
    raise exception 'Müşterisiz satışta veresiyeye iade yapılamaz' using errcode = '22023';
  end if;
  if v_cash > 0 then insert into public.return_payments(return_id, business_id, method, amount) values (v_id, s.business_id, 'nakit', v_cash); end if;
  if v_pos > 0 then insert into public.return_payments(return_id, business_id, method, amount) values (v_id, s.business_id, 'pos', v_pos); end if;
  if v_credit > 0 then
    insert into public.return_payments(return_id, business_id, method, amount) values (v_id, s.business_id, 'veresiye', v_credit);
    insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
    values (s.business_id, s.customer_id, 'iade', -v_credit, 'return', v_id, auth.uid());
  end if;
  perform app.post_cash(s.business_id, v_sess.id, 'iade', -v_cash, 'return', v_id);

  update public.returns set total_refund = v_total where id = v_id;
  if nullif(p->>'request_id', '') is not null then
    update public.return_requests set status = 'onaylandi', decided_by = auth.uid(), decided_at = now(), return_id = v_id
     where id = (p->>'request_id')::uuid and status = 'bekliyor' and sale_id = s.id;
  end if;
  perform app.audit(s.business_id, 'iade', 'returns', v_id::text, null, p || jsonb_build_object('total', v_total));
  return jsonb_build_object('id', v_id, 'no', v_no, 'total_refund', v_total, 'duplicate', false,
                            'refunds', jsonb_build_object('nakit', v_cash, 'pos', v_pos, 'veresiye', v_credit));
end $$;

-- Satış personeli iade talebi (I-05)
create or replace function public.request_return(p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare s public.sales; v_id uuid := (p->>'id')::uuid;
begin
  select * into s from public.sales where id = (p->>'sale_id')::uuid;
  if s.id is null then raise exception 'Satış bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(s.business_id, 'yonetici', 'satis');
  if not app.can_see_sale(s.id) then raise exception 'Bu satış için talep oluşturamazsınız' using errcode = '42501'; end if;
  if coalesce(trim(p->>'reason'), '') = '' then raise exception 'Neden zorunludur' using errcode = '22023'; end if;
  insert into public.return_requests(id, business_id, sale_id, items, reason, requested_by)
  values (v_id, s.business_id, s.id, coalesce(p->'items', '[]'), trim(p->>'reason'), auth.uid())
  on conflict (id) do nothing;
  return v_id;
end $$;

create or replace function public.reject_return_request(p_request uuid, p_note text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid;
begin
  select business_id into v_bid from public.return_requests where id = p_request;
  if v_bid is null then raise exception 'Talep bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici');
  update public.return_requests set status = 'reddedildi', decided_by = auth.uid(), decided_at = now(), decision_note = p_note
   where id = p_request and status = 'bekliyor';
end $$;

-- ---------------------------------------------------------------------------
-- RPC: veresiye tahsilatı (V-04, V-05)  p = { id, customer_id, method: nakit|pos, amount, note? }
-- ---------------------------------------------------------------------------
create or replace function public.record_customer_payment(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id   uuid := (p->>'id')::uuid;
  v_amt  numeric := round((p->>'amount')::numeric, 2);
  v_sess public.cash_sessions;
  c      public.customers;
begin
  perform app.require_role(p_business, 'yonetici', 'satis');
  if v_id is null then raise exception 'Kayıt kimliği eksik' using errcode = '22023'; end if;
  if exists (select 1 from public.customer_payments where id = v_id) then return v_id; end if;
  select * into c from public.customers where id = (p->>'customer_id')::uuid and business_id = p_business;
  if c.id is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'Tutar sıfırdan büyük olmalıdır' using errcode = '22023'; end if;
  if coalesce(p->>'method', '') not in ('nakit', 'pos') then raise exception 'Tahsilat nakit veya POS olmalıdır' using errcode = '22023'; end if;
  v_sess := app.ensure_session(p_business, app.default_location(p_business));
  insert into public.customer_payments(id, business_id, customer_id, session_id, method, amount, note, created_by)
  values (v_id, p_business, c.id, v_sess.id, p->>'method', v_amt, nullif(trim(p->>'note'), ''), auth.uid());
  insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
  values (p_business, c.id, 'tahsilat', -v_amt, 'customer_payment', v_id, auth.uid());
  if p->>'method' = 'nakit' then
    perform app.post_cash(p_business, v_sess.id, 'tahsilat', v_amt, 'customer_payment', v_id);
  end if;
  perform app.audit(p_business, 'tahsilat', 'customer_payments', v_id::text, null, p);
  return v_id;
end $$;

create or replace function public.cancel_customer_payment(p_payment uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare cp public.customer_payments; v_sess public.cash_sessions;
begin
  select * into cp from public.customer_payments where id = p_payment for update;
  if cp.id is null then raise exception 'Tahsilat bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(cp.business_id, 'yonetici');
  if cp.status <> 'gecerli' then raise exception 'Tahsilat zaten iptal edilmiş' using errcode = 'P0001'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'İptal nedeni zorunludur' using errcode = '22023'; end if;
  v_sess := app.ensure_session(cp.business_id, app.default_location(cp.business_id));
  insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
  values (cp.business_id, cp.customer_id, 'tahsilat_iptal', cp.amount, 'customer_payment_cancel', cp.id, auth.uid());
  if cp.method = 'nakit' then
    perform app.post_cash(cp.business_id, v_sess.id, 'tahsilat_iptal', -cp.amount, 'customer_payment_cancel', cp.id);
  end if;
  update public.customer_payments set status = 'iptal', cancelled_by = auth.uid(), cancelled_at = now(),
         cancel_reason = trim(p_reason), cancel_session_id = v_sess.id where id = cp.id;
  perform app.audit(cp.business_id, 'tahsilat_iptal', 'customer_payments', cp.id::text, null, jsonb_build_object('reason', p_reason));
end $$;

-- ---------------------------------------------------------------------------
-- RPC: depozito iadesi / kap kaybı (D-05, D-06, D-08)
-- p = { id, customer_id?, product_id (dolu ürün), qty, kind: iade|kayip, refund_method?: nakit|veresiye, note? }
-- ---------------------------------------------------------------------------
create or replace function public.container_return(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role public.member_role := app.require_role(p_business, 'yonetici', 'satis');
  v_id   uuid := (p->>'id')::uuid;
  v_loc  uuid := app.default_location(p_business);
  v_kind text := coalesce(p->>'kind', 'iade');
  v_qty  int := (p->>'qty')::int;
  v_cust uuid := nullif(p->>'customer_id', '')::uuid;
  v_meth text := coalesce(p->>'refund_method', 'nakit');
  pr     public.products;
  v_amt  numeric;
  v_sess public.cash_sessions;
begin
  if v_id is null then raise exception 'Kayıt kimliği eksik' using errcode = '22023'; end if;
  if exists (select 1 from public.container_returns where id = v_id) then
    return (select jsonb_build_object('id', id, 'amount', amount, 'duplicate', true) from public.container_returns where id = v_id);
  end if;
  pr := app.product_in_business(p_business, (p->>'product_id')::uuid);
  if pr.deposit_amount is null then raise exception 'Bu ürün depozitolu değil' using errcode = '22023'; end if;
  if v_qty is null or v_qty <= 0 then raise exception 'Kap adedi geçersiz' using errcode = '22023'; end if;
  if v_kind not in ('iade', 'kayip') then raise exception 'İşlem türü geçersiz' using errcode = '22023'; end if;
  if v_kind = 'kayip' and v_role <> 'yonetici' then raise exception 'Kap kaybını yalnızca yönetici işleyebilir' using errcode = '42501'; end if;
  if v_cust is not null and not exists (select 1 from public.customers where id = v_cust and business_id = p_business) then
    raise exception 'Müşteri bulunamadı' using errcode = 'P0002';
  end if;
  if v_kind = 'iade' and v_meth = 'veresiye' and v_cust is null then
    raise exception 'Veresiyeden mahsup için müşteri seçilmelidir' using errcode = '22023';
  end if;
  if v_meth not in ('nakit', 'veresiye') then raise exception 'İade şekli geçersiz' using errcode = '22023'; end if;

  v_amt := app.deposit_refund_amount(p_business, v_cust, pr.id, v_qty);
  v_sess := app.ensure_session(p_business, v_loc);

  insert into public.container_returns(id, business_id, location_id, session_id, customer_id, product_id, qty, kind,
                                       refund_method, amount, note, created_by)
  values (v_id, p_business, v_loc, v_sess.id, v_cust, pr.id, v_qty, v_kind,
          case when v_kind = 'iade' then v_meth end, v_amt, nullif(trim(p->>'note'), ''), auth.uid());
  insert into public.container_ledger(business_id, customer_id, product_id, qty, amount, type, ref_type, ref_id, created_by)
  values (p_business, v_cust, pr.id, -v_qty, -v_amt, v_kind, 'container_return', v_id, auth.uid());

  if v_kind = 'iade' then
    perform app.post_stock(p_business, v_loc, pr.empty_product_id, v_qty, 'bos_kap_giris', 'container_return', v_id);
    if v_meth = 'nakit' then
      perform app.post_cash(p_business, v_sess.id, 'depozito_iade', -v_amt, 'container_return', v_id);
    elsif v_amt > 0 then
      insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
      values (p_business, v_cust, 'depozito_mahsup', -v_amt, 'container_return', v_id, auth.uid());
    end if;
  end if;
  perform app.audit(p_business, 'kap_' || v_kind, 'container_returns', v_id::text, null, p || jsonb_build_object('amount', v_amt));
  return jsonb_build_object('id', v_id, 'amount', v_amt, 'duplicate', false);
end $$;

select app.apply_grants();
