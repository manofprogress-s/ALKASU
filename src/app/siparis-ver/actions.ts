"use server";
import { headers } from "next/headers";
import { z } from "zod";
import { redactSecrets, serviceRoleKey, supabaseAdmin, supabaseServer } from "@/lib/supabase/server";
import { normalizePhone, phoneEmail } from "@/lib/username";
import { todayISO, addDaysISO } from "@/lib/format";
import { KVKK_VERSION } from "@/lib/kvkk";

type Result = { ok: true; orderNo: number | null; warning?: string } | { ok: false; message: string; exists?: boolean };

const Schema = z.object({
  name: z.string().trim().min(3, "Ad soyad yazın").max(80),
  phone: z.string().trim().transform((v, ctx) => {
    const p = normalizePhone(v);
    if (!p) ctx.addIssue({ code: "custom", message: "Cep telefonunuzu 05xx xxx xx xx biçiminde yazın" });
    return p ?? "";
  }),
  password: z.string().min(8, "Şifre en az 8 karakter olmalı").max(72),
  address: z.string().trim().min(10, "Açık adresinizi yazın (mahalle, sokak, no, daire)").max(500),
  lat: z.number().min(-90).max(90).nullable(),
  lng: z.number().min(-180).max(180).nullable(),
  note: z.string().trim().max(300).default(""),
  day: z.enum(["bugun", "yarin"]),
  marketing: z.boolean().default(false), // isteğe bağlı kampanya izni (K-03)
  website: z.string().max(0).optional(), // bot tuzağı: gerçek kullanıcı boş bırakır
  items: z
    .array(z.object({ productId: z.string().uuid(), unitId: z.string().uuid(), qty: z.number().int().min(1).max(1000) }))
    .min(1, "En az bir ürün seçin")
    .max(30),
});


/** Yeni müşteri: kayıt + giriş + ilk sipariş (onay bekler). Tek adımda, yarım kayıt bırakmadan. */
export async function registerAndOrder(input: unknown): Promise<Result> {
  const parsed = Schema.safeParse(input);
  if (!parsed.success) {
    const issue = parsed.error.issues[0];
    if (issue?.path[0] === "website") return { ok: true, orderNo: null }; // botu oyalama
    return { ok: false, message: issue?.message ?? "Bilgileri kontrol edin" };
  }
  const v = parsed.data;
  if (!serviceRoleKey()) return { ok: false, message: "Şu an kayıt alınamıyor. Lütfen bizi telefonla arayın." };
  const h = await headers();
  // Vercel x-real-ip başlığını kendisi yazar (istemci değiştiremez); yoksa x-forwarded-for'un ilk değeri
  const ip = h.get("x-real-ip")?.trim() || (h.get("x-forwarded-for") ?? "").split(",")[0]?.trim() || "?";
  const admin = supabaseAdmin();
  let userId: string | null = null;
  let registered = false;

  try {
    // Hız sınırı: kontrol ve kayıt veritabanında tek adımda (eşzamanlı isteklerle aşılamaz)
    const attempt = await admin.rpc("signup_attempt", { p_ip: ip, p_phone: v.phone });
    if (attempt.error) throw attempt.error;
    if (attempt.data === null) {
      return { ok: false, message: "Çok fazla deneme yapıldı. Lütfen biraz sonra tekrar deneyin veya bizi arayın." };
    }
    const attemptId = attempt.data as number;

    const email = phoneEmail(v.phone);
    const created = await admin.auth.admin.createUser({
      email,
      password: v.password,
      email_confirm: true,
      user_metadata: { display_name: v.name, phone: v.phone },
    });
    if (!created.data?.user) {
      if (created.error && /already|registered|exists/i.test(created.error.message)) {
        return { ok: false, exists: true, message: "Bu telefon numarasıyla kaydınız var. 'Kayıtlıyım, giriş yap' ile girip siparişinizi oradan verin." };
      }
      return { ok: false, message: "Kayıt oluşturulamadı. Lütfen tekrar deneyin." };
    }
    userId = created.data.user.id;
    const reg = await admin.rpc("register_customer", {
      p_user: userId, p_name: v.name, p_phone: v.phone, p_address: v.address, p_lat: v.lat, p_lng: v.lng,
      p_notice_version: KVKK_VERSION, p_marketing: v.marketing,
    });
    if (reg.error) {
      await admin.auth.admin.deleteUser(userId); // yarım kayıt bırakma
      userId = null;
      const known = /Telefon|adres|Ad soyad|Konum/i.test(reg.error.message);
      return { ok: false, message: known ? reg.error.message : "Kayıt oluşturulamadı. Lütfen tekrar deneyin veya bizi arayın." };
    }
    registered = true;

    // Müşteri olarak oturum aç ve siparişi kendi yetkisiyle kaydet (fiyatlar sunucuda belirlenir)
    const supabase = await supabaseServer();
    const signIn = await supabase.auth.signInWithPassword({ email, password: v.password });
    if (signIn.error) return { ok: true, orderNo: null, warning: "Kaydınız oluşturuldu; giriş yapıp siparişinizi verin." };
    const { data: ctx } = await supabase.rpc("my_context");
    const businessId = (ctx as { business_id: string }[] | null)?.[0]?.business_id;
    const today = todayISO();
    const order = await supabase.rpc("save_order", {
      p_business: businessId,
      p: {
        id: crypto.randomUUID(),
        delivery_date: v.day === "yarin" ? addDaysISO(today, 1) : today,
        address: v.address,
        note: v.note || null,
        items: v.items.map((i) => ({ product_id: i.productId, unit_id: i.unitId, qty: i.qty })),
      },
    });
    await admin.from("signup_attempts").update({ ok: true }).eq("id", attemptId);
    if (order.error) {
      console.error("Online ilk sipariş hatası:", redactSecrets(order.error.message));
      return { ok: true, orderNo: null, warning: "Kaydınız oluşturuldu ancak sipariş kaydedilemedi. Lütfen “Yeni sipariş” ile tekrar deneyin." };
    }
    return { ok: true, orderNo: (order.data as { no: number }).no };
  } catch (e) {
    console.error("Online kayıt hatası:", redactSecrets(e instanceof Error ? e.message : String(e)));
    if (userId && !registered) await admin.auth.admin.deleteUser(userId).catch(() => undefined); // telefon kilitli kalmasın
    return { ok: false, message: "Bir sorun oluştu. Lütfen tekrar deneyin veya bizi arayın." };
  }
}
