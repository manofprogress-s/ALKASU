-- Sipariş ekranı müşteri araması (M-28): limit dışı müşteriler, kısaltma, kelime içi, Türkçe harf, benzer adlar
begin;
select test.fixture();
create function test.s(q text) returns text language sql as $$
  select string_agg(name, ' | ' order by match_rank, name) from public.search_order_customers(test.biz(), q, 10) $$;
create function test.first(q text) returns text language sql as $$
  select name from public.search_order_customers(test.biz(), q, 10) order by match_rank, name limit 1 $$;
grant execute on all functions in schema test to authenticated;
select test.login(test.u_admin());
select public.upsert_customer(test.biz(), jsonb_build_object('code', 'K100', 'name', 'TÜRKİYE JOKEY KULÜBÜ DERNEĞİ', 'phone', '0532 444 55 66'));
select public.upsert_customer(test.biz(), jsonb_build_object('code', 'K101', 'name', 'Y.K. Gıda Ltd.Şti.'));
select public.upsert_customer(test.biz(), jsonb_build_object('code', 'K102', 'name', 'GOİS DIŞ TİCARET'));
select public.upsert_customer(test.biz(), jsonb_build_object('code', 'K103', 'name', 'Ali Yılmaz'));
select public.upsert_customer(test.biz(), jsonb_build_object('code', 'K104', 'name', 'Ali Yılmaz İnşaat'));
select public.upsert_customer(test.biz(), jsonb_build_object('code', 'K105', 'name', 'Aliye Yılmazer'));
select public.upsert_customer(test.biz(), jsonb_build_object('code', 'K106', 'name', 'ZİRVEGÜL GIDA'));
-- 1.000 satır sınırını aşan liste: Z ile başlayan müşteri, 1.050 kayıt arkasında da bulunur
select test.logout();
insert into public.customers(business_id, code, name)
select test.biz(), 'X' || g, 'AAA Dolgu ' || lpad(g::text, 4, '0') from generate_series(1, 1050) g;
select test.login(test.u_admin());

-- 1. Tam ad
select test.eq(test.first('Ali Yılmaz'), 'Ali Yılmaz', 'Tam ad en üstte');
select test.eq((select match_rank from public.search_order_customers(test.biz(), 'ali yilmaz', 10) where name = 'Ali Yılmaz'), 0, 'Tam eşleşme sırası 0');
select test.eq(test.first('zirvegül gıda'), 'ZİRVEGÜL GIDA', '1.000 satır sınırının ötesindeki müşteri bulunur');
-- 2. Kısaltma
select test.eq(test.first('TJK'), 'TÜRKİYE JOKEY KULÜBÜ DERNEĞİ', 'Baş harflerle (TJK)');
select test.eq(test.first('yk gida'), 'Y.K. Gıda Ltd.Şti.', 'Noktalı kısaltma, noktasız yazım');
select test.eq(test.first('Y.K.'), 'Y.K. Gıda Ltd.Şti.', 'Noktalı yazım');
select test.ok(test.s('ltd sti') like '%Y.K. Gıda%', 'Ltd.Şti. → "ltd sti"');
-- 3. Adın ortasındaki kelime / kelime sırası
select test.eq(test.first('jokey'), 'TÜRKİYE JOKEY KULÜBÜ DERNEĞİ', 'Ortadaki kelime');
select test.eq(test.first('kulübü türkiye'), 'TÜRKİYE JOKEY KULÜBÜ DERNEĞİ', 'Kelime sırası farklı');
select test.eq(test.first('ticaret'), 'GOİS DIŞ TİCARET', 'Son kelime');
-- 4. Türkçe harf ve büyük/küçük
select test.eq(test.first('gois'), 'GOİS DIŞ TİCARET', 'İ → i');
select test.eq(test.first('GOIS DIS'), 'GOİS DIŞ TİCARET', 'Büyük harf, Türkçe karaktersiz');
select test.eq(test.first('ZIRVEGUL'), 'ZİRVEGÜL GIDA', 'Ü/İ olmadan');
select test.eq(test.first('  ali    yılmaz  '), 'Ali Yılmaz', 'Fazla boşluk');
select test.eq(test.first('ALİ YILMAZ'), 'Ali Yılmaz', 'İ/I büyük harf');
-- 5. Benzer adlar: doğru olan üstte, diğerleri altta ve ayrı
select test.eq(test.s('ali yılmaz'), 'Ali Yılmaz | Ali Yılmaz İnşaat | Aliye Yılmazer', 'Tam → başlayan → içeren sırası');
select test.eq((select count(*)::int from public.search_order_customers(test.biz(), 'ali yılmaz', 10) where match_rank = 0), 1, 'Tek tam eşleşme');
-- Diğer alanlar ve sınır
select test.eq(test.first('K105'), 'Aliye Yılmazer', 'Kodla arama');
select test.eq(test.first('444 55 66'), 'TÜRKİYE JOKEY KULÜBÜ DERNEĞİ', 'Telefonla arama');
select test.eq((select count(*)::int from public.search_order_customers(test.biz(), 'dolgu', 10)), 10, 'Sonuç sayısı sınırlı');
select test.eq((select max(total)::int from public.search_order_customers(test.biz(), 'dolgu', 10)), 1050, 'Toplam eşleşme sayısı bildirilir');
select test.eq((select count(*)::int from public.search_order_customers(test.biz(), '  .. ', 10)), 0, 'Boş sorgu sonuç vermez');
select test.login(test.u_depo());
select test.throws($$select * from public.search_order_customers(test.biz(), 'ali', 10)$$, '%yetkiniz yok%', 'Depo personeli müşteri arayamaz');
rollback;
