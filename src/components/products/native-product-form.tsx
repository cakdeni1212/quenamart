"use client";

import { useActionState, useState } from "react";
import { useFormStatus } from "react-dom";
import Link from "next/link";
import { createNativeProduct, type NativeProductFormState } from "@/app/actions/native-product";
import { RupiahInput } from "@/components/ui/rupiah-input";
import { compareRupiah } from "@/lib/money";

function SaveButton() {
  const { pending } = useFormStatus();
  return <button className="native-product-save" type="submit" disabled={pending}>
    {pending ? "Menyimpan…" : "Simpan Produk"}
  </button>;
}

export function NativeProductForm({
  requestId,
  categories,
  units,
  brands,
}: {
  requestId: string;
  categories: string[];
  units: string[];
  brands: string[];
}) {
  const [state, action] = useActionState(createNativeProduct, {} as NativeProductFormState);
  const [automaticSku, setAutomaticSku] = useState(false);
  const [hpp, setHpp] = useState(state.values?.hpp ?? "");
  const [sellingPrice, setSellingPrice] = useState(state.values?.sellingPrice ?? "");
  return <form className="native-product-form" action={action}>
    <input type="hidden" name="requestId" value={requestId} />
    <section className="native-product-section">
      <h2>Informasi Produk</h2>
      <div className="native-product-grid">
        <label className="native-product-field native-product-wide">Nama Produk <span>*</span>
          <input name="name" required maxLength={200} defaultValue={state.values?.name} autoComplete="off" placeholder="Contoh: Beras Pandan Wangi 5 kg" />
        </label>
        <label className="native-product-field">Kode SKU <span>*</span>
          <input name="sku" required={!automaticSku} disabled={automaticSku} maxLength={100} defaultValue={state.values?.sku} autoComplete="off" placeholder="Contoh: BR-001" />
          <span className="native-product-auto"><input type="checkbox" name="autoSku" checked={automaticSku} onChange={(event) => setAutomaticSku(event.target.checked)} /> Buat otomatis</span>
        </label>
        <label className="native-product-field">Kategori <span>*</span>
          <input name="category" required maxLength={120} list="native-product-categories" defaultValue={state.values?.category} placeholder="Pilih atau ketik kategori" />
          <datalist id="native-product-categories">{categories.map((value) => <option key={value} value={value} />)}</datalist>
        </label>
        <label className="native-product-field">Satuan <span>*</span>
          <input name="unit" required maxLength={40} list="native-product-units" defaultValue={state.values?.unit} placeholder="Contoh: pcs, botol, kg" />
          <datalist id="native-product-units">{units.map((value) => <option key={value} value={value} />)}</datalist>
        </label>
        <label className="native-product-field">Merek
          <input name="brand" maxLength={120} list="native-product-brands" defaultValue={state.values?.brand} placeholder="Opsional" />
          <datalist id="native-product-brands">{brands.map((value) => <option key={value} value={value} />)}</datalist>
        </label>
        <label className="native-product-field">Rak
          <input name="rack" maxLength={120} defaultValue={state.values?.rack} placeholder="Opsional" />
        </label>
      </div>
    </section>

    <section className="native-product-section">
      <h2>Penjualan dan HPP</h2>
      <div className="native-product-grid">
        <label className="native-product-field">Barcode
          <input name="barcode" maxLength={128} inputMode="numeric" defaultValue={state.values?.barcode} autoComplete="off" placeholder="Opsional — dapat dipindai" onKeyDown={(event) => { if (event.key === "Enter") event.preventDefault(); }} />
        </label>
        <label className="native-product-field">HPP / Harga Pokok <span>*</span>
          <RupiahInput name="hpp" required value={hpp} onValueChange={setHpp} placeholder="0" aria-label="HPP harga pokok Rupiah" />
          <small>HPP referensi produk; nilai persediaan ditentukan saat barang masuk.</small>
        </label>
        <label className="native-product-field">Harga Jual <span>*</span>
          <RupiahInput name="sellingPrice" required value={sellingPrice} onValueChange={setSellingPrice} placeholder="0" aria-label="Harga jual Rupiah" />
          <small>Harga disimpan untuk outlet aktif dan tercatat di riwayat harga.</small>
        </label>
      </div>
      {compareRupiah(sellingPrice, hpp) === -1 && <p className="native-product-price-warning" role="status">Harga jual lebih rendah dari HPP.</p>}
    </section>

    <div className="native-product-stock-note"><strong>Stok produk baru</strong><span>Stok awal produk baru adalah 0. Tambahkan stok melalui Barang Masuk.</span></div>
    {state.error && <p className="native-product-error" role="alert">{state.error}</p>}
    <div className="native-product-actions"><Link className="quiet-button" href="/produk">Batal</Link><SaveButton /></div>
  </form>;
}
