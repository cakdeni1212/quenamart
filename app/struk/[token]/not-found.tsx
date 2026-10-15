import styles from "./receipt.module.css";

export default function DigitalReceiptNotFound() {
  return <main className={styles.shell}><section className={styles.notFound}>
    <strong>QUENA MART</strong><h1>Struk tidak ditemukan atau tautan sudah tidak berlaku.</h1>
    <p>Periksa kembali tautan struk yang diberikan kepada Anda.</p>
  </section></main>;
}
