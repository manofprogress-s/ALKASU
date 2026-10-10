-- ALKASU 0020 — Kullanıcı unvanı (yalnızca görünüm; yetki rolden gelir)
-- Kural: BUSINESS_RULES §12 (R-09) · Karar: D-076

alter table public.memberships add column if not exists title text
  check (title is null or length(trim(title)) between 1 and 80);

-- Yönetici: kullanıcının unvanını yazar / kaldırır (boş = kaldır)
create or replace function public.set_member_title(p_membership uuid, p_title text) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_bid uuid; v_old text; v_new text := nullif(trim(coalesce(p_title, '')), '');
begin
  select business_id, title into v_bid, v_old from public.memberships where id = p_membership;
  if v_bid is null then raise exception 'Kullanıcı bulunamadı' using errcode = 'P0002'; end if;
  perform app.require_role(v_bid, 'yonetici');
  if length(coalesce(v_new, '')) > 80 then raise exception 'Unvan en fazla 80 karakter olabilir' using errcode = '22023'; end if;
  update public.memberships set title = v_new where id = p_membership;
  perform app.audit(v_bid, 'unvan', 'memberships', p_membership::text, jsonb_build_object('title', v_old), jsonb_build_object('title', v_new));
end $$;

create or replace function public.my_context() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'business_id', b.id, 'business_name', b.name,
    'location_id', app.default_location(b.id),
    'membership_id', m.id, 'role', m.role, 'display_name', m.display_name, 'title', m.title,
    'customer_id', m.customer_id, 'must_change_password', m.must_change_password
  ) order by b.name), '[]'::jsonb)
  from public.memberships m join public.businesses b on b.id = m.business_id
  where m.user_id = auth.uid() and m.active
$$;

select app.apply_grants();
