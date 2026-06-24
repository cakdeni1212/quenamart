"use client";

import { createContext, useContext, useState, useEffect, ReactNode } from "react";

interface User {
  id: string;
  name: string;
  email: string;
}

interface UserContextType {
  user: User | null;
  loading: boolean;
  setUser: (user: User | null) => void;
}

const UserContext = createContext<UserContextType>({
  user: null,
  loading: true,
  setUser: () => {},
});

export function useUser() {
  return useContext(UserContext);
}

export function UserProvider({
  children,
  initialUser,
}: {
  children: ReactNode;
  initialUser: User | null;
}) {
  const [user, setUser] = useState<User | null>(initialUser);
  const [loading, setLoading] = useState(!initialUser);

  useEffect(() => {
    if (!initialUser) {
      fetch("/api/me")
        .then((res) => {
          if (res.ok) return res.json();
          throw new Error("Not authenticated");
        })
        .then((data) => setUser(data.user))
        .catch(() => setUser(null))
        .finally(() => setLoading(false));
    } else {
      setLoading(false);
    }
  }, [initialUser]);

  return (
    <UserContext.Provider value={{ user, loading, setUser }}>
      {children}
    </UserContext.Provider>
  );
}
