-- Tüm müşteri ve bayi bakiyelerinin sıfırlanması (kullanıcı 21.11, D-109)
-- Kullanıcı: "Bugüne kadar olanların ödendiğini varsayarak güncelleme yap."
-- Cari satırları silinmez: her kart için bakiyeyi sıfırlayan bir açılış satırı yazılır (ekstrede görünür).
-- Tahsilat olarak girilmez (kasaya/POS'a ve gelir raporuna işlenmez). Kap/depozito bakiyeleri değişmez.
-- Geri almak için: işlem geçmişindeki 'bakiye_sifirlama' kaydında her kartın önceki bakiyesi saklıdır.
begin;

do $$
declare v_bid uuid; v_n int; v_pos numeric; v_neg numeric; v_snap jsonb;
begin
  select id into v_bid from public.businesses order by created_at limit 1;
  with b as (select l.customer_id, sum(l.amount) as bal from public.customer_ledger l
              where l.business_id = v_bid group by l.customer_id having sum(l.amount) <> 0)
  select count(*), coalesce(sum(bal) filter (where bal > 0), 0), coalesce(sum(bal) filter (where bal < 0), 0),
         coalesce(jsonb_object_agg(customer_id, bal), '{}')
    into v_n, v_pos, v_neg, v_snap from b;

  insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, note)
  select v_bid, l.customer_id, 'acilis', -sum(l.amount), 'bakiye_sifirlama',
         'Bakiye sıfırlandı: 21.11.2026 tarihine kadarki borç ödendi kabul edildi'
    from public.customer_ledger l where l.business_id = v_bid
   group by l.customer_id having sum(l.amount) <> 0;

  perform app.audit(v_bid, 'bakiye_sifirlama', 'customer_ledger', null,
    jsonb_build_object('kart', v_n, 'borc_toplami', v_pos, 'alacak_toplami', v_neg, 'onceki_bakiyeler', v_snap),
    jsonb_build_object('kart', v_n, 'bakiye', 0));
  raise notice 'Sıfırlanan kart: %, borç: %, alacak: %', v_n, v_pos, v_neg;
end $$;

select 'SONUC: sifirlanan=' || (select count(distinct customer_id) from public.customer_ledger where ref_type = 'bakiye_sifirlama')
    || ' | eski_borc=' || (select coalesce(sum(-amount) filter (where amount < 0), 0) from public.customer_ledger where ref_type = 'bakiye_sifirlama')
    || ' | eski_alacak=' || (select coalesce(sum(-amount) filter (where amount > 0), 0) from public.customer_ledger where ref_type = 'bakiye_sifirlama')
    || ' | kalan_bakiyeli=' || (select count(*) from (select customer_id from public.customer_ledger group by customer_id having sum(amount) <> 0) x) as sonuc;
commit;
