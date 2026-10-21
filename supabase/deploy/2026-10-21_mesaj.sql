-- Canlı: müşteri mesaj kaydı (0038, M-27/D-098)
begin;
-- ALKASU 0038 — Müşteriye WhatsApp / SMS mesajı (hazır taslaklar) ve gönderim kaydı
-- Kural: BUSINESS_RULES M-27 · Karar: D-098
-- Mesajı sistem GÖNDERMEZ: personel düğmeye basınca telefonundaki WhatsApp / SMS uygulaması hazır metinle açılır.
-- Burada yalnızca "kim, kime, hangi taslağı, hangi kanaldan açtı" kaydı tutulur (aynı müşteriye tekrar gönderimi önlemek için).
-- Kampanya iznini reddetmiş (kampanya_ret) ev müşterisine mesaj kaydı açılmaz.

create table if not exists public.customer_messages (
  id           bigint generated always as identity primary key,
  business_id  uuid not null references public.businesses(id),
  customer_id  uuid not null references public.customers(id),
  user_id      uuid not null,
  template     text not null check (template in ('tanitim', 'hatirlatma')),
  channel      text not null check (channel in ('whatsapp', 'sms')),
  sent_at      timestamptz not null default now()
);
create index if not exists customer_messages_customer on public.customer_messages(customer_id, sent_at desc);
alter table public.customer_messages enable row level security;
drop policy if exists customer_messages_select on public.customer_messages;
create policy customer_messages_select on public.customer_messages for select to authenticated
  using (app.has_role(business_id, 'yonetici', 'satis'));
drop trigger if exists customer_messages_immutable on public.customer_messages;
create trigger customer_messages_immutable before update or delete on public.customer_messages
  for each row execute function app.tg_immutable();

create or replace function public.log_customer_message(p_business uuid, p_customer uuid, p_template text, p_channel text) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare c public.customers; v_refused boolean;
begin
  perform app.require_role(p_business, 'yonetici', 'satis');
  select * into c from public.customers where id = p_customer and business_id = p_business;
  if c.id is null then raise exception 'Müşteri bulunamadı' using errcode = 'P0002'; end if;
  if p_template not in ('tanitim', 'hatirlatma') or p_channel not in ('whatsapp', 'sms') then
    raise exception 'Geçersiz mesaj' using errcode = '22023';
  end if;
  -- Kampanya iznini açıkça reddeden müşteriye ticari ileti gönderilmez (K-03)
  v_refused := not c.marketing_consent and exists (select 1 from public.privacy_events e where e.customer_id = c.id and e.kind = 'kampanya_ret');
  if v_refused and c.channel = 'perakende' then
    raise exception 'Bu müşteri kampanya mesajı almak istemediğini bildirmiş' using errcode = 'P0001';
  end if;
  insert into public.customer_messages(business_id, customer_id, user_id, template, channel)
  values (p_business, p_customer, auth.uid(), p_template, p_channel);
  return jsonb_build_object('ok', true);
end $$;

select app.apply_grants();

select 'SONUC: customer_messages=' || (select count(*) from information_schema.tables where table_name='customer_messages') || ' fn=' || (select count(*) from pg_proc where proname='log_customer_message') as sonuc;
commit;
