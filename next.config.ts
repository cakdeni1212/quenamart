import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  experimental: {
    // Hostinger shared hosting can report host CPU count rather than its quota.
    // Keep build-time worker/process and static-render concurrency bounded.
    cpus: 2,
    staticGenerationMaxConcurrency: 2,
    serverActions: {
      // The app accepts files up to 25 MiB; leave room for multipart framing.
      bodySizeLimit: "26mb",
    },
  },
  async headers() {
    return [{
      source: "/struk/:path*",
      headers: [
        { key: "Cache-Control", value: "private, no-store, max-age=0, must-revalidate" },
        { key: "Referrer-Policy", value: "no-referrer" },
        { key: "X-Robots-Tag", value: "noindex, nofollow, noarchive" },
      ],
    }];
  },
};

export default nextConfig;
