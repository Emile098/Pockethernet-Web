import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { handleBrandRequest, parseBrandSettings, type BrandStore } from './brandApi';
import { fileBrandStore } from './brandFile';

const png = 'data:image/png;base64,aaaa';

function memoryStore(initial: string | null = null): BrandStore & { value: string | null } {
  const store = {
    value: initial,
    read: (): Promise<string | null> => Promise.resolve(store.value),
    write: (body: string): Promise<void> => {
      store.value = body;
      return Promise.resolve();
    },
  };
  return store;
}

async function request(
  method: string,
  store: BrandStore,
  token: string | undefined,
  body?: unknown,
  password?: string,
): Promise<Response> {
  return handleBrandRequest(
    new Request('http://127.0.0.1/api/brand', {
      method,
      headers: {
        'Content-Type': 'application/json',
        ...(password ? { Authorization: `Bearer ${password}` } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    }),
    store,
    token,
  );
}

async function brandName(response: Response): Promise<string> {
  const body: unknown = JSON.parse(await response.text());
  return parseBrandSettings(body)?.name ?? '';
}

const empty = memoryStore();
const defaults = await request('GET', empty, 'secret');
assert.equal(defaults.status, 200);
assert.equal(await brandName(defaults), 'Pocketweb for Pockethernet');

const locked = await request('PUT', empty, undefined, { name: 'Acme' });
assert.equal(locked.status, 403);

const denied = await request('PUT', empty, 'secret', { name: 'Acme' }, 'wrong');
assert.equal(denied.status, 401);

const saved = await request(
  'PUT',
  empty,
  'secret',
  { name: 'Acme Cable', logoDataUrl: png, logoName: 'mark.png', iconDataUrl: '', iconName: '' },
  'secret',
);
assert.equal(saved.status, 200);
assert.equal(await brandName(saved), 'Acme Cable');

const loaded = await request('GET', empty, 'secret');
assert.equal(parseBrandSettings(JSON.parse(await loaded.text()) as unknown)?.logoDataUrl, png);

const rejected = await request(
  'PUT',
  empty,
  'secret',
  { name: 'Acme', logoDataUrl: 'data:image/svg+xml;base64,aaaa' },
  'secret',
);
assert.equal(rejected.status, 400);
assert.equal(await brandName(await request('GET', empty, 'secret')), 'Acme Cable');

const directory = await mkdtemp(join(tmpdir(), 'pocketweb-brand-'));
const file = join(directory, 'brand.json');
const disk = fileBrandStore(file);
await disk.write(
  JSON.stringify({
    name: 'Disk Brand',
    logoDataUrl: '',
    logoName: '',
    iconDataUrl: '',
    iconName: '',
  }),
);
assert.equal(
  parseBrandSettings(JSON.parse(await readFile(file, 'utf8')) as unknown)?.name,
  'Disk Brand',
);
await rm(directory, { recursive: true });

console.log('Brand API tests passed');
