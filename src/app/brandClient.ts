import { useCallback, useEffect, useState } from 'react';
import { parseBrandSettings } from '@/brandApi';
import { applyDocumentBrand, loadBrandSettings } from '@/app/storage';
import type { BrandSettings } from '@/app/types';

export async function fetchInstalledBrand(): Promise<BrandSettings | null> {
  try {
    const response = await fetch('/api/brand', { cache: 'no-store' });
    if (!response.ok) return null;
    const body: unknown = await response.json();
    return parseBrandSettings(body);
  } catch {
    return null;
  }
}

export async function saveInstalledBrand(
  brand: BrandSettings,
  password: string,
): Promise<BrandSettings> {
  const response = await fetch('/api/brand', {
    method: 'PUT',
    cache: 'no-store',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${password}`,
    },
    body: JSON.stringify(brand),
  });
  const text = await response.text();
  if (!response.ok) throw new Error(text || 'Could not save branding.');
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    throw new Error('The server returned invalid branding.');
  }
  const saved = parseBrandSettings(body);
  if (!saved) throw new Error('The server returned invalid branding.');
  return saved;
}

function writeCachedBrand(brand: BrandSettings): void {
  try {
    localStorage.setItem('pockethernet.brand', JSON.stringify(brand));
  } catch {
    // The server copy remains the brand visitors see.
  }
}

export function useServerBrand(): {
  brand: BrandSettings;
  setBrand: (brand: BrandSettings) => void;
} {
  const [brand, setBrandState] = useState(loadBrandSettings);
  const setBrand = useCallback((next: BrandSettings) => {
    writeCachedBrand(next);
    setBrandState(next);
  }, []);

  useEffect(() => {
    applyDocumentBrand(brand);
  }, [brand]);

  useEffect(() => {
    let active = true;
    void fetchInstalledBrand().then((next) => {
      if (active && next) setBrand(next);
    });
    return () => {
      active = false;
    };
  }, [setBrand]);

  return { brand, setBrand };
}
