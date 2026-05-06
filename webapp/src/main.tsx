import { QueryClient, QueryClientProvider, useMutation, useQuery } from "@tanstack/react-query";
import React, { useEffect, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { create } from "zustand";
import "./styles.css";

type Metadata = {
  format: string;
  width: number;
  height: number;
  sizeC: number;
  sizeZ: number;
  sizeT: number;
  samplesPerPixel?: number;
  pixelType: string;
  littleEndian: boolean;
  planeCount: number;
  imageCount?: number;
  seriesCount?: number;
  timestampCount?: number;
  positionCounts?: { x?: number; y?: number; z?: number; z1?: number };
  timestampRangeSeconds?: { first: number; last: number };
  dimensionOrder?: string;
  imageDescription?: string;
};

type ImageSource = { path: string; metadata: Metadata };
type PlaneResult = {
  metadata: Metadata;
  encoding: "base64";
  data: string;
  region?: { x: number; y: number; width: number; height: number };
};

type DirectoryEntry = {
  name: string;
  path: string;
  kind: "directory" | "file";
};

type DirectoryListing = {
  path: string;
  parentPath: string | null;
  homePath: string;
  entries: DirectoryEntry[];
};

type InitResult = {
  binaryPath: string;
  initialize: unknown;
};

type ViewerState = {
  z: number;
  c: number;
  t: number;
  contrast: "auto" | "raw";
  setZ: (z: number) => void;
  setC: (c: number) => void;
  setT: (t: number) => void;
  resetCoordinates: () => void;
  setContrast: (contrast: "auto" | "raw") => void;
};

type PendingRequest = {
  resolve: (value: unknown) => void;
  reject: (error: Error) => void;
};

type SocketResponse<T> = {
  id: number | null;
  result?: T;
  error?: { message: string };
};

const useViewerState = create<ViewerState>((set) => ({
  z: 0,
  c: 0,
  t: 0,
  contrast: "auto",
  setZ: (z) => set({ z }),
  setC: (c) => set({ c }),
  setT: (t) => set({ t }),
  resetCoordinates: () => set({ z: 0, c: 0, t: 0 }),
  setContrast: (contrast) => set({ contrast })
}));

const queryClient = new QueryClient();

class BridgeClient {
  private socket: WebSocket | null = null;
  private connecting: Promise<WebSocket> | null = null;
  private nextId = 1;
  private pending = new Map<number, PendingRequest>();

  request<T>(method: string, params?: Record<string, unknown>): Promise<T> {
    const id = this.nextId++;
    return this.connect().then((socket) => {
      return new Promise<T>((resolve, reject) => {
        this.pending.set(id, { resolve: resolve as (value: unknown) => void, reject });
        socket.send(JSON.stringify({ id, method, params }));
      });
    });
  }

  private connect(): Promise<WebSocket> {
    if (this.socket?.readyState === WebSocket.OPEN) return Promise.resolve(this.socket);
    if (this.connecting) return this.connecting;

    const scheme = window.location.protocol === "https:" ? "wss" : "ws";
    const socket = new WebSocket(`${scheme}://${window.location.host}/ws`);
    this.socket = socket;
    this.connecting = new Promise((resolve, reject) => {
      socket.addEventListener("open", () => {
        this.connecting = null;
        resolve(socket);
      });
      socket.addEventListener("error", () => {
        this.connecting = null;
        reject(new Error("WebSocket connection failed"));
      });
    });

    socket.addEventListener("message", (event) => this.handleMessage(event));
    socket.addEventListener("close", () => {
      this.socket = null;
      this.connecting = null;
      for (const pending of this.pending.values()) pending.reject(new Error("WebSocket connection closed"));
      this.pending.clear();
    });

    return this.connecting;
  }

  private handleMessage(event: MessageEvent<string>): void {
    const response = JSON.parse(event.data) as SocketResponse<unknown>;
    if (response.id === null) return;
    const pending = this.pending.get(response.id);
    if (!pending) return;
    this.pending.delete(response.id);
    if (response.error) {
      pending.reject(new Error(response.error.message));
    } else {
      pending.resolve(response.result ?? null);
    }
  }
}

const bridge = new BridgeClient();
const wsRequest = <T,>(method: string, params?: Record<string, unknown>) => bridge.request<T>(method, params);

function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <Viewer />
    </QueryClientProvider>
  );
}

function Viewer() {
  const [dialogOpen, setDialogOpen] = useState(false);
  const [sourceLabel, setSourceLabel] = useState("");
  const [source, setSource] = useState<ImageSource | null>(null);
  const { z, c, t, setZ, setC, setT, resetCoordinates, contrast, setContrast } = useViewerState();

  const bridgeStatus = useQuery({
    queryKey: ["initialize"],
    queryFn: () => wsRequest<InitResult>("initialize")
  });

  const openMutation = useMutation({
    mutationFn: async (path: string) => {
      const metadata = await wsRequest<Metadata>("metadata", { path });
      return { path, metadata };
    },
    onSuccess: (result) => {
      setSource(result);
      setSourceLabel(result.path);
      resetCoordinates();
    }
  });

  const planeQuery = useQuery({
    queryKey: ["plane", source?.path, z, c, t],
    enabled: source !== null,
    queryFn: () => wsRequest<PlaneResult>("readPlane", { path: source!.path, z, c, t })
  });

  const metadata = source?.metadata;
  const logicalSizeC = metadata ? selectableSizeC(metadata) : 1;
  const isReady = bridgeStatus.isSuccess && !bridgeStatus.isError;

  return (
    <main className="min-h-screen bg-zinc-950 text-zinc-100">
      <section className="border-b border-zinc-800 bg-zinc-900/70">
        <div className="mx-auto flex max-w-7xl flex-wrap items-center gap-3 px-4 py-3">
          <h1 className="text-base font-semibold">bioformats-zig viewer</h1>
          <span className="min-w-0 flex-1 truncate text-xs text-zinc-400">
            {bridgeStatus.data?.binaryPath ?? "connecting to WebSocket bridge"}
          </span>
          <span className={bridgeStatus.isError ? "status status-error" : "status"}>
            {bridgeStatus.isLoading ? "connecting" : isReady ? "ready" : "offline"}
          </span>
        </div>
      </section>

      <section className="mx-auto grid max-w-7xl gap-4 px-4 py-4 lg:grid-cols-[360px_1fr]">
        <aside className="space-y-4">
          <div className="panel">
            <div className="flex items-center justify-between gap-3">
              <div className="min-w-0">
                <p className="label">Image file</p>
                <p className="truncate text-sm text-zinc-300">{sourceLabel || "No file selected"}</p>
              </div>
              <button className="button" onClick={() => setDialogOpen(true)} disabled={openMutation.isPending}>
                Browse
              </button>
            </div>
            {openMutation.isPending ? <p className="mt-3 text-xs text-zinc-400">Opening image</p> : null}
            {openMutation.error ? <p className="error">{openMutation.error.message}</p> : null}
          </div>

          <div className="panel">
            <AxisSlider label="Z" value={z} size={metadata?.sizeZ ?? 1} disabled={!metadata} onChange={setZ} />
            <AxisSlider label="C" value={c} size={logicalSizeC} disabled={!metadata} onChange={setC} />
            <AxisSlider label="T" value={t} size={metadata?.sizeT ?? 1} disabled={!metadata} onChange={setT} />
            <div className="mt-3 grid grid-cols-2 gap-2">
              <button className={contrast === "auto" ? "button button-active" : "button"} onClick={() => setContrast("auto")}>
                Auto
              </button>
              <button className={contrast === "raw" ? "button button-active" : "button"} onClick={() => setContrast("raw")}>
                Raw
              </button>
            </div>
          </div>

          <MetadataPanel metadata={metadata} />
        </aside>

        <section className="viewer-shell">
          {planeQuery.data ? (
            <PlaneCanvas plane={planeQuery.data} contrast={contrast} />
          ) : (
            <div className="empty">{planeQuery.isLoading ? "Loading plane" : "Open an image to inspect pixels"}</div>
          )}
          {planeQuery.error ? <p className="error">{planeQuery.error.message}</p> : null}
        </section>
      </section>

      <FileDialog
        open={dialogOpen}
        onClose={() => setDialogOpen(false)}
        onPick={(entry) => {
          setDialogOpen(false);
          openMutation.mutate(entry.path);
        }}
      />
    </main>
  );
}

function selectableSizeC(metadata: Metadata): number {
  if ((metadata.samplesPerPixel ?? 0) > 1 && metadata.planeCount <= metadata.sizeZ * metadata.sizeT) return 1;
  return Math.max(1, metadata.sizeC);
}

function AxisSlider({
  label,
  value,
  size,
  disabled,
  onChange
}: {
  label: string;
  value: number;
  size: number;
  disabled: boolean;
  onChange: (value: number) => void;
}) {
  const max = Math.max(0, size - 1);
  return (
    <div className="mb-3 last:mb-0">
      <div className="flex items-center justify-between gap-2">
        <label className="label mb-0" htmlFor={`axis-${label}`}>{label}</label>
        <span className="text-xs text-zinc-400">{disabled ? "none" : `${Math.min(value, max) + 1} / ${Math.max(1, size)}`}</span>
      </div>
      <input
        id={`axis-${label}`}
        className="w-full"
        type="range"
        min={0}
        max={max}
        value={Math.min(value, max)}
        disabled={disabled || max === 0}
        onChange={(event) => onChange(Number(event.target.value))}
      />
    </div>
  );
}

function FileDialog({ open, onClose, onPick }: { open: boolean; onClose: () => void; onPick: (entry: DirectoryEntry) => void }) {
  const [path, setPath] = useState<string | undefined>();
  const [selected, setSelected] = useState<DirectoryEntry | null>(null);

  const listing = useQuery({
    queryKey: ["directory", path],
    enabled: open,
    queryFn: () => wsRequest<DirectoryListing>("listDirectory", path ? { path } : undefined)
  });

  useEffect(() => {
    if (open) setPath(undefined);
  }, [open]);

  useEffect(() => {
    setSelected(null);
  }, [listing.data?.path]);

  useEffect(() => {
    if (!open) return;
    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === "Escape") onClose();
      if (event.key === "Enter" && selected?.kind === "file") onPick(selected);
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [onClose, onPick, open, selected]);

  if (!open) return null;

  const current = listing.data;

  return (
    <div className="modal-backdrop" role="presentation">
      <div className="file-dialog" role="dialog" aria-modal="true" aria-labelledby="file-dialog-title">
        <div className="dialog-header">
          <div className="min-w-0">
            <h2 id="file-dialog-title" className="text-sm font-semibold">Open image</h2>
            <p className="truncate text-xs text-zinc-400">{current?.path ?? "Loading root"}</p>
          </div>
          <button className="button" onClick={onClose}>Close</button>
        </div>

        <div className="dialog-toolbar">
          <button className="button" onClick={() => setPath(undefined)} disabled={listing.isLoading}>
            Root
          </button>
          <button
            className="button"
            onClick={() => current?.parentPath && setPath(current.parentPath)}
            disabled={!current?.parentPath || listing.isLoading}
          >
            Up
          </button>
          <button className="button" onClick={() => setPath(current?.homePath)} disabled={!current?.homePath || listing.isLoading}>
            Home
          </button>
        </div>

        <div className="file-list" role="listbox" aria-label="Files">
          {listing.isLoading ? <div className="empty-list">Loading folder</div> : null}
          {listing.error ? <div className="empty-list text-red-300">{listing.error.message}</div> : null}
          {current?.entries.map((entry) => (
            <button
              className={selected?.path === entry.path ? "file-row file-row-active" : "file-row"}
              key={entry.path}
              onClick={() => {
                if (entry.kind === "directory") {
                  setPath(entry.path);
                } else {
                  setSelected(entry);
                }
              }}
              onDoubleClick={() => {
                if (entry.kind === "file") onPick(entry);
              }}
              role="option"
              aria-selected={selected?.path === entry.path}
            >
              <span className={entry.kind === "directory" ? "file-kind file-kind-folder" : "file-kind"}>{entry.kind === "directory" ? "DIR" : "FILE"}</span>
              <span className="truncate">{entry.name}</span>
            </button>
          ))}
          {current && current.entries.length === 0 ? <div className="empty-list">This folder is empty</div> : null}
        </div>

        <div className="dialog-footer">
          <span className="min-w-0 flex-1 truncate text-xs text-zinc-400">{selected?.path ?? "Select a file"}</span>
          <button className="button" onClick={() => selected && onPick(selected)} disabled={selected?.kind !== "file"}>
            Open
          </button>
        </div>
      </div>
    </div>
  );
}

function MetadataPanel({ metadata }: { metadata?: Metadata }) {
  if (!metadata) {
    return <div className="panel text-sm text-zinc-400">Metadata appears after opening a readable image.</div>;
  }
  const rows = [
    ["Format", metadata.format],
    ["Size", `${metadata.width} x ${metadata.height}`],
    ["Planes", metadata.planeCount],
    ["Z / C / T", `${metadata.sizeZ} / ${metadata.sizeC} / ${metadata.sizeT}`],
    ["Pixel type", metadata.pixelType],
    ["Endian", metadata.littleEndian ? "little" : "big"],
    ["Order", metadata.dimensionOrder ?? "XYZCT"],
    ["Timestamps", metadata.timestampCount ?? 0],
    ["Time range", timestampRangeLabel(metadata)],
    ["Positions", positionCountsLabel(metadata)]
  ];
  return (
    <div className="panel">
      <h2 className="mb-3 text-sm font-semibold">Metadata</h2>
      <dl className="space-y-2 text-sm">
        {rows.map(([key, value]) => (
          <div className="grid grid-cols-[92px_1fr] gap-3" key={key}>
            <dt className="text-zinc-500">{key}</dt>
            <dd className="truncate text-zinc-200">{value}</dd>
          </div>
        ))}
      </dl>
    </div>
  );
}

function positionCountsLabel(metadata: Metadata): string {
  const counts = metadata.positionCounts;
  if (!counts) return "0";
  const parts = [
    counts.x ? `X ${counts.x}` : null,
    counts.y ? `Y ${counts.y}` : null,
    counts.z ? `Z ${counts.z}` : null,
    counts.z1 ? `Z1 ${counts.z1}` : null
  ].filter(Boolean);
  return parts.length > 0 ? parts.join(" / ") : "0";
}

function timestampRangeLabel(metadata: Metadata): string {
  const range = metadata.timestampRangeSeconds;
  return range ? `${formatNumber(range.first)} - ${formatNumber(range.last)} s` : "n/a";
}

function formatNumber(value: number): string {
  return Number.isFinite(value) ? value.toFixed(3) : "n/a";
}

function PlaneCanvas({ plane, contrast }: { plane: PlaneResult; contrast: "auto" | "raw" }) {
  const canvasRef = useRef<HTMLCanvasElement | null>(null);

  useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const image = planeToImageData(plane, contrast);
    canvas.width = image.width;
    canvas.height = image.height;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;
    ctx.putImageData(image, 0, 0);
  }, [plane, contrast]);

  return (
    <div className="canvas-wrap">
      <canvas ref={canvasRef} className="pixel-canvas" />
    </div>
  );
}

function planeToImageData(plane: PlaneResult, contrast: "auto" | "raw"): ImageData {
  const metadata = plane.metadata;
  const width = plane.region?.width ?? metadata.width;
  const height = plane.region?.height ?? metadata.height;
  const bytes = base64ToBytes(plane.data);
  const image = new ImageData(width, height);

  if (metadata.pixelType === "rgb8" || metadata.pixelType === "rgba8") {
    const stride = metadata.pixelType === "rgba8" ? 4 : 3;
    for (let i = 0, p = 0; p < width * height; p++, i += stride) {
      image.data[p * 4] = bytes[i] ?? 0;
      image.data[p * 4 + 1] = bytes[i + 1] ?? 0;
      image.data[p * 4 + 2] = bytes[i + 2] ?? 0;
      image.data[p * 4 + 3] = stride === 4 ? bytes[i + 3] ?? 255 : 255;
    }
    return image;
  }

  if (metadata.pixelType === "rgb16" || metadata.pixelType === "rgba16") {
    const stride = metadata.pixelType === "rgba16" ? 4 : 3;
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    const [min, max] = contrast === "auto" ? color16Range(view, metadata.littleEndian, width * height, stride) : [0, 65535];
    for (let p = 0; p < width * height; p++) {
      const offset = p * stride * 2;
      image.data[p * 4] = scale(readUint16(view, offset, metadata.littleEndian), min, max);
      image.data[p * 4 + 1] = scale(readUint16(view, offset + 2, metadata.littleEndian), min, max);
      image.data[p * 4 + 2] = scale(readUint16(view, offset + 4, metadata.littleEndian), min, max);
      image.data[p * 4 + 3] = stride === 4 ? scale(readUint16(view, offset + 6, metadata.littleEndian), 0, 65535) : 255;
    }
    return image;
  }

  const values = samples(bytes, metadata, width * height);
  const [min, max] = contrast === "auto" ? range(values) : rawRange(metadata.pixelType);
  for (let i = 0; i < values.length; i++) {
    const v = scale(values[i], min, max);
    image.data[i * 4] = v;
    image.data[i * 4 + 1] = v;
    image.data[i * 4 + 2] = v;
    image.data[i * 4 + 3] = 255;
  }
  return image;
}

function samples(bytes: Uint8Array, metadata: Metadata, count: number): Float64Array {
  const values = new Float64Array(count);
  const little = metadata.littleEndian;
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  for (let i = 0; i < count; i++) {
    const offset = i * bytesPerSample(metadata.pixelType);
    switch (metadata.pixelType) {
      case "uint8":
        values[i] = bytes[offset] ?? 0;
        break;
      case "int8":
        values[i] = view.getInt8(offset);
        break;
      case "uint16":
        values[i] = view.getUint16(offset, little);
        break;
      case "int16":
        values[i] = view.getInt16(offset, little);
        break;
      case "uint32":
        values[i] = view.getUint32(offset, little);
        break;
      case "int32":
        values[i] = view.getInt32(offset, little);
        break;
      case "float32":
        values[i] = view.getFloat32(offset, little);
        break;
      case "float64":
        values[i] = view.getFloat64(offset, little);
        break;
      default:
        values[i] = bytes[offset] ?? 0;
    }
  }
  return values;
}

function color16Range(view: DataView, littleEndian: boolean, pixels: number, stride: number): [number, number] {
  let min = Number.POSITIVE_INFINITY;
  let max = Number.NEGATIVE_INFINITY;
  for (let p = 0; p < pixels; p++) {
    const offset = p * stride * 2;
    for (let c = 0; c < 3; c++) {
      const value = readUint16(view, offset + c * 2, littleEndian);
      min = Math.min(min, value);
      max = Math.max(max, value);
    }
  }
  if (!Number.isFinite(min) || min === max) return [0, max || 1];
  return [min, max];
}

function readUint16(view: DataView, offset: number, littleEndian: boolean): number {
  return offset + 2 <= view.byteLength ? view.getUint16(offset, littleEndian) : 0;
}

function bytesPerSample(pixelType: string): number {
  if (pixelType.endsWith("16")) return 2;
  if (pixelType.endsWith("32")) return 4;
  if (pixelType.endsWith("64")) return 8;
  return 1;
}

function range(values: Float64Array): [number, number] {
  let min = Number.POSITIVE_INFINITY;
  let max = Number.NEGATIVE_INFINITY;
  for (const value of values) {
    if (!Number.isFinite(value)) continue;
    min = Math.min(min, value);
    max = Math.max(max, value);
  }
  if (!Number.isFinite(min) || min === max) return [0, max || 1];
  return [min, max];
}

function rawRange(pixelType: string): [number, number] {
  switch (pixelType) {
    case "int8":
      return [-128, 127];
    case "uint16":
      return [0, 65535];
    case "int16":
      return [-32768, 32767];
    case "uint32":
      return [0, 4294967295];
    case "int32":
      return [-2147483648, 2147483647];
    default:
      return [0, 255];
  }
}

function scale(value: number, min: number, max: number): number {
  if (max <= min) return 0;
  return Math.max(0, Math.min(255, Math.round(((value - min) / (max - min)) * 255)));
}

function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>
);
