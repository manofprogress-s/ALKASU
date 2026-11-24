-- Canlı: depozitosuz kap (0051, F-40, D-115)
begin;
-- ALKASU 0051 — Depozitosuz kap (F-40, D-115)
-- Kullanıcı (24.11): bazen müşteriye fazladan (ör. 10) damacana bırakılıyor ve bir sonraki teslimatta geri alınıyor.
-- Stok takibi için kaplar müşteriye yazılmalı ama depozitosu 0 TL olmalı; faturası (ürün) doğru kesilmeli.
-- Satış/teslimatta ürün başına 'deposit_free' = müşteride kalan kaplardan depozitosuz olanların sayısı.
-- Kap bakiyesine qty yazılır, tutar 0; geri alınınca iade de 0 olur (iade alındığı tutardan yapılır, D-07).

-- Depozitosuz kap takibi: kap hareketinde kaç kabın depozitosuz olduğu (iade önce bunlardan düşer)
alter table public.container_ledger add column if not exists free_qty integer;

create or replace function app.container_free_out(p_customer uuid, p_product uuid) returns integer
language sql stable security definer set search_path = public, pg_temp as $$
  select greatest(coalesce(sum(coalesce(free_qty, 0)), 0), 0)::int from public.container_ledger
   where customer_id = p_customer and product_id = p_product
$$;

-- Belirtilmemişse: kap çıkışında (eksi) önce depozitosuz kaplar düşülür, girişte 0
create or replace function app.tg_container_free() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  if new.free_qty is null then
    new.free_qty := case when new.qty < 0 and new.customer_id is not null
                         then -least(-new.qty, app.container_free_out(new.customer_id, new.product_id)) else 0 end;
  end if;
  return new;
end $$;
drop trigger if exists container_ledger_free on public.container_ledger;
create trigger container_ledger_free before insert on public.container_ledger
  for each row execute function app.tg_container_free();

-- D-07 + F-40: iade, alınan depozito tutarından orantılı; depozitosuz kaplar önce ve 0 TL ile geri alınır
create or replace function app.deposit_refund_amount(p_business uuid, p_customer uuid, p_product uuid, p_qty integer) returns numeric
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare b record; v_free int; v_paid_qty int; v_paid_ret int;
begin
  select * into b from app.container_balance(p_business, p_customer, p_product);
  if b.qty < p_qty then
    raise exception 'Müşterinin elinde bu kadar kap görünmüyor (elinde: %, iade: %)', b.qty, p_qty using errcode = 'P0001';
  end if;
  v_free := least(app.container_free_out(p_customer, p_product), b.qty);
  v_paid_qty := b.qty - v_free;
  v_paid_ret := greatest(p_qty - v_free, 0);
  if v_paid_ret = 0 or v_paid_qty <= 0 then return 0; end if;
  if v_paid_ret = v_paid_qty then return b.amount; end if;
  return round(b.amount * v_paid_ret / v_paid_qty, 2);
end $$;

-- Satış iptali: depozitosuz kap sayısı da geri alınır
create or replace function public.cancel_sale(p_sale uuid, p_reason text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
declare s public.sales; r record;
begin
  select * into s from public.sales where id = p_sale for update;
  if s.id is null then raise exception 'Satış bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(s.business_id, 'yonetici');
  if coalesce(trim(p_reason), '') = '' then raise exception 'İptal nedeni zorunludur (I-05)' using errcode = '22023'; end if;
  if s.status <> 'tamamlandi' then raise exception 'Satış zaten iptal edilmiş' using errcode = 'P0001'; end if;
  if (select status from public.cash_sessions where id = s.session_id) <> 'acik' then
    raise exception 'Kasa günü kapandığı için satış iptal edilemez; iade işlemi yapın (I-01)' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.returns where sale_id = p_sale) then
    raise exception 'İadesi yapılmış satış iptal edilemez' using errcode = 'P0001';
  end if;

  for r in select product_id, location_id, sum(qty)::int as q from public.stock_movements
            where ref_type = 'sale' and ref_id = p_sale group by product_id, location_id order by product_id loop
    perform app.post_stock(s.business_id, r.location_id, r.product_id, -r.q, 'satis_iptal', 'sale_cancel', p_sale);
  end loop;
  insert into public.container_ledger(business_id, customer_id, product_id, qty, amount, type, ref_type, ref_id, created_by, free_qty)
  select business_id, customer_id, product_id, -qty, -amount, 'iptal', 'sale_cancel', p_sale, auth.uid(), -coalesce(free_qty, 0)
    from public.container_ledger where ref_type = 'sale' and ref_id = p_sale;
  insert into public.customer_ledger(business_id, customer_id, type, amount, ref_type, ref_id, created_by)
  select business_id, customer_id, 'iptal', -amount, 'sale_cancel', p_sale, auth.uid()
    from public.customer_ledger where ref_type = 'sale' and ref_id = p_sale;
  insert into public.cash_movements(business_id, session_id, type, amount, ref_type, ref_id, created_by)
  select business_id, session_id, 'satis_iptal', -amount, 'sale_cancel', p_sale, auth.uid()
    from public.cash_movements where ref_type = 'sale' and ref_id = p_sale;

  update public.sales set status = 'iptal', cancelled_at = now(), cancelled_by = auth.uid(), cancel_reason = trim(p_reason)
   where id = p_sale;
  perform app.audit(s.business_id, 'satis_iptal', 'sales', p_sale::text,
                    jsonb_build_object('status', 'tamamlandi'), jsonb_build_object('status', 'iptal', 'reason', p_reason));
end $function$;

-- Satış çekirdeği (0046 gövdesi + depozitosuz kap)
create or replace function app.complete_sale_core(p_business uuid, p jsonb, p_role member_role, p_trusted boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
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
  v_free    int;
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
      round(v_qty * v_price, 2), v_ldisc, 0, null, pr.vat_rate,
      app.deposit_for(v_cust.id, pr.id, p->>'deposit_list'),   -- F-37: müşteriye özel depozito > eve teslim (F-16) > normal
      pr.empty_product_id);
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

    -- F-40: müşteride kalan kaplardan bir kısmı depozitosuz bırakılabilir (yönetici / özel fiyat yetkilisi)
    select coalesce(max((x->>'deposit_free')::int), 0) into v_free
      from jsonb_array_elements(coalesce(p->'deposits', '[]')) x where (x->>'product_id')::uuid = d.product_id;
    if v_free <> 0 then
      if v_free < 0 or v_free > greatest(d.sold - v_ret, 0) then
        raise exception 'Depozitosuz kap sayısı müşteride kalan kap sayısını aşamaz' using errcode = '22023';
      end if;
      if not app.can_price(p_business) then
        raise exception 'Depozitosuz kap bırakmayı yalnızca yönetici veya özel fiyat yetkisi olan kişi yapabilir (F-40)' using errcode = '42501';
      end if;
    end if;
    if d.sold - v_ret > 0 then
      v_amt := (d.sold - v_ret - v_free) * d.dep;            -- müşteriden depozito alınır (depozitosuz kaplar hariç)
    elsif d.sold - v_ret < 0 then
      v_amt := -app.deposit_refund_amount(p_business, v_cust.id, d.product_id, v_ret - d.sold);  -- fazla boş: depozito iadesi
    else
      v_amt := 0;
    end if;

    insert into public.sale_deposits(sale_id, business_id, product_id, sold_qty, empty_returned, net_containers, amount)
    values (v_id, p_business, d.product_id, d.sold, v_ret, d.sold - v_ret, v_amt);
    if d.sold - v_ret <> 0 then
      insert into public.container_ledger(business_id, customer_id, product_id, qty, amount, type, ref_type, ref_id, created_by, free_qty)
      values (p_business, v_cust.id, d.product_id, d.sold - v_ret, v_amt, 'satis', 'sale', v_id, auth.uid(),
              case when d.sold - v_ret > 0 then v_free end);   -- iadede (eksi) tetikleyici önce depozitosuz kapları düşer
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
end $function$;

-- Kap bakiyesinde depozitosuz kap sayısı (ekranlar iade tutarını sunucuyla aynı hesaplar)
create or replace view public.container_balances with (security_invoker = true) as
select business_id, customer_id, product_id, sum(qty)::integer as qty, sum(amount)::numeric(14,2) as amount,
       greatest(sum(coalesce(free_qty, 0)), 0)::integer as free
  from public.container_ledger
 group by business_id, customer_id, product_id
having sum(qty) <> 0 or sum(amount) <> 0;

-- Müşteri araması: kap bakiyesinde depozitosuz sayı
create or replace function public.search_customers(p_business uuid, p_q text, p_limit integer DEFAULT 10)
 RETURNS TABLE(id uuid, code text, name text, address text, phone text, channel text, price_list text, default_assignee uuid, owner_dealer_id uuid, credit_limit numeric, unlimited_credit boolean, balance numeric, special_prices jsonb, deposits jsonb, containers jsonb, dealer_hint jsonb, match_rank integer, total bigint)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
declare
  v_k  text := app.search_norm(p_q);
  v_kc text := replace(app.search_norm(p_q), ' ', '');
  v_w  text[] := string_to_array(nullif(app.search_norm(p_q), ''), ' ');
  v_d  text := regexp_replace(regexp_replace(coalesce(p_q, ''), '\D', '', 'g'), '^(90|0)', '');
begin
  perform app.require_role(p_business, 'yonetici', 'satis');   -- satış ve sipariş yapan personel (sevkiyat dahil)
  if v_k = '' then return; end if;
  return query
  with dl as (   -- bayi kartları: ad + resmî unvan + bayi kullanıcılarının adı ve kullanıcı adı
    select cu.id, cu.code, cu.name,
           right(regexp_replace(coalesce(cu.phone, ''), '\D', '', 'g'), 10) as ph,
           app.search_norm(concat_ws(' ', cu.name, cu.legal_title,
             (select string_agg(concat_ws(' ', mb.display_name, mb.username), ' ') from public.memberships mb
               where mb.business_id = p_business and mb.customer_id = cu.id and mb.active))) as hay
      from public.customers cu
     where cu.business_id = p_business and cu.active and cu.channel = 'bayi'),
  c as (
    select cu.id, cu.code, cu.name, cu.address, cu.phone, cu.channel::text as channel, cu.price_list, cu.default_assignee,
           cu.owner_dealer_id, cu.credit_limit, cu.unlimited_credit,
           cu.name_norm as n, lower(cu.code) as nc, cu.name_initials as ini,
           coalesce((select dl.hay from dl where dl.id = cu.id), '') as extra
      from public.customers cu
     where cu.business_id = p_business and cu.active),
  m as (
    select c.*,
           case when c.n = v_k or c.nc = v_k or replace(c.n, ' ', '') = v_kc then 0
                when c.n like v_k || '%' then 1
                when (' ' || c.n) like '% ' || v_k || '%' or (length(v_kc) >= 2 and c.ini like v_kc || '%') then 2
                else 3 end as r
      from c
     where (select bool_and((' ' || c.n || ' ' || c.nc || ' ' || c.extra) like '%' || x || '%') from unnest(v_w) x)
        or (length(v_kc) >= 2 and replace(c.n, ' ', '') like '%' || v_kc || '%')
        or (length(v_kc) >= 2 and c.ini like v_kc || '%')
        or (length(v_d) >= 4 and regexp_replace(coalesce(c.phone, ''), '\D', '', 'g') like '%' || v_d || '%')),
  t as (
    select m.*, count(*) over () as cnt from m
     order by (m.channel = 'bayi') desc, m.r, m.name, m.code
     limit least(greatest(coalesce(p_limit, 10), 1), 30))
  select t.id, t.code, t.name, t.address, t.phone, t.channel, t.price_list, t.default_assignee, t.owner_dealer_id,
         t.credit_limit, t.unlimited_credit,
         coalesce((select sum(l.amount) from public.customer_ledger l where l.customer_id = t.id), 0)::numeric(14,2),
         coalesce((select jsonb_object_agg(cp.unit_id, cp.price) from public.customer_prices cp where cp.customer_id = t.id), '{}'::jsonb),
         coalesce((select jsonb_object_agg(cd.product_id, cd.amount) from public.customer_deposits cd where cd.customer_id = t.id), '{}'::jsonb),
         coalesce((select jsonb_agg(jsonb_build_object('product_id', x.product_id, 'qty', x.qty, 'amount', x.amount, 'free', x.free))
                     from (select cl.product_id, sum(cl.qty)::int as qty, sum(cl.amount)::numeric(14,2) as amount,
                                    greatest(sum(coalesce(cl.free_qty, 0)), 0)::int as free
                             from public.container_ledger cl where cl.customer_id = t.id
                            group by cl.product_id having sum(cl.qty) <> 0 or sum(cl.amount) <> 0) x), '[]'::jsonb),
         case when t.channel <> 'bayi' then (
           select jsonb_build_object('id', dl.id, 'code', dl.code, 'name', dl.name) from dl
            where (length(dl.ph) = 10 and dl.ph = right(regexp_replace(coalesce(t.phone, ''), '\D', '', 'g'), 10))
               or (exists (select 1 from unnest(string_to_array(t.n, ' ')) w where length(w) >= 3)
                   and not exists (select 1 from unnest(string_to_array(t.n, ' ')) w
                                    where length(w) >= 3 and (' ' || dl.hay || ' ') not like '% ' || w || ' %'))
            order by dl.name limit 1) end,
         t.r, t.cnt
    from t
   order by (t.channel = 'bayi') desc, t.r, t.name, t.code;
end $function$;

select app.apply_grants();

select 'SONUC: kolon=' || (select count(*) from information_schema.columns where table_name = 'container_ledger' and column_name = 'free_qty')
    || ' | tetikleyici=' || (select count(*) from pg_trigger where tgname = 'container_ledger_free')
    || ' | kap_bakiyesi=' || (select count(*) from public.container_balances) as sonuc;
commit;
