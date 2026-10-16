import { createContext, useContext } from 'react';
import type { LocaleTable, NuiErrorCode } from '@/types';

/** English fallback. Keys mirror locales/en.lua `ui` table; err_* / state_unknown / select_vehicle are new (Backend to add). */
export const EN: LocaleTable = {
  title: 'Garage', close: 'Close', back: 'Back', vehicles: 'Vehicles', empty: 'No vehicles here',
  loading: 'Loading...', take_out: 'Take out', details: 'Details',
  retired_section: 'Retired', retired_hint: 'Recover it from the phone app',
  state_out: 'Out', state_garaged: 'In garage', state_parked: 'Parked on street', state_impounded: 'Impounded',
  state_retired: 'Retired', state_unknown: 'Unknown',
  plate: 'Plate', model: 'Model', fuel: 'Fuel', engine: 'Engine', body: 'Body', mileage: 'Mileage',
  location: 'Location', owner: 'Owner', key_holder: 'Key holder', impound_fee: 'Impound fee', release_after: 'Release after',
  error: 'Something went wrong', select_vehicle: 'Select a vehicle from the list',
  err_invalid_request: 'Invalid request', err_invalid_garage: 'Invalid garage', err_wrong_garage_kind: 'This garage cannot store this vehicle',
  err_unknown_garage: 'Unknown garage', err_wrong_garage: 'This vehicle is stored in another garage', err_server_error: 'Server error, try again',
  err_rejected: 'Request rejected', err_not_found: 'Vehicle not found', err_not_owner: 'You do not have access to this vehicle',
  err_too_far: 'You are too far away', err_rate_limited: 'Please wait a moment and try again', err_locked: 'This vehicle is busy, try again',
  err_already_out: 'This vehicle is already out', err_retired: 'This vehicle was retired, recover it from the phone app',
  err_no_spawn: 'No free spawn point', err_spawn_failed: 'The vehicle could not be spawned', err_unpaid_fines: 'You have unpaid fines',
  err_insufficient_funds: 'You do not have enough money', err_world_limit: 'Too many vehicles parked on the street',
  err_external_invoice: 'Pay it from your billing menu', err_timeout: 'No response, try again',
};

export type T = (key: string) => string;
export const makeT = (locale?: LocaleTable): T => (key) => locale?.[key] ?? EN[key] ?? key;
export const errorKey = (code?: NuiErrorCode | string) => (code ? `err_${code}` : 'error');

export const I18nContext = createContext<T>(makeT());
export const useT = () => useContext(I18nContext);
