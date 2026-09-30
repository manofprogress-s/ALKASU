"use server";
import { z } from "zod";
import { getContext } from "@/lib/session";
import { supabaseAdmin, supabaseServer } from "@/lib/supabase/server";
import { SITE_URL } from "@/lib/env";

const InviteSchema = z.object({
  email: z.string().trim().toLowerCase().email("Geçerli bir e-posta girin"),
  name: z.string().trim().min(2, "Ad en az 2 karakter olmalı"),
  role: z.enum(["yonetici", "satis", "depo", "izleyici"]),
});

/** Kullanıcı daveti (T-021): yalnızca yönetici; service_role anahtarı yalnızca burada, sunucuda kullanılır. */
export async function inviteUser(input: { email: string; name: string; role: string }): Promise<{ ok: boolean; message: string }> {
  const ctx = await getContext();
  if (ctx.role !== "yonetici") return { ok: false, message: "Bu işlem için yetkiniz yok" };
  const parsed = InviteSchema.safeParse(input);
  if (!parsed.success) return { ok: false, message: parsed.error.issues[0]?.message ?? "Geçersiz bilgi" };
  const { email, name, role } = parsed.data;
  const admin = supabaseAdmin();

  let userId: string | null = null;
  const inv = await admin.auth.admin.inviteUserByEmail(email, { redirectTo: `${SITE_URL}/auth/callback` });
  if (inv.data?.user) userId = inv.data.user.id;
  else if (inv.error && /already|registered|exists/i.test(inv.error.message)) {
    for (let page = 1; page <= 20 && !userId; page++) {
      const { data } = await admin.auth.admin.listUsers({ page, perPage: 200 });
      userId = data.users.find((u) => u.email?.toLowerCase() === email)?.id ?? null;
      if (data.users.length < 200) break;
    }
  } else if (inv.error) return { ok: false, message: inv.error.message };
  if (!userId) return { ok: false, message: "Kullanıcı oluşturulamadı" };

  // Üyeliği, yöneticinin kendi yetkisiyle ekle (veritabanı yetki kontrolü de yapar)
  const supabase = await supabaseServer();
  const { error } = await supabase.rpc("add_member", { p_business: ctx.businessId, p_user: userId, p_role: role, p_name: name });
  if (error) return { ok: false, message: error.message };
  return { ok: true, message: inv.data?.user ? "Davet e-postası gönderildi" : "Mevcut kullanıcı işletmeye eklendi" };
}
