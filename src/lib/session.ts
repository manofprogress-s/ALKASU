import "server-only";
import { cache } from "react";
import { redirect } from "next/navigation";
import { supabaseServer } from "@/lib/supabase/server";
import type { Permission, Role } from "@/lib/roles";
import { can } from "@/lib/roles";

export interface AppContext {
  userId: string;
  email: string | null;
  businessId: string;
  businessName: string;
  locationId: string;
  membershipId: string;
  role: Role;
  displayName: string;
}

interface ContextRow {
  business_id: string;
  business_name: string;
  location_id: string;
  membership_id: string;
  role: Role;
  display_name: string;
}

/** Oturumdaki kullanıcının işletme bağlamı. Oturum yoksa girişe, üyelik yoksa uyarı sayfasına yönlendirir. */
export const getContext = cache(async (): Promise<AppContext> => {
  const supabase = await supabaseServer();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) redirect("/giris");
  const { data, error } = await supabase.rpc("my_context");
  if (error) throw error;
  const rows = (data ?? []) as ContextRow[];
  const row = rows[0];
  if (!row) redirect("/uyelik-yok");
  return {
    userId: user.id,
    email: user.email ?? null,
    businessId: row.business_id,
    businessName: row.business_name,
    locationId: row.location_id,
    membershipId: row.membership_id,
    role: row.role,
    displayName: row.display_name,
  };
});

/** Sayfa yetkisi: yoksa ana sayfaya döner. */
export async function requirePermission(p: Permission): Promise<AppContext> {
  const ctx = await getContext();
  if (!can(ctx.role, p)) redirect("/?yetki=yok");
  return ctx;
}
