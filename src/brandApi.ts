import { DEFAULT_BRAND_SETTINGS } from './app/storage.ts';
import type { BrandSettings } from './app/types.ts';

const MAX_IMAGE_LENGTH = 2_000_000;
const PNG_DATA_URL = /^data:image\/png;base64,[A-Za-z0-9+/]+={0,2}$/;

export interface BrandStore {
  read(): Promise<string | null>;
  write(body: string): Promise<void>;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function validImage(value: string): boolean {
  return value === '' || (value.length <= MAX_IMAGE_LENGTH && PNG_DATA_URL.test(value));
}

export function parseBrandSettings(value: unknown): BrandSettings | null {
  if (!isRecord(value)) return null;
  const logoDataUrl = typeof value.logoDataUrl === 'string' ? value.logoDataUrl : '';
  const iconDataUrl = typeof value.iconDataUrl === 'string' ? value.iconDataUrl : '';
  if (!validImage(logoDataUrl) || !validImage(iconDataUrl)) return null;
  return {
    name: typeof value.name === 'string' ? value.name.slice(0, 80) : DEFAULT_BRAND_SETTINGS.name,
    logoDataUrl,
    logoName: typeof value.logoName === 'string' ? value.logoName.slice(0, 120) : '',
    iconDataUrl,
    iconName: typeof value.iconName === 'string' ? value.iconName.slice(0, 120) : '',
    footer: typeof value.footer === 'string' ? value.footer.slice(0, 500) : '',
  };
}

function storedBrand(raw: string | null): BrandSettings {
  if (!raw) return DEFAULT_BRAND_SETTINGS;
  try {
    const parsed: unknown = JSON.parse(raw);
    return parseBrandSettings(parsed) ?? DEFAULT_BRAND_SETTINGS;
  } catch {
    return DEFAULT_BRAND_SETTINGS;
  }
}

function text(message: string, status: number, allow = ''): Response {
  const headers = new Headers({
    'Cache-Control': 'no-store',
    'Content-Type': 'text/plain; charset=utf-8',
  });
  if (allow) headers.set('Allow', allow);
  return new Response(message, { status, headers });
}

function json(brand: BrandSettings, status = 200): Response {
  return new Response(JSON.stringify(brand), {
    status,
    headers: {
      'Cache-Control': 'no-store',
      'Content-Type': 'application/json; charset=utf-8',
    },
  });
}

async function passwordMatches(expected: string, provided: string): Promise<boolean> {
  if (!expected || !provided) return false;
  const digest = async (value: string): Promise<Uint8Array> =>
    new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)));
  const [left, right] = await Promise.all([digest(expected), digest(provided)]);
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference |= left[index] ^ right[index];
  return difference === 0;
}

export async function handleBrandRequest(
  request: Request,
  store: BrandStore,
  token: string | undefined,
): Promise<Response> {
  if (request.method === 'GET' || request.method === 'HEAD') {
    const brand = storedBrand(await store.read());
    return request.method === 'HEAD'
      ? new Response(null, { headers: json(brand).headers })
      : json(brand);
  }
  if (request.method !== 'PUT' && request.method !== 'POST') {
    return text('Method not allowed', 405, 'GET, POST, PUT');
  }
  if (!token)
    return text('Branding is locked until an admin password is configured on the server.', 403);
  const header = request.headers.get('Authorization') ?? '';
  const provided = header.startsWith('Bearer ') ? header.slice('Bearer '.length) : '';
  if (!(await passwordMatches(token, provided))) return text('Admin password is wrong.', 401);
  if (request.method === 'POST')
    return new Response(null, { status: 204, headers: { 'Cache-Control': 'no-store' } });
  if (Number(request.headers.get('Content-Length') ?? 0) > MAX_IMAGE_LENGTH * 2 + 10_000) {
    return text('Branding is too large.', 413);
  }
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return text('Branding must be JSON.', 400);
  }
  const brand = parseBrandSettings(body);
  if (!brand) return text('Each logo must be a PNG image.', 400);
  await store.write(JSON.stringify(brand));
  return json(brand);
}
