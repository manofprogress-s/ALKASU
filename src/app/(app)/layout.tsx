import { AppShell } from "@/components/shell/app-shell";
import { ContextProvider } from "@/components/shell/context";
import { OfflineSync } from "@/components/offline/offline-sync";
import { redirect } from "next/navigation";
import { getContext } from "@/lib/session";

export const dynamic = "force-dynamic";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const ctx = await getContext();
  if (ctx.mustChangePassword) redirect("/sifre?zorunlu=1"); // R-08
  return (
    <ContextProvider value={ctx}>
      <AppShell role={ctx.role} name={ctx.displayName} title={ctx.title} business={ctx.businessName}>
        {children}
      </AppShell>
      <OfflineSync />
    </ContextProvider>
  );
}
