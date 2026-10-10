-- ALKASU 0022 — Mağaza düzeni: müşteri sipariş ekranındaki ürünleri yönetici gizler, yerini değiştirir, yerine başka ürün koyar
-- Kural: BUSINESS_RULES §20 (W-11) · Karar: D-082

create table if not exists public.shop_items (
  unit_id     uuid primary key references public.product_units(id),
  business_id uuid not null references public.businesses(id),
  hidden      boolean not null default false,
  sort        integer,                                   -- bölüm içindeki sıra (küçük önce); boş = otomatik
  section     text check (section is null or length(trim(section)) between 1 and 60),  -- boş = markaya/kategoriye göre
  updated_at  timestamptz not null default now(),
  updated_by  uuid
);
create index if not exists shop_items_business on public.shop_items(business_id);
alter table public.shop_items enable row level security;
create policy shop_items_select on public.shop_items for select to authenticated using (app.has_role(business_id, 'yonetici'));
create trigger shop_items_audit after insert or update on public.shop_items for each row execute function audit.tg_row();

-- Katalog çekirdeği (müşteri ve yönetici aynı kaynağı kullanır)
create or replace function app.shop_catalog(p_business uuid, p_include_hidden boolean)
returns table(product_id uuid, product_name text, unit_id uuid, unit_name text, factor integer, price numeric, has_deposit boolean,
              product_code text, brand_name text, category_name text, image_path text, popularity integer,
              hidden boolean, sort integer, section text)
language sql stable security definer set search_path = public, pg_temp as $$
  select p.id, p.name, u.id, u.name, u.factor, u.price, p.deposit_amount is not null,
         p.code, case when b.show_in_shop then b.name end, c.name, p.image_path,
         coalesce((select sum(si.qty)::int from public.sale_items si join public.sales s on s.id = si.sale_id
                    where si.unit_id = u.id and s.status = 'tamamlandi' and s.sold_at > now() - interval '60 days'), 0),
         coalesce(si2.hidden, false), si2.sort, si2.section
    from public.products p
    join public.product_units u on u.product_id = p.id
    left join public.brands b on b.id = p.brand_id
    left join public.categories c on c.id = p.category_id
    left join public.shop_items si2 on si2.unit_id = u.id
   where p.business_id = p_business and p.active and not p.is_container and u.active and u.price is not null
     and (p_include_hidden or not coalesce(si2.hidden, false))
   order by p.name, u.factor desc
$$;

drop function if exists public.public_catalog();
create or replace function public.public_catalog()
returns table(product_id uuid, product_name text, unit_id uuid, unit_name text, factor integer, price numeric, has_deposit boolean,
              product_code text, brand_name text, category_name text, image_path text, popularity integer,
              sort integer, section text)
language sql stable security definer set search_path = public, pg_temp as $$
  select product_id, product_name, unit_id, unit_name, factor, price, has_deposit, product_code, brand_name, category_name,
         image_path, popularity, sort, section
    from app.shop_catalog(app.public_business(), false)
$$;

-- Yönetici: gizlenenler dahil tüm mağaza ürünleri
create or replace function public.shop_catalog_admin(p_business uuid)
returns table(product_id uuid, product_name text, unit_id uuid, unit_name text, factor integer, price numeric, has_deposit boolean,
              product_code text, brand_name text, category_name text, image_path text, popularity integer,
              hidden boolean, sort integer, section text)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.require_role(p_business, 'yonetici');
  return query select * from app.shop_catalog(p_business, true);
end $$;

-- Yönetici: düzeni toplu kaydeder. p_items: [{unit_id, hidden?, sort?, section?}] — verilen alanlar yazılır.
create or replace function public.save_shop_layout(p_business uuid, p_items jsonb) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare it jsonb; v_unit uuid; v_n int := 0;
begin
  perform app.require_role(p_business, 'yonetici');
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 300 then
    raise exception 'Geçersiz düzen' using errcode = '22023';
  end if;
  for it in select * from jsonb_array_elements(p_items) loop
    v_unit := (it->>'unit_id')::uuid;
    if not exists (select 1 from public.product_units where id = v_unit and business_id = p_business) then
      raise exception 'Ürün birimi bulunamadı' using errcode = 'P0002';
    end if;
    insert into public.shop_items(unit_id, business_id, hidden, sort, section, updated_by)
    values (v_unit, p_business, coalesce((it->>'hidden')::boolean, false), nullif(it->>'sort', '')::int,
            nullif(trim(coalesce(it->>'section', '')), ''), auth.uid())
    on conflict (unit_id) do update set
      hidden  = case when it ? 'hidden' then coalesce((it->>'hidden')::boolean, false) else public.shop_items.hidden end,
      sort    = case when it ? 'sort' then nullif(it->>'sort', '')::int else public.shop_items.sort end,
      section = case when it ? 'section' then nullif(trim(coalesce(it->>'section', '')), '') else public.shop_items.section end,
      updated_at = now(), updated_by = auth.uid();
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

select app.apply_grants();
