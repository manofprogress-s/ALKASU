"""Kurumsal firmalara özel fiyat listesi (kullanıcıdan, 09.10.2026) → SQL.
Kısaltmalar (kullanıcı onaylı): D./F.D. = Fuska damacana (DM-FS), 1,5 = Gürpınar 1,5 L (GP-15),
Bardak = Gürpınar bardak su (GP-BARDAK), S. soda = Beypazarı sade (BP-SADE),
Meyveli = Beypazarı meyveli (limon, elma, kırmızı çilek, mango, karadut), G. 0,5 = GP-05, G. 0,33 = GP-033,
F. 0,33 = FS-033, B. Tip = büyük tüp (TP-B), K. Tip = küçük tüp (TP-K)."""
import sys

CODES = {
    "D": ["DM-FS"], "FD": ["DM-FS"], "1,5": ["GP-15"], "Bardak": ["GP-BARDAK"], "S. soda": ["BP-SADE"],
    "Meyveli": ["BP-LIMON", "BP-ELMA", "BP-KCILEK", "BP-MANGO", "BP-KARADUT"],
    "G. 0,5": ["GP-05"], "G. 0,33": ["GP-033"], "F. 0,33": ["FS-033"], "B. Tip": ["TP-B"], "K. Tip": ["TP-K"],
}
# (listedeki ad, sistemdeki ad / yeni kart adı, fiyatlar)
FIRMS = [
    ("Aantrepo", "Aantrepo", {"D": "100", "1,5": "70", "Bardak": "100", "S. soda": "260", "Meyveli": "300"}),
    ("Akhause", "Akhause", {"D": "95", "Bardak": "100", "S. soda": "260"}),
    ("Akova Antrepo", "Akova Antrepo", {"D": "120", "Bardak": "110", "S. soda": "260", "Meyveli": "300"}),
    ("Ares", "Ares Trafo", {"D": "90", "Bardak": "100"}),
    ("Ares Metal", "Ares Metal", {"D": "90", "Bardak": "100"}),
    ("Blacksea", "Blacksea", {"D": "120"}),
    ("Cengiz Topel", "Cengiz Topel", {"D": "70,70"}),
    ("Crawler", "Crawler", {"D": "100", "G. 0,5": "65", "Bardak": "110", "S. soda": "260", "Meyveli": "300", "B. Tip": "1.500", "K. Tip": "340"}),
    ("Çekok", "Çekok", {"D": "120"}),
    ("Çay Hilal", "Çay Hilal", {"D": "100", "Bardak": "125"}),
    ("Energoin", "Energoin", {"D": "90", "Bardak": "100"}),
    ("Gasline Uçar", "Gasline Uçar", {"D": "100"}),
    ("Gois", "GOİS", {"D": "105", "Bardak": "110"}),
    ("Gültaş", "Gültaş", {"D": "90", "F. 0,33": "65"}),
    ("Gürko", "Gürko", {"D": "100", "Bardak": "110", "G. 0,33": "67,50"}),
    ("Hanlog", "Hanlog", {"D": "100"}),
    ("İzostil", "İzostil", {"D": "120"}),
    ("KBT Bıçak", "KBT Bıçak", {"D": "120"}),
    ("Marmara Galvaniz", "Marmara Galvaniz", {"D": "75", "G. 0,5": "75", "S. soda": "250"}),
    ("TGB Oto", "TGB Oto", {"D": "90", "1,5": "75"}),
    ("Öner Belgelendirme", "Öner Belgelendirme", {"FD": "110", "Bardak": "100", "S. soda": "260", "Meyveli": "300"}),
    ("Özka", "Özka", {"D": "120", "G. 0,5": "65"}),
    ("Prometeon Pirelli", "Prometeon", {"D": "70,70"}),
    ("Temka Cam", "Temka Cam", {"D": "100"}),
    ("TJK (Türkiye Jokey Kulübü)", "TJK (Türkiye Jokey Kulübü)", {"D": "111,10"}),
    ("Tolgotech", "Tolgotech", {"FD": "100", "F. 0,33": "75"}),
    ("Ünifer", "Ünifer", {"D": "120", "Bardak": "100"}),
    ("Yıkob (Yatırım İzleme)", "YİKOB", {"D": "90"}),
]

def num(s: str) -> str:
    return s.replace(".", "").replace(",", ".")

def q(s: str) -> str:
    return "'" + s.replace("'", "''") + "'"

rows = []
for _, name, prices in FIRMS:
    for k, v in prices.items():
        for code in CODES[k]:
            rows.append(f"({q(name)}, {q(code)}, {num(v)})")

VALUES = ",\n    ".join(rows)
sql = f"""-- Kurumsal firmalara özel fiyatlar (09.10.2026) — data/kurumsal_ozel_fiyatlar.py ile üretildi
do $$
declare b uuid; v_ht uuid; r record; v_cust uuid; v_unit uuid; n_new int := 0; n_price int := 0;
begin
  select id into b from public.businesses where name = 'Alay Ticaret';
  select user_id into v_ht from public.memberships where business_id = b and username = 'htopal' and active;
  for r in select * from (values
    {VALUES}
  ) v(firma, kod, fiyat) loop
    select id into v_cust from public.customers where business_id = b and lower(name) = lower(r.firma);
    if v_cust is null then
      insert into public.customers(business_id, code, name, channel, default_assignee)
      values (b, 'M' || lpad(app.next_number(b, 'musteri')::text, 5, '0'), r.firma, 'kurumsal', v_ht)
      returning id into v_cust;
      n_new := n_new + 1;
    end if;
    -- Satışta kullanılan birim: fiyatı olan en büyük birim
    select u.id into v_unit from public.product_units u join public.products p on p.id = u.product_id
     where p.business_id = b and p.code = r.kod and u.active and u.price is not null order by u.factor desc limit 1;
    if v_unit is null then
      select u.id into v_unit from public.product_units u join public.products p on p.id = u.product_id
       where p.business_id = b and p.code = r.kod and u.active order by u.factor desc limit 1;
    end if;
    if v_unit is null then raise exception 'Ürün bulunamadı: %', r.kod; end if;
    insert into public.customer_prices(customer_id, unit_id, business_id, price)
    values (v_cust, v_unit, b, r.fiyat)
    on conflict (customer_id, unit_id) do update set price = excluded.price, updated_at = now();
    n_price := n_price + 1;
  end loop;
  raise notice 'Yeni firma: %, özel fiyat: %', n_new, n_price;
end $$;
select count(distinct customer_id) as firma, count(*) as ozel_fiyat from public.customer_prices;
"""
sys.stdout.write(sql)
