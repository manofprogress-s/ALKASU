# ALKASU — Geliştirme Planı (v1)

> Belge sürümü: 1.0 · Tarih: 29.09.2026
> İlke: **En kısa sürede telefonda denenebilir bir sürüm.** Satış akışı en başta gelir, ayrıntılar geri bildirimle şekillenir.
> Her aşamanın sonunda şunlar hazır olur: çalışan kod, testler, `npm run check` yeşil, kısa belge güncellemesi ve açıklayıcı Git commit'i.

## 0. Yol haritası

| Aşama | İçerik | Çıktı | Tahmini süre |
|---|---|---|---|
| 0 | Altyapı, giriş, roller, RLS iskeleti | Giriş yapılabilen boş uygulama | 1 oturum |
| 1 | Ürün/marka/birim/fiyat, içe aktarma, stok hareket çekirdeği, mal kabul | Ürün listesi ve stok | 1–2 oturum |
| 2 | Hızlı satış, müşteri, veresiye, depozito, iptal/iade | **🎯 Demo 1: telefonda satış yapılabilir** | 2 oturum |
| 3 | Kasa günü, gider, gün sonu kapatma, tahsilat | **🎯 Demo 2: bir iş gününün tamamı** | 1 oturum |
| 4 | Fire, sayım, kritik stok, raporlar, Excel/CSV dışa aktarma | Yönetici raporları | 2 oturum |
| 5 | Çevrimdışı satış kuyruğu, PWA, denetim ekranı, yedek/geri yükleme, canlıya geçiş | **🎯 Canlı sürüm** | 1–2 oturum |

"Oturum", kesintisiz bir geliştirme çalışmasıdır. Sürelerde geri bildirim düzeltmeleri hariç tutulmuştur.

## 1. Veri modeli (özet)

```
Kimlik ve yetki
  businesses · locations · memberships(user_id, business_id, role, active) · app_settings

Katalog
  brands · categories · products(base_unit, vat_rate, critical_level, deposit_amount, empty_product_id, is_container)
  product_units(product_id, name, factor, active) · product_barcodes
  product_prices(product_unit_id, price, valid_from, created_by)   ← fiyat geçmişi
  product_costs(product_id, avg_cost)          🔒 yönetici
  cost_history(product_id, old, new, source)   🔒 yönetici

Stok
  stock_movements(id, location_id, product_id, qty_base, type, ref_type, ref_id, created_by, created_at)
  stock_levels(location_id, product_id, qty)   ← yalnızca fonksiyonlar yazar
  purchases · purchase_items · purchase_item_costs 🔒 · suppliers
  waste_records · stock_counts · stock_count_lines

Satış
  customers(credit_limit, unlimited, …)
  sales(id=idempotency, cash_session_id, customer_id, status, totals, offline, synced_at)
  sale_items(unit_id, qty, factor, unit_price, discount, vat_rate, line_total)
  sale_item_costs(sale_item_id, unit_cost) 🔒
  sale_payments(method: nakit|pos|veresiye, amount)
  returns · return_items · cancel/return requests
  customer_ledger(customer_id, type, amount, ref)       ← veresiye cari
  container_ledger(customer_id, product_id, qty, deposit_amount, ref)  ← kap/depozito

Kasa
  cash_sessions(opened_at, opening_cash, expected, counted, diff, carry_over, pos_*, closed_by)
  cash_movements(session_id, type, amount, ref)
  expense_categories · expenses

Denetim
  audit.log(business_id, user_id, at, action, table, record_id, old, new, client)
```

Temel RPC'ler: `complete_sale`, `cancel_sale`, `create_return`, `receive_goods`, `approve_purchase_costs`, `record_waste`, `start_count`/`submit_count`/`approve_count`, `record_payment`, `container_return`, `add_cash_movement`, `add_expense`, `close_cash_session`, `import_products`, `import_customers`, `set_product_price`.

## 2. Aşama ayrıntıları

### Aşama 0 — Altyapı ve güvenlik temeli
- Next.js + TypeScript strict, Tailwind, shadcn/ui, ESLint, Prettier, Vitest, Playwright.
- Supabase CLI yerel ortamı. İlk migration: `businesses`, `locations`, `memberships`, `app_settings`, `audit.log`, rol yardımcı fonksiyonları, RLS'in varsayılan olarak kapalı-reddet durumu.
- Giriş ve şifre sıfırlama ekranları, oturum koruması (middleware), rol tabanlı menü.
- Kullanıcı yönetimi: davet et, rol değiştir, pasife al (Y-04 korumasıyla).
- Uygulama kabuğu: mobil alt gezinme, masaüstü yan menü, Türkçe biçimlendirme yardımcıları (tarih, para).
- `.env.example`, `.gitignore`, GitHub Actions: `check` iş akışı ve migration kontrolü.
- **Testler:** RLS (başka işletmenin verisini göremez; izleyici yazamaz), Y-04, biçimlendirme birim testleri.

### Aşama 1 — Katalog, stok çekirdeği, mal kabul
- Marka, kategori ve ürün kartları; ek birimler; barkodlar; birim fiyatları ve fiyat geçmişi.
- Depozitolu ürün ile boş kap ürünü eşleştirmesi.
- Stok hareket çekirdeği (`app.post_stock_movement`), `stock_levels` ve tutarlılık kontrolü.
- Ürün içe aktarma: şablon indirme, yükleme, önizleme, hata listesi, onay (E-01..E-04), açılış stoğu ve maliyeti.
- Tedarikçi kartı, mal kabul (depo) ve fiyat onayı (yönetici) — ağırlıklı ortalama (M-02).
- Stok listesi ve ürün bazında hareket geçmişi.
- **Testler:** B-03 dönüşümü, M-02 (sıfır/negatif eldeki dahil), A-05 bedelsiz, T-01 (doğrudan yazma reddedilir), fiyat anlık görüntüsü, içe aktarma işlem bütünlüğü.

### Aşama 2 — Hızlı satış 🎯 Demo 1
- Tezgâh ekranı: arama, barkod (klavye ve kamera), sık satılanlar ızgarası, birim değiştirici, miktar ve indirim.
- Müşteri seçimi ve hızlı müşteri ekleme, limit ve bakiye gösterimi.
- Damacana akışı: "Boş getirdi" sayısı ve otomatik depozito satırı (D-03).
- Ödeme ekranı: nakit (para üstü), POS, veresiye, bölünmüş ödeme.
- `complete_sale` RPC: tek işlem ve idempotency (S-01, S-02).
- Bilgi fişi (yazdır/paylaş), satış listesi ve satış detayı.
- İptal (kasa günü açıkken), iade (kalem/miktar, sağlam/kusurlu, para iade dağılımı), satış personelinin iade talebi.
- Müşteri kartı, cari ekstre, kap/depozito özeti, depozito iadesi.
- Demo ortamı: kurgusal ürünler, müşteriler ve her rol için birer demo kullanıcısı.
- **Testler:** S-01 (yarıda hata → sıfır kayıt), S-02 (çift gönderim), S-03, F-06 (indirim limiti veritabanında), V-02 (limit), D-03..D-06 (depozito senaryoları), I-01..I-04; Playwright: telefon görünümünde uçtan uca satış.
- **Kullanıcıdan geri bildirim:** satış ekranı akışı, ürün düzeni, damacana adımı.

### Aşama 3 — Kasa ve gider 🎯 Demo 2
- Kasa günü: otomatik açılış, devreden nakit.
- Kasa hareketleri: giriş, çıkış (bankaya/sahibe teslim), gider.
- Veresiye tahsilatı (nakit/POS) ve tahsilat iptali (ters kayıt).
- Gün sonu sihirbazı: beklenen nakit → sayılan nakit (küpür sayacı) → fark ve açıklama → POS teyidi → devreden nakit → kapat.
- Günlük özet ekranı (yönetici ana sayfası).
- **Testler:** K-03 formülü (tüm hareket türleriyle), K-04 tolerans, K-06 kapalı gün kilidi, K-07/K-08, I-01'in kapalı günde reddi.

### Aşama 4 — Stok kontrolü ve raporlar
- Fire/hasar kaydı, boş kap hareketleri (tedarikçiye iade, kırık/kayıp).
- Sayım oturumu: tam/kısmi, birim karışık giriş, fark listesi, onay (T-04).
- Kritik stok uyarıları ve öneri değeri (T-05), ana sayfa rozeti.
- Raporlar (PRODUCT_SPEC §4.11): günlük/aylık satış, brüt kâr, ürün/marka bazında satış, hızlı/yavaş hareket, stok değeri, veresiye yaşlandırma, damacana/depozito, kasa farkları, fire/sayım, kendi satışlarım.
- Tüm listelerde ve raporlarda Excel/CSV dışa aktarma.
- Müşteri içe aktarma (açılış bakiyesi ve kap sayısı).
- **Testler:** Rapor toplamları ile hareket toplamlarının mutabakatı, izleyici ve satış rolünün maliyet raporlarına erişememesi (Y-02), T-06 hesapları.

### Aşama 5 — Çevrimdışı, sağlamlaştırma, canlıya geçiş
- PWA: yüklenebilir uygulama, ikonlar, çevrimdışı kabuk, fiyat listesi önbelleği.
- Çevrimdışı satış kuyruğu (C-01..C-05), senkron durumu ve "Sorunlu kayıtlar" ekranı.
- Denetim kaydı ekranı (filtreli, önceki/yeni değer karşılaştırması).
- Yedekleme iş akışı, geri yükleme betiği ve tatbikat; `docs/BACKUP_RESTORE.md`.
- Güvenlik gözden geçirmesi: RLS matris testi (her rol × her tablo × her işlem), gizli anahtar taraması, bağımlılık denetimi, HTTP güvenlik başlıkları.
- Performans: satış ekranı paket boyutu ve sorgu indeksleri.
- Canlıya geçiş kontrol listesi: canlı Supabase projesi, gerçek ürün içe aktarması, açılış sayımı, kullanıcı davetleri, `docs/OPERATIONS.md` (kullanım kılavuzu).
- **Testler:** Playwright ile ağ kesme senaryosu (satış → kuyruk → bağlantı → tek kayıt), geri yükleme tatbikatı.

## 3. Kalite kapısı (her özellik için)

1. `npm run lint` — ESLint, uyarısız.
2. `npm run typecheck` — `tsc --noEmit`.
3. `npm run test` — Vitest.
4. `npm run test:db` — pgTAP (RLS ve RPC'ler).
5. `npm run test:e2e` — Playwright (kritik akışlar, Aşama 2'den itibaren).
6. `npm run build` — production build.

## 4. Yayın ve ortamlar

- **GitHub** deposu → her push'ta CI; `main` dalı → Vercel production, diğer dallar → Vercel preview (demo veritabanına bağlı).
- Migrationlar CI'da `supabase db push` ile önce demo, sonra onaylı sürümde canlı projeye uygulanır.
- Ortam değişkenleri: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` (sunucu), `SUPABASE_DB_URL` (CI/yedek), `BACKUP_AGE_RECIPIENT`.

## 5. Kullanıcıdan gerekecekler (zamanı gelince)

| Ne | Ne zaman | Neden |
|---|---|---|
| Supabase hesabı ve 2 proje (demo, canlı) | Demo 1 öncesi | Veritabanı ve giriş; hesap açmayı ve anahtar girmeyi yalnızca kullanıcı yapabilir |
| Vercel hesabı + GitHub deposu | Demo 1 öncesi | Uygulamanın internete açılması |
| Ürün listesi (şablona göre) | Aşama 1 sonrası, herhangi bir zaman | Gerçek verilerle deneme |
| Müşteri listesi, açılış bakiyeleri | Canlıya geçiş öncesi | D-025 |

## 6. Riskler

| Risk | Önlem |
|---|---|
| Çevrimdışı satışlarda çakışma ve çift kayıt | Idempotency anahtarı, sunucu doğrulaması, Sorunlu kayıtlar ekranı |
| Negatif stokun kronikleşmesi | Kritik stok raporunda en üstte gösterim, sayım teşviki, ürün bazlı engelleme ayarı (ileride) |
| Kasa farklarının izlenememesi | Tüm nakit hareketleri tek tablodan, farkın açıklaması zorunlu |
| Supabase ücretsiz plan sınırları (duraklatma, yedek yok) | Canlı ortam için Pro plan önerisi ve bağımsız günlük yedek (T-019) |
| Rol sızıntısı (maliyetin personelde görünmesi) | Ayrı tablolar ve RLS matris testi |
