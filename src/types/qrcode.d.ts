declare module "qrcode" {
  type Options = { errorCorrectionLevel?: "L" | "M" | "Q" | "H"; margin?: number; width?: number; color?: { dark?: string; light?: string } };
  function toDataURL(value: string, options?: Options): Promise<string>;
  const QRCode: { toDataURL: typeof toDataURL };
  export default QRCode;
}
