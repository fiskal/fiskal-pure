// @vitest-environment jsdom
// ---------------------------------------------------------------------------
// outlet.test.ts — the built-in Outlet (dependency-injected dynamic view)
// ---------------------------------------------------------------------------
// The Outlet is injected into any wired view by name (like TaskItem into
// TaskList). It renders a registered view chosen at runtime by name, forwarding
// the dynamic query params that view merges into its own read. No map lookup.

import { describe, it, expect } from 'vitest'
import { createElement as h } from 'react'
import { render, screen } from '@testing-library/react'
import { createStore } from '../src/store.js'
import { createWireView } from '../src/react/wireView.js'
import { MemoryAdapter } from '../src/adapters/memory.js'
import { seed } from '../src/test/index.js'

/* eslint-disable @typescript-eslint/no-explicit-any */

describe('Outlet — dependency-injected dynamic view', () => {
  it('renders a registered view by name with the dynamic query merged in', () => {
    const store = createStore(MemoryAdapter())
    seed(store, {
      tasks: [
        { id: 'tasks/t1', title: 'Deploy' },
        { id: 'tasks/t2', title: 'Review' },
      ],
    })
    const wireView = createWireView(store)

    // Presented view: declares the STATIC path; the modal supplies the dynamic query.
    const TaskDetailView = ({ task }: any) =>
      h('div', { 'data-testid': 'detail' }, task.title)
    wireView('TaskDetail', ({ query }: any) => ({ task: { path: 'tasks', ...query } }), [], TaskDetailView)

    // Shell receives Outlet by injection and hands it a name + query.
    const ShellView = ({ Outlet }: any) =>
      h(Outlet, { view: 'TaskDetail', query: { id: 'tasks/t2' } })
    const Shell = wireView('Shell', {}, [], ShellView)

    render(h(Shell))
    expect(screen.getByTestId('detail').textContent).toBe('Review')
  })

  it('the same Outlet renders a different registered view from the same slot', () => {
    const store = createStore(MemoryAdapter())
    seed(store, { settings: [{ id: 'settings/app', theme: 'dark' }] })
    const wireView = createWireView(store)

    const SettingsView = ({ config }: any) =>
      h('div', { 'data-testid': 'settings' }, config.theme)
    wireView('Settings', ({ query }: any) => ({ config: { path: 'settings', ...query } }), [], SettingsView)

    const ShellView = ({ Outlet }: any) =>
      h(Outlet, { view: 'Settings', query: { id: 'settings/app' } })
    const Shell = wireView('Shell2', {}, [], ShellView)

    render(h(Shell))
    expect(screen.getByTestId('settings').textContent).toBe('dark')
  })

  it('renders nothing when the named view is not registered', () => {
    const store = createStore(MemoryAdapter())
    const wireView = createWireView(store)

    const ShellView = ({ Outlet }: any) =>
      h('div', { 'data-testid': 'shell' }, h(Outlet, { view: 'DoesNotExist' }))
    const Shell = wireView('Shell3', {}, [], ShellView)

    render(h(Shell))
    expect(screen.getByTestId('shell').textContent).toBe('')
  })
})
