# ALKASU — Karar Kaydı

> Her karar: bağlam, karar, gerekçe, geri dönüş maliyeti.
> **D-** iş/operasyon kararları · **T-** teknik kararlar.
> Durum: ✅ Kabul · 🔁 Kullanıcı geri bildirimiyle değişebilir · ⛔ Değiştirilmesi pahalı

## İş / operasyon kararları

29.09.2026 tarihli operasyon görüşmesinde kullanıcı tüm sorularda önerilen varsayılanları kabul etti. Aşağıda seçilen varsayılanlar ve sorulmayan ayrıntılar için yapılan varsayımlar yer alır.

| Kod | Karar | Gerekçe | Durum |
|---|---|---|---|
| D-001 | Satışlar **fiş bazında** kaydedilir. | Stok, kâr, veresiye ve depozito doğruluğu için gereklidir. | ⛔ |
| D-002 | Satış kanalları: tezgâh satışı ve müşteri kartlı satış (teslimat adresi not olarak tutulur). Kurye/rota yönetimi v1'de yoktur. | Görüşmede kanal ayrıntısı verilmedi; en düşük karmaşıklık seçildi. | 🔁 |
| D-003 | Tek işletme, tek lokasyon ("Merkez"), aynı anda 1–3 cihaz. Veri modeli çoklu işletme ve lokasyonu destekler. | Varsayım. | 🔁 |
| D-004 | İnternet kesintisinde yalnızca **satış** cihazda kuyruğa alınır; diğer işlemler çevrimiçi gerektirir. | Tezgâhın durmamasıyla stok ve kasa doğruluğu arasındaki denge. | ✅ |
| D-005 | Barkod okuyucu isteğe bağlıdır; USB/Bluetooth klavye tipi okuyucu ve telefon kamerası desteklenir. Fiş yazıcı zorunlu değildir; tarayıcıdan yazdırma yapılır. | Donanım ayrıntısı bilinmiyor; donanımdan bağımsız çözüm seçildi. | 🔁 |
| D-006 | Stok, **temel birimde tam sayı** olarak tutulur. Ürün başına en fazla 2 ek birim (Paket, Koli) tanımlanır. | Varsayılan kabul edildi. | ⛔ |
| D-007 | Kesirli (kg/L) satış yoktur. | Su/içecek işletmesi için gerekli görülmedi. | 🔁 |
| D-008 | Fiyatlar birim başına **KDV dahil** girilir. Müşteri grubuna göre fiyat v1'de yoktur. | Varsayılan kabul edildi. Müşteri grubu fiyatı sonradan eklenebilecek şekilde tasarlandı. | 🔁 |
| D-009 | **Negatif stoğa izin verilir** (uyarıyla). | Çevrimdışı satış ve tezgâh hızı bunu gerektirir; aksi halde fiziksel olarak var olan ama sisteme girilmemiş ürün satılamaz. Negatif stok raporda öne çıkarılır. İstenirse ürün bazında "negatife düşmesin" ayarı eklenebilir. | 🔁 |
| D-010 | Maliyet yöntemi **ağırlıklı ortalama**dır. Alış maliyeti KDV dahil girilir. | Varsayılan kabul edildi. Kâr hesabının tutarlılığı sağlandı. | ⛔ |
| D-011 | Satış personelinin indirim limiti fiş tutarının %5'idir (ayar). | Varsayım. | 🔁 |
| D-012 | Depozito ürün bazında tanımlanır, gelir sayılmaz, iade edilebilir. Boş kaplar ayrı bir "boş kap ürünü" stoğunda izlenir. | Varsayılan kabul edildi. Muhasebe açısından doğru yöntem budur. | ⛔ |
| D-013 | Veresiye yalnızca kayıtlı müşteriye, kredi limitiyle verilir. Limit aşımı yönetici onayıyla geçilebilir. Tahsilat fişlere dağıtılmaz, cari bakiye tutulur. | Varsayılan kabul edildi. | ✅ |
| D-014 | Kullanıcı başına işletme içinde **tek rol** vardır. | Karma rol ihtiyacı (satış+depo) doğarsa, satış personeline depo yetkileri eklenmiş özel bir rol tanımlanabilir. | 🔁 |
| D-015 | Tek fişte bölünmüş ödeme (nakit + POS + veresiye) desteklenir. POS hesabı tektir; birden fazla POS/banka tanımlanabilir. | Düşük maliyetli bir esneklik. | ✅ |
| D-016 | ALKASU yasal belge üretmez; ekranda üretilen fiş "Bilgi fişi"dir. | Varsayılan kabul edildi. | ✅ |
| D-017 | Mal kabulü depo girer, alış fiyatını yönetici onaylar. Stok, kayıtla birlikte artar; maliyet, onayla güncellenir. Tedarikçi cari hesabı yoktur. | Varsayılan kabul edildi. | ✅ |
| D-018 | Bedelsiz ürün (kampanya), mal kabulde ayrı miktar olarak girilir ve ortalama maliyeti düşürür. | Varsayım. | ✅ |
| D-019 | İptal yalnızca kasa günü kapanmadan yapılır, sonrası iadedir. Her ikisi de yönetici onayı gerektirir; satış personeli talep açar. | Varsayılan kabul edildi. | ✅ |
| D-020 | İade edilen ürün için "Sağlam/Kusurlu" seçimi yapılır. Para iadesi varsayılan olarak veresiye → POS → nakit sırasıyla orijinal ödemeye göre yapılır. | Varsayılan kabul edildi. | ✅ |
| D-021 | Sayım tam veya kısmi yapılabilir, farklar yönetici onayıyla harekete dönüşür. Parti/SKT takibi yoktur. | Varsayılan kabul edildi. | ✅ |
| D-022 | Tek kasa vardır, kasayı yönetici kapatır. Kasa farkı toleransı 50 ₺'dir (ayar). Açılış nakdi, önceki günün devreden nakdidir. | Varsayılan kabul edildi. | 🔁 |
| D-023 | Gideri yalnızca yönetici girer. Varsayılan gider kategorileri BUSINESS_RULES K-10'da listelenmiştir. | Varsayım. | 🔁 |
| D-024 | Kritik stok seviyesi elle girilir; sistem 30 günlük satış × 7 gün formülüyle öneri gösterir. | Varsayılan kabul edildi. | ✅ |
| D-025 | Canlıya geçişte açılış stoğu, açılış maliyeti, müşteri veresiye bakiyesi ve müşterideki kap sayısı Excel ile içe aktarılır. | Varsayılan kabul edildi. | ✅ |
| D-026 | Öncelikli raporlar: günlük özet, kritik stok, veresiye bakiyeleri. Diğer raporlar sonraki aşamada gelir. | Kullanıcı hızlı geri bildirim döngüsünü tercih etti. | 🔁 |
| D-027 | Hızlı/yavaş hareket, satış miktarına göre %20'lik dilimlerle ve 30 günlük dönemle belirlenir. | Varsayım. | 🔁 |
| D-028 | Kasa kapandıktan sonra senkron olan çevrimdışı satış, açık olan yeni kasa gününe yazılır. | Kapanmış günün değişmezliği korunur. | ✅ |

## Teknik kararlar

| Kod | Karar | Gerekçe |
|---|---|---|
| T-001 | **Next.js (güncel kararlı sürüm, App Router) + TypeScript (strict)**, tek depo. | Kullanıcı gereksinimi. |
| T-002 | **Node.js 24 LTS**. `.nvmrc`, `package.json#engines` ve Vercel ayarı ile sabitlenir. | Kullanıcı gereksinimi. |
| T-003 | **Supabase**: PostgreSQL, Auth, RLS. Yerel geliştirme Supabase CLI ile yapılır. Migrationlar `supabase/migrations/` altında düz SQL olarak tutulur. | Migrationlar deploy hattında otomatik uygulanır (`supabase db push`). |
| T-004 | **Tüm yazma işlemleri PostgreSQL fonksiyonlarıyla (RPC) yapılır.** Tablolara istemci üzerinden doğrudan INSERT/UPDATE/DELETE yetkisi verilmez. | Tek işlem bütünlüğü (S-01), idempotency (S-02) ve yetki kontrolünün veritabanında yapılması (Y-01) bu şekilde sağlanır. |
| T-005 | Okumalar RLS korumalı tablo ve görünümlerden yapılır. `business_id` üyelik kontrolü `auth.uid()` ile yapılır, rol yardımcı fonksiyonu `app.has_role()` kullanılır. | Çoklu işletmeye hazırlık ve veritabanı seviyesinde yetki. |
| T-006 | **Hassas finansal veri ayrı tablolarda tutulur** (`product_costs`, `cost_history`, `sale_item_costs`, `purchase_item_costs`, raporlar). Bu tabloların RLS'i yalnızca yöneticiye açıktır. Kâr raporları yönetici kontrolü yapan fonksiyonlardan döner. | PostgreSQL RLS satır bazında çalışır; sütun bazlı gizleme için tablo ayrımı en güvenilir yoldur. |
| T-007 | `stock_levels` tablosu, stok hareketi eklenirken fonksiyon içinde güncellenir. İstemci rolünün yazma yetkisi yoktur. Tutarlılık için "hareket toplamı = seviye" kontrol fonksiyonu ve testi vardır. | Hızlı okuma ve T-01 kuralı. |
| T-008 | Eşzamanlılık: stok ve maliyet güncellemeleri ürün satırı `SELECT … FOR UPDATE` ile kilitlenir. Kasa günü açma işlemi advisory lock ile tek seferde yapılır. | Aynı anda iki cihazdan gelen satışlarda tutarlılık. |
| T-009 | Para `numeric(14,2)`, birim maliyet `numeric(14,4)`, miktar `integer` (temel birim) olarak tutulur. İstemcide para hesabı kuruş cinsinden tam sayıyla yapılır. Son söz veritabanı fonksiyonundadır. | Kayan nokta hatalarını önlemek için. |
| T-010 | Kimlikler UUID'dir. Satış kimliği istemcide `crypto.randomUUID()` ile üretilir ve idempotency anahtarı olarak kullanılır. | Çevrimdışı kuyruk ve tekrar gönderime dayanıklılık için. |
| T-011 | UI: **Tailwind CSS + shadcn/ui (Radix)**, ikonlar lucide. Formlar react-hook-form + zod. İstemci veri önbelleği TanStack Query. | Hızlı, erişilebilir ve mobil uyumlu bileşenler. |
| T-012 | PWA: Serwist (next-pwa halefi) ile service worker. Çevrimdışı kuyruk IndexedDB'de (idb-keyval/Dexie) tutulur. | D-004. |
| T-013 | Excel: içe ve dışa aktarma için **ExcelJS**, CSV için Papaparse. CSV dışa aktarması UTF-8 BOM ve `;` ayırıcıyla yapılır (Türkçe Excel uyumu). | — |
| T-014 | Tarih/saat: `date-fns` + `date-fns-tz`, sabit `Europe/Istanbul`. Veritabanında `timestamptz` kullanılır, gün sınırları `AT TIME ZONE 'Europe/Istanbul'` ile hesaplanır. Para için `Intl.NumberFormat('tr-TR', {currency:'TRY'})` kullanılır. | G-02. |
| T-015 | Testler: **Vitest** (birim), **pgTAP** (veritabanı: RLS, RPC, iş kuralları), **Playwright** (uçtan uca: satış, iade, kasa kapatma; mobil görünümde). | Kritik kurallar veritabanında olduğu için veritabanı testleri öncelikli. |
| T-016 | Kalite kapısı: `npm run check` = ESLint + `tsc --noEmit` + Vitest + pgTAP + `next build`. GitHub Actions'ta her PR'da çalışır. | Kullanıcı gereksinimi (madde 13). |
| T-017 | Ortamlar: `local` (Supabase CLI), `demo` (ayrı Supabase projesi + Vercel preview, seed verili), `production`. Demo verisi `supabase/seed/demo.sql` ile yüklenir; kurgusal ürün adları kullanılır. | Kullanıcı gereksinimi. |
| T-018 | Gizli anahtarlar yalnızca ortam değişkenlerindedir. `.env.example` depoda, `.env*.local` dosyaları `.gitignore`'dadır. `service_role` anahtarı yalnızca sunucu tarafında (Route Handler / Server Action) ve yalnızca kullanıcı davet işlemi için kullanılır. | Kullanıcı gereksinimi (madde 11). |
| T-019 | Yedekleme: Supabase günlük yedeğine ek olarak GitHub Actions ile günlük `pg_dump` alınır ve şifrelenmiş olarak (age) ayrı depolamaya yazılır, 30 gün saklanır. Geri yükleme betiği ve aylık geri yükleme tatbikatı `docs/BACKUP_RESTORE.md`'de tanımlanır. | Supabase ücretsiz planında PITR yoktur; bağımsız bir kopya gerekir. |
| T-020 | Denetim kaydı, `audit.log` şemasında tutulur ve yalnızca `SECURITY DEFINER` fonksiyonlar tarafından yazılır. Kritik tablolarda tetikleyici ile önceki/yeni değer JSON olarak saklanır. | L-01..L-03. |
| T-021 | Kullanıcı daveti: Yönetici e-posta ve rol girer, sunucu `auth.admin.inviteUserByEmail` çağırır, üyelik kaydı rol ile oluşturulur. Açık kayıt kapalıdır. | — |
| T-022 | Klasör yapısı: `src/app` (rotalar), `src/features/<modül>` (ekran, bileşen, sorgu), `src/lib` (ortak), `supabase/migrations`, `supabase/tests`, `docs`, `templates`. | Modül bazlı ayrım, aşamalı geliştirmeye uygun. |

## Uygulama sırasında alınan kararlar (30.09.2026)

| Kod | Karar | Gerekçe |
|---|---|---|
| T-023 | Derleme, lint, tip kontrolü ve testler **GitHub Actions**'ta çalışır; geliştirme ortamında npm paket sunucusuna erişim yoktur. | Çalışma ortamının ağ politikası. CI aynı zamanda her değişikliğin kalite kapısıdır (T-016). |
| T-024 | Veritabanı testleri pgTAP yerine düz SQL ile yazılmış küçük bir test yardımcısıyla (`supabase/tests/_helpers.sql`) çalışır; her test dosyası bir işlem içinde çalışıp geri alınır. | pgTAP eklentisi gerektirmez; herhangi bir PostgreSQL 15+ üzerinde (CI dahil) çalışır. T-015'in yerine geçer. |
| T-025 | UI bileşenleri shadcn/TanStack yerine projede elle yazıldı (Tailwind v4 + lucide). Service worker Serwist yerine elle yazıldı (`public/sw.js`). CSV Papaparse yerine kendi yardımcımızla. | Bağımlılık sayısını ve yükseltme riskini azaltmak. T-011, T-012, T-013'ü günceller. |
| T-026 | Next.js 16 ile `middleware.ts` yerine `src/proxy.ts` kullanılır. | Next.js 16 adlandırması. Sürüm 15'e düşülürse dosya adı `middleware.ts`, fonksiyon adı `middleware` olur. |
| T-027 | Çevrimdışı satış ekranı: katalog ve müşteri listesi IndexedDB'de önbelleğe alınır; `/` ve `/satis` sayfaları service worker ile çevrimdışı açılır. Çıkışta tüm önbellek silinir. | D-004, C-01..C-05. Paylaşılan cihazda veri sızıntısını önler. |
| D-029 | Fazla getirilen boş kap için geri verilen depozito, müşterinin **ödediği ortalama depozito** üzerinden hesaplanır (güncel depozito tutarı değil). | Depozito tutarı zamanla değişirse müşteriye ödediğinden fazla/az iade yapılmaz. |
| D-030 | Kasa kapanışında POS farkı kaydedilir ama açıklama zorunlu değildir; nakit farkı tolerans üstündeyse zorunludur. | POS farkı çoğunlukla gün sonu/batch zamanlamasından kaynaklanır. |

## Gerçek ürün listesine geçiş (01.10.2026)

| Kod | Karar | Durum |
|---|---|---|
| D-031 | Listede verilen fiyatlar **paket/koli fiyatıdır**. Stok şişe/bidon cinsinden tutulur; tek şişe fiyatı tanımlanmadığı için tek şişe satılmaz (gerekirse ürün kartından fiyat eklenir). | ✅ |
| D-032 | Paket içerikleri: 0,33 L → 12, 0,5 L → 12, 1 L → 12, 1,5 L → 6, 5 L → 2 bidon, bardak su → 60'lı koli, Beypazarı → 24'lü koli. 0,33/1,5/5 L kullanıcıdan; diğerleri tahmin. | 🔁 0,5 L, 1 L, bardak, Beypazarı teyit edilecek |
| D-033 | Damacana fiyatı **değişim fiyatıdır** (boş getir, dolu götür). Her marka ayrı boş kap ürünüyle izlenir. 19 L Pet kullan-at, depozitosuz. | ✅ |
| D-034 | Başlangıç stoğu: her damacana ürünü 30 palet × 36 = 1080; diğer her ürün 1 palet = 200 paket/koli/adet (geçici, sayımla düzeltilecek). | 🔁 |
| D-035 | Damacana depozito tutarı **geçici olarak 250 ₺** (kullanıcı tutar belirtmedi). | 🔁 teyit edilecek |
| D-036 | Tüpler (küçük/büyük) damacana gibi depozitolu: fiyat boş getir dolu götür fiyatı; depozito küçük 500 ₺, büyük 1500 ₺. | ✅ |
| D-037 | KDV: su ve damacana %1, Beypazarı maden suyu %10, tüp/pompa/bardak %20. Beypazarı Sade alış 230 ₺ (yazım düzeltmesi). | 🔁 maden suyu oranı muhasebeciyle teyit |
| D-038 | Deneme verisi (ürün, müşteri, satış, kasa, işlem geçmişi) kullanıcı onayıyla silindi; işletme adı "Alay Ticaret". | ✅ |

## Bayi sistemi ve siparişler (01.10.2026)

| Kod | Karar | Durum |
|---|---|---|
| D-039 | Bayi = bizden bayi fiyatıyla alan müşteri (kullanıcı seçimi). Bayinin kendi satışları izlenmez. Bayi kullanıcısı bir bayi müşteri kartına bağlanır ve yalnızca o kartın verisini görür. | ✅ |
| D-040 | Palet bir fiyat listesidir, birim değildir (kullanıcı seçimi). Palet müşterisi paket/koli bazında palet fiyatı öder. | ✅ |
| D-041 | Sipariş teslim edildiğinde otomatik satışa dönüşür (kullanıcı seçimi): teslim eden gerçek miktarı, boş kapı ve ödemeyi girer. | ✅ |
| D-042 | Yeni rol **sevkiyat** = depo + satış yetkileri + atanan siparişi kapatma. Hüseyin Topaloğlu bu rolde. | ✅ |
| D-043 | Teslimatta liste fiyatı ve indirim kontrolü sipariş fiyatına güvenir (sipariş açılışında doğrulanmıştır); limit aşımı reddedilmez, işaretlenir (O-05). | ✅ |
| D-044 | Teslimattaki nakit, işletmenin açık kasa gününe yazılır (ayrı araç kasası yok). Gerekirse sonra "araç kasası" eklenebilir. | 🔁 |
| D-045 | Kullanıcı girişi **kullanıcı adı + şifre**. Kullanıcı adı Türkçe karakterler sadeleştirilip küçük harfe çevrilerek iç e-posta adresine dönüştürülür (`isaglam@kullanici.alkasu.app`); gerçek e-posta ile giriş de çalışır. | ✅ |
| D-046 | Yönetici kullanıcıyı geçici şifreyle oluşturur; kullanıcı ilk girişte şifresini değiştirmek zorundadır. Ortak tek şifre kalıcı kullanılmaz. | ✅ |
| T-028 | Rol kalıtımı veritabanında `app.role_covers` ile yapılır; `has_role(…,'satis')` sevkiyat için de doğrudur. Enum değerleri ayrı migration'da (0010) eklenir. | ✅ |
| T-029 | Kullanıcı oluşturma sunucu tarafında `service_role` anahtarıyla (`auth.admin.createUser`) yapılır; anahtar yalnızca Vercel ortam değişkenindedir. | ✅ |

## Performans (01.10.2026)

| Kod | Karar | Gerekçe |
|---|---|---|
| T-030 | Vercel sunucu fonksiyonları **fra1 (Frankfurt)** bölgesinde çalışır (`vercel.json` → `regions`). | Veritabanı Frankfurt'ta. Fonksiyonlar varsayılan iad1'de (ABD) çalışırken her sorgu Atlantik'i geçiyordu (~90 ms × sayfa başına 5-10 sorgu). |

## Konum, tedarikçiler, müşteri grupları (01.10.2026)

| Kod | Karar | Durum |
|---|---|---|
| D-047 | Konum Google Maps ile **API anahtarsız** çalışır: koordinat bağlantıdan ayrıştırılır, kısa bağlantılar (maps.app.goo.gl) sunucuda açılır; gösterim ve yol tarifi Google Maps'in herkese açık adresleriyle yapılır. Ücretli Maps API gerekmez. | ✅ |
| D-048 | "Ev müşterisi" = perakende kanalı (veritabanı değeri `perakende`, ekranda "Ev müşterisi"). | ✅ |
| D-049 | Müşterideki kap sayısı ayrı bir alan değil, kap hareketlerinden hesaplanır; açılış/sayım farkı yönetici tarafından fark hareketiyle girilir (`set_customer_containers`). | ✅ |
| D-050 | Sebil sayısı müşteri kartında tek alan olarak tutulur (değişiklikler işlem geçmişine yazılır). Seri no / zimmet takibi gerekirse ileride ayrı tabloya taşınır. | 🔁 |
| T-031 | Oturum kontrolü `auth.getClaims()` ile yapılır: erişim jetonu Supabase'in ES256 açık anahtarıyla sunucuda doğrulanır (anahtar bir kez indirilip önbelleğe alınır). Proxy ve sayfa aynı yardımcıyı (`lib/supabase/claims.ts`) kullanır; her istekte Supabase Auth'a giden iki ağ isteği kalktı. | Yetki kararları zaten veritabanında (RLS) verildiği için güvenlik düzeyi değişmez; çıkış yapan kullanıcının jetonu en geç süresi dolunca (1 saat) geçersizleşir, veritabanı üyeliği her istekte yine kontrol edilir. |

## Müşteri siparişi, bayi dağıtımı, rota (06.10.2026)

| Kod | Karar | Durum |
|---|---|---|
| D-051 | Müşteri internetten sipariş verir; kayıt ve ilk sipariş tek adımdadır (kullanıcı isteği). | ✅ |
| D-052 | Müşteri girişi **telefon + şifre** (kullanıcı seçimi). Telefon iç e-postaya çevrilir (`5xxxxxxxxx@musteri.alkasu.app`); SMS/e-posta gönderilmez, ücret yoktur. Yeni rol `musteri`. | ✅ |
| D-053 | İnternetten gelen **ilk sipariş onay bekler** (kullanıcı seçimi); onayla müşteri kartı da onaylanır. | ✅ |
| D-054 | Ev müşterisi siparişleri bayiye **elle** verilir (kullanıcı seçimi). Bayinin teslimatı **bayinin kendi satışıdır** (kullanıcı seçimi): bizde stok/kasa/cari hareketi oluşmaz. | ✅ |
| D-055 | Bayi ve müşteri artık stok seviyesini, fiyat geçmişini, ayarları ve kendi listesi dışındaki fiyatları göremez (RLS sıkılaştırıldı). | ✅ |
| D-056 | Rota ücretsiz hesaplanır: kuş uçuşu mesafeyle en yakın komşu + 2-opt; sürüş Google Maps yol tarifinde açılır (10 durakta bir bölünür). Gerçek yol mesafesiyle optimizasyon (Google Routes API) gerekirse ileride ücretli eklenebilir. | 🔁 |
| D-057 | Depo konumu varsayılan lokasyonda tutulur (Ayarlar → Depo konumu); bayinin başlangıcı kendi müşteri kartındaki konumdur (Hesabım). | ✅ |
| D-058 | Yeni internet müşterisinin kodu `W` ile başlar (ofis kartları `M`). | ✅ |

## Bayi sipariş girişi (09.10.2026)

| Kod | Karar | Durum |
|---|---|---|
| D-059 | Bayinin müşteri kartı merkezde tutulur, `owner_dealer_id` ile bayiye bağlanır; kod `B` ile başlar. | ✅ |
| D-060 | Bayi siparişinde "teslim eden" seçilir: kendisi (onaysız), merkez veya başka bayi (onaylı). Talep edilen bayi `requested_dealer_id` alanında tutulur, onayla `dealer_customer_id`'ye geçer. | ✅ |
| D-061 | Bayinin bizden alımı da onay bekler (kullanıcı isteği: "Hüseyin'e açılan sipariş onaylı"). | ✅ |
| D-062 | Onay yetkisi: yönetici, satış, sevkiyat. Selin için Ayarlar'dan satış (veya yönetici) rolüyle kullanıcı açılmalı. | 🔁 |
| D-063 | Firmaya özel fiyat ayrı tabloda (`customer_prices`, birim bazında). Kurumsal listedeki kısaltmalar kullanıcıyla netleştirildi: D./F.D. = Fuska damacana, 1,5 = Gürpınar 1,5 L, Bardak = Gürpınar bardak su, S. soda = Beypazarı sade, Meyveli = Beypazarı meyveli (5 çeşit), Ares = Ares Trafo. Veri: `data/kurumsal_ozel_fiyatlar.py`. | ✅ |

## KVKK (09.10.2026)

| Kod | Karar | Durum |
|---|---|---|
| D-064 | Kullanıcının hazırladığı KVKK Uyum Paketi taslağı uygulandı: zorunlu "onaylıyorum" kutusu kaldırıldı (aydınlatma için rıza istenmez); kısa aydınlatma + `/kvkk` tam metin; sürüm ve gösterim kaydı `privacy_events` tablosunda, değiştirilemez. | ✅ |
| D-065 | Bayiler bağımsız işletme olarak yazıldı (kullanıcı seçimi); veri aktarımı "teslimat için gerekli veriler" ile sınırlı. | ✅ |
| D-066 | Kampanya izni kutusu eklendi (kullanıcı seçimi), işaretsiz ve isteğe bağlı; Hesabım'dan geri çekilir. İYS entegrasyonu yok — gönderim başlamadan önce İYS kaydı yapılmalı. | 🔁 |
| D-067 | Yurt dışı aktarım: Supabase (Almanya), Vercel (ABD şirketi, Frankfurt sunucu), Google Maps. Metin "standart sözleşme gibi uygun güvenceler" diye yazıldı; standart sözleşmenin imzalanıp 5 iş günü içinde Kurum'a bildirilmesi hukuk danışmanının kararıdır. | ⏳ |
| D-068 | Veri sorumlusu vergi levhasına göre **Ayhan Alay (şahıs işletmesi)**; adres İstasyon Mah. Hüsnü Efe Cad. No 12 A Kartepe/Kocaeli; KVKK e-postası ilk aşamada Enes Karakaya'nın adresi (kullanıcı kararı). Telefon/KEP isteğe bağlı. Bilgiler `src/lib/kvkk.ts` içinde; eksikse test yayını durdurur. | ✅ |

## Müşteri sipariş ekranı (09.10.2026)

| Kod | Karar | Durum |
|---|---|---|
| D-069 | Kullanıcının çizdiği görsele göre mağaza düzeni: marka bölümleri, yatay kaydırmalı kartlar, "+", alt sabit sepet çubuğu, üstte sepet sayacı. Hızlı sipariş ve kayıtlı müşteri aynı bileşeni kullanır. Veri kaynağı `public_catalog()` (marka, kategori, fotoğraf, 60 günlük satış adedi eklendi). | ✅ |
| D-070 | Ürün fotoğrafları Supabase Storage'da herkese açık `urun` kovasında (1 MB, webp/jpeg/png); yükleme/silme yalnızca yönetici (RLS). Marka logoları uygulamada çizilmez; gerçek ürün fotoğrafı işletme tarafından yüklenir. | ✅ |
| D-071 | Giriş ekranında hızlı sipariş öne çıkarıldı; çalışan girişi küçük bağlantı olarak en alta alındı (kullanıcı isteği). | ✅ |

## Bayi gizliliği ve yönlendirme (10.10.2026)

| Kod | Karar | Durum |
|---|---|---|
| D-072 | Bayiye ait kart veritabanı tetikleyicisiyle korunur: bayi dışındaki her rolün ad/telefon/adres/not/konum/aktiflik değişikliği reddedilir (kullanıcı isteği: "bayilerden izinsiz düzeltme yapamayız"). | ✅ |
| D-073 | Öneriler `customer_requests` tablosunda; bayi onayıyla `app.dealer_customer_write` çekirdeği uygular (bayinin kendi düzenlemesiyle aynı kod). | ✅ |
| D-074 | Özel yönlendirme yetkisi sevkiyat + yönetici (varsayım: yöneticiler de yapabilir); gerekçe zorunlu (varsayım). Kullanıcı farklı isterse yalnızca sevkiyat'a daraltılabilir. | 🔁 |
| D-075 | Yönlendirme kaydı `order_routing_log` — yalnızca yönetici okur, kimse değiştiremez. Önceki "bayinin kendi alımı başka bayiye verilemez" kuralı kaldırıldı; artık özel yönlendirme olarak yapılabilir. | ✅ |
