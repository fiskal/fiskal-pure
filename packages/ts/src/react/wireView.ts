// wireView — the only connection point between a component and the store.
//
// Call createWireView once in your store file to get a wireView factory
// bound to that store and its mutates. Then use wireView everywhere else.
//
// Pattern:
//   1. Pure component with zero library imports.
//   2. wireView called AFTER the component, outside its file.
//   3. Registered under `name` so other wired components can inject it by
//      prop name automatically.

import { createElement, useEffect, useRef, useState } from 'react'
import type { ComponentType, ReactElement } from 'react'
import type { Doc, MutateFn, Query, StoreInstance } from '../types.js'

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type QuerySpec = {
  path?: string
  id?: string
  where?: Record<string, unknown>
  fields?: string[]
}

type QueryMap = Record<string, QuerySpec>
type QueryFn<P> = (props: P) => QueryMap

// ---------------------------------------------------------------------------
// createWireView
// ---------------------------------------------------------------------------

export function createWireView(
  store: StoreInstance,
  mutates?: Record<string, MutateFn>,
): <P extends Record<string, unknown>>(
  name: string,
  queries: QueryMap | QueryFn<P>,
  actionNames: string[],
  component: ComponentType<P>,
) => ComponentType<Partial<P>> {
  const registry = new Map<string, ComponentType<Record<string, unknown>>>()
  const allMutates = { ...store.mutates, ...(mutates ?? {}) }

  function specToQuery(spec: QuerySpec): Query {
    const extras = {
      ...(spec.where !== undefined ? { where: spec.where } : {}),
      ...(spec.fields !== undefined ? { fields: spec.fields } : {}),
    }
    // Path-based id: 'tasks/task-1' encodes path + local id in one string.
    // When no explicit path is given, split on the first slash.
    if (spec.id !== undefined && spec.path === undefined) {
      const slash = spec.id.indexOf('/')
      if (slash !== -1) {
        return { ...extras, path: spec.id.slice(0, slash), id: spec.id.slice(slash + 1) }
      }
    }
    const path = spec.path ?? ''
    if (spec.id !== undefined) {
      return { ...extras, path, id: spec.id }
    }
    return { ...extras, path }
  }

  function wireView<P extends Record<string, unknown>>(
    name: string,
    queries: QueryMap | QueryFn<P>,
    actionNames: string[],
    component: ComponentType<P>,
  ): ComponentType<Partial<P>> {
    const WiredComponent = (ownProps: Partial<P>): ReactElement | null => {
      const resolvedMap =
        typeof queries === 'function'
          ? (queries as QueryFn<P>)(ownProps as P)
          : queries

      const mapKey = JSON.stringify(resolvedMap)
      const mapKeyRef = useRef(mapKey)

      const [data, setData] = useState<Record<string, Doc | Doc[] | null>>(() => {
        const initial: Record<string, Doc | Doc[] | null> = {}
        for (const [key, spec] of Object.entries(resolvedMap)) {
          const q = specToQuery(spec)
          const cache = store.getCache()
          if (q.id !== undefined) {
            const doc = cache.get(q.path)?.get(q.id)
            initial[key] = doc ? store.enrich(q.path, doc) : null
          } else {
            const col = cache.get(q.path)
            initial[key] = col ? Array.from(col.values()).map(d => store.enrich(q.path, d)) : []
          }
        }
        return initial
      })

      useEffect(() => {
        mapKeyRef.current = mapKey
        const unsubs = Object.entries(resolvedMap).map(([key, spec]) => {
          const q = specToQuery(spec)
          return store.adapter.subscribe(q, (docs: Doc[]) => {
            const enriched = docs.map(d => store.enrich(q.path, d))
            const value: Doc | Doc[] | null =
              spec.id !== undefined
                ? enriched.length > 0 ? (enriched[0] ?? null) : null
                : enriched
            setData((prev: Record<string, Doc | Doc[] | null>) => ({ ...prev, [key]: value }))
          })
        })
        return () => unsubs.forEach(u => u())
        // eslint-disable-next-line react-hooks/exhaustive-deps
      }, [mapKey])

      const actions = actionNames.reduce<Record<string, MutateFn>>(
        (acc, n) => ({ ...acc, [n]: allMutates[n] ?? (async () => {}) }),
        {},
      )

      // Inject registered wired components for any prop name that matches
      const injectedViews: Record<string, ComponentType<Record<string, unknown>>> = {}
      for (const [regName, regComp] of registry) {
        injectedViews[regName] = regComp
      }

      const merged = {
        ...injectedViews,
        ...ownProps,
        ...data,
        ...actions,
      } as unknown as P

      return createElement(component, merged)
    }

    WiredComponent.displayName = `Wired(${name})`
    registry.set(name, WiredComponent as ComponentType<Record<string, unknown>>)
    return WiredComponent
  }

  return wireView
}
