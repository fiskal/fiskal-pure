import React from 'react';
import type { Query, Doc, BoundMutate, StoreInstance } from '../types.js';

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/** A record of query definitions, either static Query objects or functions of props. */
export type QueryMap<TProps> = {
  [K: string]: Query | ((props: TProps) => Query);
};

/** A record of action names to bind from the store. */
export type ActionMap = Record<string, string>;

/** Props injected into the pure component by wireView. */
export type WiredProps<TData extends Record<string, unknown>, TActions extends Record<string, BoundMutate>> =
  TData & TActions;

// ---------------------------------------------------------------------------
// wireView
// ---------------------------------------------------------------------------

/**
 * Wires a pure component to the store.
 *
 * @param name        Display name for the HOC (for React DevTools).
 * @param queries     Record of key → Query (or key → (props) => Query).
 *                    Each key is injected as a prop with live data.
 * @param actionNames Array of action names to bind from store.actions.
 * @param Component   The pure component that accepts the combined props.
 * @param store       The StoreInstance to wire to.
 *
 * Returns a new component that injects live data and bound actions.
 * The inner Component is unchanged and remains directly testable.
 */
export const wireView = <
  TOwnProps extends Record<string, unknown>,
  TQueryKeys extends string,
  TActionKeys extends string,
>(
  name: string,
  queries: Record<TQueryKeys, Query | ((props: TOwnProps) => Query)>,
  actionNames: readonly TActionKeys[],
  Component: React.ComponentType<
    TOwnProps &
      Record<TQueryKeys, Doc | Doc[] | undefined | null> &
      Record<TActionKeys, BoundMutate>
  >,
  store: StoreInstance,
): React.FC<TOwnProps> => {
  const Wired: React.FC<TOwnProps> = (ownProps: TOwnProps) => {
    // Resolve all queries to live data via the store's useRead hook
    const data: Record<string, Doc | Doc[] | undefined | null> = {};
    for (const [key, queryOrFn] of Object.entries(queries) as Array<[string, Query | ((p: TOwnProps) => Query)]>) {
      const query: Query = typeof queryOrFn === 'function' ? queryOrFn(ownProps) : queryOrFn;
      // useRead is called unconditionally — same number of calls per render
      // (key order is stable because Object.entries preserves insertion order)
      // eslint-disable-next-line react-hooks/rules-of-hooks
      data[key] = store.useRead(query);
    }

    // Bind action functions
    const actions: Record<string, BoundMutate> = {};
    for (const actionName of actionNames) {
      const fn = store.actions[actionName];
      if (!fn) throw new Error(`wireView(${name}): action '${actionName}' not found in store`);
      actions[actionName] = fn;
    }

    const combinedProps = {
      ...ownProps,
      ...data,
      ...actions,
    } as TOwnProps &
      Record<TQueryKeys, Doc | Doc[] | undefined | null> &
      Record<TActionKeys, BoundMutate>;

    return <Component {...combinedProps} />;
  };

  Wired.displayName = `Wired(${name})`;
  return Wired;
};
