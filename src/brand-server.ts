import { createServer } from 'node:http';
import { handleBrandRequest } from './brandApi.ts';
import { fileBrandStore } from './brandFile.ts';

const port = Number(process.env.POCKETWEB_BRAND_PORT ?? 8787);
const file = process.env.POCKETWEB_BRAND_FILE ?? '/var/lib/pocketweb/brand.json';
const store = fileBrandStore(file);

const server = createServer((req, res) => {
  const path = (req.url ?? '').split('?')[0];
  if (path !== '/api/brand') {
    res.writeHead(404, { 'Cache-Control': 'no-store' });
    res.end('Not found');
    return;
  }
  const chunks: Buffer[] = [];
  req.on('data', (chunk: Buffer) => chunks.push(chunk));
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    void handleBrandRequest(
      new Request('http://127.0.0.1/api/brand', {
        method: req.method,
        headers: {
          Authorization: req.headers.authorization ?? '',
          'Content-Type': req.headers['content-type'] ?? '',
          'Content-Length': String(body.byteLength),
        },
        body: req.method === 'GET' || req.method === 'HEAD' ? undefined : body.toString('utf8'),
      }),
      store,
      process.env.POCKETWEB_BRAND_TOKEN,
    )
      .then(async (response) => {
        const headers = Object.fromEntries(response.headers.entries());
        res.writeHead(response.status, headers);
        res.end(Buffer.from(await response.arrayBuffer()));
      })
      .catch((error: unknown) => {
        res.writeHead(500, { 'Cache-Control': 'no-store' });
        res.end(error instanceof Error ? error.message : 'Could not store branding');
      });
  });
});

server.listen(port, '127.0.0.1', () => {
  console.log(`Pocketweb branding store listening on 127.0.0.1:${port}`);
});
