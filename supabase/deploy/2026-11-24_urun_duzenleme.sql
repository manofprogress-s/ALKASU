-- 24.11 (D-118): ürün kartı düzenleme yetkisi (0053) + Hüseyin Topaloğlu'na verilmesi
-- Kullanıcı: "Stok kartından ürünün fiyat/isim/birim bilgisini değiştirme yetkisi — Hüseyin ile bana."
-- Enes (yönetici) zaten yetkili; Hüseyin (sevkiyat) için memberships.can_product açılır.
begin;

-- 0053: ürün kartı düzenleme yetkisi (kullanıcı 24.11, D-118, F-42)
-- Stok kartından ürüne geçip ad/birim/fiyat değiştirme: yönetici her zaman; satış/sevkiyat personeline yönetici verir.
alter table public.memberships add column if not exists can_product boolean not null default false;

create or replace function app.can_product(p_business uuid) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.memberships m
                  where m.business_id = p_business and m.user_id = auth.uid() and m.active
                    and (m.role = 'yonetici' or (m.can_product and m.role in ('satis', 'sevkiyat'))))
$$;

create or replace function public.set_member_product_perm(p_membership uuid, p_on boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare m public.memberships;
begin
  select * into m from public.memberships where id = p_membership;
  if m.id is null then raise exception 'Kullanıcı bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(m.business_id, 'yonetici');
  if m.role not in ('satis', 'sevkiyat', 'yonetici') then raise exception 'Bu yetki yalnızca personele verilir' using errcode = '22023'; end if;
  update public.memberships set can_product = coalesce(p_on, false) where id = p_membership;
  perform app.audit(m.business_id, 'yetki_urun', 'memberships', p_membership::text,
                    jsonb_build_object('can_product', m.can_product), jsonb_build_object('can_product', coalesce(p_on, false)));
end $$;

CREATE OR REPLACE FUNCTION public.upsert_product(p_business uuid, p jsonb)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare
  v_id      uuid := nullif(p->>'id', '')::uuid;
  v_old     public.products;
  v_base    uuid;
  v_unit    jsonb;
  v_uid     uuid;
  v_ex      public.product_units;
  v_keep    uuid[] := '{}';
  v_bc      jsonb;
  v_empty   public.products;
  v_is_cont boolean := coalesce((p->>'is_container')::boolean, false);
  v_dep     numeric := nullif(p->>'deposit_amount', '')::numeric;
  v_emp_id  uuid := nullif(p->>'empty_product_id', '')::uuid;
begin
  -- Yönetici veya ürün düzenleme yetkilisi (F-42, D-118)
  if not app.can_product(p_business) then
    raise exception 'Ürün düzenleme yetkiniz yok' using errcode = '42501';
  end if;

  if coalesce(trim(p->>'code'), '') = '' or coalesce(trim(p->>'name'), '') = '' then
    raise exception 'Ürün kodu ve adı zorunludur' using errcode = '22023';
  end if;
  if v_emp_id is not null then
    select * into v_empty from public.products where id = v_emp_id and business_id = p_business;
    if v_empty.id is null or not v_empty.is_container then
      raise exception 'Bağlı boş kap ürünü geçersiz; "boş kap" olarak tanımlı bir ürün seçin' using errcode = '22023';
    end if;
  end if;
  if exists (select 1 from public.products where business_id = p_business
              and lower(code) = lower(trim(p->>'code')) and id is distinct from v_id) then
    raise exception 'Bu ürün kodu zaten kullanılıyor: %', p->>'code' using errcode = '23505';
  end if;
  if v_dep is not null and v_emp_id is null then
    raise exception 'Depozitolu ürün için boş kap ürünü seçilmelidir (D-01)' using errcode = '22023';
  end if;

  if v_id is null then
    insert into public.products(business_id, code, name, brand_id, category_id, base_unit_name, vat_rate,
                                critical_level, is_container, deposit_amount, empty_product_id, active)
    values (p_business, trim(p->>'code'), trim(p->>'name'),
            nullif(p->>'brand_id', '')::uuid, nullif(p->>'category_id', '')::uuid,
            coalesce(nullif(trim(p->>'base_unit_name'), ''), 'Adet'),
            coalesce((p->>'vat_rate')::smallint, 1),
            nullif(p->>'critical_level', '')::int, v_is_cont, v_dep, v_emp_id,
            coalesce((p->>'active')::boolean, true))
    returning id into v_id;
    insert into public.product_units(business_id, product_id, name, factor, is_base, sort)
    values (p_business, v_id, coalesce(nullif(trim(p->>'base_unit_name'), ''), 'Adet'), 1, true, 0)
    returning id into v_base;
    insert into public.product_costs(product_id, business_id) values (v_id, p_business);
  else
    select * into v_old from public.products where id = v_id and business_id = p_business for update;
    if v_old.id is null then raise exception 'Ürün bulunamadı' using errcode = 'P0002'; end if;
    update public.products set
      code = trim(p->>'code'), name = trim(p->>'name'),
      brand_id = nullif(p->>'brand_id', '')::uuid, category_id = nullif(p->>'category_id', '')::uuid,
      base_unit_name = coalesce(nullif(trim(p->>'base_unit_name'), ''), base_unit_name),
      vat_rate = coalesce((p->>'vat_rate')::smallint, vat_rate),
      critical_level = nullif(p->>'critical_level', '')::int,
      is_container = v_is_cont, deposit_amount = v_dep, empty_product_id = v_emp_id,
      active = coalesce((p->>'active')::boolean, active)
    where id = v_id;
    select id into v_base from public.product_units where product_id = v_id and is_base;
    update public.product_units set name = (select base_unit_name from public.products where id = v_id)
     where id = v_base;
  end if;

  -- Temel birim fiyatı
  if p ? 'base_price' then
    perform app.set_unit_price(v_base, case when v_is_cont then null else nullif(p->>'base_price', '')::numeric end);
  end if;
  v_keep := array[v_base];

  -- Ek birimler
  if p ? 'units' then
    for v_unit in select * from jsonb_array_elements(coalesce(p->'units', '[]'::jsonb)) loop
      v_uid := nullif(v_unit->>'id', '')::uuid;
      if coalesce((v_unit->>'factor')::int, 0) < 2 then
        raise exception 'Ek birim çarpanı 1''den büyük tam sayı olmalıdır (B-02): %', v_unit->>'name' using errcode = '22023';
      end if;
      if v_uid is null then
        -- Aynı ad + çarpanla aktif bir birim varsa onu kullan
        select * into v_ex from public.product_units
         where product_id = v_id and not is_base and active and lower(name) = lower(trim(v_unit->>'name'));
        if v_ex.id is not null and v_ex.factor <> (v_unit->>'factor')::int then
          -- B-06: eski birimi pasife al, yenisini oluştur
          update public.product_units set active = false where id = v_ex.id;
          v_ex := null;
        end if;
        if v_ex.id is null then
          insert into public.product_units(business_id, product_id, name, factor, sort, active)
          values (p_business, v_id, trim(v_unit->>'name'), (v_unit->>'factor')::int,
                  coalesce((v_unit->>'sort')::smallint, 1), coalesce((v_unit->>'active')::boolean, true))
          returning id into v_uid;
        else
          v_uid := v_ex.id;
        end if;
      else
        update public.product_units set name = trim(v_unit->>'name'),
               factor = (v_unit->>'factor')::int,
               active = coalesce((v_unit->>'active')::boolean, true)
         where id = v_uid and product_id = v_id and not is_base;
        if not found then raise exception 'Birim bulunamadı' using errcode = 'P0002'; end if;
      end if;
      perform app.set_unit_price(v_uid, case when v_is_cont then null else nullif(v_unit->>'price', '')::numeric end);
      if coalesce((v_unit->>'active')::boolean, true) then v_keep := v_keep || v_uid; end if;
    end loop;
    update public.product_units set active = false
     where product_id = v_id and not is_base and active and not (id = any(v_keep));
    if (select count(*) from public.product_units where product_id = v_id and not is_base and active) > 2 then
      raise exception 'Bir ürünün en fazla 2 aktif ek birimi olabilir (B-02)' using errcode = '22023';
    end if;
  end if;

  -- Barkodlar
  if p ? 'barcodes' then
    delete from public.product_barcodes where product_id = v_id;
    for v_bc in select * from jsonb_array_elements(coalesce(p->'barcodes', '[]'::jsonb)) loop
      begin
        insert into public.product_barcodes(business_id, product_id, unit_id, barcode)
        values (p_business, v_id,
                coalesce(nullif(v_bc->>'unit_id', '')::uuid,
                         (select id from public.product_units where product_id = v_id and active
                            and lower(name) = lower(v_bc->>'unit_name') limit 1)),
                trim(v_bc->>'barcode'));
      exception when unique_violation then
        raise exception 'Barkod başka bir üründe kayıtlı: %', v_bc->>'barcode' using errcode = '23505';
      end;
    end loop;
  end if;

  return v_id;
end $function$
;

-- Aktif/pasif: özel fiyat veya ürün düzenleme yetkilisi
create or replace function public.set_product_active(p_product uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare p public.products;
begin
  select * into p from public.products where id = p_product;
  if p.id is null then raise exception 'Ürün bulunamadı' using errcode = 'P0002'; end if;
  if not (app.can_price(p.business_id) or app.can_product(p.business_id)) then
    raise exception 'Ürünü aktif/pasif yapmak için özel fiyat yetkisi gerekir' using errcode = '42501';
  end if;
  if p.active = coalesce(p_active, true) then return; end if;
  update public.products set active = coalesce(p_active, true), updated_at = now() where id = p_product;
  perform app.audit(p.business_id, 'urun_aktiflik', 'products', p_product::text,
                    jsonb_build_object('active', p.active), jsonb_build_object('active', coalesce(p_active, true), 'kod', p.code));
end $$;

select app.apply_grants();

do $$
declare m public.memberships;
begin
  select * into m from public.memberships where username = 'htopal' and role = 'sevkiyat' and active;
  if m.id is null then raise exception 'Hüseyin (htopal) bulunamadı'; end if;
  update public.memberships set can_product = true where id = m.id;
  perform app.audit(m.business_id, 'yetki_urun', 'memberships', m.id::text,
                    jsonb_build_object('can_product', false), jsonb_build_object('can_product', true, 'not', 'kullanıcı isteği 24.11'));
end $$;

select 'SONUC: ' || string_agg(display_name || ' ' || role || ' urun=' || (role = 'yonetici' or can_product), ' ; ' order by display_name) as sonuc
  from public.memberships where active and role in ('yonetici', 'satis', 'sevkiyat');
commit;
