# ALKASU — İş Kuralları (v1)

> Belge sürümü: 1.0 · Tarih: 29.09.2026
> Kural kodları (ör. **S-03**) koddaki testlerde ve hata mesajlarında referans olarak kullanılır.
> "Ayar" ile işaretli değerler yönetici tarafından Ayarlar ekranından değiştirilebilir.

## 1. Genel

- **G-01** Her kayıt bir işletmeye (`business_id`) bağlıdır. Stok ve kasa kayıtları ayrıca bir lokasyona (`location_id`) bağlıdır. v1'de tek işletme ve tek lokasyon ("Merkez") bulunur.
- **G-02** Tüm zaman damgaları UTC olarak saklanır. Gösterim ve gün/ay sınırları Europe/Istanbul saat dilimine göre yapılır.
- **G-03** Para birimi TRY'dir. Tutarlar 2 ondalık basamakla saklanır, birim maliyetler 4 ondalık basamakla. Yuvarlama satır bazında "yarım yukarı" yöntemiyle yapılır, fiş toplamı yuvarlanmış satırların toplamıdır.
- **G-04** Finansal ve stok kayıtları silinmez. Düzeltme yalnızca ters kayıt veya düzeltme hareketiyle yapılır.
- **G-05** Kritik işlemler denetim kaydı üretir (bkz. §12).

## 2. Birimler ve dönüşüm

- **B-01** Her ürünün bir **temel birimi** vardır (adet, şişe, damacana...). Stok yalnızca temel birimde, tam sayı olarak tutulur.
- **B-02** Ürünün en fazla iki ek birimi olabilir (varsayılan adlar "Paket" ve "Koli"). Her ek birimin çarpanı tam sayıdır ve 1'den büyüktür (ör. 1 koli = 12 adet).
- **B-03** Satış ve mal kabulde herhangi bir birim seçilebilir. Stoğa etkisi `miktar × çarpan` kadar temel birimdir.
- **B-04** Koli açıp tek adet satmak için ayrı bir işlem gerekmez; stok zaten temel birimde tutulur.
- **B-05** Farklı ambalajlar (ör. 0,5 L 6'lı ve 0,5 L 12'li) aynı temel ürünün ek birimleri olarak tanımlanabilir. İçerik farklıysa (1,5 L ve 0,5 L gibi) ayrı ürün tanımlanır.
- **B-06** Kullanımda olan bir ek birimin çarpanı değiştirilemez; yeni bir birim tanımlanır ve eskisi pasife alınır. Bu, geçmiş hareketlerin anlamını korur.

## 3. Fiyatlandırma

- **F-01** Satış fiyatları **KDV dahil** girilir ve her birim için ayrı tutulur (adet, paket, koli). Ek birimin fiyatı boş bırakılırsa, o birim satışta seçilemez.
- **F-02** Her üründe bir KDV oranı (%0, %1, %10, %20) tanımlıdır. Bu oran yalnızca raporlarda KDV hariç tutarı hesaplamak için kullanılır.
- **F-03** Fiyatı yalnızca yönetici değiştirir. Değişiklik, geçerlilik zamanıyla birlikte fiyat geçmişine yazılır.
- **F-04** Satış kalemi; birim fiyatı, indirimi, KDV oranını ve birim maliyeti satış anındaki değerleriyle **kopyalar** (anlık görüntü). Sonradan yapılan fiyat veya maliyet değişikliği geçmiş satışları etkilemez.
- **F-05** İndirim satır bazında veya fiş bazında, tutar ya da yüzde olarak uygulanabilir. Fiş indirimi satırlara tutarları oranında dağıtılır.
- **F-06** Satış personelinin uygulayabileceği toplam indirim fiş tutarının **%5**'ini aşamaz (Ayar). Daha yüksek indirimi yalnızca yönetici yapar.
- **F-07** Birim fiyatı sıfır olan satış yalnızca yönetici tarafından yapılabilir (ikram, numune).

## 4. Maliyet

- **M-01** Maliyet yöntemi **ağırlıklı ortalamadır**. Birim maliyet temel birim başına tutulur.
- **M-02** Mal kabul onaylandığında:
  `yeni_ort = (eldeki × eski_ort + alınan × alış_birim_maliyeti) / (eldeki + alınan + bedelsiz)`
  Formüldeki `eldeki` değeri 0 veya negatifse `yeni_ort = (alınan × alış_birim_maliyeti) / (alınan + bedelsiz)` olur.
- **M-03** Alış birim maliyeti **KDV dahil** girilir. İşletme KDV mükellefi olsa da v1 kâr raporları KDV dahil fiyat ve KDV dahil maliyetle hesaplanır (tutarlılık için). KDV hariç görünüm raporda ayrıca verilir.
- **M-04** Satışın maliyeti, satış anındaki ortalama maliyettir (F-04). İadede maliyet, iade edilen satış kalemindeki orijinal maliyetle geri alınır.
- **M-05** Sayım ve fire düzeltmeleri güncel ortalama maliyetten değerlenir ve ortalamayı değiştirmez.
- **M-06** Brüt kâr = net satış tutarı (KDV dahil, indirim ve iade düşülmüş, depozito hariç) − satılan malın maliyeti.
- **M-07** Ürünün hiç mal kabulü yoksa maliyeti, açılış içe aktarmasındaki alış fiyatıdır. O da yoksa 0 kabul edilir ve kâr raporunda "maliyetsiz" uyarısı gösterilir.

## 5. Satış

- **S-01** Her satış bir fiştir. Fiş başlığı, kalemler, ödemeler, stok hareketleri, depozito hareketleri, kasa hareketi ve veresiye hareketi **tek veritabanı işleminde** oluşur. Herhangi bir adım başarısız olursa hiçbir kayıt oluşmaz.
- **S-02** Her satışın istemci tarafından üretilen benzersiz bir kimliği (idempotency key) vardır. Aynı kimlikle ikinci gönderim yeni kayıt oluşturmaz, ilk kaydı döner.
- **S-03** Ödemelerin toplamı fiş net toplamına eşit olmalıdır. Nakitte fazla verilen tutar para üstü olarak gösterilir ve kasaya net tutar yazılır.
- **S-04** Veresiye ödeme payı varsa müşteri seçimi zorunludur ve veresiye limiti kontrol edilir (bkz. V-02).
- **S-05** **Stok yetersizliği satışı engellemez.** Satış ekranında uyarı gösterilir ve stok negatife düşebilir. Negatif stoklu ürünler kritik stok raporunda en üstte kırmızı ile listelenir. (Gerekçe: çevrimdışı satış ve tezgâh hızı; bkz. DECISIONS D-009.)
- **S-06** Pasif ürün satılamaz.
- **S-07** Satış, işlemin yapıldığı anda açık olan kasa gününe (kasa oturumu) bağlanır. Açık kasa günü yoksa ilk satış kasa gününü otomatik açar (bkz. K-02).
- **S-08** Satış personeli yalnızca kendi satışlarının ayrıntısını görür. Yönetici tüm satışları görür.

## 6. Damacana ve depozito

- **D-01** Depozitolu bir ürün (dolu damacana), bir **boş kap ürününe** bağlıdır. Boş kap ürünü satılabilir ürün değildir, yalnızca stok takibi yapılır.
- **D-02** Depozito tutarı, dolu ürünün kartında tanımlıdır (Ayar, ürün bazında).
- **D-03** Dolu damacana satışında satış personeli "Boş getirdi" sayısını girer (varsayılan = satılan adet):
  - Getirilen her boş kap: **boş kap stoğu +1**.
  - Getirilmeyen her kap için müşteriden depozito alınır, depozito satırı fişe eklenir ve müşterinin **kap bakiyesi +1** olur.
  - Müşteri kap bakiyesi fazlası kadar boş getirirse (ör. 2 dolu alıp 3 boş getirirse) fazla kap, müşterinin kap bakiyesinden düşer ve karşılığındaki depozito iade edilir ya da bakiyede alacak olarak bırakılır (D-05).
- **D-04** Depozito **gelir değildir.** Ciro ve kâra dahil edilmez, müşteriye karşı yükümlülük olarak ayrı izlenir. Nakit alınan depozito kasa beklenen tutarına dahildir.
- **D-05** Depozito iadesi: müşteri kabı getirir, kap bakiyesi −1, boş kap stoğu +1 olur. Depozito nakit iade edilir veya veresiye bakiyesinden mahsup edilir.
- **D-06** Kayıtsız (perakende) müşteri kap getirmezse depozito yine alınır. Kap, "Perakende müşteri" hesabında izlenir; iade edildiğinde bu hesaptan düşülür.
- **D-07** Tedarikçiye boş kap iadesi: boş kap stoğu −N (hareket türü: `tedarikci_bos_iade`).
- **D-08** Kırık/kayıp kap: boş kap stoğu −N (fire). Müşteriden kırık kap bildirilirse, depozitosu işletmede kalır ve müşteri kap bakiyesi düşer (hareket türü: `musteri_kap_kaybi`, depozito gelire değil "depozito tahsil edilen kayıp" hesabına yazılır).
- **D-09** Açılış: müşterinin elindeki kap sayısı ve ödenmiş depozito, içe aktarma ile "Açılış" hareketi olarak girilir.

## 7. Veresiye (cari hesap)

- **V-01** Veresiye yalnızca kayıtlı müşteriye verilir.
- **V-02** Müşterinin kredi limiti vardır (0 = limitsiz değil, veresiye kapalı demektir; "Limitsiz" ayrı bir seçenektir). Satış sonrası bakiye limiti aşarsa satış durur. Yönetici onayıyla geçilebilir ve bu olay denetime yazılır.
- **V-03** Bakiye = açılış + veresiye satışlar − tahsilatlar − veresiyeye yapılan iadeler − veresiyeden mahsup edilen depozito iadeleri.
- **V-04** Tahsilat nakit veya POS ile yapılır, kısmi olabilir. Tahsilat fişlere dağıtılmaz; cari hesap tek bakiye olarak izlenir (yaşlandırma için FIFO kabul edilir).
- **V-05** Tahsilatı yönetici ve satış personeli girebilir. Tahsilat iptalini yalnızca yönetici, ters kayıtla yapar.
- **V-06** Yaşlandırma grupları: 0–30, 31–60, 61–90 ve 90+ gün.

## 8. Mal kabul

- **A-01** Depo personeli mal kabul fişini oluşturur: tedarikçi, irsaliye/fatura no, tarih, kalemler (ürün, birim, miktar, bedelsiz miktar).
- **A-02** Kaydedildiği anda stok artar (hareket türü `mal_kabul`). Fiş durumu "Fiyat onayı bekliyor" olur.
- **A-03** Yönetici alış fiyatlarını girip onaylar. Onayla birlikte ortalama maliyet M-02'ye göre güncellenir ve maliyet geçmişine yazılır. Onaylanmamış mal kabul, onaya kadar önceki ortalama maliyeti etkilemez; kâr raporunda "onaysız alış var" uyarısı gösterilir.
- **A-04** Onaylanmış mal kabul değiştirilemez. Hata, "Mal kabul düzeltmesi" (ters kayıt + yeni fiş) ile giderilir.
- **A-05** Bedelsiz miktar stoğa girer, maliyeti sıfırdır ve ortalamayı düşürür.
- **A-06** Dolu damacana mal kabulünde, tedarikçiye verilen boş kap sayısı aynı fişte girilebilir (D-07).

## 9. İptal ve iade

- **I-01** **İptal**: Satışın tamamı için yapılır ve yalnızca satışın bağlı olduğu kasa günü kapanmadan mümkündür. Tüm hareketler (stok, ödeme, kasa, veresiye, depozito) ters kayıtla geri alınır. Satış durumu "İptal" olur.
- **I-02** **İade**: Kalem ve miktar seçilerek yapılır. İade edilen miktar, satılan miktardan önceki iadeler düşüldükten sonra kalan miktarı aşamaz.
- **I-03** İade edilen her kalem için durum seçilir: **Sağlam** (stoğa geri döner) veya **Kusurlu** (stoğa girip aynı işlemde fire olarak düşer; raporda iade kaynaklı fire görünür).
- **I-04** Para iadesi varsayılan olarak orijinal ödeme dağılımıyla yapılır: önce veresiye bakiyesinden düşülür, sonra POS, sonra nakit. Yönetici bu dağılımı değiştirebilir.
- **I-05** İptal ve iadede yönetici onayı ve neden zorunludur. v1'de onay, işlemi yöneticinin kendi hesabıyla yapmasıdır. Satış personeli "İade talebi" oluşturabilir; yönetici talebi onaylar.
- **I-06** İade, iadenin yapıldığı günün kasasına yazılır. Orijinal satış gününe dokunulmaz.
- **I-07** İade edilen depozitolu üründe kap iadesi D-05'e göre ayrıca işlenir.

## 10. Stok, fire ve sayım

- **T-01** Güncel stok (`stock_levels`) yalnızca stok hareketlerinden türetilir. Hiçbir kullanıcı ya da API bu tabloya doğrudan yazamaz.
- **T-02** Hareket türleri: `acilis`, `satis`, `satis_iptal`, `iade`, `mal_kabul`, `mal_kabul_duzeltme`, `fire`, `sayim_duzeltme`, `bos_kap_giris`, `bos_kap_cikis`, `tedarikci_bos_iade`, `musteri_kap_kaybi`.
- **T-03** Fire/hasar: ürün, miktar, neden (Kırık, Sızıntı, SKT geçmiş, Kayıp/çalıntı, Diğer) ve not girilir. Depo personeli ve yönetici girebilir. Fire tutarı (maliyetle) yalnızca yöneticiye görünür.
- **T-04** Sayım oturumu:
  1. Yönetici veya depo personeli oturumu açar (tam sayım veya ürün seçerek kısmi sayım). Sistem stoğu anlık görüntü olarak alınır.
  2. Sayılan miktarlar birim seçilerek girilir (ör. 3 koli + 5 adet).
  3. Sayım süresince yapılan satışlar farka yansıtılır: `fark = sayılan − (anlık_görüntü + sayım_süresindeki_hareketler)`. v1'de öneri, sayımın satış dışı saatte yapılmasıdır.
  4. Yönetici farkları onaylar. Her fark için `sayim_duzeltme` hareketi oluşur. Onaylanan sayım kilitlenir.
- **T-05** Kritik stok: ürün kartındaki "kritik seviye" (temel birim) değerinde veya altında olan ürünler uyarı listesine girer. Sistem, son 30 günlük ortalama günlük satış × **7 gün** (Ayar) formülüyle öneri değer gösterir.
- **T-06** Hızlı/yavaş hareket (seçilen dönem, varsayılan 30 gün):
  - Hızlı: satış miktarına göre en üstteki %20'lik dilim.
  - Yavaş: stokta olan, ama satış miktarı en alttaki %20'lik dilimde olan ya da hiç satılmayan ürünler.
  - Stokta kalma süresi: `eldeki / ortalama_günlük_satış`.

## 11. Kasa ve gider

- **K-01** İşletmenin tek kasası vardır (lokasyon başına bir kasa).
- **K-02** Kasa günü (oturum) açılış nakdiyle başlar. Açılış nakdi = önceki kapanıştaki **devreden nakit**. İlk satış veya ilk kasa hareketi, açık gün yoksa günü otomatik açar.
- **K-03** Beklenen nakit hesabı:
  `açılış + nakit satış + nakit veresiye tahsilatı + nakit alınan depozito + kasaya giriş − nakit iade − nakit depozito iadesi − kasadan ödenen gider − kasadan çıkış (bankaya/sahibe)`
- **K-04** Kapanış: sayılan nakit girilir, `fark = sayılan − beklenen` hesaplanır. |fark| > **50 ₺** (Ayar) ise açıklama zorunludur. POS toplamı sistemdeki POS satışları ve tahsilatlarıyla karşılaştırılır; banka slip tutarı girilir, POS farkı da kaydedilir.
- **K-05** Kapanışta "devreden nakit" girilir. Sayılan nakit ile devreden nakit arasındaki tutar, otomatik "kasadan çıkış – gün sonu teslim" hareketi olarak kaydedilir.
- **K-06** Kasa kapanışını yalnızca yönetici yapar. Kapanmış gün değiştirilemez ve yeniden açılamaz. Hata, sonraki güne "Kasa düzeltme" hareketiyle yansıtılır.
- **K-07** Kasa kapalıyken (günün sonunda) yapılan satış, yeni bir kasa gününü açar (K-02).
- **K-08** Çevrimdışı kuyruktan kasa kapandıktan sonra gelen satış, orijinal saatini korur ancak **açık olan (yeni) kasa gününe** yazılır ve "geç senkron" işaretiyle raporlanır.
- **K-09** Gider kaydı: tarih, kategori, tutar, ödeme şekli (Kasa-nakit / Banka-kart), açıklama. Yalnızca kasa-nakit giderler beklenen nakdi etkiler. Gideri yalnızca yönetici girer.
- **K-10** Varsayılan gider kategorileri: Kira, Elektrik/Su/Doğalgaz, Yakıt, Araç bakım, Personel, Vergi/SGK, Kırtasiye/Sarf, Yemek, Diğer. Kategoriler yönetici tarafından düzenlenebilir.

## 12. Yetkiler

| İşlem | Yönetici | Satış | Depo | İzleyici |
|---|:-:|:-:|:-:|:-:|
| Satış yapma | ✅ | ✅ | ❌ | ❌ |
| Satış iptali / iade (onay) | ✅ | Talep | ❌ | ❌ |
| Müşteri kartı oluşturma/düzenleme | ✅ | ✅ | ❌ | ❌ |
| Kredi limiti belirleme | ✅ | ❌ | ❌ | ❌ |
| Veresiye tahsilatı | ✅ | ✅ | ❌ | ❌ |
| Ürün/marka/kategori kartı | ✅ | ❌ | ❌ | ❌ |
| Satış fiyatı görme | ✅ | ✅ | ✅ | ✅ |
| Satış fiyatı değiştirme | ✅ | ❌ | ❌ | ❌ |
| Alış fiyatı, maliyet, kâr, stok değeri görme | ✅ | ❌ | ❌ | ❌ |
| Stok miktarı görme | ✅ | ✅ | ✅ | ✅ |
| Mal kabul girişi | ✅ | ❌ | ✅ | ❌ |
| Mal kabul fiyat onayı | ✅ | ❌ | ❌ | ❌ |
| Fire / hasar girişi | ✅ | ❌ | ✅ | ❌ |
| Sayım girişi | ✅ | ❌ | ✅ | ❌ |
| Sayım onayı | ✅ | ❌ | ❌ | ❌ |
| Boş kap hareketleri | ✅ | ✅ (satışta) | ✅ | ❌ |
| Kasa hareketi, gider, kasa kapatma | ✅ | ❌ | ❌ | ❌ |
| Veresiye bakiyelerini görme | ✅ | Seçilen müşteri | ❌ | ❌ |
| Raporlar | Tümü | Kendi satışları, kritik stok, damacana | Stok raporları | Satış miktar/ciro, stok (maliyetsiz) |
| Kullanıcı ve ayar yönetimi | ✅ | ❌ | ❌ | ❌ |
| İşlem geçmişi (denetim) | ✅ | ❌ | ❌ | ❌ |

- **Y-01** Bu yetkiler hem arayüzde hem veritabanında (RLS politikaları ve yetki kontrollü fonksiyonlar) uygulanır. Arayüzde gizlenen bir işlem, API üzerinden de reddedilir.
- **Y-02** Maliyet, alış fiyatı ve kâr içeren tablolar yalnızca yönetici rolüne açıktır.
- **Y-03** Satış personeli, satış ekranında müşteri seçtiğinde yalnızca o müşterinin bakiyesini ve limitini görür.
- **Y-04** İşletmede en az bir aktif yönetici bulunmalıdır. Son yönetici pasife alınamaz ve rolü düşürülemez.

## 13. Denetim kaydı

- **L-01** Denetim kaydı alanları: işletme, kullanıcı, zaman, işlem türü, tablo, kayıt kimliği, önceki değer (JSON), yeni değer (JSON), cihaz/istemci bilgisi.
- **L-02** Denetim tablosuna yalnızca veritabanı fonksiyonları ve tetikleyiciler yazar. Güncelleme ve silme hiçbir rol için mümkün değildir.
- **L-03** Kapsam: satış, iptal, iade, tahsilat, fiyat değişikliği, maliyet değişikliği, mal kabul ve onayı, fire, sayım onayı, kasa hareketleri ve kapanış, limit aşımı onayı, ürün/müşteri kartı değişiklikleri, kullanıcı/rol değişiklikleri, ayar değişiklikleri, içe aktarmalar.

## 14. Çevrimdışı satış

- **C-01** Yalnızca satış (ve satışa eklenen depozito/boş kap bilgisi) çevrimdışı kuyruğa alınabilir.
- **C-02** Çevrimdışı satışta fiyatlar cihazda önbelleğe alınmış son fiyat listesinden alınır. Sunucu, kayıt sırasında fiyatı **yeniden hesaplamaz**; cihazın gönderdiği fiyatı yetki ve indirim kurallarına göre doğrular (F-06). Kural ihlali varsa kayıt "Sorunlu kayıtlar" listesine düşer.
- **C-03** Çevrimdışıyken veresiye yalnızca son bilinen bakiye limiti karşılıyorsa yapılabilir. Sunucuda limit aşılırsa satış yine kaydedilir ve yöneticiye "çevrimdışı limit aşımı" uyarısı gider (satış geri alınmaz, çünkü mal teslim edilmiştir).
- **C-04** Kuyruktaki satış 72 saatten eskiyse, gönderim öncesi kullanıcıya uyarı gösterilir.
- **C-05** Cihazdaki kuyruk, kullanıcı çıkış yapsa bile gönderilene kadar silinmez. Çıkış öncesi "gönderilmemiş N satış var" uyarısı gösterilir.

## 15. İçe aktarma

- **E-01** İçe aktarma iki adımlıdır: dosya doğrulama ve önizleme (satır bazında hata/uyarı), ardından onay ile tek işlemde kayıt. Tek satır hatalıysa hiçbir satır kaydedilmez.
- **E-02** Ürün eşleştirme `urun_kodu` ile yapılır. Var olan kod güncellenir, yoksa yeni ürün oluşturulur. Güncelleme fiyat değişikliği içeriyorsa fiyat geçmişine yazılır.
- **E-03** Açılış stoğu ve açılış maliyeti yalnızca ürünün hiç stok hareketi yoksa uygulanır. Aksi halde uyarı verilir ve bu alanlar yok sayılır.
- **E-04** Marka ve kategori adları bulunamazsa otomatik oluşturulur (önizlemede "yeni" olarak işaretlenir).
