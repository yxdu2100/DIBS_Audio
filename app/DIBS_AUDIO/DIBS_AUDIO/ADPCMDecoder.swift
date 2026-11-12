import Foundation

/// IMA ADPCM decoder matching firmware/src/adpcm.c (low nibble first).
enum ADPCMDecoder {
    private static let stepTable: [Int32] = [
        7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37,
        41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173,
        190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
        724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
        2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894,
        6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289,
        16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
    ]

    private static let indexTable: [Int32] = [
        -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8,
    ]

    static func decode(_ packet: AudioPacket, into out: inout [Int16]) {
        var predictor = Int32(packet.predictor)
        var index = Int32(min(packet.stepIndex, 88))

        func step(_ nibble: UInt8) -> Int16 {
            let n = Int32(nibble)
            let step = stepTable[Int(index)]
            var diff = step >> 3
            if n & 4 != 0 { diff += step }
            if n & 2 != 0 { diff += step >> 1 }
            if n & 1 != 0 { diff += step >> 2 }
            predictor += (n & 8 != 0) ? -diff : diff
            predictor = min(max(predictor, Int32(Int16.min)), Int32(Int16.max))
            index = min(max(index + indexTable[Int(n)], 0), 88)
            return Int16(predictor)
        }

        for byte in packet.payload {
            out.append(step(byte & 0x0F))
            out.append(step(byte >> 4))
        }
    }
}
