-- 21.10.2026: saha geri bildirimi (0033): sayım önizleme, verilen/alınan kap-ambalaj, sipariş devri kaydı.
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
select 'SONUC: saha 0033 hazir, yon=' || count(*) from information_schema.columns where table_name='purchase_empties' and column_name='direction';
commit;
