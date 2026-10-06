// Excel (.xlsx) ve CSV dışa aktarma (T-013): CSV UTF-8 BOM + ";" ayırıcı (Türkçe Excel uyumlu).
export type ExportRow = Record<string, string | number | null | undefined>;

export function toCsv(rows: ExportRow[]): string {
  if (rows.length === 0) return "﻿";
  const headers = Object.keys(rows[0]!);
  const esc = (v: unknown) => {
    if (v === null || v === undefined) return "";
    let s = typeof v === "number" ? String(v).replace(".", ",") : String(v);
    // Excel formül enjeksiyonuna karşı: =, +, -, @ ile başlayan metinler formül olarak çalışmasın
    if (typeof v !== "number" && /^[=+\-@\t\r]/.test(s)) s = `'${s}`;
    return /[;"\n\r]/.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
  };
  return "﻿" + [headers.join(";"), ...rows.map((r) => headers.map((h) => esc(r[h])).join(";"))].join("\r\n");
}

function download(blob: Blob, name: string) {
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 5000);
}

export function downloadCsv(rows: ExportRow[], filename: string) {
  download(new Blob([toCsv(rows)], { type: "text/csv;charset=utf-8" }), `${filename}.csv`);
}

export async function downloadXlsx(rows: ExportRow[], filename: string, sheet = "Rapor") {
  const ExcelJS = await import("exceljs");
  const wb = new ExcelJS.Workbook();
  wb.creator = "ALKASU";
  const ws = wb.addWorksheet(sheet.slice(0, 31));
  const headers = rows.length ? Object.keys(rows[0]!) : [];
  ws.columns = headers.map((h) => ({
    header: h,
    key: h,
    width: Math.min(40, Math.max(10, h.length + 2, ...rows.slice(0, 200).map((r) => String(r[h] ?? "").length + 2))),
  }));
  rows.forEach((r) => ws.addRow(r));
  ws.getRow(1).font = { bold: true };
  ws.views = [{ state: "frozen", ySplit: 1 }];
  headers.forEach((h, i) => {
    if (rows.some((r) => typeof r[h] === "number" && !Number.isInteger(r[h]))) ws.getColumn(i + 1).numFmt = "#,##0.00";
  });
  const buf = await wb.xlsx.writeBuffer();
  download(new Blob([buf as ArrayBuffer], { type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" }), `${filename}.xlsx`);
}
