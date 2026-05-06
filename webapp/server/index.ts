import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createServer } from "node:http";
import { homedir } from "node:os";
import { dirname, parse, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { readdir, stat } from "node:fs/promises";
import { WebSocketServer, type RawData } from "ws";

type JsonValue = null | boolean | number | string | JsonValue[] | { [key: string]: JsonValue };
type RpcResult = unknown;

type RpcResponse = {
  jsonrpc: "2.0";
  id: number;
  result?: JsonValue;
  error?: { code: number; message: string };
};

type PendingRequest = {
  resolve: (value: RpcResult) => void;
  reject: (error: Error) => void;
};

type ClientRequest = {
  id: number;
  method: string;
  params?: Record<string, JsonValue>;
};

type DirectoryEntry = {
  name: string;
  path: string;
  kind: "directory" | "file";
};

const port = Number(process.env.PORT ?? 5174);
const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..", "..");
const defaultBinary = resolve(
  repoRoot,
  "zig-out",
  "bin",
  process.platform === "win32" ? "bioformats-zig.exe" : "bioformats-zig"
);
const binaryPath = process.env.BIOFORMATS_ZIG_BIN ?? defaultBinary;

class ZigRpc {
  private child: ChildProcessWithoutNullStreams;
  private nextId = 1;
  private pending = new Map<number, PendingRequest>();
  private stdout = "";

  constructor(private readonly binary: string) {
    this.child = spawn(binary, [], {
      cwd: repoRoot,
      stdio: ["pipe", "pipe", "pipe"],
      windowsHide: true
    });
    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (chunk: string) => this.handleStdout(chunk));
    this.child.stderr.setEncoding("utf8");
    this.child.stderr.on("data", (chunk: string) => {
      process.stderr.write(`[bioformats-zig] ${chunk}`);
    });
    this.child.on("error", (error) => this.rejectAll(error));
    this.child.on("exit", (code, signal) => {
      this.rejectAll(new Error(`bioformats-zig exited with code ${code ?? "null"} signal ${signal ?? "null"}`));
    });
  }

  request(method: string, params?: Record<string, JsonValue>): Promise<RpcResult> {
    const id = this.nextId++;
    const payload = JSON.stringify({ jsonrpc: "2.0", id, method, params });
    return new Promise((resolvePromise, reject) => {
      this.pending.set(id, { resolve: resolvePromise, reject });
      this.child.stdin.write(`${payload}\n`, (error) => {
        if (error) {
          this.pending.delete(id);
          reject(error);
        }
      });
    });
  }

  shutdown(): void {
    if (!this.child.killed) {
      this.child.stdin.write(JSON.stringify({ jsonrpc: "2.0", method: "shutdown" }) + "\n");
      this.child.stdin.end();
    }
  }

  private handleStdout(chunk: string): void {
    this.stdout += chunk;
    while (true) {
      const newline = this.stdout.indexOf("\n");
      if (newline < 0) return;
      const line = this.stdout.slice(0, newline).trim();
      this.stdout = this.stdout.slice(newline + 1);
      if (line.length === 0) continue;
      const parsed = JSON.parse(line) as RpcResponse;
      const pending = this.pending.get(parsed.id);
      if (!pending) continue;
      this.pending.delete(parsed.id);
      if (parsed.error) {
        pending.reject(new Error(parsed.error.message));
      } else {
        pending.resolve(parsed.result ?? null);
      }
    }
  }

  private rejectAll(error: Error): void {
    for (const pending of this.pending.values()) pending.reject(error);
    this.pending.clear();
  }
}

const rpc = new ZigRpc(binaryPath);

async function listDirectory(params?: Record<string, JsonValue>) {
  if (typeof params?.path !== "string" || params.path.length === 0) {
    return process.platform === "win32" ? listWindowsDrives() : listDirectoryPath(parse(process.cwd()).root);
  }

  return listDirectoryPath(params.path);
}

async function listWindowsDrives() {
  const entries: DirectoryEntry[] = [];
  for (let code = "A".charCodeAt(0); code <= "Z".charCodeAt(0); code++) {
    const name = `${String.fromCharCode(code)}:\\`;
    try {
      const driveStat = await stat(name);
      if (!driveStat.isDirectory()) continue;
      entries.push({ name, path: name, kind: "directory" });
    } catch {
      // Ignore drive letters that are not mounted or are not readable.
    }
  }

  return {
    path: "This PC",
    parentPath: null,
    homePath: homedir(),
    entries
  };
}

async function listDirectoryPath(requested: string) {
  const directory = resolve(requested);
  const directoryStat = await stat(directory);
  if (!directoryStat.isDirectory()) throw new Error(`${directory} is not a directory`);

  const entries: DirectoryEntry[] = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (!entry.isDirectory() && !entry.isFile()) continue;
    entries.push({
      name: entry.name,
      path: resolve(directory, entry.name),
      kind: entry.isDirectory() ? "directory" : "file"
    });
  }

  entries.sort((a, b) => {
    if (a.kind !== b.kind) return a.kind === "directory" ? -1 : 1;
    return a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: "base" });
  });

  const root = parse(directory).root;
  return {
    path: directory,
    parentPath: directory === root ? null : dirname(directory),
    homePath: homedir(),
    entries
  };
}

function parseRequest(data: RawData): ClientRequest {
  const parsed = JSON.parse(data.toString()) as ClientRequest;
  if (!Number.isInteger(parsed.id)) throw new Error("request id must be an integer");
  if (typeof parsed.method !== "string" || parsed.method.length === 0) throw new Error("method is required");
  return parsed;
}

async function dispatch(request: ClientRequest): Promise<unknown> {
  switch (request.method) {
    case "initialize":
      return { binaryPath, initialize: await rpc.request("initialize") };
    case "listDirectory":
      return listDirectory(request.params);
    case "formats":
    case "probe":
    case "open":
    case "metadata":
    case "readPlane":
    case "close":
      return rpc.request(request.method, request.params);
    default:
      throw new Error(`unknown method: ${request.method}`);
  }
}

const server = createServer((request, response) => {
  if (request.url === "/health") {
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: true }));
    return;
  }
  response.writeHead(404);
  response.end();
});
const wss = new WebSocketServer({ server, path: "/ws" });

wss.on("connection", (socket) => {
  socket.on("message", async (data) => {
    let id: number | null = null;
    try {
      const request = parseRequest(data);
      id = request.id;
      socket.send(JSON.stringify({ id, result: await dispatch(request) }));
    } catch (error) {
      socket.send(JSON.stringify({ id, error: { message: error instanceof Error ? error.message : String(error) } }));
    }
  });
});

function shutdown(): void {
  rpc.shutdown();
  server.close();
  process.exit(0);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);

server.listen(port, "127.0.0.1", () => {
  console.log(`bioformats-zig WebSocket bridge listening on ws://127.0.0.1:${port}/ws`);
  console.log(`using ${binaryPath}`);
});
