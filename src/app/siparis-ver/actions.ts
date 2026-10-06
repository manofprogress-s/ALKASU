"use server";
import { headers } from "next/headers";
import { z } from "zod";
import { redactSecrets, serviceRoleKey, supabaseAdmin, supabaseServer } from "@/lib/supabase/server";
import { normalizePhone, phoneEmail } from "@/lib/username";
import { todayISO, addDaysISO } from "@/lib/format";

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
  consent: z.literal(true, { message: "Bilgilerinizin teslimat için kullanılmasını onaylayın" }),
  website: z.string().max(0).optional(), // bot tuzağı: gerçek kullanıcı boş bırakır
  items: z
    .array(z.object({ productId: z.string().uuid(), unitId: z.string().uuid(), qty: z.number().int().min(1).max(1000) }))
    .min(1, "En az bir ürün seçin")
    .max(30),
});

const LIMIT_IP_PER_HOUR = 5;
const LIMIT_PHONE_PER_DAY = 5;

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
  const ip = (h.get("x-forwarded-for") ?? "").split(",")[0]?.trim() || h.get("x-real-ip") || "?";
  const admin = supabaseAdmin();

  try {
    // Hız sınırı (kötüye kullanım ve kaba kuvvet denemelerine karşı)
    const hourAgo = new Date(Date.now() - 3600_000).toISOString();
    const dayAgo = new Date(Date.now() - 86_400_000).toISOString();
    const [byIp, byPhone] = await Promise.all([
      admin.from("signup_attempts").select("id", { count: "exact", head: true }).eq("ip", ip).gte("created_at", hourAgo),
      admin.from("signup_attempts").select("id", { count: "exact", head: true }).eq("phone", v.phone).gte("created_at", dayAgo),
    ]);
    if ((byIp.count ?? 0) >= LIMIT_IP_PER_HOUR || (byPhone.count ?? 0) >= LIMIT_PHONE_PER_DAY) {
      return { ok: false, message: "Çok fazla deneme yapıldı. Lütfen biraz sonra tekrar deneyin veya bizi arayın." };
    }
    const { data: attempt } = await admin.from("signup_attempts").insert({ ip, phone: v.phone }).select("id").single();

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
    const userId = created.data.user.id;
    const reg = await admin.rpc("register_customer", {
      p_user: userId, p_name: v.name, p_phone: v.phone, p_address: v.address, p_lat: v.lat, p_lng: v.lng,
    });
    if (reg.error) {
      await admin.auth.admin.deleteUser(userId); // yarım kayıt bırakma
      return { ok: false, message: redactSecrets(reg.error.message) };
    }

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
    if (attempt?.id) await admin.from("signup_attempts").update({ ok: true }).eq("id", attempt.id);
    if (order.error) {
      return { ok: true, orderNo: null, warning: `Kaydınız oluşturuldu ancak sipariş kaydedilemedi: ${order.error.message}` };
    }
    return { ok: true, orderNo: (order.data as { no: number }).no };
  } catch (e) {
    console.error("Online kayıt hatası:", redactSecrets(e instanceof Error ? e.message : String(e)));
    return { ok: false, message: "Bir sorun oluştu. Lütfen tekrar deneyin veya bizi arayın." };
  }
}
