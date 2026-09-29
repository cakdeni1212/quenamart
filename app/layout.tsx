import type { Metadata } from "next";
import type { ReactNode } from "react";
import { Geist } from "next/font/google";
import "./globals.css";

const geist = Geist({ variable: "--font-geist-sans", subsets: ["latin"] });

export const metadata: Metadata = {
  title: "Quena Mart — Ruang Kerja",
  description: "Ruang kerja operasional Quena Mart.",
};

interface RootLayoutProps {
  children: ReactNode;
}

export default function RootLayout({ children }: RootLayoutProps) {
  return <html lang="id" className={`${geist.variable} h-full antialiased`}><body>{children}</body></html>;
}
