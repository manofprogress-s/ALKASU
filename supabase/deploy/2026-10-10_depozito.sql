-- 10.10.2026 yayını: depozito fark cariye alacak (0025) + 19 L damacana depozitosu 220 TL. Tek işlem.
begin;
create temp table _onceki on commit drop as select code, deposit_amount from public.products where code in ('DM-GP', 'DM-FS', 'DM-KZ');
-- ALKASU 0025 — Depozito: fazla boş kap iadesi ürün tutarını aşınca fark müşterinin carisine alacak yazılır
-- Kural: BUSINESS_RULES §7 (D-07) · Karar: D-085
-- Örnek: bayi 30 boş getirip 20 dolu alır → 20 dolu tutarı − 10 depozito iadesi eksi çıkarsa fark bayinin cari hesabına
-- "depozito_mahsup" (alacak) olarak yazılır; nakit/POS ödemesi istenmez. Fiş iptal edilirse kayıt otomatik ters çevrilir.
-- complete_sale_core gövdesi 0016'dakiyle aynı; yalnızca eksi toplam kuralı değişti.

create or replace function app.complete_sale_core(p_business uuid, p jsonb, p_role public.member_role,
                                              p_trusted boolean default false) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_role    public.member_role := p_role;          -- çağıran fonksiyon yetkiyi doğrular
  v_list    text := 'perakende';
  v_cur     numeric;
  v_id      uuid := (p->>'id')::uuid;
  v_loc     uuid := coalesce(nullif(p->>'location_id', '')::uuid, app.default_location(p_business));
  v_set     public.app_settings;
  v_sess    public.cash_sessions;
  v_cust    public.customers;
  v_offline boolean := coalesce((p->>'offline')::boolean, false);
  v_client  timestamptz := coalesce(nullif(p->>'client_created_at', '')::timestamptz, now());
  v_sold_at timestamptz;
  v_no      bigint;
  it        jsonb;
  pr        public.products;
  u         public.product_units;
  v_line    int := 0;
  v_qty     int;
  v_price   numeric;
  v_ldisc   numeric;
  v_gross   numeric := 0;
  v_ldisc_total numeric := 0;
  v_bill    numeric := coalesce(nullif(p->>'bill_discount', '')::numeric, 0);
  v_net_before_bill numeric;
  v_share   numeric;
  v_share_left numeric;
  v_goods_net numeric := 0;
  v_dep_total numeric := 0;
  v_grand   numeric;
  v_pay_total numeric := 0;
  v_cash    numeric := 0; v_pos numeric := 0; v_credit numeric := 0;
  v_given   numeric := nullif(p->>'cash_given', '')::numeric;
  v_balance numeric;
  v_limit_override boolean := false;
  v_offline_limit boolean := false;
  d         record;
  v_ret     int;
  v_cb      record;
  v_amt     numeric;
  rec       record;
  v_item_id uuid;
begin
  if v_id is null then raise exception 'Satış kimliği eksik' using errcode = '22023'; end if;

  -- S-02: aynı kimlikle tekrar gönderim
  if exists (select 1 from public.sales where id = v_id) then
    return (select jsonb_build_object('id', s.id, 'no', s.no, 'grand_total', s.grand_total,
                                      'change', s.change_given, 'duplicate', true)
              from public.sales s where s.id = v_id and s.business_id = p_business);
  end if;

  select * into v_set from public.app_settings where business_id = p_business;
  if jsonb_array_length(coalesce(p->'items', '[]')) = 0 then
    raise exception 'Sepet boş' using errcode = '22023';
  end if;
  if v_bill < 0 then raise exception 'İndirim negatif olamaz' using errcode = '22023'; end if;

  if nullif(p->>'customer_id', '') is not null then
    select * into v_cust from public.customers where id = (p->>'customer_id')::uuid and business_id = p_business;
    if v_cust.id is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
    if not v_cust.active then raise exception 'Müşteri pasif durumda' using errcode = 'P0001'; end if;
    v_list := coalesce(v_cust.price_list, 'perakende');   -- F-10: müşterinin fiyat listesi
  end if;

  v_sess := app.ensure_session(p_business, v_loc);
  v_sold_at := case when v_offline then least(v_client, now()) else now() end;
  v_no := app.next_number(p_business, 'satis');

  if to_regclass('pg_temp._sale_lines') is null then
  create temp table _sale_lines (
    line_no int, product_id uuid, unit_id uuid, unit_name text, factor int, qty int, base_qty int,
    unit_price numeric, line_gross numeric, line_discount numeric, share numeric default 0,
    line_net numeric, vat_rate smallint, deposit_amount numeric, empty_product_id uuid
  ) on commit drop;
  end if;
  truncate _sale_lines;

  -- 1) Kalemleri doğrula
  for it in select * from jsonb_array_elements(p->'items') loop
    v_line := v_line + 1;
    pr := app.product_in_business(p_business, (it->>'product_id')::uuid);
    if not pr.active then raise exception 'Pasif ürün satılamaz: % (S-06)', pr.name using errcode = 'P0001'; end if;
    if pr.is_container then raise exception 'Boş kap ürünü satılamaz: %', pr.name using errcode = 'P0001'; end if;
    select * into u from public.product_units where id = (it->>'unit_id')::uuid and product_id = pr.id;
    if u.id is null then raise exception 'Ürün birimi geçersiz: %', pr.name using errcode = '22023'; end if;
    if not u.active and not v_offline then raise exception 'Bu birim artık kullanılmıyor: % %', pr.name, u.name using errcode = 'P0001'; end if;

    v_qty   := (it->>'qty')::int;
    v_price := round((it->>'unit_price')::numeric, 2);
    v_ldisc := round(coalesce(nullif(it->>'line_discount', '')::numeric, 0), 2);
    if v_qty is null or v_qty <= 0 then raise exception 'Miktar geçersiz: %', pr.name using errcode = '22023'; end if;
    if v_price is null or v_price < 0 then raise exception 'Fiyat geçersiz: %', pr.name using errcode = '22023'; end if;

    if v_role <> 'yonetici' and not p_trusted then
      -- Satış personeli fiyatı değiştiremez; müşterinin fiyat listesi geçerlidir (F-10).
      -- Çevrimdışında satış anındaki fiyat da kabul edilir (C-02)
      v_cur := app.customer_unit_price(v_cust.id, u.id, v_list);   -- F-13: firmaya özel fiyat önce
      if v_cur is null and app.unit_price_at(u.id, v_client, v_list) is null then
        raise exception 'Bu birim için satış fiyatı tanımlı değil: % %', pr.name, u.name using errcode = 'P0001';
      end if;
      if v_price is distinct from v_cur
         and not (v_offline and v_price = app.unit_price_at(u.id, v_client, v_list)) then
        raise exception 'Fiyat güncel değil: % % (güncel: %)', pr.name, u.name, v_cur using errcode = 'P0001';
      end if;
      if v_price = 0 then raise exception 'Sıfır fiyatlı satışı yalnızca yönetici yapabilir (F-07)' using errcode = '42501'; end if;
    end if;

    if v_ldisc < 0 or v_ldisc > round(v_qty * v_price, 2) then
      raise exception 'Satır indirimi geçersiz: %', pr.name using errcode = '22023';
    end if;

    insert into _sale_lines values (v_line, pr.id, u.id, u.name, u.factor, v_qty, v_qty * u.factor, v_price,
      round(v_qty * v_price, 2), v_ldisc, 0, null, pr.vat_rate, pr.deposit_amount, pr.empty_product_id);
    v_gross := v_gross + round(v_qty * v_price, 2);
    v_ldisc_total := v_ldisc_total + v_ldisc;
  end loop;

  -- 2) Fiş indirimini satırlara dağıt (F-05)
  v_net_before_bill := v_gross - v_ldisc_total;
  if v_bill > v_net_before_bill then raise exception 'Fiş indirimi tutarı aşıyor' using errcode = '22023'; end if;
  if v_bill > 0 then
    v_share_left := v_bill;
    for rec in select line_no, line_gross - line_discount as net from _sale_lines order by line_no loop
      if rec.line_no = v_line then
        v_share := v_share_left;
      else
        v_share := round(v_bill * rec.net / v_net_before_bill, 2);
        v_share_left := v_share_left - v_share;
      end if;
      update _sale_lines set share = v_share where line_no = rec.line_no;
    end loop;
  end if;
  update _sale_lines set line_net = line_gross - line_discount - share where true;  -- pg_safeupdate: WHERE zorunlu
  select coalesce(sum(line_net), 0) into v_goods_net from _sale_lines;

  -- F-06: indirim limiti
  if v_role <> 'yonetici' and not p_trusted and (v_ldisc_total + v_bill) > round(v_gross * v_set.max_discount_pct_satis / 100, 2) then
    raise exception 'İndirim limitinizi aşıyor (en fazla %%%). Yönetici onayı gerekir (F-06)',
      v_set.max_discount_pct_satis using errcode = '42501';
  end if;

  -- 3) Satış kaydı
  insert into public.sales(id, business_id, location_id, no, session_id, customer_id, goods_gross, discount_total,
                           goods_net, deposit_total, grand_total, sold_at, created_by, offline, late_sync, note)
  values (v_id, p_business, v_loc, v_no, v_sess.id, v_cust.id, v_gross, v_ldisc_total + v_bill,
          v_goods_net, 0, v_goods_net, v_sold_at, auth.uid(), v_offline,
          v_offline and v_client < v_sess.opened_at, nullif(trim(p->>'note'), ''));

  for rec in select l.*, coalesce(pc.avg_cost, 0) as avg_cost, coalesce(pc.has_cost, false) as has_cost
               from _sale_lines l left join public.product_costs pc on pc.product_id = l.product_id
              order by l.line_no loop
    insert into public.sale_items(sale_id, business_id, line_no, product_id, unit_id, unit_name, factor, qty, base_qty,
                                  unit_price, line_gross, line_discount, bill_discount_share, line_net, vat_rate)
    values (v_id, p_business, rec.line_no, rec.product_id, rec.unit_id, rec.unit_name, rec.factor, rec.qty, rec.base_qty,
            rec.unit_price, rec.line_gross, rec.line_discount, rec.share, rec.line_net, rec.vat_rate)
    returning id into v_item_id;
    insert into public.sale_item_costs(sale_item_id, business_id, unit_cost, total_cost, has_cost)
    values (v_item_id, p_business, rec.avg_cost, round(rec.avg_cost * rec.base_qty, 2), rec.has_cost);
  end loop;

  -- 4) Stok hareketleri (ürün sırasıyla: kilit sırası sabit, T-008)
  for rec in select product_id, sum(base_qty)::int as q from _sale_lines group by product_id order by product_id loop
    perform app.post_stock(p_business, v_loc, rec.product_id, -rec.q, 'satis', 'sale', v_id);
  end loop;

  -- 5) Depozito ve boş kap (D-03..D-06)
  for d in select product_id, sum(base_qty)::int as sold, max(deposit_amount) as dep, max(empty_product_id::text)::uuid as empty_id
             from _sale_lines where deposit_amount is not null group by product_id order by product_id loop
    select coalesce(max((x->>'empty_returned')::int), d.sold) into v_ret
      from jsonb_array_elements(coalesce(p->'deposits', '[]')) x where (x->>'product_id')::uuid = d.product_id;
    v_ret := coalesce(v_ret, d.sold);
    if v_ret < 0 then raise exception 'Boş kap sayısı geçersiz' using errcode = '22023'; end if;

    if d.sold - v_ret > 0 then
      v_amt := (d.sold - v_ret) * d.dep;                     -- müşteriden depozito alınır
    elsif d.sold - v_ret < 0 then
      v_amt := -app.deposit_refund_amount(p_business, v_cust.id, d.product_id, v_ret - d.sold);  -- fazla boş: depozito iadesi
    else
      v_amt := 0;
    end if;

    insert into public.sale_deposits(sale_id, business_id, product_id, sold_qty, empty_returned, net_containers, amount)
    values (v_id, p_business, d.product_id, d.sold, v_ret, d.sold - v_ret, v_amt);
    if d.sold - v_ret <> 0 then
      insert into public.container_ledger(business_id, customer_id, product_id, qty, amount, type, ref_type, ref_id, created_by)
      values (p_business, v_cust.id, d.product_id, d.sold - v_ret, v_amt, 'satis', 'sale', v_id, auth.uid());
    end if;
    if v_ret > 0 then
      perform app.post_stock(p_business, v_loc, d.empty_id, v_ret, 'bos_kap_giris', 'sale', v_id);
    end if;
    v_dep_total := v_dep_total + v_amt;
  end loop;
  -- Satılmayan ürün için gönderilmiş depozito satırı kabul edilmez
  if exists (select 1 from jsonb_array_elements(coalesce(p->'deposits', '[]')) x
              where not exists (select 1 from _sale_lines l where l.product_id = (x->>'product_id')::uuid
                                  and l.deposit_amount is not null)) then
    raise exception 'Boş kap bilgisi yalnızca satılan depozitolu ürünler için girilebilir' using errcode = '22023';
  end if;

  v_grand := v_goods_net + v_dep_total;
  -- D-07: fazla boş kap iadesi ürün tutarını aşarsa fark müşterinin cari hesabına ALACAK yazılır (ödeme alınmaz)
  if v_grand < 0 and v_cust.id is null then
    raise exception 'Fazla boş kap iadesi için müşteri seçilmelidir' using errcode = '22023';
  end if;

  -- 6) Ödemeler (S-03)
  for it in select * from jsonb_array_elements(coalesce(p->'payments', '[]')) loop
    v_amt := round((it->>'amount')::numeric, 2);
    if v_amt is null or v_amt <= 0 then raise exception 'Ödeme tutarı geçersiz' using errcode = '22023'; end if;
    case it->>'method'
      when 'nakit' then v_cash := v_cash + v_amt;
      when 'pos' then v_pos := v_pos + v_amt;
      when 'veresiye' then v_credit := v_credit + v_amt;
      else raise exception 'Ödeme şekli geçersiz: %', it->>'method' using errcode = '22023';
    end case;
  end loop;
  v_pay_total := v_cash + v_pos + v_credit;
  if v_grand < 0 then
    if v_pay_total <> 0 then
      raise exception 'Fiş toplamı eksi: ödeme girilmez, fark müşterinin hesabına alacak yazılır' using errcode = '22023';
    end if;
    insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
    values (p_business, v_cust.id, 'depozito_mahsup', v_grand, 'sale', v_id, auth.uid());
  elsif v_pay_total <> v_grand then
    raise exception 'Ödemeler toplamı (%) fiş toplamına (%) eşit değil (S-03)', v_pay_total, v_grand using errcode = '22023';
  end if;
  if v_given is not null and v_given < v_cash then
    raise exception 'Alınan nakit, nakit ödeme tutarından az olamaz' using errcode = '22023';
  end if;

  -- V-01..V-02: veresiye
  if v_credit > 0 then
    if v_cust.id is null then raise exception 'Veresiye için müşteri seçilmelidir (V-01)' using errcode = '22023'; end if;
    perform 1 from public.customers where id = v_cust.id for update;   -- aynı müşteriye eşzamanlı veresiye
    v_balance := app.customer_balance(v_cust.id);
    if not v_cust.unlimited_credit and v_balance + v_credit > v_cust.credit_limit then
      if v_offline or p_trusted then
        v_offline_limit := true;                    -- C-03 / teslimat: satış kaydedilir, yöneticiye uyarı
      elsif coalesce((p->>'limit_override')::boolean, false) and v_role = 'yonetici' then
        v_limit_override := true;
      else
        raise exception 'Veresiye limiti aşılıyor. Bakiye: %, limit: %, bu satış: % (V-02)',
          v_balance, v_cust.credit_limit, v_credit using errcode = 'P0001';
      end if;
    end if;
    insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
    values (p_business, v_cust.id, 'satis', v_credit, 'sale', v_id, auth.uid());
  end if;

  if v_cash > 0 then insert into public.sale_payments(sale_id, business_id, method, amount) values (v_id, p_business, 'nakit', v_cash); end if;
  if v_pos > 0 then insert into public.sale_payments(sale_id, business_id, method, amount) values (v_id, p_business, 'pos', v_pos); end if;
  if v_credit > 0 then insert into public.sale_payments(sale_id, business_id, method, amount) values (v_id, p_business, 'veresiye', v_credit); end if;
  perform app.post_cash(p_business, v_sess.id, 'satis', v_cash, 'sale', v_id);

  update public.sales set deposit_total = v_dep_total, grand_total = v_grand,
         cash_given = v_given, change_given = case when v_given is not null then v_given - v_cash end,
         limit_override = v_limit_override, offline_limit_exceeded = v_offline_limit
   where id = v_id;

  perform app.audit(p_business, case when v_limit_override then 'satis_limit_asimi' else 'satis' end,
                    'sales', v_id::text, null,
                    jsonb_build_object('no', v_no, 'grand_total', v_grand, 'customer_id', v_cust.id,
                                       'offline', v_offline, 'limit_override', v_limit_override,
                                       'offline_limit_exceeded', v_offline_limit));

  return jsonb_build_object('id', v_id, 'no', v_no, 'grand_total', v_grand, 'goods_net', v_goods_net,
                            'deposit_total', v_dep_total,
                            'change', case when v_given is not null then v_given - v_cash end,
                            'session_id', v_sess.id, 'duplicate', false,
                            'limit_override', v_limit_override, 'offline_limit_exceeded', v_offline_limit);
end $$;

select app.apply_grants();
insert into supabase_migrations.schema_migrations(version, name) values ('20261010002500', 'deposit_credit') on conflict do nothing;
-- Kullanıcı: "Depozito olacak PC damacana ücretimiz 220 TL" (10.10)
update public.products set deposit_amount = 220, updated_at = now()
 where code in ('DM-GP', 'DM-FS', 'DM-KZ') and deposit_amount is distinct from 220;
select 'SONUC: surum=' || (select max(version) from supabase_migrations.schema_migrations)
    || ' onceki=' || (select string_agg(code || ':' || coalesce(deposit_amount::text, '-'), ',' order by code) from _onceki)
    || ' simdi=' || (select string_agg(code || ':' || coalesce(deposit_amount::text, '-'), ',' order by code) from public.products where code in ('DM-GP', 'DM-FS', 'DM-KZ')) as sonuc;
commit;
