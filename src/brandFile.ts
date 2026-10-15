import { mkdir, readFile, rename, writeFile } from 'node:fs/promises';
import type { IncomingMessage, ServerResponse } from 'node:http';
import { dirname } from 'node:path';
import { handleBrandRequest, type BrandStore } from './brandApi.ts';

export function fileBrandStore(file: string): BrandStore {
  return {
    async read(): Promise<string | null> {
      try {
        return await readFile(file, 'utf8');
      } catch {
        return null;
      }
    },
    async write(body: string): Promise<void> {
      await mkdir(dirname(file), { recursive: true });
      const temporary = `${file}.tmp`;
      await writeFile(temporary, body);
      await rename(temporary, file);
    },
  };
}

function headerValue(value: string | string[] | undefined): string {
  return Array.isArray(value) ? (value[0] ?? '') : (value ?? '');
}

function readBody(request: IncomingMessage): Promise<Buffer> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    request.on('data', (chunk: Buffer) => chunks.push(chunk));
    request.on('end', () => resolve(Buffer.concat(chunks)));
    request.on('error', reject);
  });
}

export function createBrandMiddleware(
  file = 'data/brand.json',
  token = process.env.POCKETWEB_BRAND_TOKEN || 'pocketweb',
): (req: IncomingMessage, res: ServerResponse, next: (error?: unknown) => void) => void {
  const store = fileBrandStore(file);
  return (req, res, next) => {
    const path = (req.url ?? '').split('?')[0];
    if (path !== '/api/brand') {
      next();
      return;
    }
    void readBody(req)
      .then(async (body) => {
        const request = new Request('http://127.0.0.1/api/brand', {
          method: req.method,
          headers: {
            Authorization: headerValue(req.headers.authorization),
            'Content-Type': headerValue(req.headers['content-type']),
            'Content-Length': String(body.byteLength),
          },
          body: req.method === 'GET' || req.method === 'HEAD' ? undefined : body.toString('utf8'),
        });
        const response = await handleBrandRequest(request, store, token);
        res.statusCode = response.status;
        response.headers.forEach((value, key) => res.setHeader(key, value));
        res.end(Buffer.from(await response.arrayBuffer()));
      })
      .catch(next);
  };
}
