# Sürümler ve geri dönüş noktaları

## BETA#1 — 10.10.2026

İlk beta. Bu noktaya üç parça birlikte döner: **kod**, **uygulama yayını**, **veritabanı**.

| Parça | Geri dönüş noktası |
|---|---|
| Kod (GitHub) | etiket **`beta-1`** → commit `6f8b835` · GitHub'da "BETA#1" sürümü |
| Uygulama (Vercel) | yayın `6sbGHsfVTN5r7DvZM5Uc1n8Nnpi5` · kalıcı adres `alkasu-qi3hb8lvn-manofprogress-s.vercel.app` |
| Veritabanı şeması | migration `20261010002000` (0001–0020) |
| Veritabanı verisi | Supabase içinde **`snap_beta1`** şeması (54 tablo; 37 müşteri, 36 ürün) — alındığı an: 10.10.2026 ~12:30 |

İçerik: satış/kasa/stok/sipariş temeli; bayi ve müşteri rolleri; internetten sipariş (mağaza ekranı, marka bölümleri);
bayinin müşteri listesi ve sipariş girişi; firmaya özel fiyatlar (28 kurumsal firma); KVKK aydınlatma ve kampanya izni;
bayi listesi gizliliği (öneri/onay) ve özel sevkiyat yönlendirme; kullanıcı unvanları.

### Anlık görüntü hakkında
- `supabase/snapshots/beta1_snapshot.sql` ile alındı: `public` ve `audit` şemalarındaki tüm tabloların, `auth.users`
  ve `storage.objects` kayıtlarının kopyası. API'ye açık değildir; yalnızca veritabanı sahibi okur (RLS açık, yetkiler kaldırıldı).
- **Aynı veritabanının içindedir.** Yanlış veri girişi, hatalı güncelleme gibi durumlarda geri dönüş sağlar;
  Supabase projesinin tamamen kaybına karşı **koruma sağlamaz**. Bunun için gece yedeğinin (docs/BACKUP_RESTORE.md)
  açılması gerekir.
- Kişisel veri içerir (KVKK): ihtiyaç kalmayınca `drop schema snap_beta1 cascade;` ile silinmelidir
  (öneri: BETA#2 alındıktan ve 30 gün sorunsuz geçtikten sonra).

## Geri dönüş (BETA#1'e)

Sırayla, gerektiği kadar:

1. **Yalnızca uygulamada sorun varsa (veri sağlam):** Vercel → alkasu → Deployments → `6sbGHsfVTN5r7DvZM5Uc1n8Nnpi5`
   → "⋯" → **Promote to Production** (ya da "Instant Rollback"). Veritabanına dokunulmaz.
   Not: veritabanı BETA#1'den yeni bir sürüme taşındıysa eski uygulama yeni şemayla çalışmalıdır; migration'lar geriye
   uyumlu yazılır (sütun/tablo eklenir, kaldırılmaz), sorun çıkarsa 3. adım.
2. **Kod:** `git checkout beta-1` (inceleme) veya yeni dal: `git switch -c geri-donus beta-1`. `main`e zorla yazılmaz;
   gerekirse geri dönüş dalı birleştirilir.
3. **Veri (yalnızca gerçekten gerekiyorsa — BETA#1'den sonra girilen satış, sipariş, müşteri vb. SİLİNİR):**
   1. Önce o anki hali kaydedin: `beta1_snapshot.sql` içindeki `snap_beta1` adlarını örn. `snap_oncesi_20261101` yapıp çalıştırın.
   2. Supabase → SQL Editor → `supabase/snapshots/restore_snapshot.sql` içeriğini yapıştırın (`v_snap` = `snap_beta1`) → Run.
   3. Çıktıdaki `SONUC:` satırını kontrol edin (BETA#1'de: 37 müşteri, 36 ürün).
   - `audit` (işlem geçmişi) ve `auth` (kullanıcılar, şifreler) geri alınmaz; geçmiş kaybolmaz.
   - Betik yerel kopyada denendi: veri değiştirildi → geri yüklendi → tüm tablo sayıları ve ürün verisi birebir aynı.

## Sonraki sürüm için
`beta1_snapshot.sql`'i kopyalayıp `snap_beta2` / etiket `beta-2` yapın; bu dosyaya yeni bir bölüm ekleyin.
