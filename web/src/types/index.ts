// Mirrors docs/architecture.md → "NUI contract". Keep in sync with client/main.lua.
export type ViewName = 'list' | 'detail';
export type GarageKind = 'public' | 'private' | 'impound';

/** 0=out, 1=garaged, 2=parked_world, 3=impounded, 4=retired (inactivity; recovered via app, phase 7), 5=removed (never shown) */
export enum VehicleState { Out = 0, Garaged = 1, ParkedWorld = 2, Impounded = 3, Retired = 4, Removed = 5 }

export interface Garage {
  /** 'public:<id>' | 'private:<id>' | 'impound:<id>' */
  id: `${GarageKind}:${string}`;
  kind: GarageKind;
  label: string;
  /** private only */ slots?: number;
  /** private only */ used?: number;
  /** impound only; display only (server recomputes) */ fee?: number;
}

/** Plate validation: uppercase A-Z, 0-9, space; 1-8 chars. */
export const PLATE_RE = /^[A-Z0-9 ]{1,8}$/;
export const isValidPlate = (p: string) => PLATE_RE.test(p);

export interface Vec3 { x: number; y: number; z: number }

export interface ImpoundInfo { reason: string; fee: number; /** unix seconds */ release_after: number | null }

export interface Vehicle {
  /** normalized, 1-8 chars [A-Z0-9 ] (GTA limit); see PLATE_RE */ plate: string;
  model: string;
  label: string;
  state: VehicleState;
  /** 0-100 */ fuel: number;
  /** 0-1000 */ engine: number;
  /** 0-1000 */ body: number;
  mileage: number;
  mileage_unit: 'km' | 'mi';
  garage_id: string | null;
  /** false = key holder */ is_owner: boolean;
  /** only if permitted */ coords?: Vec3;
  /** state 3 only */ impound?: ImpoundInfo;
}

export interface OpenData { garage: Garage; vehicles: Vehicle[] }

// Lua → NUI
/** UI strings from Lua `UILocale()` (Locales.<lang>.ui). Missing keys fall back to English. */
export type LocaleTable = Record<string, string>;

export type NuiMessage =
  /** `plate` (optional, proposed): vehicle to show when view = 'detail'. */
  | { action: 'open'; view: ViewName; data: OpenData; locale?: LocaleTable; plate?: string }
  | { action: 'update'; data: Partial<OpenData>; view?: ViewName; plate?: string }
  | { action: 'close' };

// NUI → Lua
export const NUI_ERROR_CODES = [
  'invalid_request', 'invalid_garage', 'wrong_garage_kind', 'unknown_garage', 'wrong_garage', 'server_error', 'rejected', 'not_found', 'not_owner', 'too_far', 'rate_limited', 'locked', 'already_out', 'retired', 'impounded', 'no_spawn', 'spawn_failed', 'unpaid_fines', 'insufficient_funds', 'world_limit', 'external_invoice', 'not_ready', 'wrong_vehicle_type', 'plate_unresolved', 'invalid_state', 'not_in_vehicle', 'clone_detected', 'not_tracked', 'invalid_source', 'already_paid', 'invalid_amount', 'fine_not_found', 'in_use', 'vehicle_moved', 'occupied',
  /** UI-only: fetchNui got no answer within 10 s. */
  'timeout',
] as const;
export type NuiErrorCode = (typeof NUI_ERROR_CODES)[number];
/** Any code outside the contract list (docs/architecture.md) is shown as 'rejected'. */
export const normalizeError = (code: unknown): NuiErrorCode =>
  (NUI_ERROR_CODES as readonly string[]).includes(code as string) ? (code as NuiErrorCode) : 'rejected';

export interface NuiResponse<T = unknown> { ok: boolean; error?: NuiErrorCode; data?: T }

export interface NuiCallbacks {
  close: { req: Record<string, never>; res: undefined };
  getVehicles: { req: { garage_id: string }; res: Vehicle[] };
  takeOut: { req: { plate: string; garage_id: string }; res: { netId: number } };
}
export type NuiEvent = keyof NuiCallbacks;

/** State 5 (Removed) is filtered out of every list and detail. */
export const visibleVehicles = (list: unknown): Vehicle[] =>
  (Array.isArray(list) ? (list as Vehicle[]) : []).filter((v) => Number(v?.state) !== VehicleState.Removed);
