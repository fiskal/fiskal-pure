// StatelessUI — Store internal accessors
// Exposes configs to in-package consumers (WireView, dispatch, tests).
// Not part of the public API surface.

import Foundation

extension Store {
    /// Package-internal access to backing configs (needed by dispatch + WireView).
    var _configs: [String: BackingStoreConfig] {
        // Mirror the private `configs` dict.
        // Because this file is in the same module, the stored property is accessible.
        configs
    }
}
