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
//
// Loading model (ADR-0013): wireView owns the subscription AND the loading
// state. While any query is still loading (or a single-item query is missing),
// the container renders nothing and injects no props — so the wrapped view only
// ever receives LOADED data and never sees null/undefined. A view that needs a
// custom loading/not-found UI reads the explicit Loadable via useRead directly.

import { createElement, useEffect, useRef, useState } from 'react'
import type { ComponentType, ReactElement } from 'react'
import { Loadable, type Doc, type MutateFn, type Query, type StoreInstance } from '../types.js'

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
type ReadValue = Loadable<Doc | Doc[]>

// Module-scope shared noop so the missing-action prop is referentially stable
// across renders (preserves React.memo / useCallback dep stability).
const NOOP: MutateFn = async () => {}

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

  // Read the current cache value for a spec as an explicit Loadable.
  function readInitial(spec: QuerySpec): ReadValue {
    const q = specToQuery(spec)
    const col = store.getCache().get(q.path)
    if (q.id !== undefined) {
      if (col === undefined) return Loadable.loading()
      const item = col.get(q.id)
      return item ? Loadable.loaded(store.enrich(q.path, item)) : Loadable.missing()
    }
    if (col === undefined) return Loadable.loading()
    return Loadable.loaded(Array.from(col.values()).map(d => store.enrich(q.path, d)))
  }

  // Shape an adapter delivery (always a list) into a Loadable for a spec.
  function shapeDelivery(spec: QuerySpec, q: Query, raw: Doc[]): ReadValue {
    const list = Array.isArray(raw) ? raw : raw == null ? [] : [raw as Doc]
    const enriched = list.map(d => store.enrich(q.path, d))
    if (spec.id !== undefined) {
      const first = enriched[0]
      return first ? Loadable.loaded(first) : Loadable.missing()
    }
    return Loadable.loaded(enriched)
  }

  function wireView<P extends Record<string, unknown>>(
    name: string,
    queries: QueryMap | QueryFn<P>,
    actionNames: string[],
    component: ComponentType<P>,
  ): ComponentType<Partial<P>> {
    const Container = (ownProps: Partial<P>): ReactElement | null => {
      const resolvedMap =
        typeof queries === 'function'
          ? (queries as QueryFn<P>)(ownProps as P)
          : queries

      const mapKey = JSON.stringify(resolvedMap)
      const mapKeyRef = useRef(mapKey)

      const [data, setData] = useState<Record<string, ReadValue>>(() => {
        const initial: Record<string, ReadValue> = {}
        for (const [key, spec] of Object.entries(resolvedMap)) {
          initial[key] = readInitial(spec)
        }
        return initial
      })

      useEffect(() => {
        mapKeyRef.current = mapKey
        const unsubs = Object.entries(resolvedMap).map(([key, spec]) => {
          const q = specToQuery(spec)
          return store.adapter.subscribe(q, (raw: Doc[]) => {
            const value = shapeDelivery(spec, q, raw)
            setData(prev => ({ ...prev, [key]: value }))
          })
        })
        return () => unsubs.forEach(u => u())
        // eslint-disable-next-line react-hooks/exhaustive-deps
      }, [mapKey])

      const actions = actionNames.reduce<Record<string, MutateFn>>(
        (acc, n) => ({ ...acc, [n]: allMutates[n] ?? NOOP }),
        {},
      )

      // Loading gate: render nothing until every query is loaded. The wrapped
      // view never receives a loading/missing sentinel — only loaded data.
      const entries = Object.entries(data)
      const allLoaded = entries.every(([, v]) => v.status === 'loaded')
      if (!allLoaded) return null

      const loadedData: Record<string, unknown> = {}
      for (const [key, v] of entries) {
        loadedData[key] = (v as { status: 'loaded'; data: unknown }).data
      }

      // Inject registered wired components for any prop name that matches.
      const injectedViews: Record<string, ComponentType<Record<string, unknown>>> = {}
      for (const [regName, regComp] of registry) {
        injectedViews[regName] = regComp
      }

      const merged = {
        ...injectedViews,
        ...ownProps,
        ...loadedData,
        ...actions,
      } as unknown as P

      return createElement(component, merged)
    }

    Container.displayName = name
    registry.set(name, Container as ComponentType<Record<string, unknown>>)
    return Container
  }

  return wireView
}
