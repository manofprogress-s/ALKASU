import Link from "next/link";
import { requirePermission } from "@/lib/session";
import { supabaseServer } from "@/lib/supabase/server";
import { PageHeader } from "@/components/ui/card";
import { UsersPanel } from "@/components/settings/users-panel";
import { SettingsPanel } from "@/components/settings/settings-panel";

export const metadata = { title: "Ayarlar" };

export default async function SettingsPage() {
  const ctx = await requirePermission("users");
  const supabase = await supabaseServer();
  const [{ data: members }, { data: settings }] = await Promise.all([
    supabase.from("memberships").select("id, user_id, role, display_name, active, created_at").eq("business_id", ctx.businessId).order("created_at"),
    supabase.from("app_settings").select("*").eq("business_id", ctx.businessId).maybeSingle(),
  ]);
  return (
    <div className="space-y-4">
      <PageHeader title="Ayarlar" actions={<Link href="/ayarlar/islem-gecmisi" className="inline-flex h-11 items-center rounded-xl border border-border bg-surface px-4">İşlem geçmişi</Link>} />
      <UsersPanel members={(members ?? []) as { id: string; user_id: string; role: string; display_name: string; active: boolean }[]} me={ctx.userId} />
      {settings ? <SettingsPanel initial={settings as Record<string, number>} /> : null}
    </div>
  );
}
