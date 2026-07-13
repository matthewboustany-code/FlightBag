import Foundation
import Observation

/// User-controlled layer stack for the EFB map. Layers are data, not code:
/// Phase 4 adds traffic and FIS-B radar as more entries in the same panel.
@Observable
final class MapLayersState {
    var sectionalEnabled = true
    var sectionalOpacity = 1.0
    var radarEnabled = false
    var radarOpacity = 0.7
    var airportsEnabled = true

    /// Charts found on disk; refreshed when the map appears.
    var availableCharts: [ChartStore.ChartSet] = []
}
