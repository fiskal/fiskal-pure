// ---------------------------------------------------------------------------
// validateDoc — minimal pure JSON-Schema validator for write descriptors
// ---------------------------------------------------------------------------
//
// Enforces a Model's declared `schema` against the fields of a write before the
// optimistic cache update. Pure: same input → same output, no side effects.
//
// Supported keywords (the subset the library declares in its models):
//   - type        ('object' | 'string' | 'number' | 'boolean' | 'array')
//   - properties  (per-key sub-schema)
//   - required    (string[] of property names that must be present)
//   - minLength   (string minimum length)
//   - enum        (allowed value set)
//
// Atomic-op sentinel fields (`{ __op: '::...' }`) are skipped — their concrete
// value is resolved by the adapter at write time, so they cannot be validated
// against a scalar schema here.

import { isAtomicOp } from './types.js'

export interface ValidationResult {
  valid: boolean
  /** Human-readable reason for the first failure, or '' when valid. */
  message: string
}

const OK: ValidationResult = { valid: true, message: '' }

function fail(message: string): ValidationResult {
  return { valid: false, message }
}

function jsonType(v: unknown): string {
  if (v === null) return 'null'
  if (Array.isArray(v)) return 'array'
  return typeof v
}

// Validates a single value against a sub-schema. Returns the first failure.
function validateValue(
  value: unknown,
  schema: Record<string, unknown>,
  pathLabel: string,
): ValidationResult {
  // Atomic ops are resolved by the adapter — not validatable as scalars here.
  if (isAtomicOp(value)) return OK

  const expectedType = schema['type']
  if (typeof expectedType === 'string') {
    const actual = jsonType(value)
    // JSON Schema treats integers as numbers; we keep it simple.
    if (actual !== expectedType) {
      return fail(`${pathLabel}: expected type ${expectedType}, got ${actual}`)
    }
  }

  const enumValues = schema['enum']
  if (Array.isArray(enumValues) && !enumValues.includes(value)) {
    return fail(`${pathLabel}: value ${JSON.stringify(value)} not in enum`)
  }

  if (typeof value === 'string') {
    const minLength = schema['minLength']
    if (typeof minLength === 'number' && value.length < minLength) {
      return fail(`${pathLabel}: string shorter than minLength ${minLength}`)
    }
  }

  if (expectedType === 'object' && jsonType(value) === 'object') {
    return validateObject(value as Record<string, unknown>, schema, pathLabel)
  }

  return OK
}

function validateObject(
  fields: Record<string, unknown>,
  schema: Record<string, unknown>,
  pathLabel: string,
): ValidationResult {
  const required = schema['required']
  if (Array.isArray(required)) {
    for (const key of required) {
      if (typeof key !== 'string') continue
      // A field set to an atomic ::delete sentinel counts as removal, not present.
      const v = fields[key]
      const isDeleteOp = isAtomicOp(v) && v[0] === '::delete'
      if (!(key in fields) || v === undefined || isDeleteOp) {
        return fail(`${pathLabel ? pathLabel + '.' : ''}${key}: required field missing`)
      }
    }
  }

  const properties = schema['properties']
  if (properties && typeof properties === 'object') {
    const props = properties as Record<string, unknown>
    for (const [key, value] of Object.entries(fields)) {
      const sub = props[key]
      if (sub && typeof sub === 'object') {
        const label = pathLabel ? `${pathLabel}.${key}` : key
        const res = validateValue(value, sub as Record<string, unknown>, label)
        if (!res.valid) return res
      }
    }
  }

  return OK
}

/**
 * Validate a write descriptor's `fields` against a Model's JSON schema.
 * Returns `{ valid: true }` when the schema is absent/empty (nothing to enforce).
 */
export function validateDoc(
  schema: Record<string, unknown> | undefined,
  fields: Record<string, unknown> | undefined,
): ValidationResult {
  if (!schema || Object.keys(schema).length === 0) return OK
  if (!fields) return OK
  return validateObject(fields, schema, '')
}
