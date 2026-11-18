-- İbrahim Sağlam (A1027) eski sistem borcunun Sağlam Ticaret (B001) bayi kartına aktarılması (kullanıcı 18.11, D-106)
-- Kullanıcı: "Bayi kartına aktarırken onun borcunu 60 000 TL ödendi olarak gösterelim."
-- Cari kayıtları değiştirilmez/silinmez: aktarım ve ödeme yeni açılış satırları olarak yazılır, ekstrede görünür.
-- 60.000 TL ödeme eski borca karşılık geçmiş ödemedir: bugünün kasasına/POS'una ve gelir raporuna işlenmez.
begin;

do $$
declare
  v_a uuid; v_b uuid; v_bid uuid; v_open numeric; v_bal_a numeric; v_bal_b numeric;
begin
  select id, business_id into v_a, v_bid from public.customers where code = 'A1027' and name = 'İBRAHİM SAĞLAM';
  select id into v_b from public.customers where code = 'B001' and channel = 'bayi' and business_id = v_bid;
  if v_a is null or v_b is null then raise exception 'Kartlar bulunamadı'; end if;
  if exists (select 1 from public.customer_ledger where customer_id = v_b and ref_type = 'acilis_aktarim') then
    raise exception 'Aktarım daha önce yapılmış';
  end if;
  select coalesce(sum(amount) filter (where type = 'acilis'), 0), coalesce(sum(amount), 0) into v_open, v_bal_a
    from public.customer_ledger where customer_id = v_a;
  select coalesce(sum(amount), 0) into v_bal_b from public.customer_ledger where customer_id = v_b;
  if v_open <> 72346 or v_bal_a <> 72346 then raise exception 'A1027 beklenen borç değil (açılış %, bakiye %)', v_open, v_bal_a; end if;

  insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, note) values
    (v_bid, v_a, 'acilis', -72346, 'acilis_aktarim', 'Eski sistem borcu bayi kartına aktarıldı: Sağlam Ticaret (B001)'),
    (v_bid, v_b, 'acilis',  72346, 'acilis_aktarim', 'İbrahim Sağlam (A1027) eski sistem borcu aktarıldı'),
    (v_bid, v_b, 'acilis', -60000, 'acilis_odeme',   'Eski borçtan ödenen 60.000 TL (kasaya işlenmez)');

  perform app.audit(v_bid, 'acilis_aktarim', 'customers', v_b::text,
    jsonb_build_object('A1027', v_bal_a, 'B001', v_bal_b),
    jsonb_build_object('A1027', 0, 'B001', v_bal_b + 72346 - 60000, 'aktarilan', 72346, 'odenen', 60000));
end $$;

select 'SONUC: A1027=' || (select coalesce(sum(l.amount), 0) from public.customer_ledger l join public.customers c on c.id = l.customer_id where c.code = 'A1027')
    || ' | B001=' || (select coalesce(sum(l.amount), 0) from public.customer_ledger l join public.customers c on c.id = l.customer_id where c.code = 'B001') as sonuc;
commit;
