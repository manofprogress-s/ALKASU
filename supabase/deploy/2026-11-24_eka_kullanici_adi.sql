-- Enes Karakaya (yönetici) kullanıcı adı: EKA (kullanıcı 24.11, D-120)
-- Hesap e-postayla açık kalır; girişte "EKA" yazılınca e-posta sunucuda bulunur (giris/actions.ts). Şifreye dokunulmaz.
begin;
do $$
declare m public.memberships;
begin
  if exists (select 1 from public.memberships where username = 'eka') then raise exception 'eka kullanıcı adı zaten kullanılıyor'; end if;
  if exists (select 1 from auth.users where lower(email) = 'eka@kullanici.alkasu.app') then raise exception 'eka sentetik hesabı zaten var'; end if;
  select * into m from public.memberships where display_name = 'Enes Karakaya' and role = 'yonetici' and active;
  if m.id is null then raise exception 'Enes Karakaya üyeliği bulunamadı'; end if;
  update public.memberships set username = 'eka' where id = m.id;
  perform app.audit(m.business_id, 'kullanici_adi', 'memberships', m.id::text,
                    jsonb_build_object('username', m.username), jsonb_build_object('username', 'eka'));
end $$;
select 'SONUC: ' || string_agg(display_name || '=' || coalesce(username, '-'), ' ; ' order by display_name) as sonuc
  from public.memberships where active and role in ('yonetici', 'satis', 'sevkiyat');
commit;
