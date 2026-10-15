// Generated from src/brand-server.ts. Do not edit.

// src/brand-server.ts
import { createServer } from "node:http";

// src/app/storage.ts
var DEFAULT_BRAND_NAME = "Pocketweb for Pockethernet";
var DEFAULT_BRAND_SETTINGS = {
  name: DEFAULT_BRAND_NAME,
  logoDataUrl: "",
  logoName: "",
  iconDataUrl: "",
  iconName: ""
};

// src/brandApi.ts
var MAX_IMAGE_LENGTH = 2e6;
var PNG_DATA_URL = /^data:image\/png;base64,[A-Za-z0-9+/]+={0,2}$/;
function isRecord(value) {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
function validImage(value) {
  return value === "" || value.length <= MAX_IMAGE_LENGTH && PNG_DATA_URL.test(value);
}
function parseBrandSettings(value) {
  if (!isRecord(value)) return null;
  const logoDataUrl = typeof value.logoDataUrl === "string" ? value.logoDataUrl : "";
  const iconDataUrl = typeof value.iconDataUrl === "string" ? value.iconDataUrl : "";
  if (!validImage(logoDataUrl) || !validImage(iconDataUrl)) return null;
  return {
    name: typeof value.name === "string" ? value.name.slice(0, 80) : DEFAULT_BRAND_SETTINGS.name,
    logoDataUrl,
    logoName: typeof value.logoName === "string" ? value.logoName.slice(0, 120) : "",
    iconDataUrl,
    iconName: typeof value.iconName === "string" ? value.iconName.slice(0, 120) : ""
  };
}
function storedBrand(raw) {
  if (!raw) return DEFAULT_BRAND_SETTINGS;
  try {
    const parsed = JSON.parse(raw);
    return parseBrandSettings(parsed) ?? DEFAULT_BRAND_SETTINGS;
  } catch {
    return DEFAULT_BRAND_SETTINGS;
  }
}
function text(message, status, allow = "") {
  const headers = new Headers({
    "Cache-Control": "no-store",
    "Content-Type": "text/plain; charset=utf-8"
  });
  if (allow) headers.set("Allow", allow);
  return new Response(message, { status, headers });
}
function json(brand, status = 200) {
  return new Response(JSON.stringify(brand), {
    status,
    headers: {
      "Cache-Control": "no-store",
      "Content-Type": "application/json; charset=utf-8"
    }
  });
}
async function passwordMatches(expected, provided) {
  if (!expected || !provided) return false;
  const digest = async (value) => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
  const [left, right] = await Promise.all([digest(expected), digest(provided)]);
  let difference = 0;
  for (let index = 0; index < left.length; index += 1) difference |= left[index] ^ right[index];
  return difference === 0;
}
async function handleBrandRequest(request, store2, token) {
  if (request.method === "GET" || request.method === "HEAD") {
    const brand2 = storedBrand(await store2.read());
    return request.method === "HEAD" ? new Response(null, { headers: json(brand2).headers }) : json(brand2);
  }
  if (request.method !== "PUT" && request.method !== "POST") {
    return text("Method not allowed", 405, "GET, POST, PUT");
  }
  if (!token)
    return text("Branding is locked until an admin password is configured on the server.", 403);
  const header = request.headers.get("Authorization") ?? "";
  const provided = header.startsWith("Bearer ") ? header.slice("Bearer ".length) : "";
  if (!await passwordMatches(token, provided)) return text("Admin password is wrong.", 401);
  if (request.method === "POST")
    return new Response(null, { status: 204, headers: { "Cache-Control": "no-store" } });
  if (Number(request.headers.get("Content-Length") ?? 0) > MAX_IMAGE_LENGTH * 2 + 1e4) {
    return text("Branding is too large.", 413);
  }
  let body;
  try {
    body = await request.json();
  } catch {
    return text("Branding must be JSON.", 400);
  }
  const brand = parseBrandSettings(body);
  if (!brand) return text("Each logo must be a PNG image.", 400);
  await store2.write(JSON.stringify(brand));
  return json(brand);
}

// src/brandFile.ts
import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname } from "node:path";
function fileBrandStore(file2) {
  return {
    async read() {
      try {
        return await readFile(file2, "utf8");
      } catch {
        return null;
      }
    },
    async write(body) {
      await mkdir(dirname(file2), { recursive: true });
      const temporary = `${file2}.tmp`;
      await writeFile(temporary, body);
      await rename(temporary, file2);
    }
  };
}

// src/brand-server.ts
var port = Number(process.env.POCKETWEB_BRAND_PORT ?? 8787);
var file = process.env.POCKETWEB_BRAND_FILE ?? "/var/lib/pocketweb/brand.json";
var store = fileBrandStore(file);
var server = createServer((req, res) => {
  const path = (req.url ?? "").split("?")[0];
  if (path !== "/api/brand") {
    res.writeHead(404, { "Cache-Control": "no-store" });
    res.end("Not found");
    return;
  }
  const chunks = [];
  req.on("data", (chunk) => chunks.push(chunk));
  req.on("end", () => {
    const body = Buffer.concat(chunks);
    void handleBrandRequest(
      new Request("http://127.0.0.1/api/brand", {
        method: req.method,
        headers: {
          Authorization: req.headers.authorization ?? "",
          "Content-Type": req.headers["content-type"] ?? "",
          "Content-Length": String(body.byteLength)
        },
        body: req.method === "GET" || req.method === "HEAD" ? void 0 : body.toString("utf8")
      }),
      store,
      process.env.POCKETWEB_BRAND_TOKEN
    ).then(async (response) => {
      const headers = Object.fromEntries(response.headers.entries());
      res.writeHead(response.status, headers);
      res.end(Buffer.from(await response.arrayBuffer()));
    }).catch((error) => {
      res.writeHead(500, { "Cache-Control": "no-store" });
      res.end(error instanceof Error ? error.message : "Could not store branding");
    });
  });
});
server.listen(port, "127.0.0.1", () => {
  console.log(`Pocketweb branding store listening on 127.0.0.1:${port}`);
});
