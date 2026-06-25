// ---------------------------------------------------------------------------
// GunAdapter
// ---------------------------------------------------------------------------
//
// Gun has no official TypeScript types — all Gun API calls use `any`.
// P2P CRDT semantics: writes are independent; no transaction support.
//
// Subscribe patterns:
//   Single doc  → gun.get(collection).get(id).on(cb)
//   Collection  → gun.get(collection).map().on(cb)
//
// Write:
//   gun.get(collection).get(id).put(fields)
//
// Gun metadata (_: { '#': soul, '>': state }) is stripped before delivery.
//
// Where-clause filtering is applied client-side after receiving the
// full collection (Gun has no server-side query support).

/* eslint-disable @typescript-eslint/no-explicit-any */

import { isAtomicOp, type FieldMap } from '../types.js'
import type {
  Adapter,
  Doc,
  OnChangeCallback,
  Query,
  Unsubscribe,
  WriteDescriptor,
  WriteOp,
} from '../types.js'

// ---------------------------------------------------------------------------
// Strip Gun internal metadata
// ---------------------------------------------------------------------------

function stripGunMeta(raw: any): Record<string, unknown> | null {
  if (raw == null || typeof raw !== 'object') return null
  // eslint-disable-next-line @typescript-eslint/no-unused-vars
  const { _: _meta, ...rest } = raw as Record<string, unknown>
  return rest
}

function toDoc(id: string, raw: any): Doc | null {
  const stripped = stripGunMeta(raw)
  if (!stripped || Object.keys(stripped).length === 0) return null
  return { id, ...stripped }
}

// ---------------------------------------------------------------------------
// Client-side where filter
// ---------------------------------------------------------------------------

function matchesWhere(doc: Doc, where: Record<string, unknown>): boolean {
  return Object.entries(where).every(([k, v]) => doc[k] === v)
}

// ---------------------------------------------------------------------------
// Adapter
// ---------------------------------------------------------------------------

export function GunAdapter(gun: any): Adapter {
  function subscribe(query: Query, onChange: OnChangeCallback): Unsubscribe {
    if (query.id) {
      // Single document subscription
      const node = gun.get(query.path).get(query.id)
      node.on((data: any) => {
        const doc = toDoc(query.id as string, data)
        onChange(doc ? [doc] : [])
      })

      return () => {
        node.off()
      }
    }

    // Collection subscription — accumulate all docs in a local map
    // Gun fires .map().on() once per document, then re-fires on updates.
    const accumulated = new Map<string, Doc>()
    const colNode = gun.get(query.path)

    colNode.map().on((data: any, id: string) => {
      if (data == null) {
        accumulated.delete(id)
      } else {
        const doc = toDoc(id, data)
        if (doc) {
          accumulated.set(id, doc)
        } else {
          accumulated.delete(id)
        }
      }

      let docs = Array.from(accumulated.values())
      if (query.where && Object.keys(query.where).length > 0) {
        docs = docs.filter(d => matchesWhere(d, query.where!))
      }
      onChange(docs)
    })

    return () => {
      colNode.off()
    }
  }

  async function write(operation: WriteOp): Promise<void> {
    const descs: WriteDescriptor[] = Array.isArray(operation)
      ? operation
      : [operation]

    // Gun has no transactions — apply each descriptor independently
    for (const desc of descs) {
      const node = gun.get(desc.path).get(desc.id)

      if (desc.delete) {
        // Gun deletes a node by putting null
        await new Promise<void>((resolve, reject) => {
          node.put(null, (ack: any) => {
            if (ack.err) reject(new Error(ack.err))
            else resolve()
          })
        })
        continue
      }

      if (desc.fields) {
        // Strip AtomicOp sentinels — Gun CRDTs don't support server-side ops.
        // Sentinels are reduced to their plain JS equivalent locally.
        const plain = resolvePlainFields(desc.fields)
        await new Promise<void>((resolve, reject) => {
          node.put(plain, (ack: any) => {
            if (ack.err) reject(new Error(ack.err))
            else resolve()
          })
        })
      }
    }
  }

  return { subscribe, write }
}

// ---------------------------------------------------------------------------
// AtomicOp → plain JS (Gun doesn't understand sentinels)
// ---------------------------------------------------------------------------

function resolvePlainFields(fields: FieldMap): Record<string, unknown> {
  const out: Record<string, unknown> = {}
  for (const [key, value] of Object.entries(fields)) {
    if (isAtomicOp(value)) {
      switch (value.__op) {
        case '::arrayUnion':
          // Gun doesn't have arrays in the traditional sense — store as object
          // with index keys. Here we convert the additions to a plain object.
          out[key] = value.values
          break
        case '::arrayRemove':
          // Removal cannot be expressed without reading first — emit null to
          // signal deletion of the field. Caller should read-then-write instead.
          // Warn loudly: this is a lossy coercion, not a true arrayRemove.
          // eslint-disable-next-line no-console
          console.warn(`GunAdapter: ::arrayRemove on '${key}' is not supported by Gun's CRDT model; coercing to null. Use read-then-write instead.`)
          out[key] = null
          break
        case '::increment':
          // Cannot increment without reading first — set to the delta value.
          // Callers should use read-then-write for atomic counters in Gun.
          // Warn loudly: the delta is written as an absolute value, not added.
          // eslint-disable-next-line no-console
          console.warn(`GunAdapter: ::increment on '${key}' is not atomic in Gun; writing the delta (${value.n}) as an absolute value. Use read-then-write instead.`)
          out[key] = value.n
          break
        case '::serverTimestamp':
          out[key] = new Date().toISOString()
          break
        case '::delete':
          out[key] = null
          break
      }
    } else {
      out[key] = value
    }
  }
  return out
}
