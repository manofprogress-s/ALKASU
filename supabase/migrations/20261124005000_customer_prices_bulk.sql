-- ALKASU 0050 — Özel fiyat ekranı: toplu kaydetme ve özel fiyat yetkisi (F-38, F-39, D-113)
-- Kullanıcı (24.11): özel fiyat belirlemek için kullanıcı dostu ekran; bayi ve kurumsal fiyatları piyasaya göre sık
-- güncelleniyor, Hüseyin de özel fiyat girip güncelleyebilsin. Ekran birden çok değişikliği tek seferde kaydeder
-- (hepsi ya da hiçbiri); her değişiklik ayrı ayrı işlem geçmişine yazılır.

-- F-39: kişiye özel "özel fiyat" yetkisi (yönetici her zaman; satış/sevkiyata yönetici verir)
alter table public.memberships add column if not exists can_price boolean not null default false;

create or replace function app.can_price(p_business uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.memberships m
                  where m.business_id = p_business and m.user_id = auth.uid() and m.active
                    and (m.role = 'yonetici' or (m.can_price and m.role in ('satis', 'sevkiyat'))))
$$;

create or replace function public.set_member_price_perm(p_membership uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.memberships;
begin
  select * into m from public.memberships where id = p_membership;
  if m.id is null then raise exception 'Kullanıcı bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(m.business_id, 'yonetici');
  if m.role not in ('satis', 'sevkiyat', 'yonetici') then raise exception 'Bu yetki yalnızca personele verilir' using errcode = '22023'; end if;
  update public.memberships set can_price = coalesce(p_on, false) where id = p_membership;
  perform app.audit(m.business_id, 'yetki_ozel_fiyat', 'memberships', p_membership::text,
                    jsonb_build_object('can_price', m.can_price), jsonb_build_object('can_price', coalesce(p_on, false)));
end $$;

-- Tek fiyat (müşteri kartı): aynı yetki
create or replace function public.set_customer_price(p_customer uuid, p_unit uuid, p_price numeric) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.set_customer_prices(p_customer, jsonb_build_array(jsonb_build_object('unit_id', p_unit, 'price', p_price)));
end $$;

create or replace function public.set_customer_prices(p_customer uuid, p_items jsonb) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid; it jsonb; v_unit uuid; v_price numeric; v_old numeric; v_n int := 0;
begin
  select business_id into v_bid from public.customers where id = p_customer;
  if v_bid is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici', 'satis');
  if not app.can_price(v_bid) then
    raise exception 'Özel fiyatı yalnızca yönetici veya özel fiyat yetkisi olan kişi girebilir (F-39)' using errcode = '42501';
  end if;
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'Geçersiz liste' using errcode = '22023'; end if;
  if jsonb_array_length(p_items) > 500 then raise exception 'Tek seferde en fazla 500 değişiklik' using errcode = '22023'; end if;
  for it in select * from jsonb_array_elements(p_items) loop
    v_unit := (it->>'unit_id')::uuid;
    v_price := case when it->>'price' is null or it->>'price' = '' then null else round((it->>'price')::numeric, 2) end;
    if not exists (select 1 from public.product_units where id = v_unit and business_id = v_bid) then
      raise exception 'Ürün birimi bulunamadı' using errcode = 'P0002';
    end if;
    if v_price is not null and v_price < 0 then raise exception 'Fiyat negatif olamaz' using errcode = '22023'; end if;
    select price into v_old from public.customer_prices where customer_id = p_customer and unit_id = v_unit;
    continue when v_old is not distinct from v_price;
    if v_price is null then
      delete from public.customer_prices where customer_id = p_customer and unit_id = v_unit;
    else
      insert into public.customer_prices(customer_id, unit_id, business_id, price, updated_by)
      values (p_customer, v_unit, v_bid, v_price, auth.uid())
      on conflict (customer_id, unit_id) do update set price = excluded.price, updated_at = now(), updated_by = auth.uid();
    end if;
    perform app.audit(v_bid, 'ozel_fiyat', 'customer_prices', p_customer::text,
                      jsonb_build_object('unit_id', v_unit, 'price', v_old), jsonb_build_object('unit_id', v_unit, 'price', v_price));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

select app.apply_grants();
