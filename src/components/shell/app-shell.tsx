"use client";
import Link from "next/link";
import { usePathname } from "next/navigation";
import { useState, type ReactNode } from "react";
import {
  BarChart3, Boxes, Home, LogOut, Menu, Receipt, Settings, ShoppingCart, Tag, Truck, Users, Wallet, X, type LucideIcon,
} from "lucide-react";
import { cn } from "@/lib/cn";
import { can, ROLE_LABELS, type Role } from "@/lib/roles";
import { NAV } from "./nav";
import { supabaseBrowser } from "@/lib/supabase/client";
import { OfflineBadge } from "@/components/offline/offline-badge";

const ICONS: Record<string, LucideIcon> = {
  home: Home, cart: ShoppingCart, receipt: Receipt, boxes: Boxes, users: Users, truck: Truck, tag: Tag,
  wallet: Wallet, chart: BarChart3, settings: Settings,
};

export function AppShell({ role, name, business, children }: { role: Role; name: string; business: string; children: ReactNode }) {
  const path = usePathname();
  const [menu, setMenu] = useState(false);
  const items = NAV.filter((n) => !n.perm || can(role, n.perm));
  const mobileItems = items.filter((n) => n.mobile).slice(0, 4);
  const active = (href: string) => (href === "/" ? path === "/" : path === href || path.startsWith(`${href}/`));

  async function logout() {
    const { countPending } = await import("@/lib/offline/queue");
    const pending = await countPending();
    if (pending > 0 && !confirm(`Gönderilmemiş ${pending} satış var. Çıkış yaparsanız bu cihazda kalır ve tekrar girişte gönderilir. Devam edilsin mi?`)) return;
    await supabaseBrowser().auth.signOut();
    // Paylaşılan cihazda önceki kullanıcının sayfaları çevrimdışı görünmesin
    if ("caches" in window) for (const k of await caches.keys()) await caches.delete(k);
    window.location.href = "/giris";
  }

  const navList = (
    <nav className="flex flex-col gap-1">
      {items.map((n) => {
        const Icon = ICONS[n.icon] ?? Home;
        return (
          <Link
            key={n.href}
            href={n.href}
            onClick={() => setMenu(false)}
            className={cn(
              "flex items-center gap-3 rounded-xl px-3 py-2.5 text-[15px]",
              active(n.href) ? "bg-brand-soft font-semibold text-brand" : "text-text hover:bg-surface-2",
            )}
          >
            <Icon className="h-5 w-5" />
            {n.label}
          </Link>
        );
      })}
    </nav>
  );

  const userBox = (
    <div className="border-t border-border pt-3">
      <div className="px-3 text-sm font-medium">{name}</div>
      <div className="px-3 text-xs text-muted">{ROLE_LABELS[role]}</div>
      <button onClick={logout} className="mt-2 flex w-full items-center gap-3 rounded-xl px-3 py-2.5 text-sm text-muted hover:bg-surface-2">
        <LogOut className="h-4 w-4" /> Çıkış yap
      </button>
    </div>
  );

  return (
    <div className="min-h-dvh md:flex">
      {/* Masaüstü yan menü */}
      <aside className="no-print sticky top-0 hidden h-dvh w-60 shrink-0 flex-col justify-between border-r border-border bg-surface p-3 md:flex">
        <div>
          <div className="mb-4 px-3 pt-1">
            <div className="text-lg font-bold tracking-tight text-brand">ALKASU</div>
            <div className="truncate text-xs text-muted">{business}</div>
          </div>
          {navList}
        </div>
        {userBox}
      </aside>

      <div className="flex min-w-0 flex-1 flex-col">
        {/* Mobil üst çubuk */}
        <header className="no-print sticky top-0 z-30 flex h-12 items-center justify-between border-b border-border bg-surface/95 px-3 backdrop-blur md:hidden">
          <span className="font-bold text-brand">ALKASU</span>
          <OfflineBadge />
        </header>
        <div className="no-print hidden justify-end px-6 pt-3 md:flex">
          <OfflineBadge />
        </div>
        <main className="mx-auto w-full max-w-6xl flex-1 px-3 pt-3 pb-24 md:px-6 md:pb-8">{children}</main>
      </div>

      {/* Mobil alt gezinme */}
      <nav className="no-print safe-bottom fixed inset-x-0 bottom-0 z-40 grid grid-cols-5 border-t border-border bg-surface md:hidden">
        {mobileItems.map((n) => {
          const Icon = ICONS[n.icon] ?? Home;
          return (
            <Link key={n.href} href={n.href} className={cn("flex flex-col items-center gap-0.5 py-2 text-[11px]", active(n.href) ? "text-brand" : "text-muted")}>
              <Icon className="h-6 w-6" />
              {n.label}
            </Link>
          );
        })}
        <button onClick={() => setMenu(true)} className="flex flex-col items-center gap-0.5 py-2 text-[11px] text-muted">
          <Menu className="h-6 w-6" />
          Menü
        </button>
      </nav>

      {menu ? (
        <div className="fixed inset-0 z-50 md:hidden" role="dialog" aria-modal="true">
          <div className="absolute inset-0 bg-black/40" onClick={() => setMenu(false)} />
          <div className="safe-bottom absolute inset-x-0 bottom-0 max-h-[85dvh] overflow-y-auto rounded-t-3xl bg-surface p-3">
            <div className="mb-2 flex items-center justify-between px-3">
              <div>
                <div className="font-semibold">{business}</div>
              </div>
              <button onClick={() => setMenu(false)} aria-label="Kapat" className="rounded-full p-2 hover:bg-surface-2">
                <X className="h-5 w-5" />
              </button>
            </div>
            {navList}
            <div className="mt-3">{userBox}</div>
          </div>
        </div>
      ) : null}
    </div>
  );
}
