# ALKASU — Ürün Gereksinimleri (v1)

> İşletme: Alay Ticaret · Belge sürümü: 1.0 · Tarih: 29.09.2026
> Kaynak: İlk operasyon görüşmesi. Tüm sorularda önerilen varsayılanlar kabul edildi.
> İş kuralları ayrıntısı için `BUSINESS_RULES.md`, alınan kararlar için `DECISIONS.md` dosyasına bakınız.

## 1. Amaç

ALKASU; Alay Ticaret'in su, damacana ve içecek ağırlıklı satışlarını, stoğunu, kasasını ve veresiye hesaplarını tek bir bulut uygulamasında yöneten, telefon, tablet ve bilgisayarda çalışan Türkçe bir iç yönetim sistemidir.

Başarı ölçütleri:
- Tezgâhta bir satış **15 saniyenin altında** tamamlanır (en sık satılan 3 kalemle).
- Her an sistemdeki stok, fiziksel stokla sayım dışında elle oynanmadan tutarlıdır.
- Gün sonu kasa kapatma **5 dakikanın altında** yapılır ve fark nedeniyle kayıt altına alınır.
- Yönetici; günlük satış, brüt kâr, veresiye alacağı ve müşterideki damacana sayısını tek ekranda görür.

## 2. Kapsam dışı (v1)

- Yasal belge üretimi (e-Fatura, e-Arşiv, ÖKC/yazarkasa entegrasyonu). Yasal fiş ve faturalar mevcut düzende kesilmeye devam eder.
- Tedarikçi cari hesabı (borç/ödeme takibi). Yalnızca alış kayıtları tutulur.
- Kurye ve teslimat rotası yönetimi. Teslimat adresi müşteri kartında not olarak durur.
- Parti/son kullanma tarihi takibi.
- Kesirli (kg/litre) satış.
- Çoklu şube arayüzü. Veri modeli hazırdır, arayüz tek işletme ve tek lokasyonla açılır.

## 3. Kullanıcılar ve roller

| Rol | Tipik kullanıcı | Özet |
|---|---|---|
| Yönetici | İşletme sahibi | Her şeyi görür ve yapar; maliyet, kâr ve kasa yalnızca onda görünür |
| Satış personeli | Tezgâh çalışanı | Satış, müşteri ve veresiye tahsilatı; maliyet göremez |
| Depo personeli | Depo/araç çalışanı | Mal kabul, fire, sayım girişi, boş damacana hareketleri |
| İzleyici | Muhasebeci, ortak | Finansal olmayan raporları salt okunur görür |

Kullanıcı başına işletme içinde tek rol vardır (ayrıntı: DECISIONS D-014). Tam yetki matrisi `BUSINESS_RULES.md` §11'dedir.

## 4. Modüller ve gereksinimler

### 4.1 Giriş ve oturum
- E-posta + şifre ile giriş (Supabase Auth). Kayıt ekranı yoktur; kullanıcıyı yönetici davet eder.
- Şifre sıfırlama e-postası.
- Pasife alınan kullanıcı giriş yapamaz; geçmiş kayıtları korunur.
- Oturum cihazda kalıcıdır. Satış personeli cihazı paylaşıyorsa "Kullanıcı değiştir" kısayolu vardır.

### 4.2 Ürün, marka ve kategori kartları
- Marka kartı: ad, aktif/pasif.
- Kategori kartı: ad (Su, Damacana, Maden suyu, Meşrubat, Diğer...).
- Ürün kartı: kod, barkod (birden fazla olabilir), ad, marka, kategori, **temel birim**, ek birimler (paket, koli) ve çarpanları, birim başına satış fiyatı, KDV oranı, kritik stok seviyesi, depozitolu mu, bağlı boş kap ürünü, aktif/pasif.
- Ürün silinmez; hareketi olan ürün yalnızca pasife alınır.
- Excel/CSV ile toplu içe aktarma (şablon: `templates/urun_ice_aktarma_sablonu.xlsx`). Önizleme, satır bazında hata gösterimi ve onaydan sonra tek işlemde kayıt yapılır.

### 4.3 Fiyat ve maliyet
- Satış fiyatları birim bazındadır (adet, paket ve koli fiyatı ayrı girilir).
- Fiyat değişikliği yalnızca yöneticiye açıktır. Her değişiklik fiyat geçmişine yazılır (eski/yeni değer, kullanıcı, zaman).
- Maliyet, ağırlıklı ortalama yöntemiyle mal kabulde otomatik hesaplanır ve maliyet geçmişi tutulur.
- Satış kalemi, satış anındaki fiyatı ve maliyeti kopyalar. Sonradan yapılan değişiklikler geçmişi etkilemez.

### 4.4 Hızlı satış (tezgâh ekranı)
- Mobilde tek elle kullanılabilir. Üstte arama/barkod alanı, altta en sık satılan ürünler ızgarası bulunur.
- Ürün seçilince varsayılan birim ve 1 miktar eklenir; birim (adet/paket/koli) tek dokunuşla değişir.
- Müşteri seçimi isteğe bağlıdır ("Perakende müşteri"). Veresiye ve müşteri bazlı depozito için müşteri seçimi zorunludur.
- Depozitolu üründe "Boş getirdi" sayısı sorulur (varsayılan = satılan adet); eksik boş için depozito satırı otomatik eklenir.
- Satır ve fiş indirimi rol limitine tabidir.
- Ödeme: Nakit, POS, Veresiye ya da bunların kombinasyonu (bölünmüş ödeme). Nakitte para üstü hesaplanır.
- "Tamamla" ile satış tek veritabanı işleminde kaydedilir. İnternet yoksa satış cihazda kuyruğa alınır (§4.13).
- Fiş ekranı tarayıcıdan yazdırılabilir veya paylaşılabilir (yasal belge değildir, "Bilgi fişi" ibaresi taşır).

### 4.5 İptal ve iade
- **İptal**: Kasa kapanmadan önce, satışın tamamı için yapılır. Yönetici onayı ve neden zorunludur. Tüm hareketler ters kayıtla geri alınır.
- **İade**: Kasa kapandıktan sonra veya kısmi olarak yapılır. İade edilen kalemler ve miktarlar seçilir. Her kalem için "Sağlam → stoğa" veya "Kusurlu → fire" seçilir. Para iadesi varsayılan olarak orijinal ödeme şekliyle yapılır, değiştirilebilir. Yönetici onayı gerekir.
- Satış kaydı hiçbir koşulda silinmez.

### 4.6 Müşteriler ve veresiye
- Müşteri kartı: ad/unvan, telefon, adres/teslimat notu, vergi no (isteğe bağlı), kredi limiti, depozito ve damacana özeti.
- Cari hesap ekstresi: satışlar, tahsilatlar, iadeler, açılış bakiyesi; tarih aralığıyla Excel/PDF (yazdır) alınabilir.
- Tahsilat: nakit veya POS, kısmi tahsilat yapılabilir.
- Limit aşımında satış durur; yönetici onayı ile geçilebilir ve bu durum kayda geçer.

### 4.7 Damacana ve depozito
- Her depozitolu ürünün (ör. "Erikli 19 L Damacana") bağlı bir **boş kap ürünü** vardır (ör. "Erikli Boş Damacana"). Boş kap stoğu ayrıca izlenir.
- Müşteri bazında: elindeki kap sayısı ve ödediği depozito tutarı izlenir.
- Depozito iadesi: müşteri kabı geri getirir, depozito nakit veya veresiyeden mahsup yoluyla iade edilir.
- Tedarikçiye boş kap iadesi ve kırık/kayıp kap (fire) hareketleri kaydedilir.

### 4.8 Mal kabul
- Depo personeli tedarikçi, irsaliye no, tarih ve kalemleri (ürün, birim, miktar, bedelsiz miktar) girer. Kayıt "Onay bekliyor" durumunda stoğa girer.
- Yönetici alış fiyatlarını girer veya onaylar. Onayla birlikte maliyet ve ortalama maliyet güncellenir.
- Tedarikçi kartı: ad, telefon, not.

### 4.9 Stok hareketleri, fire ve sayım
- Stok yalnızca hareketlerle değişir: satış, iade, iptal, mal kabul, fire/hasar, sayım düzeltmesi, boş kap hareketleri, açılış.
- Stok hareket geçmişi ürün, tür, tarih ve kullanıcı filtresiyle görüntülenir.
- Fire kaydı: ürün, miktar, neden (kırık, sızıntı, SKT, kayıp, diğer), not.
- Sayım: tam sayım veya ürün seçerek kısmi sayım. Sayım başladığında sistem stoğu "anlık görüntü" olarak alınır. Sayılan değerler girilir, farklar listelenir, yönetici onayıyla düzeltme hareketi oluşur.

### 4.10 Kasa ve gider
- İşletmede tek kasa vardır. Gün, kasa açılışıyla başlar (açılış nakdi = önceki kapanıştaki devreden nakit).
- Kasa hareketleri: nakit satış, nakit tahsilat, nakit iade, depozito alma/iade, gider, kasadan çıkış (bankaya yatan, sahibe teslim), kasaya giriş.
- Gün sonu kapatma: beklenen nakit hesaplanır → sayılan nakit girilir (isteğe bağlı küpür sayacı) → fark gösterilir → POS toplamı slipe göre teyit edilir → devreden nakit girilir → kapatılır. Farkın toleransı aşması durumunda açıklama zorunludur.
- Kapanmış gün değiştirilemez; sonradan fark çıkarsa bir sonraki güne düzeltme hareketi yazılır.
- Gider kaydı: tarih, kategori, tutar, ödeme şekli (kasa nakit / banka-kart), açıklama.

### 4.11 Raporlar
Tüm raporlarda tarih aralığı seçilebilir ve Excel (.xlsx) / CSV dışa aktarma yapılabilir.

| Rapor | Görenler |
|---|---|
| Günlük özet (satış, ödeme dağılımı, gider, kasa) | Yönetici |
| Günlük/aylık satış (miktar, ciro) | Yönetici, izleyici |
| Brüt kâr — ürün/marka/gün | Yönetici |
| Ürün ve marka bazında satış | Yönetici, izleyici |
| Kritik stok | Tüm roller |
| Hızlı / yavaş hareket eden stok | Yönetici, izleyici, depo |
| Stok değeri (maliyetle) | Yönetici |
| Veresiye bakiyeleri ve yaşlandırma | Yönetici |
| Müşterideki damacana ve depozito | Yönetici, satış |
| Kasa kapanış geçmişi ve farklar | Yönetici |
| Fire ve sayım farkları | Yönetici |
| Kullanıcı işlem geçmişi | Yönetici |
| Kendi satışlarım | Satış personeli |

### 4.12 Kullanıcı işlem geçmişi (denetim)
- Kritik işlemler (satış, iptal, iade, fiyat/maliyet değişikliği, stok hareketi, sayım onayı, kasa kapanışı, limit aşımı, kullanıcı/rol değişikliği) değiştirilemez bir denetim tablosuna yazılır: kim, ne zaman, hangi kayıt, önceki/yeni değer.

### 4.13 Çevrimdışı satış
- Bağlantı yokken tezgâh ekranı çalışmaya devam eder. Satış, benzersiz kimlikle cihazda kuyruğa alınır ve ekranda "Gönderilmedi" rozeti gösterilir.
- Bağlantı gelince kuyruk sırayla ve tekrar gönderime dayanıklı biçimde işlenir.
- Çevrimdışıyken: veresiye limiti son bilinen bakiyeyle kontrol edilir, iptal/iade/kasa/stok işlemleri kapalıdır.
- Sunucuda reddedilen kuyruk kaydı (ör. pasif ürün) kaybolmaz; "Sorunlu kayıtlar" listesinde yöneticiye gösterilir.

### 4.14 Veri içe/dışa aktarma ve geçiş
- İçe aktarma: ürünler (açılış stoğu dahil), müşteriler (açılış veresiye bakiyesi ve elindeki damacana dahil).
- Dışa aktarma: tüm listeler ve raporlar.
- Açılış bakiyeleri "Açılış" türünde hareket olarak yazılır.

## 5. Kullanılabilirlik ilkeleri
- Mobil öncelikli; en küçük hedef 360 px genişlik. Dokunma hedefleri en az 44 px.
- Arayüz Türkçedir. Tarih GG.AA.YYYY, saat SS:DD, para `1.234,50 ₺` biçimindedir.
- Tüm saatler Europe/Istanbul saat dilimine göre gösterilir ve gün sınırları bu dilime göre hesaplanır.
- Satış ekranında en fazla 2 dokunuşla ödeme ekranına geçilir.
- Hatalar sade Türkçe ile ve ne yapılması gerektiği belirtilerek gösterilir.
- Açık/koyu tema desteği vardır ve ana ekrana eklenebilir (PWA).

## 6. Fonksiyonel olmayan gereksinimler
- **Güvenlik:** Rol kontrolleri veritabanında (RLS + yetki kontrollü fonksiyonlar) uygulanır. Maliyet ve kâr verisi ayrı, yalnızca yöneticiye açık tablolarda tutulur. Gizli anahtarlar kaynak kodda yer almaz.
- **Bütünlük:** Satış, iade, iptal, mal kabul onayı, sayım onayı ve kasa kapanışı tek veritabanı işlemidir. Tekrar gönderilen istek çift kayıt oluşturmaz.
- **Performans:** Satış ekranı 4G bağlantıda 2 saniyede açılır. Satış kaydı 1 saniyenin altında tamamlanır.
- **Yedekleme:** Günlük otomatik mantıksal yedek alınır, 30 gün saklanır. Geri yükleme prosedürü belgelenir ve test edilir (`docs/BACKUP_RESTORE.md`).
- **Ortamlar:** Yerel geliştirme, demo (test verili) ve canlı ortam.
- **Tarayıcılar:** Güncel Chrome, Safari (iOS 16+), Edge ve Samsung Internet.
