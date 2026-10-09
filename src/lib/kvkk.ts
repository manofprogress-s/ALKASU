/**
 * KVKK metinleri (BUSINESS_RULES §23, D-064..D-067). Tek kaynak: metin değişirse KVKK_VERSION da değişir;
 * kayıtlarda hangi sürümün gösterildiği bu değerle tutulur.
 */
export const KVKK_VERSION = "2026-10-09";
export const KVKK_UPDATED = "9 Ekim 2026";

/** Veri sorumlusu bilgileri — vergi levhasındaki bilgilerle doldurulur. Boş alan yayın öncesi kontrolde yakalanır. */
export const CONTROLLER = {
  title: "Ayhan Alay (şahıs işletmesi)", // Vergi levhası: ticaret unvanı yok, mükellef Ayhan Alay
  brand: "AlkaSu",
  address: "İstasyon Mahallesi, Hüsnü Efe Caddesi No: 12 A, Kartepe / Kocaeli", // Tebligat ve başvuru adresi
  email: "me.eneskarakaya@gmail.com", // KVKK başvuru e-postası (ilk aşama; kullanıcı kararı 09.10)
  phone: "",      // İsteğe bağlı; boşsa metinde gösterilmez
  kep: "",        // Varsa KEP adresi
  site: "https://alkasu.vercel.app",
};

/** Eksik veri sorumlusu bilgisi (yayın öncesi kontrol ve test için) */
export function missingControllerFields(): string[] {
  const m: string[] = [];
  if (!CONTROLLER.title.trim()) m.push("ticari unvan");
  if (!CONTROLLER.address.trim()) m.push("adres");
  if (!CONTROLLER.email.trim()) m.push("KVKK e-postası");
  return m;
}

export const SHORT_NOTICE =
  "Siparişinizi almak ve teslim etmek için ad soyad, telefon, açık adres, haritada seçtiğiniz teslimat noktası, sipariş ve ödeme bilgilerinizi işliyoruz. " +
  "Bu bilgiler siparişin hazırlanması, size en yakın bayiye atanması, rota planlanması, teslimat, tahsilat ve yasal yükümlülükler için yetkili çalışanlarımız, " +
  "teslimatı yapan bayi ve gerekli hizmet sağlayıcılarla paylaşılabilir.";

export const MARKETING_TEXT =
  "AlkaSu ürünleri, indirimleri ve kampanyaları hakkında telefon, SMS, e-posta veya elektronik mesaj yoluyla ticari ileti almak istiyorum. " +
  "Bu amaçla iletişim bilgilerimin işlenmesine izin veriyorum. İznimi dilediğim zaman ücretsiz olarak geri çekebilirim.";

export const LOCATION_NOTICE =
  "Teslimat noktanızı daha hızlı belirlemek için cihazınızın konumunu bir kez kullanabiliriz. Konum izni vermeden de adresinizi yazıp " +
  "Google Maps bağlantısı yapıştırarak sipariş verebilirsiniz. Konumunuz yalnızca teslimat adresinin belirlenmesi ve siparişin teslimi için kullanılır.";

/** Hizmet sağlayıcılar (yurt dışı aktarım bölümü ve envanter için) */
export const PROVIDERS = [
  { name: "Supabase Inc.", role: "Veritabanı ve kullanıcı girişi", where: "Sunucular Almanya (Frankfurt)", data: "Uygulamadaki tüm müşteri, sipariş ve hesap kayıtları" },
  { name: "Vercel Inc.", role: "Uygulama sunucusu ve barındırma", where: "Şirket ABD'de; uygulama sunucusu Almanya (Frankfurt)", data: "Sayfa istekleri, IP adresi ve işlem sırasında geçen veriler" },
  { name: "Google LLC (Google Maps)", role: "Harita bağlantısı ve sayfadaki küçük harita", where: "ABD ve küresel sunucular", data: "Haritası gösterilen konum ve harita açıldığında cihazınızın IP adresi" },
];
