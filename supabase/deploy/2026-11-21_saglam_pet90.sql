-- Sağlam Ticaret: Gürpınar 19 L pet özel fiyatı 95 → 90; güncel borçtaki 1 pet için bakiye −5 (kullanıcı 21.11, D-110)
begin;
do $$
declare v_c uuid; v_bid uuid; v_u uuid; v_old numeric;
begin
  select id, business_id into v_c, v_bid from public.customers where code = 'B001' and channel = 'bayi';
  select u.id into v_u from public.products p join public.product_units u on u.product_id = p.id and u.is_base
   where p.business_id = v_bid and p.code = 'GP-19PET';
  select price into v_old from public.customer_prices where customer_id = v_c and unit_id = v_u;
  if v_c is null or v_u is null or v_old is distinct from 95 then raise exception 'Beklenmeyen durum (eski fiyat %)', v_old; end if;
  update public.customer_prices set price = 90, updated_at = now() where customer_id = v_c and unit_id = v_u;
  perform app.audit(v_bid, 'ozel_fiyat', 'customer_prices', v_c::text,
                    jsonb_build_object('unit_id', v_u, 'price', 95), jsonb_build_object('unit_id', v_u, 'price', 90, 'kod', 'GP-19PET'));
  insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, note)
  values (v_bid, v_c, 'acilis', -5, 'acilis_bildirim', 'Düzeltme: 1 × Gürpınar 19 L pet fiyatı 95 → 90');
end $$;
select 'SONUC: pet=' || (select cp.price from public.customer_prices cp join public.customers c on c.id = cp.customer_id
                           join public.product_units u on u.id = cp.unit_id join public.products p on p.id = u.product_id
                          where c.code = 'B001' and p.code = 'GP-19PET')
    || ' | bakiye=' || (select sum(l.amount) from public.customer_ledger l join public.customers c on c.id = l.customer_id where c.code = 'B001') as sonuc;
commit;
