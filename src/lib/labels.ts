export const MOVEMENT_LABELS: Record<string, string> = {
  acilis: "Açılış", satis: "Satış", satis_iptal: "Satış iptali", iade: "İade", iade_fire: "İade (kusurlu)", mal_kabul: "Mal kabul",
  mal_kabul_duzeltme: "Mal kabul düzeltme", fire: "Fire", sayim_duzeltme: "Sayım düzeltmesi", bos_kap_giris: "Boş kap girişi",
  bos_kap_cikis: "Boş kap çıkışı", tedarikci_bos_iade: "Tedarikçiye boş iade", musteri_kap_kaybi: "Müşteri kap kaybı",
};
export const PAYMENT_LABELS: Record<string, string> = { nakit: "Nakit", pos: "POS", veresiye: "Veresiye" };
export const CASH_LABELS: Record<string, string> = {
  satis: "Nakit satış", satis_iptal: "Satış iptali", iade: "Nakit iade", tahsilat: "Veresiye tahsilatı", tahsilat_iptal: "Tahsilat iptali",
  depozito_iade: "Depozito iadesi", gider: "Gider", giris: "Kasaya giriş", cikis: "Kasadan çıkış", gun_sonu_teslim: "Gün sonu teslim", duzeltme: "Düzeltme",
};
