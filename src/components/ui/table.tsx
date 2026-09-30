import Link from "next/link";
import type { ReactNode } from "react";
import { cn } from "@/lib/cn";

export interface Column<T> {
  key: string;
  label: string;
  render: (row: T) => ReactNode;
  align?: "left" | "right" | "center";
  className?: string;
  hideOnMobile?: boolean;
}

/** Masaüstünde tablo; mobilde her satırı kart olarak gösterir. */
export function DataTable<T>({ rows, columns, rowKey, onRowClick, empty, mobileTitle }: {
  rows: T[];
  columns: Column<T>[];
  rowKey: (r: T) => string;
  onRowClick?: (r: T) => string | undefined;
  empty?: ReactNode;
  mobileTitle?: (r: T) => ReactNode;
}) {
  if (rows.length === 0) return <div className="rounded-2xl border border-dashed border-border p-8 text-center text-muted">{empty ?? "Kayıt yok"}</div>;
  return (
    <>
      <div className="hidden overflow-x-auto rounded-2xl border border-border bg-surface md:block">
        <table className="w-full text-sm">
          <thead className="bg-surface-2 text-left text-xs text-muted">
            <tr>
              {columns.map((c) => (
                <th key={c.key} className={cn("px-3 py-2 font-medium", c.align === "right" && "text-right", c.align === "center" && "text-center")}>
                  {c.label}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {rows.map((r) => {
              const href = onRowClick?.(r);
              return (
                <tr key={rowKey(r)} className={cn(href && "cursor-pointer hover:bg-surface-2")}>
                  {columns.map((c) => (
                    <td key={c.key} className={cn("px-3 py-2", c.align === "right" && "num text-right", c.align === "center" && "text-center", c.className)}>
                      {href ? <Link href={href} className="block">{c.render(r)}</Link> : c.render(r)}
                    </td>
                  ))}
                </tr>
              );
            })}
          </tbody>
        </table>
      </div>
      <ul className="space-y-2 md:hidden">
        {rows.map((r) => {
          const href = onRowClick?.(r);
          const body = (
            <div className="rounded-2xl border border-border bg-surface p-3">
              {mobileTitle ? <div className="mb-1 font-medium">{mobileTitle(r)}</div> : null}
              <dl className="grid grid-cols-2 gap-x-3 gap-y-1 text-sm">
                {columns
                  .filter((c) => !c.hideOnMobile)
                  .map((c) => (
                    <div key={c.key} className="contents">
                      <dt className="text-muted">{c.label}</dt>
                      <dd className={cn("text-right", c.align === "right" && "num")}>{c.render(r)}</dd>
                    </div>
                  ))}
              </dl>
            </div>
          );
          return <li key={rowKey(r)}>{href ? <Link href={href}>{body}</Link> : body}</li>;
        })}
      </ul>
    </>
  );
}
