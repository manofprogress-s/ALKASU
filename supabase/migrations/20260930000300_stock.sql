-- ALKASU 0003 — Stok çekirdeği, mal kabul, fire, açılış stoğu
-- Kurallar: T-01, T-02, T-03, A-01..A-06, M-02, M-05 · Kararlar: T-007, T-008

create type public.movement_type as enum (
  'acilis', 'satis', 'satis_iptal', 'iade', 'iade_fire', 'mal_kabul', 'mal_kabul_duzeltme',
  'fire', 'sayim_duzeltme', 'bos_kap_giris', 'bos_kap_cikis', 'tedarikci_bos_iade', 'musteri_kap_kaybi'
);

create table public.stock_movements (
  id           bigint generated always as identity primary key,
  business_id  uuid not null references public.businesses(id),
  location_id  uuid not null references public.locations(id),
  product_id   uuid not null references public.products(id),
  qty          integer not null check (qty <> 0),       -- temel birim, + giriş / − çıkış
  type         public.movement_type not null,
  ref_type     text,
  ref_id       uuid,
  note         text,
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index stock_movements_product on public.stock_movements(product_id, created_at desc);
create index stock_movements_ref on public.stock_movements(ref_type, ref_id);
create index stock_movements_business_at on public.stock_movements(business_id, created_at desc);

-- T-01 / T-007: yalnızca app.post_stock yazar
create table public.stock_levels (
  business_id  uuid not null references public.businesses(id),
  location_id  uuid not null references public.locations(id),
  product_id   uuid not null references public.products(id),
  qty          integer not null default 0,
  updated_at   timestamptz not null default now(),
  primary key (location_id, product_id)
);
create index stock_levels_business on public.stock_levels(business_id);

-- Hareket tablosu değiştirilemez (G-04)
create or replace function app.tg_immutable() returns trigger
language plpgsql as $$
begin
  raise exception '% kayıtları değiştirilemez veya silinemez; ters kayıt kullanın (G-04)', tg_table_name
    using errcode = 'P0001';
end $$;
create trigger stock_movements_immutable before update or delete on public.stock_movements
  for each row execute function app.tg_immutable();

create or replace function app.post_stock(
  p_business uuid, p_location uuid, p_product uuid, p_qty integer,
  p_type public.movement_type, p_ref_type text, p_ref_id uuid, p_note text default null
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if p_qty = 0 then return; end if;
  insert into public.stock_movements(business_id, location_id, product_id, qty, type, ref_type, ref_id, note, created_by)
  values (p_business, p_location, p_product, p_qty, p_type, p_ref_type, p_ref_id, p_note, auth.uid());
  insert into public.stock_levels(business_id, location_id, product_id, qty, updated_at)
  values (p_business, p_location, p_product, p_qty, now())
  on conflict (location_id, product_id)
  do update set qty = public.stock_levels.qty + excluded.qty, updated_at = now();
end $$;

-- Ürünün bir birimini doğrular ve çarpanını döner
create or replace function app.unit_factor(p_business uuid, p_product uuid, p_unit uuid) returns integer
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare f integer;
begin
  if p_unit is null then return 1; end if;
  select factor into f from public.product_units
   where id = p_unit and product_id = p_product and business_id = p_business;
  if f is null then raise exception 'Ürün birimi geçersiz' using errcode = '22023'; end if;
  return f;
end $$;

create or replace function app.product_in_business(p_business uuid, p_product uuid) returns public.products
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare r public.products;
begin
  select * into r from public.products where id = p_product and business_id = p_business;
  if r.id is null then raise exception 'Ürün bulunamadı' using errcode = 'P0002'; end if;
  return r;
end $$;

-- ---------------------------------------------------------------------------
-- Mal kabul
-- ---------------------------------------------------------------------------
create table public.purchases (
  id           uuid primary key,                         -- istemci üretir (idempotency)
  business_id  uuid not null references public.businesses(id),
  location_id  uuid not null references public.locations(id),
  no           bigint not null,
  supplier_id  uuid references public.suppliers(id),
  doc_no       text,
  doc_date     date not null default app.local_date(now()),
  status       text not null default 'onay_bekliyor' check (status in ('onay_bekliyor', 'onaylandi')),
  note         text,
  created_by   uuid,
  created_at   timestamptz not null default now(),
  approved_by  uuid,
  approved_at  timestamptz,
  unique (business_id, no)
);
create index purchases_business_at on public.purchases(business_id, created_at desc);

create table public.purchase_items (
  id           uuid primary key default gen_random_uuid(),
  purchase_id  uuid not null references public.purchases(id),
  business_id  uuid not null references public.businesses(id),
  product_id   uuid not null references public.products(id),
  unit_id      uuid not null references public.product_units(id),
  factor       integer not null check (factor >= 1),
  qty          integer not null check (qty >= 0),
  free_qty     integer not null default 0 check (free_qty >= 0),
  base_qty     integer generated always as (qty * factor) stored,
  free_base    integer generated always as (free_qty * factor) stored,
  constraint purchase_items_nonzero check (qty + free_qty > 0)
);
create index purchase_items_purchase on public.purchase_items(purchase_id);

-- 🔒 alış fiyatları
create table public.purchase_item_costs (
  purchase_item_id uuid primary key references public.purchase_items(id),
  business_id      uuid not null references public.businesses(id),
  unit_cost        numeric(14,4) not null check (unit_cost >= 0),  -- alış birimi başına, KDV dahil
  base_unit_cost   numeric(14,4) not null,
  line_total       numeric(14,2) not null
);

create table public.purchase_empties (
  id           uuid primary key default gen_random_uuid(),
  purchase_id  uuid not null references public.purchases(id),
  business_id  uuid not null references public.businesses(id),
  product_id   uuid not null references public.products(id),   -- boş kap ürünü
  qty          integer not null check (qty > 0)
);

create table public.waste_records (
  id           uuid primary key,
  business_id  uuid not null references public.businesses(id),
  location_id  uuid not null references public.locations(id),
  product_id   uuid not null references public.products(id),
  unit_id      uuid references public.product_units(id),
  qty          integer not null check (qty > 0),        -- girilen birimde
  base_qty     integer not null check (base_qty > 0),
  reason       text not null check (reason in ('kirik', 'sizinti', 'skt', 'kayip', 'iade_kusurlu', 'diger')),
  note         text,
  created_by   uuid,
  created_at   timestamptz not null default now()
);
create index waste_records_business_at on public.waste_records(business_id, created_at desc);

alter table public.stock_movements     enable row level security;
alter table public.stock_levels        enable row level security;
alter table public.purchases           enable row level security;
alter table public.purchase_items      enable row level security;
alter table public.purchase_item_costs enable row level security;
alter table public.purchase_empties    enable row level security;
alter table public.waste_records       enable row level security;

create policy stock_mov_select on public.stock_movements for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'depo'));
create policy stock_lvl_select on public.stock_levels for select to authenticated
  using (app.is_member(business_id));
create policy purchases_select on public.purchases for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'depo'));
create policy purchase_items_select on public.purchase_items for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'depo'));
create policy purchase_costs_select on public.purchase_item_costs for select to authenticated
  using (app.is_admin(business_id));
create policy purchase_empties_select on public.purchase_empties for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'depo'));
create policy waste_select on public.waste_records for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'depo'));

-- Onay: M-02 ağırlıklı ortalama
create or replace function app.approve_purchase(p_purchase uuid, p_costs jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  pu   public.purchases;
  it   record;
  c    numeric;
  pr   record;
  v_level integer; v_prior integer; v_old numeric; v_new numeric;
begin
  select * into pu from public.purchases where id = p_purchase for update;
  if pu.status <> 'onay_bekliyor' then
    raise exception 'Bu mal kabul zaten onaylanmış (A-04)' using errcode = 'P0001';
  end if;

  for it in select * from public.purchase_items where purchase_id = p_purchase loop
    select (e->>'unit_cost')::numeric into c
      from jsonb_array_elements(p_costs) e where (e->>'item_id')::uuid = it.id;
    if c is null or c < 0 then
      raise exception 'Tüm kalemler için alış fiyatı girilmelidir' using errcode = '22023';
    end if;
    insert into public.purchase_item_costs(purchase_item_id, business_id, unit_cost, base_unit_cost, line_total)
    values (it.id, pu.business_id, c, round(c / it.factor, 4), round(c * it.qty, 2));
  end loop;

  -- Ürün bazında ortalama maliyet (ürünler sıralı kilitlenir: T-008)
  for pr in
    select i.product_id,
           sum(i.base_qty)::int as recv, sum(i.free_base)::int as free,
           sum(i.base_qty * pc.base_unit_cost) as total_cost
      from public.purchase_items i join public.purchase_item_costs pc on pc.purchase_item_id = i.id
     where i.purchase_id = p_purchase
     group by i.product_id order by i.product_id
  loop
    perform 1 from public.products where id = pr.product_id for update;
    select coalesce(qty, 0) into v_level from public.stock_levels
     where location_id = pu.location_id and product_id = pr.product_id;
    v_prior := coalesce(v_level, 0) - pr.recv - pr.free;        -- mal kabul stoğa zaten girdi (A-02)
    select avg_cost into v_old from public.product_costs where product_id = pr.product_id;
    if v_prior > 0 then
      v_new := (v_prior * coalesce(v_old, 0) + pr.total_cost) / (v_prior + pr.recv + pr.free);
    else
      v_new := pr.total_cost / (pr.recv + pr.free);
    end if;
    perform app.set_avg_cost(pr.product_id, v_new, 'mal_kabul', p_purchase);
  end loop;

  update public.purchases set status = 'onaylandi', approved_by = auth.uid(), approved_at = now()
   where id = p_purchase;
  perform app.audit(pu.business_id, 'mal_kabul_onay', 'purchases', p_purchase::text, null, p_costs);
end $$;

-- RPC: mal kabul
-- p = { id, supplier_id?, doc_no?, doc_date?, note?, items:[{product_id, unit_id, qty, free_qty?, unit_cost?}],
--       empties:[{product_id, qty}] }   unit_cost yalnızca yönetici için; tüm kalemlerde varsa anında onaylanır.
create or replace function public.receive_goods(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role public.member_role := app.require_role(p_business, 'yonetici', 'depo');
  v_id   uuid := (p->>'id')::uuid;
  v_loc  uuid := coalesce(nullif(p->>'location_id', '')::uuid, app.default_location(p_business));
  v_no   bigint;
  it     jsonb;
  pr     public.products;
  f      integer;
  v_item uuid;
  v_costs jsonb := '[]'::jsonb;
  v_all_costed boolean := true;
  e      jsonb;
begin
  if v_id is null then raise exception 'Kayıt kimliği eksik' using errcode = '22023'; end if;
  if exists (select 1 from public.purchases where id = v_id) then
    return (select jsonb_build_object('id', id, 'no', no, 'status', status, 'duplicate', true)
              from public.purchases where id = v_id and business_id = p_business);
  end if;
  if jsonb_array_length(coalesce(p->'items', '[]')) = 0 and jsonb_array_length(coalesce(p->'empties', '[]')) = 0 then
    raise exception 'En az bir kalem girilmelidir' using errcode = '22023';
  end if;
  if nullif(p->>'supplier_id', '') is not null and not exists (
      select 1 from public.suppliers where id = (p->>'supplier_id')::uuid and business_id = p_business) then
    raise exception 'Tedarikçi bulunamadı' using errcode = 'P0002';
  end if;

  v_no := app.next_number(p_business, 'mal_kabul');
  insert into public.purchases(id, business_id, location_id, no, supplier_id, doc_no, doc_date, note, created_by)
  values (v_id, p_business, v_loc, v_no, nullif(p->>'supplier_id', '')::uuid, nullif(trim(p->>'doc_no'), ''),
          coalesce(nullif(p->>'doc_date', '')::date, app.local_date(now())), nullif(trim(p->>'note'), ''), auth.uid());

  for it in select * from jsonb_array_elements(coalesce(p->'items', '[]')) order by value->>'product_id' loop
    pr := app.product_in_business(p_business, (it->>'product_id')::uuid);
    f  := app.unit_factor(p_business, pr.id, (it->>'unit_id')::uuid);
    if coalesce((it->>'qty')::int, 0) < 0 or coalesce((it->>'free_qty')::int, 0) < 0
       or coalesce((it->>'qty')::int, 0) + coalesce((it->>'free_qty')::int, 0) = 0 then
      raise exception 'Miktar geçersiz: %', pr.name using errcode = '22023';
    end if;
    insert into public.purchase_items(purchase_id, business_id, product_id, unit_id, factor, qty, free_qty)
    values (v_id, p_business, pr.id, (it->>'unit_id')::uuid, f, coalesce((it->>'qty')::int, 0), coalesce((it->>'free_qty')::int, 0))
    returning id into v_item;
    perform app.post_stock(p_business, v_loc, pr.id,
                           (coalesce((it->>'qty')::int, 0) + coalesce((it->>'free_qty')::int, 0)) * f,
                           'mal_kabul', 'purchase', v_id);
    if nullif(it->>'unit_cost', '') is null then
      v_all_costed := false;
    else
      v_costs := v_costs || jsonb_build_object('item_id', v_item, 'unit_cost', (it->>'unit_cost')::numeric);
    end if;
  end loop;

  -- A-06: tedarikçiye verilen boş kaplar
  for e in select * from jsonb_array_elements(coalesce(p->'empties', '[]')) loop
    pr := app.product_in_business(p_business, (e->>'product_id')::uuid);
    if not pr.is_container then raise exception 'Yalnızca boş kap ürünleri iade edilebilir' using errcode = '22023'; end if;
    if coalesce((e->>'qty')::int, 0) <= 0 then raise exception 'Boş kap miktarı geçersiz' using errcode = '22023'; end if;
    insert into public.purchase_empties(purchase_id, business_id, product_id, qty)
    values (v_id, p_business, pr.id, (e->>'qty')::int);
    perform app.post_stock(p_business, v_loc, pr.id, -(e->>'qty')::int, 'tedarikci_bos_iade', 'purchase', v_id);
  end loop;

  perform app.audit(p_business, 'mal_kabul', 'purchases', v_id::text, null, p);

  if not exists (select 1 from public.purchase_items where purchase_id = v_id) then
    update public.purchases set status = 'onaylandi', approved_by = auth.uid(), approved_at = now() where id = v_id;
  elsif v_role = 'yonetici' and v_all_costed then
    perform app.approve_purchase(v_id, v_costs);
  end if;

  return (select jsonb_build_object('id', id, 'no', no, 'status', status, 'duplicate', false)
            from public.purchases where id = v_id);
end $$;

-- RPC: alış fiyatı onayı (yönetici)  p_costs = [{item_id, unit_cost}]
create or replace function public.approve_purchase(p_purchase uuid, p_costs jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid;
begin
  select business_id into v_bid from public.purchases where id = p_purchase;
  if v_bid is null then raise exception 'Mal kabul bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici');
  perform app.approve_purchase(p_purchase, p_costs);
end $$;

-- RPC: fire / hasar  p = { id, product_id, unit_id?, qty, reason, note? }
create or replace function public.record_waste(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id  uuid := (p->>'id')::uuid;
  v_loc uuid := coalesce(nullif(p->>'location_id', '')::uuid, app.default_location(p_business));
  pr    public.products;
  f     integer;
begin
  perform app.require_role(p_business, 'yonetici', 'depo');
  if v_id is null then raise exception 'Kayıt kimliği eksik' using errcode = '22023'; end if;
  if exists (select 1 from public.waste_records where id = v_id) then return v_id; end if;
  pr := app.product_in_business(p_business, (p->>'product_id')::uuid);
  f  := app.unit_factor(p_business, pr.id, nullif(p->>'unit_id', '')::uuid);
  if coalesce((p->>'qty')::int, 0) <= 0 then raise exception 'Miktar sıfırdan büyük olmalıdır' using errcode = '22023'; end if;
  if (p->>'reason') = 'iade_kusurlu' then
    raise exception 'Bu neden yalnızca iade işleminde kullanılır' using errcode = '22023';
  end if;
  insert into public.waste_records(id, business_id, location_id, product_id, unit_id, qty, base_qty, reason, note, created_by)
  values (v_id, p_business, v_loc, pr.id, nullif(p->>'unit_id', '')::uuid, (p->>'qty')::int, (p->>'qty')::int * f,
          p->>'reason', nullif(trim(p->>'note'), ''), auth.uid());
  perform app.post_stock(p_business, v_loc, pr.id, -((p->>'qty')::int * f), 'fire', 'waste', v_id, p->>'reason');
  perform app.audit(p_business, 'fire', 'waste_records', v_id::text, null, p);
  return v_id;
end $$;

-- RPC: stok tutarlılık kontrolü (T-007) — seviye ile hareket toplamı farklı olan ürünler
create or replace function public.stock_consistency_check(p_business uuid)
returns table(product_id uuid, level_qty integer, movement_qty bigint)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.require_role(p_business, 'yonetici');
  return query
  select coalesce(l.product_id, m.product_id), l.qty, m.total
    from (select sl.product_id, sl.location_id, sl.qty from public.stock_levels sl where sl.business_id = p_business) l
    full join (select sm.product_id, sm.location_id, sum(sm.qty) as total from public.stock_movements sm
                where sm.business_id = p_business group by sm.product_id, sm.location_id) m
      on m.product_id = l.product_id and m.location_id = l.location_id
   where coalesce(l.qty, 0) <> coalesce(m.total, 0);
end $$;

select app.apply_grants();
