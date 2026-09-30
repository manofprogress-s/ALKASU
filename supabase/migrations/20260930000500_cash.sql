-- ALKASU 0005 — Gider, kasa hareketleri, gün sonu kapatma
-- Kurallar: K-01..K-10

create table public.expense_categories (
  id           uuid primary key default gen_random_uuid(),
  business_id  uuid not null references public.businesses(id),
  name         text not null check (length(trim(name)) > 0),
  active       boolean not null default true,
  sort         smallint not null default 0
);
create unique index expense_categories_name on public.expense_categories(business_id, lower(name));

create table public.expenses (
  id            uuid primary key,
  business_id   uuid not null references public.businesses(id),
  location_id   uuid not null references public.locations(id),
  category_id   uuid not null references public.expense_categories(id),
  expense_date  date not null,
  amount        numeric(14,2) not null check (amount > 0),
  method        text not null check (method in ('kasa', 'banka')),
  description   text,
  session_id    uuid references public.cash_sessions(id),
  status        text not null default 'gecerli' check (status in ('gecerli', 'iptal')),
  created_by    uuid,
  created_at    timestamptz not null default now(),
  cancelled_by  uuid,
  cancelled_at  timestamptz,
  cancel_reason text
);
create index expenses_business_date on public.expenses(business_id, expense_date desc);
create trigger expenses_audit after insert or update on public.expenses for each row execute function audit.tg_row();

alter table public.expense_categories enable row level security;
alter table public.expenses enable row level security;
create policy expense_categories_select on public.expense_categories for select to authenticated using (app.is_admin(business_id));
create policy expenses_select on public.expenses for select to authenticated using (app.is_admin(business_id));

-- K-10: varsayılan kategoriler işletme oluşturulurken eklenir
create or replace function app.tg_business_defaults() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  insert into public.expense_categories(business_id, name, sort)
  select new.id, x.name, x.ord from unnest(array['Kira','Elektrik/Su/Doğalgaz','Yakıt','Araç bakım','Personel',
                                                 'Vergi/SGK','Kırtasiye/Sarf','Yemek','Diğer']) with ordinality as x(name, ord);
  return new;
end $$;
create trigger businesses_defaults after insert on public.businesses
  for each row execute function app.tg_business_defaults();

create or replace function public.upsert_expense_category(p_business uuid, p_name text, p_id uuid default null, p_active boolean default true)
returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_id uuid;
begin
  perform app.require_role(p_business, 'yonetici');
  if exists (select 1 from public.expense_categories where business_id = p_business and lower(name) = lower(trim(p_name))
             and id is distinct from p_id) then
    raise exception 'Bu adla bir kategori zaten var' using errcode = '23505';
  end if;
  if p_id is null then
    insert into public.expense_categories(business_id, name, active, sort)
    values (p_business, trim(p_name), p_active, 100) returning id into v_id;
  else
    update public.expense_categories set name = trim(p_name), active = p_active
     where id = p_id and business_id = p_business returning id into v_id;
  end if;
  return v_id;
end $$;

-- RPC: gider (K-09)  p = { id, category_id, expense_date?, amount, method: kasa|banka, description? }
create or replace function public.add_expense(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id   uuid := (p->>'id')::uuid;
  v_amt  numeric := round((p->>'amount')::numeric, 2);
  v_loc  uuid := app.default_location(p_business);
  v_sess public.cash_sessions;
begin
  perform app.require_role(p_business, 'yonetici');
  if v_id is null then raise exception 'Kayıt kimliği eksik' using errcode = '22023'; end if;
  if exists (select 1 from public.expenses where id = v_id) then return v_id; end if;
  if v_amt is null or v_amt <= 0 then raise exception 'Tutar sıfırdan büyük olmalıdır' using errcode = '22023'; end if;
  if coalesce(p->>'method', '') not in ('kasa', 'banka') then raise exception 'Ödeme şekli geçersiz' using errcode = '22023'; end if;
  if not exists (select 1 from public.expense_categories where id = (p->>'category_id')::uuid and business_id = p_business) then
    raise exception 'Gider kategorisi bulunamadı' using errcode = 'P0002';
  end if;
  if p->>'method' = 'kasa' then v_sess := app.ensure_session(p_business, v_loc); end if;
  insert into public.expenses(id, business_id, location_id, category_id, expense_date, amount, method, description, session_id, created_by)
  values (v_id, p_business, v_loc, (p->>'category_id')::uuid,
          coalesce(nullif(p->>'expense_date', '')::date, app.local_date(now())), v_amt, p->>'method',
          nullif(trim(p->>'description'), ''), v_sess.id, auth.uid());
  if p->>'method' = 'kasa' then
    perform app.post_cash(p_business, v_sess.id, 'gider', -v_amt, 'expense', v_id, nullif(trim(p->>'description'), ''));
  end if;
  return v_id;
end $$;

create or replace function public.cancel_expense(p_expense uuid, p_reason text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare e public.expenses; v_sess public.cash_sessions;
begin
  select * into e from public.expenses where id = p_expense for update;
  if e.id is null then raise exception 'Gider bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(e.business_id, 'yonetici');
  if e.status <> 'gecerli' then raise exception 'Gider zaten iptal edilmiş' using errcode = 'P0001'; end if;
  if coalesce(trim(p_reason), '') = '' then raise exception 'İptal nedeni zorunludur' using errcode = '22023'; end if;
  if e.method = 'kasa' then
    v_sess := app.ensure_session(e.business_id, e.location_id);
    perform app.post_cash(e.business_id, v_sess.id, 'duzeltme', e.amount, 'expense_cancel', e.id, 'Gider iptali');
  end if;
  update public.expenses set status = 'iptal', cancelled_by = auth.uid(), cancelled_at = now(), cancel_reason = trim(p_reason)
   where id = e.id;
end $$;

-- RPC: kasaya giriş / kasadan çıkış  p = { type: giris|cikis|duzeltme, amount (duzeltme için işaretli), note }
create or replace function public.add_cash_movement(p_business uuid, p jsonb) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_amt numeric := round((p->>'amount')::numeric, 2); v_sess public.cash_sessions; v_type text := p->>'type';
begin
  perform app.require_role(p_business, 'yonetici');
  if v_type not in ('giris', 'cikis', 'duzeltme') then raise exception 'Hareket türü geçersiz' using errcode = '22023'; end if;
  if v_amt is null or v_amt = 0 or (v_type <> 'duzeltme' and v_amt < 0) then
    raise exception 'Tutar geçersiz' using errcode = '22023';
  end if;
  if coalesce(trim(p->>'note'), '') = '' then raise exception 'Açıklama zorunludur' using errcode = '22023'; end if;
  v_sess := app.ensure_session(p_business, app.default_location(p_business));
  perform app.post_cash(p_business, v_sess.id, v_type,
                        case when v_type = 'cikis' then -v_amt else v_amt end, 'manual', null, trim(p->>'note'));
  perform app.audit(p_business, 'kasa_' || v_type, 'cash_movements', v_sess.id::text, null, p);
end $$;

-- Kasa günü özeti (yönetici). p_session null = açık gün
create or replace function public.cash_session_summary(p_business uuid, p_session uuid default null) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare s public.cash_sessions; v jsonb; v_pos numeric;
begin
  perform app.require_role(p_business, 'yonetici');
  if p_session is null then
    select * into s from public.cash_sessions where business_id = p_business and status = 'acik'
     and location_id = app.default_location(p_business);
    if s.id is null then
      return jsonb_build_object('status', 'yok',
        'opening_cash', coalesce((select carry_over from public.cash_sessions where business_id = p_business and status = 'kapali'
                                   order by closed_at desc limit 1), 0));
    end if;
  else
    select * into s from public.cash_sessions where id = p_session and business_id = p_business;
    if s.id is null then raise exception 'Kasa günü bulunamadı' using errcode = 'P0002'; end if;
  end if;

  select coalesce(jsonb_object_agg(type, total), '{}'::jsonb) into v
    from (select type, sum(amount) as total from public.cash_movements where session_id = s.id group by type) t;

  v_pos := coalesce((select sum(sp.amount) from public.sale_payments sp join public.sales sa on sa.id = sp.sale_id
                      where sa.session_id = s.id and sa.status = 'tamamlandi' and sp.method = 'pos'), 0)
         + coalesce((select sum(amount) from public.customer_payments where session_id = s.id and method = 'pos'), 0)
         - coalesce((select sum(amount) from public.customer_payments where cancel_session_id = s.id and method = 'pos'), 0)
         - coalesce((select sum(rp.amount) from public.return_payments rp join public.returns r on r.id = rp.return_id
                      where r.session_id = s.id and rp.method = 'pos'), 0);

  return jsonb_build_object(
    'id', s.id, 'no', s.no, 'status', s.status, 'opened_at', s.opened_at, 'closed_at', s.closed_at,
    'opening_cash', s.opening_cash,
    'movements', v,
    'expected_cash', coalesce(s.expected_cash, s.opening_cash + coalesce((select sum(amount) from public.cash_movements
                                                                          where session_id = s.id and type <> 'gun_sonu_teslim'), 0)),
    'pos_expected', coalesce(s.pos_expected, v_pos),
    'sales_count', (select count(*) from public.sales where session_id = s.id and status = 'tamamlandi'),
    'sales_total', coalesce((select sum(grand_total) from public.sales where session_id = s.id and status = 'tamamlandi'), 0),
    'goods_total', coalesce((select sum(goods_net) from public.sales where session_id = s.id and status = 'tamamlandi'), 0),
    'credit_sales', coalesce((select sum(sp.amount) from public.sale_payments sp join public.sales sa on sa.id = sp.sale_id
                               where sa.session_id = s.id and sa.status = 'tamamlandi' and sp.method = 'veresiye'), 0),
    'late_sync_count', (select count(*) from public.sales where session_id = s.id and late_sync),
    'counted_cash', s.counted_cash, 'cash_diff', s.cash_diff, 'diff_note', s.diff_note,
    'pos_slip', s.pos_slip, 'pos_diff', s.pos_diff, 'carry_over', s.carry_over
  );
end $$;

-- RPC: gün sonu kapatma (K-03..K-06)
-- p = { session_id, counted_cash, carry_over, pos_slip?, diff_note? }
create or replace function public.close_cash_session(p_business uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  s        public.cash_sessions;
  v_set    public.app_settings;
  v_sum    jsonb;
  v_exp    numeric;
  v_cnt    numeric := round((p->>'counted_cash')::numeric, 2);
  v_carry  numeric := round((p->>'carry_over')::numeric, 2);
  v_slip   numeric := round(nullif(p->>'pos_slip', '')::numeric, 2);
  v_posexp numeric;
  v_diff   numeric;
begin
  perform app.require_role(p_business, 'yonetici');
  select * into s from public.cash_sessions where id = (p->>'session_id')::uuid and business_id = p_business for update;
  if s.id is null then raise exception 'Kasa günü bulunamadı' using errcode = 'P0002'; end if;
  if s.status <> 'acik' then raise exception 'Kasa günü zaten kapalı (K-06)' using errcode = 'P0001'; end if;
  if v_cnt is null or v_cnt < 0 then raise exception 'Sayılan nakit girilmelidir' using errcode = '22023'; end if;
  if v_carry is null or v_carry < 0 or v_carry > v_cnt then
    raise exception 'Devreden nakit 0 ile sayılan nakit arasında olmalıdır (K-05)' using errcode = '22023';
  end if;
  select * into v_set from public.app_settings where business_id = p_business;

  v_sum := public.cash_session_summary(p_business, s.id);
  v_exp := (v_sum->>'expected_cash')::numeric;
  v_posexp := (v_sum->>'pos_expected')::numeric;
  v_diff := v_cnt - v_exp;
  if abs(v_diff) > v_set.cash_diff_tolerance and coalesce(trim(p->>'diff_note'), '') = '' then
    raise exception 'Kasa farkı % ₺ toleransı (% ₺) aşıyor; açıklama zorunludur (K-04)', v_diff, v_set.cash_diff_tolerance
      using errcode = '22023';
  end if;

  -- K-05: sayılan − devreden = gün sonu teslim
  perform app.post_cash(p_business, s.id, 'gun_sonu_teslim', -(v_cnt - v_carry), 'cash_session', s.id, 'Gün sonu teslim');

  update public.cash_sessions set
    status = 'kapali', closed_at = now(), closed_by = auth.uid(),
    expected_cash = v_exp, counted_cash = v_cnt, cash_diff = v_diff, diff_note = nullif(trim(p->>'diff_note'), ''),
    pos_expected = v_posexp, pos_slip = v_slip, pos_diff = case when v_slip is not null then v_slip - v_posexp end,
    carry_over = v_carry
  where id = s.id;

  perform app.audit(p_business, 'kasa_kapanis', 'cash_sessions', s.id::text, null,
                    jsonb_build_object('expected', v_exp, 'counted', v_cnt, 'diff', v_diff, 'carry_over', v_carry,
                                       'pos_expected', v_posexp, 'pos_slip', v_slip));
  return public.cash_session_summary(p_business, s.id);
end $$;

select app.apply_grants();
