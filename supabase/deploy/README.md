# 07.10.2026 yayını: müşteri siparişi, bayi teslimatı, rota

Sıra önemlidir (yeni rol değeri ayrı işlemde eklenmelidir):

1. Supabase → SQL Editor: `2026-10-07_1_rol.sql` → Run
2. Supabase → SQL Editor: `2026-10-07_2_online_siparis.sql` → Run → son tabloda `internet_siparisi_acik = true`, `kurulan_adim = 2`
3. GitHub: `musteri-siparis` dalını `main`e birleştir → Vercel otomatik yayınlar (~1 dk)
4. Kontrol: https://alkasu.vercel.app/giris → 3 seçenek; "Sipariş ver" sayfası ürünleri listeliyor

Geri alma: 3. adım geri alınırsa (main önceki sürüme döner) veritabanı değişiklikleri eski uygulamayla da uyumludur;
yalnızca `update public.businesses set public_ordering = false;` ile internet siparişi kapatılır.
