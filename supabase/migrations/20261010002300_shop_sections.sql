-- ALKASU 0023 — Mağaza düzeni: bölümlerin (marka grupları, "Çok satanlar", kategoriler) sırası
-- Kural: BUSINESS_RULES §20 (W-12) · Karar: D-083

create table if not exists public.shop_sections (
  business_id uuid not null references public.businesses(id),
  title       text not null check (length(trim(title)) between 1 and 60),   -- '__top__' = Çok satanlar
  sort        integer not null,
  updated_at  timestamptz not null default now(),
  updated_by  uuid,
  primary key (business_id, title)
);
alter table public.shop_sections enable row level security;
create policy shop_sections_select on public.shop_sections for select to authenticated using (app.has_role(business_id, 'yonetici'));
create trigger shop_sections_audit after insert or update on public.shop_sections for each row execute function audit.tg_row();

-- Katalog çekirdeği: bölüm sırası (section_rank) ve çok satanların sırası (top_rank) eklendi
drop function if exists public.public_catalog();
drop function if exists public.shop_catalog_admin(uuid);
drop function if exists app.shop_catalog(uuid, boolean);
create function app.shop_catalog(p_business uuid, p_include_hidden boolean)
returns table(product_id uuid, product_name text, unit_id uuid, unit_name text, factor integer, price numeric, has_deposit boolean,
              product_code text, brand_name text, category_name text, image_path text, popularity integer,
              hidden boolean, sort integer, section text, section_rank integer, top_rank integer)
language sql stable security definer set search_path = public, pg_temp as $$
  select x.product_id, x.product_name, x.unit_id, x.unit_name, x.factor, x.price, x.has_deposit, x.product_code, x.brand_name,
         x.category_name, x.image_path, x.popularity, x.hidden, x.sort, x.section,
         (select ss.sort from public.shop_sections ss where ss.business_id = p_business
             and ss.title = coalesce(x.section, case when x.brand_name is not null then x.brand_name || ' çeşitleri' else coalesce(x.category_name, 'Diğer') end)),
         (select ss.sort from public.shop_sections ss where ss.business_id = p_business and ss.title = '__top__')
    from (
      select p.id as product_id, p.name as product_name, u.id as unit_id, u.name as unit_name, u.factor, u.price,
             p.deposit_amount is not null as has_deposit, p.code as product_code,
             case when b.show_in_shop then b.name end as brand_name, c.name as category_name, p.image_path,
             coalesce((select sum(si.qty)::int from public.sale_items si join public.sales s on s.id = si.sale_id
                        where si.unit_id = u.id and s.status = 'tamamlandi' and s.sold_at > now() - interval '60 days'), 0) as popularity,
             coalesce(si2.hidden, false) as hidden, si2.sort, si2.section
        from public.products p
        join public.product_units u on u.product_id = p.id
        left join public.brands b on b.id = p.brand_id
        left join public.categories c on c.id = p.category_id
        left join public.shop_items si2 on si2.unit_id = u.id
       where p.business_id = p_business and p.active and not p.is_container and u.active and u.price is not null
         and (p_include_hidden or not coalesce(si2.hidden, false))
    ) x
   order by x.product_name, x.factor desc
$$;

create function public.public_catalog()
returns table(product_id uuid, product_name text, unit_id uuid, unit_name text, factor integer, price numeric, has_deposit boolean,
              product_code text, brand_name text, category_name text, image_path text, popularity integer,
              sort integer, section text, section_rank integer, top_rank integer)
language sql stable security definer set search_path = public, pg_temp as $$
  select product_id, product_name, unit_id, unit_name, factor, price, has_deposit, product_code, brand_name, category_name,
         image_path, popularity, sort, section, section_rank, top_rank
    from app.shop_catalog(app.public_business(), false)
$$;

create function public.shop_catalog_admin(p_business uuid)
returns table(product_id uuid, product_name text, unit_id uuid, unit_name text, factor integer, price numeric, has_deposit boolean,
              product_code text, brand_name text, category_name text, image_path text, popularity integer,
              hidden boolean, sort integer, section text, section_rank integer, top_rank integer)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform app.require_role(p_business, 'yonetici');
  return query select * from app.shop_catalog(p_business, true);
end $$;

-- Yönetici: bölüm sırasını kaydeder (listedeki sırayla 10, 20, 30…; listede olmayanlar otomatik sıraya döner)
create or replace function public.save_shop_sections(p_business uuid, p_titles text[]) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_n int := 0; v_t text;
begin
  perform app.require_role(p_business, 'yonetici');
  if p_titles is null or cardinality(p_titles) > 100 then raise exception 'Geçersiz bölüm sırası' using errcode = '22023'; end if;
  delete from public.shop_sections where business_id = p_business;
  foreach v_t in array p_titles loop
    v_t := trim(v_t);
    if length(v_t) between 1 and 60 then
      v_n := v_n + 1;
      insert into public.shop_sections(business_id, title, sort, updated_by) values (p_business, v_t, v_n * 10, auth.uid())
      on conflict (business_id, title) do nothing;
    end if;
  end loop;
  perform app.audit(p_business, 'magaza_bolum_sirasi', 'shop_sections', p_business::text, null, to_jsonb(p_titles));
  return v_n;
end $$;

select app.apply_grants();
