import Foundation

/// One NEXRAD global block: 128 intensity bins (32 wide × 4 tall),
/// row-major from the block's northwest corner.
public struct NEXRADBlock: Sendable, Hashable {
    public let blockNumber: Int
    public let scaleFactor: Int
    /// Intensity 0–7 per bin; 0/1 mean no precipitation.
    public let intensities: [UInt8]

    public init(blockNumber: Int, scaleFactor: Int, intensities: [UInt8]) {
        self.blockNumber = blockNumber
        self.scaleFactor = scaleFactor
        self.intensities = intensities
    }
}

/// A decoded regional (product 63) or CONUS (product 64) NEXRAD APDU:
/// either one RLE-encoded block or a list of blocks to clear.
public struct NEXRADProduct: Sendable {
    public enum Scope: Sendable, Hashable {
        case regional
        case conus
    }

    public let scope: Scope
    public let blocks: [NEXRADBlock]
    /// Block numbers explicitly reported as precipitation-free.
    public let clearedBlocks: [Int]

    public init(scope: Scope, blocks: [NEXRADBlock], clearedBlocks: [Int] = []) {
        self.scope = scope
        self.blocks = blocks
        self.clearedBlocks = clearedBlocks
    }
}

public enum NEXRADGlobalBlock {
    public static let binsWide = 32
    public static let binsTall = 4
    public static let binsPerBlock = 128

    /// Decodes one APDU payload. The record is a 3-byte block reference
    /// (bit 7: RLE flag, bits 6–4: scale factor, low 20 bits: block
    /// number) followed by either RLE runs (5-bit run length − 1, 3-bit
    /// intensity) or an empty-block bitmap.
    public static func decode(payload: [UInt8], scope: NEXRADProduct.Scope) -> NEXRADProduct? {
        guard payload.count >= 4 else { return nil }
        let isRLE = payload[0] & 0x80 != 0
        let scaleFactor = Int(payload[0] >> 4) & 0x07
        let blockNumber = Int(payload[0] & 0x0F) << 16 | Int(payload[1]) << 8 | Int(payload[2])

        if isRLE {
            var bins: [UInt8] = []
            bins.reserveCapacity(binsPerBlock)
            for byte in payload.dropFirst(3) {
                let run = Int(byte >> 3) + 1
                guard bins.count + run <= binsPerBlock else { return nil }
                bins.append(contentsOf: repeatElement(byte & 0x07, count: run))
            }
            guard bins.count == binsPerBlock else { return nil }
            let block = NEXRADBlock(blockNumber: blockNumber, scaleFactor: scaleFactor, intensities: bins)
            return NEXRADProduct(scope: scope, blocks: [block], clearedBlocks: [])
        }

        // Empty-block record: the referenced block plus a bitmap of
        // following blocks that are also precipitation-free. Byte 3:
        // low nibble = bitmap length in bytes (including itself),
        // bits 4–7 = blocks +1…+4; each later byte i covers +8i−3…+8i+4.
        var cleared = [blockNumber]
        let bitmapLength = max(1, Int(payload[3] & 0x0F))
        guard payload.count >= 3 + bitmapLength else { return nil }
        for bit in 0..<4 where payload[3] & (0x10 << bit) != 0 {
            cleared.append(blockNumber + 1 + bit)
        }
        for i in 1..<bitmapLength {
            let byte = payload[3 + i]
            for bit in 0..<8 where byte & (1 << bit) != 0 {
                cleared.append(blockNumber + 8 * i - 3 + bit)
            }
        }
        return NEXRADProduct(scope: scope, blocks: [], clearedBlocks: cleared)
    }
}

/// Maps block numbers to geographic bounds. Blocks tile the globe from
/// 0°N/0°E going north and east; below 60°N a row is 450 blocks of
/// 48′ × 4′ (at scale factor 0). Scale factors 1 and 2 multiply bin sizes
/// by 5 and 9 (CONUS NEXRAD broadcasts at scale 1).
public enum NEXRADBlockGeometry {
    public struct Bounds: Sendable, Equatable {
        public let south: Double
        public let west: Double
        public let north: Double
        public let east: Double
    }

    static let scaleMultipliers: [Double] = [1, 5, 9]

    /// Block bounds in degrees; longitude normalized to -180…180.
    /// Returns nil for invalid scale factors.
    public static func bounds(blockNumber: Int, scaleFactor: Int) -> Bounds? {
        guard scaleFactor >= 0 && scaleFactor < scaleMultipliers.count, blockNumber >= 0 else { return nil }
        let multiplier = scaleMultipliers[scaleFactor]

        let row: Int
        let column: Int
        let blockLatMinutes: Double
        let blockLonMinutes: Double
        var southMinutes: Double

        if scaleFactor == 0 && blockNumber >= 405_000 {
            // Above 60°N rows are 225 double-width blocks; only even
            // offsets are used.
            let index = (blockNumber - 405_000) / 2
            row = index / 225
            column = index % 225
            blockLatMinutes = 4
            blockLonMinutes = 96
            southMinutes = 60 * 60 + Double(row) * blockLatMinutes
        } else {
            let blocksPerRow = Int(450 / multiplier)
            row = blockNumber / blocksPerRow
            column = blockNumber % blocksPerRow
            blockLatMinutes = 4 * multiplier
            blockLonMinutes = 48 * multiplier
            southMinutes = Double(row) * blockLatMinutes
        }

        let south = southMinutes / 60
        var west = Double(column) * blockLonMinutes / 60
        if west > 180 { west -= 360 }
        return Bounds(
            south: south,
            west: west,
            north: south + blockLatMinutes / 60,
            east: west + blockLonMinutes / 60
        )
    }

    /// Bounds of one bin within a block. Bin 0 is the block's northwest
    /// corner; bins scan west→east then north→south.
    public static func binBounds(blockNumber: Int, scaleFactor: Int, binIndex: Int) -> Bounds? {
        guard binIndex >= 0 && binIndex < NEXRADGlobalBlock.binsPerBlock,
              let block = bounds(blockNumber: blockNumber, scaleFactor: scaleFactor) else { return nil }
        let binRow = binIndex / NEXRADGlobalBlock.binsWide
        let binColumn = binIndex % NEXRADGlobalBlock.binsWide
        let binWidth = (block.east - block.west) / Double(NEXRADGlobalBlock.binsWide)
        let binHeight = (block.north - block.south) / Double(NEXRADGlobalBlock.binsTall)
        let north = block.north - Double(binRow) * binHeight
        let west = block.west + Double(binColumn) * binWidth
        return Bounds(south: north - binHeight, west: west, north: north, east: west + binWidth)
    }
}
