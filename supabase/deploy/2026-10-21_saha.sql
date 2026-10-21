-- 21.10.2026: saha geri bildirimi (0033) + sayımda çift onay (0034).
begin;
-- ALKASU 0033 — Saha geri bildirimi (21.10): sayım onayı görünürlüğü, mal kabulde verilen/alınan kap-ambalaj,
-- sipariş devri kaydı. Kurallar: BUSINESS_RULES T-04, A-07, S-25 · Karar: D-092

-- ---------------------------------------------------------------------------
-- 1) Sayım: onay öncesi fark önizlemesi (stoğa dokunmaz). Onay (approve_stock_count) zaten satır kilidi +
--    durum kontrolüyle tek kez uygulanır; ikinci onay "Sayım zaten kapanmış" hatası verir.
-- ---------------------------------------------------------------------------
create or replace function public.stock_count_preview(p_count uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.stock_counts;
begin
  select * into c from public.stock_counts where id = p_count;
  if c.id is null then raise exception 'Sayım bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(c.business_id, 'yonetici', 'depo');
  return jsonb_build_object(
    'status', c.status,
    'lines', coalesce((
      select jsonb_agg(jsonb_build_object('product_id', l.product_id, 'name', pr.name, 'unit', pr.base_unit_name,
                                          'system', l.snapshot_qty + m.moved, 'counted', l.counted_qty,
                                          'diff', l.counted_qty - (l.snapshot_qty + m.moved)) order by pr.name)
        from public.stock_count_lines l
        join public.products pr on pr.id = l.product_id
        cross join lateral (select coalesce(sum(s.qty), 0)::int as moved from public.stock_movements s
                             where s.product_id = l.product_id and s.location_id = c.location_id and s.id > c.snapshot_movement_id) m
       where l.count_id = p_count and l.counted_qty is not null), '[]'::jsonb));
end $$;

-- ---------------------------------------------------------------------------
-- 2) Mal kabul: tedarikçiye verilen / tedarikçiden alınan kap-ambalaj (A-07)
-- ---------------------------------------------------------------------------
alter table public.purchase_empties add column if not exists direction text not null default 'verilen'
  check (direction in ('verilen', 'alinan'));

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

  -- A-06 / A-07: tedarikçiye verilen veya tedarikçiden alınan kap / ambalaj (boş damacana, viyol, palet …)
  --   direction 'verilen' → stok azalır, 'alinan' → stok artar. Yalnızca "kap / ambalaj" ürünleri (satılmaz).
  for e in select * from jsonb_array_elements(coalesce(p->'empties', '[]')) loop
    pr := app.product_in_business(p_business, (e->>'product_id')::uuid);
    if not pr.is_container then
      raise exception 'Yalnızca kap / ambalaj ürünleri (boş damacana, viyol, palet) bu bölüme eklenebilir: %', pr.name using errcode = '22023';
    end if;
    if coalesce((e->>'qty')::int, 0) <= 0 then raise exception 'Miktar geçersiz: %', pr.name using errcode = '22023'; end if;
    if coalesce(e->>'direction', 'verilen') not in ('verilen', 'alinan') then raise exception 'Yön geçersiz' using errcode = '22023'; end if;
    insert into public.purchase_empties(purchase_id, business_id, product_id, qty, direction)
    values (v_id, p_business, pr.id, (e->>'qty')::int, coalesce(e->>'direction', 'verilen'));
    if coalesce(e->>'direction', 'verilen') = 'alinan' then
      perform app.post_stock(p_business, v_loc, pr.id, (e->>'qty')::int, 'bos_kap_giris', 'purchase', v_id, 'tedarikçiden alındı');
    else
      perform app.post_stock(p_business, v_loc, pr.id, -(e->>'qty')::int, 'tedarikci_bos_iade', 'purchase', v_id);
    end if;
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

-- ---------------------------------------------------------------------------
-- 3) Sipariş sorumlusu devri: yalnızca siparişin sorumlusu değişir, müşteri kartı değişmez (S-25). Kayıt altına alınır.
-- ---------------------------------------------------------------------------
create or replace function public.assign_order(p_order uuid, p_assignee uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare o public.orders;
begin
  select * into o from public.orders where id = p_order for update;
  if o.id is null then raise exception 'Sipariş bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(o.business_id, 'yonetici', 'satis');
  if o.status not in ('acik', 'onay_bekliyor') then raise exception 'Kapanmış sipariş değiştirilemez' using errcode = 'P0001'; end if;
  if p_assignee is not null and not exists (select 1 from public.memberships where business_id = o.business_id
                                             and user_id = p_assignee and active and role in ('yonetici', 'satis', 'sevkiyat')) then
    raise exception 'Atanan kişi geçersiz' using errcode = '22023';
  end if;
  update public.orders set assignee = p_assignee,
         dealer_customer_id = case when p_assignee is not null then null else dealer_customer_id end
   where id = p_order;
  perform app.audit(o.business_id, 'siparis_devir', 'orders', p_order::text,
                    jsonb_build_object('assignee', o.assignee, 'dealer', o.dealer_customer_id),
                    jsonb_build_object('assignee', p_assignee));
end $$;

select app.apply_grants();
-- ALKASU 0034 — Sayım: onaya gönderim + iki yönetici onayı + fark raporu
-- Kural: BUSINESS_RULES T-04/6 · Karar: D-093 (kullanıcı isteği 21.10: "Ayhan + Enes, 2 onaydan geçtikten sonra sisteme yansısın")
-- Akış: acik (sayılıyor) → onayda (sayan "Onaya gönder" dedi, girişler kilitli) → 2 farklı yönetici onayı → onaylandi (stoğa işlendi)
--       Yönetici düzeltme için geri gönderebilir (onayda → acik, verilen onaylar silinir) veya iptal edebilir.
-- İşletmede 2'den az aktif yönetici varsa gereken onay sayısı aktif yönetici sayısıdır (en az 1).

alter table public.stock_counts drop constraint if exists stock_counts_status_check;
alter table public.stock_counts add constraint stock_counts_status_check check (status in ('acik', 'onayda', 'onaylandi', 'iptal'));
drop index if exists public.stock_counts_one_open;
create unique index stock_counts_one_open on public.stock_counts(location_id) where status in ('acik', 'onayda');
alter table public.stock_counts add column if not exists submitted_by uuid;
alter table public.stock_counts add column if not exists submitted_at timestamptz;
alter table public.stock_counts add column if not exists summary jsonb;     -- onaya gönderimdeki fark raporu

create table if not exists public.stock_count_approvals (
  count_id    uuid not null references public.stock_counts(id),
  business_id uuid not null references public.businesses(id),
  user_id     uuid not null,
  approved_at timestamptz not null default now(),
  primary key (count_id, user_id)
);
alter table public.stock_count_approvals enable row level security;
drop policy if exists stock_count_approvals_select on public.stock_count_approvals;
create policy stock_count_approvals_select on public.stock_count_approvals for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'depo'));

create or replace function app.count_approvals_required(p_business uuid) returns int
language sql stable security definer set search_path = public, pg_temp as $$
  select greatest(1, least(2, (select count(*) from public.memberships
                                where business_id = p_business and active and role = 'yonetici')::int))
$$;

-- Satır bazında fark: önce = anlık görüntü + sayım sırasındaki hareketler; fark = sayılan − önce
create or replace function app.stock_count_diff(p_count uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object('product_id', l.product_id, 'name', pr.name, 'unit', pr.base_unit_name,
                                               'system', l.snapshot_qty + m.moved, 'counted', l.counted_qty,
                                               'diff', l.counted_qty - (l.snapshot_qty + m.moved)) order by pr.name), '[]'::jsonb)
    from public.stock_count_lines l
    join public.stock_counts c on c.id = l.count_id
    join public.products pr on pr.id = l.product_id
    cross join lateral (select coalesce(sum(s.qty), 0)::int as moved from public.stock_movements s
                         where s.product_id = l.product_id and s.location_id = c.location_id and s.id > c.snapshot_movement_id) m
   where l.count_id = p_count and l.counted_qty is not null
$$;

-- Önizleme / rapor: durum, onaylar, güncel farklar, gönderimdeki özet
create or replace function public.stock_count_preview(p_count uuid) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare c public.stock_counts;
begin
  select * into c from public.stock_counts where id = p_count;
  if c.id is null then raise exception 'Sayım bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(c.business_id, 'yonetici', 'depo');
  return jsonb_build_object(
    'status', c.status, 'no', c.no,
    'required', app.count_approvals_required(c.business_id),
    'submitted_at', c.submitted_at,
    'submitted_by', (select display_name from public.memberships where business_id = c.business_id and user_id = c.submitted_by limit 1),
    'approvals', coalesce((select jsonb_agg(jsonb_build_object('user_id', a.user_id, 'at', a.approved_at,
                                    'name', (select display_name from public.memberships m where m.business_id = c.business_id and m.user_id = a.user_id limit 1))
                                    order by a.approved_at)
                             from public.stock_count_approvals a where a.count_id = p_count), '[]'::jsonb),
    'approvers', coalesce((select jsonb_agg(jsonb_build_object('user_id', m.user_id, 'name', m.display_name) order by m.display_name)
                             from public.memberships m where m.business_id = c.business_id and m.active and m.role = 'yonetici'), '[]'::jsonb),
    'summary', c.summary,
    'lines', app.stock_count_diff(p_count));
end $$;

-- Sayan kişi (depo/sevkiyat/yönetici) onaya gönderir: girişler kilitlenir, fark raporu saklanır
create or replace function public.submit_stock_count(p_count uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.stock_counts; v_lines jsonb;
begin
  select * into c from public.stock_counts where id = p_count for update;
  if c.id is null then raise exception 'Sayım bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(c.business_id, 'yonetici', 'depo');
  if c.status <> 'acik' then raise exception 'Sayım zaten onaya gönderilmiş veya kapanmış' using errcode = 'P0001'; end if;
  v_lines := app.stock_count_diff(p_count);
  if jsonb_array_length(v_lines) = 0 then raise exception 'Önce en az bir ürünün sayılan miktarını girin' using errcode = 'P0001'; end if;
  update public.stock_counts set status = 'onayda', submitted_by = auth.uid(), submitted_at = now(), summary = v_lines where id = p_count;
  perform app.audit(c.business_id, 'sayim_onaya_gonder', 'stock_counts', p_count::text, null,
                    jsonb_build_object('urun', jsonb_array_length(v_lines),
                                       'farkli', (select count(*) from jsonb_array_elements(v_lines) x where (x->>'diff')::int <> 0)));
  return jsonb_build_object('status', 'onayda', 'required', app.count_approvals_required(c.business_id), 'lines', v_lines);
end $$;

-- Yönetici onayı. Gereken sayıda farklı yönetici onaylayınca farklar stoğa işlenir (tek kez).
drop function if exists public.approve_stock_count(uuid);
create or replace function public.approve_stock_count(p_count uuid) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.stock_counts; l record; v_moved int; v_diff int; v_n int := 0; v_total int := 0; v_have int; v_need int;
begin
  select * into c from public.stock_counts where id = p_count for update;
  if c.id is null then raise exception 'Sayım bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(c.business_id, 'yonetici');
  if c.status = 'acik' then raise exception 'Sayım henüz onaya gönderilmedi' using errcode = 'P0001'; end if;
  if c.status <> 'onayda' then raise exception 'Sayım zaten kapanmış' using errcode = 'P0001'; end if;
  if exists (select 1 from public.stock_count_approvals where count_id = p_count and user_id = auth.uid()) then
    raise exception 'Bu sayımı zaten onayladınız; diğer yöneticinin onayı bekleniyor' using errcode = 'P0001';
  end if;
  insert into public.stock_count_approvals(count_id, business_id, user_id) values (p_count, c.business_id, auth.uid());
  perform app.audit(c.business_id, 'sayim_onay_ver', 'stock_counts', p_count::text, null, null);
  select count(*) into v_have from public.stock_count_approvals where count_id = p_count;
  v_need := app.count_approvals_required(c.business_id);
  if v_have < v_need then
    return jsonb_build_object('applied', false, 'approvals', v_have, 'required', v_need);
  end if;

  for l in select * from public.stock_count_lines where count_id = p_count and counted_qty is not null order by product_id loop
    select coalesce(sum(qty), 0) into v_moved from public.stock_movements
     where product_id = l.product_id and location_id = c.location_id and id > c.snapshot_movement_id;
    v_diff := l.counted_qty - (l.snapshot_qty + v_moved);
    update public.stock_count_lines set moved_during = v_moved, diff = v_diff where count_id = p_count and product_id = l.product_id;
    if v_diff <> 0 then
      perform app.post_stock(c.business_id, c.location_id, l.product_id, v_diff, 'sayim_duzeltme', 'stock_count', p_count);
      v_n := v_n + 1; v_total := v_total + v_diff;
    end if;
  end loop;
  update public.stock_counts set status = 'onaylandi', decided_by = auth.uid(), decided_at = now() where id = p_count;
  perform app.audit(c.business_id, 'sayim_onay', 'stock_counts', p_count::text, null,
                    jsonb_build_object('adjusted_products', v_n, 'net_diff', v_total, 'approvals', v_have));
  return jsonb_build_object('applied', true, 'approvals', v_have, 'required', v_need, 'adjusted_products', v_n, 'net_diff', v_total);
end $$;

-- Yönetici: düzeltme için geri gönderir (verilen onaylar silinir; girişler tekrar açılır)
create or replace function public.reopen_stock_count(p_count uuid, p_note text default null) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.stock_counts;
begin
  select * into c from public.stock_counts where id = p_count for update;
  if c.id is null then raise exception 'Sayım bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(c.business_id, 'yonetici');
  if c.status <> 'onayda' then raise exception 'Yalnızca onaydaki sayım geri gönderilebilir' using errcode = 'P0001'; end if;
  delete from public.stock_count_approvals where count_id = p_count;
  update public.stock_counts set status = 'acik', submitted_by = null, submitted_at = null, summary = null where id = p_count;
  perform app.audit(c.business_id, 'sayim_geri_gonder', 'stock_counts', p_count::text, null, jsonb_build_object('not', p_note));
end $$;

-- İptal: sayılırken veya onaydayken
create or replace function public.cancel_stock_count(p_count uuid) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.stock_counts;
begin
  select * into c from public.stock_counts where id = p_count for update;
  if c.id is null then raise exception 'Sayım bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(c.business_id, 'yonetici');
  if c.status not in ('acik', 'onayda') then raise exception 'Sayım zaten kapanmış' using errcode = 'P0001'; end if;
  update public.stock_counts set status = 'iptal', decided_by = auth.uid(), decided_at = now() where id = p_count;
  perform app.audit(c.business_id, 'sayim_iptal', 'stock_counts', p_count::text, null, null);
end $$;

-- Açık sayım kontrolü onaydaki sayımı da kapsar (start_stock_count unique index ile korunur; mesaj için)
create or replace function app.tg_count_one_open_msg() returns trigger language plpgsql as $$
begin
  if exists (select 1 from public.stock_counts where location_id = new.location_id and status = 'onayda') then
    raise exception 'Onay bekleyen bir sayım var; önce onaylanması veya iptal edilmesi gerekir' using errcode = 'P0001';
  end if;
  return new;
end $$;
drop trigger if exists stock_counts_one_open_msg on public.stock_counts;
create trigger stock_counts_one_open_msg before insert on public.stock_counts
  for each row execute function app.tg_count_one_open_msg();

select app.apply_grants();
select 'SONUC: saha hazir, gereken onay=' || app.count_approvals_required((select business_id from public.stock_counts order by started_at desc limit 1)) || ', yon=' || (select count(*) from information_schema.columns where table_name='purchase_empties' and column_name='direction');
commit;
