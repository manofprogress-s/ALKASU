"""Gerçek ürün listesi (01.10.2026, kullanıcının ekran görüntüsünden) → içe aktarma satırları.
Varsayımlar docs/DECISIONS.md D-031..D-038'de."""
import json, csv
P = 200            # 1 palet = 200 paket/koli/adet (D-034, sonra sayımla düzeltilecek)
DAMACANA = 30 * 36 # 30 palet × 36 (D-033)
DEP_DAMACANA = 250 # D-035: geçici, kullanıcıya soruldu
rows = []
def add(code, name, brand, cat, base, kdv, sale, cost, pack=None, pack_name="Paket", stock=0, **kw):
    r = dict(urun_kodu=code, urun_adi=name, marka=brand, kategori=cat, temel_birim=base, kdv_orani=str(kdv),
             depozitolu="H", bos_kap_mi="H", aktif="E")
    if pack:
        r.update(paket_adi=pack_name, paket_icerik=str(pack), paket_satis_fiyati=f"{sale:.2f}",
                 alis_fiyati=f"{cost/pack:.4f}")
    else:
        if sale is not None: r["satis_fiyati"] = f"{sale:.2f}"
        if cost is not None: r["alis_fiyati"] = f"{cost:.4f}"
    if stock: r["acilis_stogu"] = str(stock)
    r.update({k: str(v) for k, v in kw.items()})
    rows.append(r)

water = {  # boyut: (paket içi, temel birim, kategori)
    "0,33": (12, "Şişe"), "0,5": (12, "Şişe"), "1": (12, "Şişe"), "1,5": (6, "Şişe"), "5": (2, "Bidon")}
lists = {
  "Gürpınar": ("GP", {"0,33": (65, 50), "0,5": (65, 50), "1,5": (60, 45), "5": (55, 45)}, (80, 55)),
  "Fuska":    ("FS", {"0,33": (65, 50), "0,5": (65, 50), "1": (65, 50), "1,5": (60, 45), "5": (55, 45)}, (80, 55)),
  "Kızılay":  ("KZ", {"0,33": (70, 55), "0,5": (70, 55), "1": (65, 50), "1,5": (65, 50), "5": (60, 45)}, (100, 75)),
}
for brand, (pre, sizes, (dsale, dcost)) in lists.items():
    # boş kap önce
    add(f"BK-{pre}", f"{brand} Boş Damacana", brand, "Boş kap", "Adet", 20, None, None, bos_kap_mi="E")
    add(f"DM-{pre}", f"{brand} 19 L Damacana", brand, "Damacana", "Damacana", 1, dsale, dcost, stock=DAMACANA,
        depozitolu="E", depozito_tutari=f"{DEP_DAMACANA:.2f}", bos_kap_urun_kodu=f"BK-{pre}")
    for size, (sale, cost) in sizes.items():
        n, base = water[size]
        add(f"{pre}-{size.replace(',', '')}", f"{brand} {size} L Su", brand, "Su", base, 1, sale, cost,
            pack=n, stock=P * n)
add("GP-19PET", "Gürpınar 19 L Pet (kullan-at)", "Gürpınar", "Damacana", "Adet", 1, 100, 65, stock=P)
add("GP-BARDAK", "Gürpınar Bardak Su", "Gürpınar", "Su", "Bardak", 1, 100, 65, pack=60, pack_name="Koli", stock=P * 60)
# Tüpler (D-036): boş getir dolu götür fiyatı; boş getirmezse depozito
add("BK-KTUP", "Boş Küçük Tüp", "Envanter", "Boş kap", "Adet", 20, None, None, bos_kap_mi="E")
add("BK-BTUP", "Boş Büyük Tüp", "Envanter", "Boş kap", "Adet", 20, None, None, bos_kap_mi="E")
add("TP-K", "Küçük Tüp (dolu)", "Envanter", "Tüp", "Tüp", 20, 350, 250, stock=P,
    depozitolu="E", depozito_tutari="500.00", bos_kap_urun_kodu="BK-KTUP")
add("TP-B", "Büyük Tüp (dolu)", "Envanter", "Tüp", "Tüp", 20, 1500, 1250, stock=P,
    depozitolu="E", depozito_tutari="1500.00", bos_kap_urun_kodu="BK-BTUP")
add("EN-PBARDAK", "Plastik Bardak", "Envanter", "Sarf", "Paket", 20, None, None, stock=P)   # fiyat bekleniyor
add("EN-KBARDAK", "Karton Bardak", "Envanter", "Sarf", "Paket", 20, 80, 60, stock=P)
add("EN-EPOMPA", "Elektrikli Pompa", "Envanter", "Pompa", "Adet", 20, 600, 400, stock=P)
add("EN-BPOMPA", "Basma Pompa", "Envanter", "Pompa", "Adet", 20, 150, 75, stock=P)
for name, sale, cost in [("Limon", 300, 265), ("Elma", 300, 265), ("Kırmızı Çilek", 300, 265),
                         ("Mango", 310, 275), ("Karadut", 310, 275), ("Sade", 260, 230)]:
    code = "BP-" + {"Kırmızı Çilek": "KCILEK"}.get(name, name.upper().replace("Ç", "C").replace("Ş", "S").replace("İ", "I"))
    add(code, f"Beypazarı Maden Suyu {name}", "Beypazarı", "Maden suyu", "Şişe", 10, sale, cost,
        pack=24, pack_name="Koli", stock=P * 24)
for i, r in enumerate(rows, start=2): r["row"] = str(i)
json.dump(rows, open("data/urunler_2026-10-01.json", "w"), ensure_ascii=False, indent=1)
cols = ["urun_kodu","urun_adi","marka","kategori","temel_birim","barkod","satis_fiyati","paket_adi","paket_icerik",
        "paket_satis_fiyati","koli_adi","koli_icerik","koli_satis_fiyati","kdv_orani","alis_fiyati","acilis_stogu",
        "kritik_stok","depozitolu","depozito_tutari","bos_kap_urun_kodu","bos_kap_mi","aktif"]
print(len(rows), "ürün")
