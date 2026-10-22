-- Canlı: her ay düzenli giderler (0041, K-15..K-17, D-101)
begin;
-- ALKASU 0041 — Her ay düzenli giderler (maaş, kira ...)
-- Kural: BUSINESS_RULES K-15..K-17 · Karar: D-101 (kullanıcı isteği 22.10: "her ay tek tek girmeyelim, zamanı geldiğinde grafiğe yansısın")
--  * Yönetici bir gideri "her ay düzenli" işaretler: kalem, tutar, kime, ayın günü, başlangıç ayı.
--  * Ayın o günü geldiğinde gider kaydı kendiliğinden oluşur (Giderler / Gelir-gider açıldığında işlenir; zamanlayıcı gerekmez).
--  * Her şablon + ay için en fazla bir kayıt (iptal edilse bile yeniden oluşmaz). Ödeme: banka/havale (kasayı etkilemez).
--  * Tutar değişikliği yalnızca sonraki aylara yansır; geçmiş kayıtlar değişmez.

create table if not exists public.recurring_expenses (
  id            uuid primary key default gen_random_uuid(),
  business_id   uuid not null references public.businesses(id),
  category_id   uuid not null references public.expense_categories(id),
  amount        numeric(14,2) not null check (amount > 0 and amount <= 10000000),
  payee         text check (length(payee) <= 120),
  description   text check (length(description) <= 300),
  day_of_month  smallint not null check (day_of_month between 1 and 31),   -- ay kısaysa ayın son günü
  start_month   date not null check (start_month = date_trunc('month', start_month)::date),
  active        boolean not null default true,
  created_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists recurring_expenses_business on public.recurring_expenses(business_id) where active;
alter table public.recurring_expenses enable row level security;
drop policy if exists recurring_expenses_select on public.recurring_expenses;
create policy recurring_expenses_select on public.recurring_expenses for select to authenticated using (app.is_admin(business_id));
drop trigger if exists recurring_expenses_audit on public.recurring_expenses;
create trigger recurring_expenses_audit after insert or update on public.recurring_expenses for each row execute function audit.tg_row();
drop trigger if exists recurring_expenses_touch on public.recurring_expenses;
create trigger recurring_expenses_touch before update on public.recurring_expenses for each row execute function app.touch_updated_at();

alter table public.expenses add column if not exists recurring_id uuid references public.recurring_expenses(id);
alter table public.expenses add column if not exists period date;   -- düzenli giderin ayı (ayın 1'i)
-- Aynı şablon + ay bir kez (iptal edilmiş olsa bile yeniden üretilmez)
create unique index if not exists expenses_recurring_period on public.expenses(recurring_id, period) where recurring_id is not null;

-- Vadesi gelen düzenli giderleri işler. p_today test içindir. En fazla 24 ay geriye.
create or replace function app.post_due_recurring(p_business uuid, p_today date default null) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_today date := coalesce(p_today, app.local_date(now()));
  r public.recurring_expenses; m date; v_due date; v_n int := 0; v_ins int;
begin
  for r in select * from public.recurring_expenses where business_id = p_business and active order by created_at loop
    for m in select d::date from generate_series(greatest(r.start_month, (date_trunc('month', v_today) - interval '23 months')::date),
                                                 date_trunc('month', v_today)::date, interval '1 month') d loop
      v_due := least(m + (r.day_of_month - 1), (m + interval '1 month' - interval '1 day')::date);
      continue when v_due > v_today;
      insert into public.expenses(id, business_id, location_id, category_id, expense_date, amount, method, description, payee,
                                  created_by, recurring_id, period)
      values (gen_random_uuid(), p_business, app.default_location(p_business), r.category_id, v_due, r.amount, 'banka',
              coalesce(r.description, 'Düzenli gider'), r.payee, r.created_by, r.id, m)
      on conflict (recurring_id, period) where recurring_id is not null do nothing;
      get diagnostics v_ins = row_count;
      v_n := v_n + v_ins;
    end loop;
  end loop;
  return v_n;
end $$;

create or replace function public.post_due_recurring(p_business uuid) returns integer
language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform app.require_role(p_business, 'yonetici');
  return app.post_due_recurring(p_business);
end $$;

-- p = { id?, category_id, amount, payee?, description?, day_of_month, start_month (YYYY-MM-01), active? }
create or replace function public.upsert_recurring_expense(p_business uuid, p jsonb) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_id   uuid := nullif(p->>'id', '')::uuid;
  v_amt  numeric := round((p->>'amount')::numeric, 2);
  v_day  int := (p->>'day_of_month')::int;
  v_start date := date_trunc('month', coalesce(nullif(p->>'start_month', '')::date, app.local_date(now())))::date;
  v_cat  public.expense_categories;
begin
  perform app.require_role(p_business, 'yonetici');
  if v_amt is null or v_amt <= 0 then raise exception 'Tutar sıfırdan büyük olmalıdır' using errcode = '22023'; end if;
  if v_amt > 10000000 then raise exception 'Tutar çok büyük; lütfen kontrol edin' using errcode = '22023'; end if;
  if v_day is null or v_day < 1 or v_day > 31 then raise exception 'Ödeme günü 1 ile 31 arasında olmalı' using errcode = '22023'; end if;
  select * into v_cat from public.expense_categories where id = (p->>'category_id')::uuid and business_id = p_business;
  if v_cat.id is null then raise exception 'Gider kategorisi bulunamadı' using errcode = 'P0002'; end if;
  if v_id is null then
    insert into public.recurring_expenses(business_id, category_id, amount, payee, description, day_of_month, start_month, created_by)
    values (p_business, v_cat.id, v_amt, nullif(trim(p->>'payee'), ''), nullif(trim(p->>'description'), ''), v_day, v_start, auth.uid())
    returning id into v_id;
  else
    update public.recurring_expenses set category_id = v_cat.id, amount = v_amt, payee = nullif(trim(p->>'payee'), ''),
           description = nullif(trim(p->>'description'), ''), day_of_month = v_day,
           active = coalesce((p->>'active')::boolean, active)
     where id = v_id and business_id = p_business;
    if not found then raise exception 'Düzenli gider bulunamadı' using errcode = 'P0002'; end if;
  end if;
  perform app.post_due_recurring(p_business);
  return v_id;
end $$;

create or replace function public.set_recurring_active(p_id uuid, p_active boolean) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_b uuid;
begin
  select business_id into v_b from public.recurring_expenses where id = p_id;
  if v_b is null then raise exception 'Düzenli gider bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_b, 'yonetici');
  -- Yeniden başlatılınca durdurulduğu aylar geriye dönük üretilmez: bu aydan devam eder
  update public.recurring_expenses set active = p_active,
         start_month = case when p_active and not active then greatest(start_month, date_trunc('month', app.local_date(now()))::date) else start_month end
   where id = p_id;
  if p_active then perform app.post_due_recurring(v_b); end if;
end $$;

select app.apply_grants();

select 'SONUC: tablo=' || (select count(*) from information_schema.tables where table_name = 'recurring_expenses') || ' | fn=' || (select count(*) from pg_proc where proname in ('post_due_recurring','upsert_recurring_expense','set_recurring_active')) || ' | gider=' || (select count(*) from public.expenses) as sonuc;
commit;
