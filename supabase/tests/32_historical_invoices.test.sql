-- Logo İşbaşı geçmiş faturaları gelir-gider raporunda (GG-04..GG-06)
begin;
select test.fixture();
grant execute on all functions in schema test to authenticated;
create function test.hist() returns jsonb language sql as $$ select '[
  {"direction":"satis","doc_type":"Toptan Satış Faturası","doc_no":"DIG1","doc_date":"2026-06-10T10:00:00+03:00","party_name":"A Firma","total":1200,"vat":200,"net":1000},
  {"direction":"satis","doc_type":"Perakende Satış Faturası","doc_no":"ARV1","doc_date":"2026-06-20T10:00:00+03:00","party_name":"B Kişi","total":300},
  {"direction":"satis","doc_type":"Perakende Satış Faturası","doc_no":"ARV2","doc_date":"2026-06-21T10:00:00+03:00","party_name":"C","total":999,"cancelled":true},
  {"direction":"alis","doc_type":"Satınalma Faturası","doc_no":"K1","doc_date":"2026-06-05T09:00:00+03:00","party_name":"Kızılay","total":800},
  {"direction":"alis","doc_type":"Satınalma İade Faturası","doc_no":"K2","doc_date":"2026-06-06T09:00:00+03:00","party_name":"Kızılay","total":100},
  {"direction":"satis","doc_type":"Toptan Satış Faturası","doc_no":"DIG2","doc_date":"2026-10-02T10:00:00+03:00","party_name":"A Firma","total":5000}
]'::jsonb $$;

select test.eq(app.import_historical_invoices(test.biz(), test.hist())->>'inserted', '6', 'Faturalar yüklenir');
select test.eq(app.import_historical_invoices(test.biz(), test.hist())->>'updated', '6', 'Tekrar yükleme çift kayıt oluşturmaz');
select test.eq((select count(*)::int from public.historical_invoices), 6, 'Toplam 6 kayıt');
select test.eq((select total from public.historical_invoices where doc_no = 'K2'), -100.00::numeric, 'İade faturası eksi');
select test.ok(app.is_return_doc('Satınalma İade Faturası') and app.is_return_doc('SATIŞ İADE FATURASI') and app.is_return_doc('iade')
               and not app.is_return_doc('Satınalma Faturası') and not app.is_return_doc(null), 'İade türü yerel ayardan bağımsız tanınır');

select test.login(test.u_admin());
-- Sınır yokken geçmiş rapora girmez
select test.eq((public.profit_report(test.biz(), date '2026-06-01', date '2026-06-30', 'ay')->'periods'->0->>'history_income')::numeric, 0::numeric, 'Sınır ayarlanmadan geçmiş sayılmaz');
select public.set_history_until(test.biz(), date '2026-09-30');
create temp table jun on commit drop as select public.profit_report(test.biz(), date '2026-06-01', date '2026-06-30', 'ay')->'periods'->0 as p;
select test.eq((select (p->>'income_invoiced')::numeric from jun), 1500::numeric, 'Satış faturaları faturalı gelir (iptal hariç)');
select test.eq((select (p->>'purchases')::numeric from jun), 700::numeric, 'Alış − iade = mal alımı');
select test.eq((select (p->>'gross_profit')::numeric from jun), 800::numeric, 'Brüt kâr = 1500 − 700');
select test.eq((select (p->>'history_sales_count')::int from jun), 2, 'Geçmiş satış faturası sayısı');
-- Sınırdan sonraki (Ekim) Logo faturası ALKASU ile çakışmasın diye sayılmaz
select test.eq((public.profit_report(test.biz(), date '2026-10-01', date '2026-10-31', 'ay')->'periods'->0->>'history_income')::numeric, 0::numeric, 'Sınır sonrası Logo faturası sayılmaz');
select public.set_history_until(test.biz(), date '2026-10-31');
select test.eq((public.profit_report(test.biz(), date '2026-10-01', date '2026-10-31', 'ay')->'periods'->0->>'history_income')::numeric, 5000::numeric, 'Sınır ileri alınınca dahil olur');

select test.login(test.u_satis());
select test.eq((select count(*)::int from public.historical_invoices), 0, 'Personel geçmiş faturaları görmez');
select test.throws($$select public.set_history_until(test.biz(), current_date)$$, '%yetkiniz yok%', 'Sınırı yalnızca yönetici değiştirir');
select test.throws($$select app.import_historical_invoices(test.biz(), '[]')$$, '%permission denied%', 'Yükleme çekirdeği personele kapalı');
rollback;
