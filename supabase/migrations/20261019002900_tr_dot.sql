-- ALKASU 0029 — Önceki yüklemeden kalan birleşik nokta (U+0307, "İbrahi̇m") temizliği; tr_initcap da bu noktayı atar
-- Kural: BUSINESS_RULES §27 (M-21) · Karar: D-087
create or replace function app.tr_initcap(p text) returns text
language sql immutable as $$
  select nullif(string_agg(upper(translate(left(x, 1), 'iışğüöç', 'İIŞĞÜÖÇ')) || substr(x, 2), ' ' order by n), '')
    from regexp_split_to_table(lower(translate(replace(trim(coalesce(p, '')), U&'\0307', ''), 'İIŞĞÜÖÇ', 'iışğüöç')), '\s+') with ordinality as t(x, n)
   where x <> ''
$$;

update public.customers set
  area = app.tr_initcap(area),
  district = app.tr_initcap(district)
 where area like '%' || U&'\0307' || '%' or district like '%' || U&'\0307' || '%';

select app.apply_grants();
