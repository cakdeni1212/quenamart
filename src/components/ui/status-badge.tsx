import type { ReactNode } from "react";
import styles from "./status-badge.module.css";

export type StatusVariant = "success" | "warning" | "danger" | "neutral" | "info";

export function StatusBadge({ children, variant = "neutral", className }: {
  children: ReactNode;
  variant?: StatusVariant;
  className?: string;
}) {
  return <span className={[styles.badge, styles[variant], className].filter(Boolean).join(" ")}>{children}</span>;
}
