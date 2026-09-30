"use client";
import { useState } from "react";
import { Download } from "lucide-react";
import { Button } from "@/components/ui/button";
import { downloadCsv, downloadXlsx, type ExportRow } from "@/lib/excel/write";
import { todayISO } from "@/lib/format";

export function ExportButton({ rows, filename }: { rows: ExportRow[]; filename: string }) {
  const [open, setOpen] = useState(false);
  const name = `${filename}_${todayISO()}`;
  return (
    <div className="no-print relative">
      <Button variant="secondary" onClick={() => setOpen((o) => !o)} disabled={rows.length === 0}>
        <Download className="h-4 w-4" /> Dışa aktar
      </Button>
      {open ? (
        <div className="absolute right-0 z-20 mt-1 w-40 rounded-xl border border-border bg-surface p-1 shadow-lg">
          <button className="block w-full rounded-lg px-3 py-2 text-left hover:bg-surface-2" onClick={() => { setOpen(false); void downloadXlsx(rows, name); }}>Excel (.xlsx)</button>
          <button className="block w-full rounded-lg px-3 py-2 text-left hover:bg-surface-2" onClick={() => { setOpen(false); downloadCsv(rows, name); }}>CSV</button>
        </div>
      ) : null}
    </div>
  );
}
