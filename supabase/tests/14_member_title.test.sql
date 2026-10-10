-- Kullanıcı unvanı (R-09): yalnızca yönetici yazar, my_context döner
begin;
select test.fixture();
create function test.mid(p_user uuid) returns uuid language sql stable security definer as $$ select id from public.memberships where user_id = p_user $$;
grant execute on all functions in schema test to authenticated;

select test.login(test.u_admin());
select public.set_member_title(test.mid(test.u_satis()), '  Accounting Specialist - Muhasebe Teknisyeni ');
select test.eq((select title from public.memberships where user_id = test.u_satis()), 'Accounting Specialist - Muhasebe Teknisyeni', 'Yönetici unvan yazar (boşluklar kırpılır)');
select test.throws($$select public.set_member_title(test.mid(test.u_satis()), repeat('x', 81))$$, '%80 karakter%', 'Unvan en fazla 80 karakter');
select test.ok((select count(*) from audit.log where action = 'unvan') >= 1, 'Unvan değişikliği işlem geçmişine yazılır');

select test.login(test.u_satis());
select test.eq((public.my_context()->0->>'title'), 'Accounting Specialist - Muhasebe Teknisyeni', 'Kullanıcı kendi unvanını görür');
select test.eq((public.my_context()->0->>'role'), 'satis', 'Unvan rolü değiştirmez');
select test.throws($$select public.set_member_title(test.mid(test.u_satis()), 'Müdür')$$, '%yetkiniz yok%', 'Unvanı yalnızca yönetici değiştirir');

select test.login(test.u_admin());
select public.set_member_title(test.mid(test.u_satis()), '');
select test.ok((select title from public.memberships where user_id = test.u_satis()) is null, 'Boş unvan kaldırır');
rollback;
