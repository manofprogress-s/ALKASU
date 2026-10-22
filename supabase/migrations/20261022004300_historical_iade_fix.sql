-- ALKASU 0043 — Geçmiş faturalarda iade tespiti: "İade" (büyük noktalı İ) canlı veritabanının yerel ayarında ilike ile eşleşmiyordu.
-- Kural: GG-04 · Karar: D-102. İade türleri her ortamda eksi yazılır; yüklenmiş kayıtlar düzeltilir.

create or replace function app.is_return_doc(p_doc_type text) returns boolean
language sql immutable as $$
  select position('iade' in lower(translate(coalesce(p_doc_type, ''), 'İIı', 'iii'))) > 0
$$;

create or replace function app.import_historical_invoices(p_business uuid, p_rows jsonb) returns jsonb
language plpgsql security definer set search_path = public, pg_temp as $$
declare v_ins int := 0; v_upd int := 0; x jsonb; v_total numeric; v_new boolean;
begin
  for x in select * from jsonb_array_elements(p_rows) loop
    if coalesce(x->>'direction', '') not in ('satis', 'alis') then raise exception 'Yön geçersiz: %', x->>'direction' using errcode = '22023'; end if;
    if coalesce(trim(x->>'doc_no'), '') = '' then raise exception 'Fatura numarası eksik' using errcode = '22023'; end if;
    v_total := abs(round((x->>'total')::numeric, 2));
    if app.is_return_doc(x->>'doc_type') then v_total := -v_total; end if;
    insert into public.historical_invoices(business_id, direction, doc_type, doc_no, doc_date, party_name, party_code, tax_no, total, vat, net, cancelled)
    values (p_business, x->>'direction', trim(x->>'doc_type'), trim(x->>'doc_no'), (x->>'doc_date')::timestamptz,
            nullif(trim(x->>'party_name'), ''), nullif(trim(x->>'party_code'), ''), nullif(trim(x->>'tax_no'), ''),
            v_total, nullif(x->>'vat', '')::numeric, nullif(x->>'net', '')::numeric, coalesce((x->>'cancelled')::boolean, false))
    on conflict (business_id, direction, doc_type, doc_no) do update
       set doc_date = excluded.doc_date, party_name = excluded.party_name, party_code = excluded.party_code, tax_no = excluded.tax_no,
           total = excluded.total, vat = excluded.vat, net = excluded.net, cancelled = excluded.cancelled, imported_at = now()
    returning (xmax = 0) into v_new;
    if v_new then v_ins := v_ins + 1; else v_upd := v_upd + 1; end if;
  end loop;
  return jsonb_build_object('inserted', v_ins, 'updated', v_upd);
end $$;

-- Yüklenmiş iade kayıtlarını düzelt
update public.historical_invoices set total = -abs(total) where app.is_return_doc(doc_type) and total > 0;

select app.apply_grants();
