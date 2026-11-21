-- Sağlam Ticaret (B001) güncel borcu (kullanıcı 21.11, D-110): 33 Gürpınar damacana, 2 Fuska, 2 Kızılay, 1 Gürpınar 19 L pet.
-- Tutar Sağlam'ın bugünkü fiyatlarıyla: firmaya özel fiyat > bayi listesi > gel al. Tek açılış satırı (ekstrede görünür).
begin;

do $$
declare v_c uuid; v_bid uuid; v_total numeric; v_note text;
begin
  select id, business_id into v_c, v_bid from public.customers where code = 'B001' and channel = 'bayi';
  if v_c is null then raise exception 'B001 bulunamadı'; end if;
  if exists (select 1 from public.customer_ledger where customer_id = v_c and ref_type = 'acilis_bildirim') then raise exception 'Daha önce girilmiş'; end if;
  with want(code, qty) as (values ('DM-GP', 33), ('DM-FS', 2), ('DM-KZ', 2), ('GP-19PET', 1)),
  p as (
    select w.code, w.qty, p.name,
           coalesce((select cp.price from public.customer_prices cp where cp.customer_id = v_c and cp.unit_id = u.id),
                    (select lp.price from public.product_list_prices lp where lp.unit_id = u.id and lp.price_list = 'bayi'),
                    u.price) as price
      from want w join public.products p on p.business_id = v_bid and p.code = w.code
      join public.product_units u on u.product_id = p.id and u.is_base)
  select sum(qty * price), string_agg(qty || ' × ' || name || ' @ ' || price, ', ' order by code) into v_total, v_note from p;
  if (select count(*) from public.products where code in ('DM-GP','DM-FS','DM-KZ','GP-19PET') and business_id = v_bid) <> 4 then raise exception 'Ürün eksik'; end if;
  insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, note)
  values (v_bid, v_c, 'acilis', v_total, 'acilis_bildirim', 'Güncel borç (21.11.2026): ' || v_note);
  perform app.audit(v_bid, 'acilis_bildirim', 'customer_ledger', v_c::text, null, jsonb_build_object('tutar', v_total, 'kalemler', v_note));
end $$;

select 'SONUC: ' || (select note || ' = ' || amount from public.customer_ledger where ref_type = 'acilis_bildirim' order by created_at desc limit 1)
    || ' | bakiye=' || (select sum(l.amount) from public.customer_ledger l join public.customers c on c.id = l.customer_id where c.code = 'B001') as sonuc;
commit;
