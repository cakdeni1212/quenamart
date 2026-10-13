import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  experimental: {
    serverActions: {
      // The app accepts files up to 25 MiB; leave room for multipart framing.
      bodySizeLimit: "26mb",
    },
  },
};

export default nextConfig;
