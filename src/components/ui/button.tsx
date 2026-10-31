import Link from "next/link";
import type { ButtonHTMLAttributes, ReactNode } from "react";
import styles from "./button.module.css";

export type ButtonVariant = "primary" | "secondary" | "outline" | "destructive" | "ghost" | "icon";

const variantClass: Record<ButtonVariant, string> = {
  primary: styles.primary,
  secondary: styles.secondary,
  outline: styles.outline,
  destructive: styles.destructive,
  ghost: styles.ghost,
  icon: styles.icon,
};

export function Button({ variant = "primary", className, children, ...props }: ButtonHTMLAttributes<HTMLButtonElement> & { variant?: ButtonVariant }) {
  return <button {...props} className={[variantClass[variant], className].filter(Boolean).join(" ")}>{children}</button>;
}

export function ButtonLink({ href, variant = "primary", className, children, ...props }: {
  href: string;
  variant?: ButtonVariant;
  className?: string;
  children: ReactNode;
} & Omit<React.ComponentProps<typeof Link>, "href" | "className" | "children">) {
  return <Link {...props} href={href} className={[variantClass[variant], className].filter(Boolean).join(" ")}>{children}</Link>;
}
