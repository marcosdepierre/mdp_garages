import { createContext, useContext } from 'react';
import type { LocaleTable, NuiErrorCode } from '@/types';
import { normalizeError } from '@/types';

/** English fallback — generated verbatim from locales/en.lua `ui` table (keep in sync). */
export const EN: LocaleTable = {
  title: "Garage",
  close: "Close",
  back: "Back",
  vehicles: "Vehicles",
  search: "Search plate or model",
  empty: "No vehicles here",
  loading: "Loading...",
  take_out: "Take out",
  details: "Details",
  retired_section: "Retired",
  retired_hint: "Recover it from the phone app",
  state_out: "Out",
  state_garaged: "In garage",
  state_parked: "Parked on street",
  state_impounded: "Impounded",
  state_retired: "Retired",
  plate: "Plate",
  model: "Model",
  fuel: "Fuel",
  engine: "Engine",
  body: "Body",
  mileage: "Mileage",
  location: "Location",
  owner: "Owner",
  key_holder: "Key holder",
  impound_fee: "Impound fee",
  release_after: "Release after",
  error: "Something went wrong",
  state_unknown: "Unknown",
  select_vehicle: "Select a vehicle from the list",
  err_invalid_request: "Invalid request",
  err_invalid_garage: "Invalid garage",
  err_wrong_garage_kind: "This garage cannot store this vehicle",
  err_unknown_garage: "Unknown garage",
  err_wrong_garage: "This vehicle is stored in another garage",
  err_server_error: "Server error, try again",
  err_rejected: "Request rejected",
  err_not_found: "Vehicle not found",
  err_not_owner: "You do not have access to this vehicle",
  err_too_far: "You are too far away",
  err_rate_limited: "Please wait a moment and try again",
  err_locked: "This vehicle is busy, try again",
  err_already_out: "This vehicle is already out",
  err_retired: "This vehicle was retired, recover it from the phone app",
  err_no_spawn: "No free spawn point",
  err_spawn_failed: "The vehicle could not be spawned",
  err_unpaid_fines: "You have unpaid fines",
  err_insufficient_funds: "You do not have enough money",
  err_world_limit: "Too many vehicles parked on the street",
  err_external_invoice: "Pay it from your billing menu",
  err_timeout: "No response, try again",
  err_not_ready: "The garage system is starting, try again in a moment",
  err_wrong_vehicle_type: "This garage does not accept this type of vehicle",
  err_plate_unresolved: "Could not identify this vehicle",
  err_invalid_state: "This vehicle cannot be stored right now",
  err_not_in_vehicle: "You must be inside the vehicle",
  err_clone_detected: "This vehicle is not valid",
  err_not_tracked: "This vehicle was not taken out from a garage",
  err_invalid_source: "Player not loaded",
  err_already_paid: "This fine is already paid",
  err_invalid_amount: "Invalid amount",
  err_impounded: "This vehicle is impounded, release it at the impound lot",
  err_fine_not_found: "Fine not found or already paid",
  err_in_use: "Someone is using this vehicle",
  err_vehicle_moved: "This vehicle is no longer where it was parked",
  err_invalid_props: "Vehicle data was rejected by the server",
  retry: "Retry",
  cancel: "Cancel",
  impound_pay_title: "Impound release",
  impound_pay: "Pay %s to release",
  err_occupied: "Everyone else must leave the vehicle first (you must be the driver)",
  // --- NUI phase 1 keys NOT yet in locales/*.lua (Backend to add to Locales.*.ui) ---
  storing: "Storing vehicle…",
  parking: "Parking vehicle…",
  taken_out: "Vehicle taken out",
  available_now: "Available now",
  empty_hint: "Store a vehicle near the garage point to see it here.",
  impound_reason: "Reason",
};

/** t(key, ...args): Lua locale → EN fallback → key. `%s` / `%d` placeholders are filled in order. */
export type TF = (key: string, ...args: (string | number)[]) => string;
export const makeT = (locale?: LocaleTable): TF => (key, ...args) => {
  let i = 0;
  const raw = locale?.[key] ?? EN[key] ?? key;
  return args.length ? raw.replace(/%[sd]/g, () => String(args[i++] ?? '')) : raw;
};
export const errorKey = (code?: NuiErrorCode | string) => (code ? `err_${normalizeError(code)}` : 'error');

export const I18nContext = createContext<TF>(makeT());
export const useT = () => useContext(I18nContext);

/** BCP-47 tag for Intl from Config.Locale ('es' → 'es-ES'). */
export const langTag = (lang?: string) => ({ es: 'es-ES', en: 'en-US' } as Record<string, string>)[lang ?? ''] ?? lang ?? 'en-US';
export const LangContext = createContext<string>('en-US');
export const useLang = () => useContext(LangContext);
