import Link from "next/link";
import type { ReactNode } from "react";
import { CONTROLLER, KVKK_UPDATED, KVKK_VERSION, PROVIDERS } from "@/lib/kvkk";

export const metadata = { title: "Müşteri Aydınlatma Metni" };

const blank = (v: string, label: string) => (v.trim() ? v : `[${label}]`);

function Section({ id, title, children }: { id?: string; title: string; children: ReactNode }) {
  return (
    <section id={id} className="scroll-mt-4 space-y-2">
      <h2 className="text-lg font-semibold">{title}</h2>
      {children}
    </section>
  );
}

const List = ({ items }: { items: string[] }) => (
  <ul className="list-disc space-y-1 pl-5">{items.map((i) => <li key={i}>{i}</li>)}</ul>
);

/** Herkese açık KVKK aydınlatma metni (D-064). Sürüm: KVKK_VERSION. */
export default function KvkkPage() {
  const c = CONTROLLER;
  const contact = [
    blank(c.address, "AÇIK ADRES"),
    blank(c.email, "KVKK E-POSTA ADRESİ"),
    c.kep.trim() ? `KEP: ${c.kep}` : null,
    c.phone.trim() ? `Tel: ${c.phone}` : null,
  ].filter(Boolean).join(" · ");

  return (
    <main className="mx-auto max-w-2xl space-y-6 p-4 pb-16 text-[15px] leading-relaxed">
      <div className="flex items-center justify-between">
        <Link href="/siparis-ver" className="text-2xl font-bold tracking-tight text-brand">ALKASU</Link>
        <Link href="/siparis-ver" className="text-sm text-brand">Sipariş ver</Link>
      </div>
      <header className="space-y-1">
        <h1 className="text-2xl font-bold">Müşteri Aydınlatma Metni</h1>
        <p className="text-sm text-muted">Son güncelleme: {KVKK_UPDATED} · Sürüm {KVKK_VERSION}</p>
      </header>

      <Section title="Veri sorumlusu">
        <p>
          6698 sayılı Kişisel Verilerin Korunması Kanunu (“Kanun”) kapsamında veri sorumlusu {blank(c.title, "VERGİ LEVHASINDAKİ TAM TİCARİ UNVAN")} olup
          {" "}{c.brand} markasıyla hizmet vermektedir. Bize şu kanallardan ulaşabilirsiniz: {contact}.
        </p>
      </Section>

      <Section title="İşlenen kişisel veriler">
        <p>Uygulamayı kullanma biçiminize göre şu veriler işlenebilir:</p>
        <List items={[
          "Kimlik: ad ve soyad.",
          "İletişim: telefon numarası ve varsa e-posta adresi, kampanya iletişimi tercihiniz.",
          "Adres ve konum: açık teslimat adresi, adres tarifi, paylaştığınız Google Maps bağlantısındaki ya da isteğinizle cihazınızdan alınan konumun enlem ve boylamı.",
          "Müşteri işlem: sipariş kalemleri, miktar, teslimat günü ve durumu, iptal, iade, notunuz, siparişin atandığı bayi ve sipariş geçmişi.",
          "Finans: ödeme yöntemi, tahsilat, cari hesap ve depozito bilgileri. Kart numarası veya güvenlik kodu uygulamada alınmaz ve saklanmaz.",
          "İşlem güvenliği: kullanıcı ve işlem kayıtları, tarih-saat, kayıt sırasında IP adresi, oturum ve hata kayıtları.",
          "Kurumsal müşteriler: firma yetkilisi veya irtibat kişisinin ad soyadı, telefonu, teslimat ve cari hesap bilgileri.",
        ]} />
      </Section>

      <Section title="İşleme amaçları">
        <List items={[
          "Müşteri hesabının oluşturulması ve doğrulanması.",
          "Siparişin alınması, hazırlanması, stokla ilişkilendirilmesi, uygun bayiye atanması ve teslim edilmesi.",
          "Teslimat adresinin doğrulanması, size ulaşılması ve dağıtım rotasının planlanması.",
          "Ödeme, tahsilat, faturalama, cari hesap, depozito, iade ve muhasebe işlemlerinin yürütülmesi.",
          "Talep ve şikâyetlerin sonuçlandırılması, hizmet kalitesinin ölçülmesi.",
          "Yetkisiz erişimin ve kötüye kullanımın önlenmesi, bilgi güvenliğinin sağlanması, işlem kayıtlarının tutulması.",
          "Kanuni yükümlülüklerin yerine getirilmesi ve hukuki uyuşmazlıklarda hakların korunması.",
          "Ayrıca ve isteğe bağlı izin verdiyseniz kampanya, tanıtım ve ticari elektronik ileti gönderilmesi.",
        ]} />
      </Section>

      <Section title="Hukuki sebepler">
        <p>
          Siparişin alınması ve teslimi için gerekli veriler, Kanunun 5. maddesinin 2. fıkrası kapsamında sözleşmenin kurulması veya ifasıyla
          doğrudan ilgili olması, hukuki yükümlülüğümüzü yerine getirebilmemiz, bir hakkın tesisi, kullanılması veya korunması ve temel hak ve
          özgürlüklerinize zarar vermemek kaydıyla meşru menfaatlerimiz için zorunlu olması sebeplerine dayanılarak işlenir. Kampanya iletişimi
          ve cihaz konumunun kullanılması gibi isteğe bağlı işlemler için ayrıca ve özgür iradenizle izin alınır; bu izinleri vermemeniz sipariş
          vermenize engel değildir.
        </p>
      </Section>

      <Section title="Toplama yöntemi">
        <p>
          Veriler; uygulamadaki kayıt ve sipariş formları, paylaştığınız harita bağlantısı veya izin verdiğinizde cihaz konumu, telefon ve mesaj
          görüşmeleri, kurumsal müşteri kayıtları, teslimat sırasında oluşturulan kayıtlar, ödeme ve muhasebe kayıtları ile uygulamanın güvenlik ve
          işlem kayıtları üzerinden otomatik veya kısmen otomatik yollarla toplanır.
        </p>
      </Section>

      <Section title="Aktarım">
        <p>Kişisel verileriniz yalnızca yukarıdaki amaçlarla ve gerektiği ölçüde şu alıcılara aktarılabilir:</p>
        <List items={[
          "Siparişinizi teslim eden bağımsız bayilerimiz (Gürpınar ve Fuska bölgesi bayileri): yalnızca teslimat için gereken ad soyad, telefon, adres, konum ve sipariş bilgileri.",
          "Yetkili çalışanlarımız ve teslimat personeli: görevleri için gerekli olduğu kadar.",
          "Uygulama, barındırma, veritabanı ve harita hizmeti sağlayıcıları (aşağıda listelenmiştir).",
          "Yasal yükümlülükler kapsamında yetkili kamu kurum ve kuruluşları ile adli ve idari merciler.",
          "Gizlilik yükümlülüğü altındaki hukuk, mali müşavirlik ve denetim hizmeti sağlayıcıları.",
        ]} />
      </Section>

      <Section title="Yurt dışına aktarım">
        <p>
          Uygulamamız aşağıdaki sağlayıcıların sunucularında çalışır. Bu nedenle verileriniz yurt dışına aktarılır. Aktarım, Kanunun 9. maddesindeki
          şartlara uygun olarak, Kişisel Verileri Koruma Kurulu tarafından ilan edilen standart sözleşmeler gibi uygun güvencelerle yapılır.
        </p>
        <div className="overflow-x-auto">
          <table className="w-full text-left text-sm">
            <thead className="text-muted">
              <tr><th className="py-1 pr-3 font-medium">Sağlayıcı</th><th className="py-1 pr-3 font-medium">Hizmet</th><th className="py-1 pr-3 font-medium">Konum</th><th className="py-1 font-medium">Veri</th></tr>
            </thead>
            <tbody>
              {PROVIDERS.map((p) => (
                <tr key={p.name} className="border-t border-border align-top">
                  <td className="py-1.5 pr-3">{p.name}</td><td className="py-1.5 pr-3">{p.role}</td><td className="py-1.5 pr-3">{p.where}</td><td className="py-1.5">{p.data}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Section>

      <Section title="Saklama ve imha">
        <p>
          Verileriniz işleme amacı için gerekli süre boyunca ve vergi, ticaret, tüketici ve borçlar mevzuatında öngörülen süreler kadar saklanır.
          Süresi dolan ve işleme sebebi kalmayan veriler silinir, yok edilir veya anonim hâle getirilir. Hesabınızın kapatılması, fatura ve
          muhasebe kayıtlarının kanuni saklama süresi dolmadan silineceği anlamına gelmez.
        </p>
      </Section>

      <Section id="basvuru" title="Haklarınız ve başvuru">
        <p>Kanunun 11. maddesi kapsamında bize başvurarak:</p>
        <List items={[
          "Kişisel verilerinizin işlenip işlenmediğini öğrenebilir, işlenmişse bilgi isteyebilirsiniz.",
          "İşleme amacını ve amaca uygun kullanılıp kullanılmadığını öğrenebilirsiniz.",
          "Yurt içinde veya yurt dışında aktarıldığı üçüncü kişileri bilebilirsiniz.",
          "Eksik veya yanlış işlenmişse düzeltilmesini isteyebilirsiniz.",
          "Kanundaki şartlar çerçevesinde silinmesini veya yok edilmesini isteyebilirsiniz.",
          "Düzeltme, silme veya yok etme işlemlerinin aktarıldığı üçüncü kişilere bildirilmesini isteyebilirsiniz.",
          "Münhasıran otomatik sistemlerle analiz sonucunda aleyhinize bir sonuç doğmasına itiraz edebilirsiniz.",
          "Kanuna aykırı işleme nedeniyle zarara uğrarsanız zararın giderilmesini talep edebilirsiniz.",
        ]} />
        <p>
          Başvurunuzu adınız soyadınız, T.C. kimlik numaranız (yabancılar için uyruk ve pasaport/kimlik numarası), tebligat adresiniz, varsa
          e-posta ve telefonunuz ile talebinizi içeren, imzalı bir dilekçeyle {blank(c.address, "AÇIK POSTA ADRESİ")} adresine elden ya da posta ile,
          {c.kep.trim() ? ` ${c.kep} KEP adresine,` : ""} veya sistemimizde kayıtlı e-posta adresinizden {blank(c.email, "KVKK BAŞVURU E-POSTA ADRESİ")} adresine
          iletebilirsiniz. Başvurular talebin niteliğine göre en kısa sürede ve en geç otuz gün içinde ücretsiz sonuçlandırılır.
        </p>
      </Section>

      <Section title="Kampanya izni ve cihaz konumu">
        <p>
          Kampanya iletileri için verdiğiniz izni dilediğiniz zaman “Hesabım” sayfasından ya da bizi arayarak ücretsiz geri çekebilirsiniz.
          Cihaz konumu yalnızca “Konumumu kullan” düğmesine bastığınızda, bir kez alınır; vermek zorunda değilsiniz.
        </p>
      </Section>
    </main>
  );
}
