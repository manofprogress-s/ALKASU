import { cn } from "@/lib/cn";

/** Yükleniyor iskeleti: sayfa verisi gelene kadar anında görünen yer tutucular (hız adımı 3) */
export function Bone({ className }: { className?: string }) {
  return <div aria-hidden="true" className={cn("animate-pulse rounded-lg bg-surface-2", className)} />;
}

function Header({ action = true }: { action?: boolean }) {
  return (
    <div className="mb-4 flex items-end justify-between gap-3">
      <div className="space-y-2">
        <Bone className="h-7 w-44" />
        <Bone className="h-4 w-28" />
      </div>
      {action ? <Bone className="h-11 w-32 rounded-xl" /> : null}
    </div>
  );
}

/** Liste sayfaları: başlık + filtre çipleri + satırlar */
export function ListSkeleton({ rows = 8 }: { rows?: number }) {
  return (
    <div role="status" aria-label="Yükleniyor">
      <Header />
      <div className="mb-3 flex gap-2">
        {[0, 1, 2].map((i) => <Bone key={i} className="h-9 w-24 rounded-full" />)}
      </div>
      <div className="divide-y divide-border rounded-2xl border border-border bg-surface">
        {Array.from({ length: rows }, (_, i) => (
          <div key={i} className="flex items-center justify-between gap-3 p-3">
            <div className="flex-1 space-y-2">
              <Bone className="h-4 w-2/5" />
              <Bone className="h-3 w-3/5" />
            </div>
            <Bone className="h-5 w-16" />
          </div>
        ))}
      </div>
    </div>
  );
}

/** Pano / ayrıntı sayfaları: başlık + kutucuklar + kartlar */
export function DashboardSkeleton() {
  return (
    <div role="status" aria-label="Yükleniyor" className="space-y-4">
      <Header action={false} />
      <div className="grid grid-cols-2 gap-3 md:grid-cols-4">
        {[0, 1, 2, 3].map((i) => (
          <div key={i} className="space-y-2 rounded-2xl border border-border bg-surface p-4">
            <Bone className="h-3 w-20" />
            <Bone className="h-6 w-24" />
          </div>
        ))}
      </div>
      {[0, 1].map((i) => (
        <div key={i} className="space-y-3 rounded-2xl border border-border bg-surface p-4">
          <Bone className="h-5 w-36" />
          <Bone className="h-4 w-full" />
          <Bone className="h-4 w-4/5" />
          <Bone className="h-4 w-3/5" />
        </div>
      ))}
    </div>
  );
}

/** Ürün ızgarası (satış ekranı, mağaza) */
export function GridSkeleton({ items = 12 }: { items?: number }) {
  return (
    <div role="status" aria-label="Yükleniyor" className="space-y-3">
      <Bone className="h-11 w-full rounded-xl" />
      <div className="grid grid-cols-2 gap-2.5 sm:grid-cols-3 lg:grid-cols-4">
        {Array.from({ length: items }, (_, i) => (
          <div key={i} className="space-y-2 rounded-2xl border border-border bg-surface p-3">
            <Bone className="mx-auto h-20 w-16" />
            <Bone className="h-4 w-3/4" />
            <Bone className="h-4 w-1/2" />
          </div>
        ))}
      </div>
    </div>
  );
}

/** Form sayfaları */
export function FormSkeleton() {
  return (
    <div role="status" aria-label="Yükleniyor" className="space-y-4">
      <Header action={false} />
      <div className="grid gap-3 rounded-2xl border border-border bg-surface p-4 md:grid-cols-2">
        {Array.from({ length: 6 }, (_, i) => (
          <div key={i} className="space-y-2">
            <Bone className="h-3 w-24" />
            <Bone className="h-11 w-full rounded-xl" />
          </div>
        ))}
      </div>
    </div>
  );
}
