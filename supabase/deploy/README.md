# 07.10.2026 yayını: müşteri siparişi, bayi teslimatı, rota

Sıra önemlidir (yeni rol değeri ayrı işlemde eklenmelidir):

1. Supabase → SQL Editor: `2026-10-07_1_rol.sql` → Run
2. Supabase → SQL Editor: `2026-10-07_2_online_siparis.sql` → Run → son tabloda `internet_siparisi_acik = true`, `kurulan_adim = 2`
3. GitHub: `musteri-siparis` dalını `main`e birleştir → Vercel otomatik yayınlar (~1 dk)
4. Kontrol: https://alkasu.vercel.app/giris → 3 seçenek; "Sipariş ver" sayfası ürünleri listeliyor

Not: 2. adımla 3. adım arasında (1–2 dk) eski uygulamanın Siparişler sayfası hata verir (siparişte ikinci müşteri
bağlantısı eklendiği için). Bu yüzden 2. ve 3. adım art arda yapılır; satış ekranı bu sürede çalışmaya devam eder.

Geri alma: internet siparişini kapatmak için `update public.businesses set public_ordering = false;`
Uygulamayı önceki sürüme döndürmek gerekirse Vercel → Deployments → önceki yayın → "Promote to Production";
bu durumda Siparişler sayfası için düzeltme gerekir (bkz. D-054 notu).
