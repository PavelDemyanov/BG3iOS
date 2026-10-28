// Правки байтов в переделанных бинарниках известных игр (то же, что tools/patch_binary.py): файл по имени, адрес
// в памяти, ожидаемые и новые байты. Байты не совпали (другая версия игры) — правка пропускается.

import Foundation

public enum BinaryPatches {
    struct Patch {
        let title: String
        let address: UInt64
        let old: [UInt8]
        let new: [UInt8]
    }

    static func floats(_ values: Float...) -> [UInt8] {
        values.flatMap { v in withUnsafeBytes(of: v.bitPattern.littleEndian) { Array($0) } }
    }
    static func word(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.littleEndian) { Array($0) } }

    // BG3 4.1.1 (Mac): ожидание подгрузки {0,5 с, 20 с} — литерал на шесть мест (экран загрузки, затемнения,
    // ролики): подгрузка на телефоне дольше 20 с — максимум 60 с. BaseApp::InitFrameStages добавляет набор
    // SHADOW_BUFFER_PACK дважды — второе добавление (blr) → nop: каскады теней один раз за кадр.
    static let patches: [String: [Patch]] = [
        "Baldur's Gate 3": [
            Patch(title: "streaming wait: max 20 → 60 s", address: 0x10786db60,
                  old: floats(0.5, 20.0), new: floats(0.5, 60.0)),
            Patch(title: "shadow cascades once per frame", address: 0x105d1a830,
                  old: word(0xD63F0100), new: word(0xD503201F)),
        ],
    ]

    // Применить правки для файла с этим именем; возвращает строки отчёта.
    public static func apply(to data: inout [UInt8], fileName: String) -> [String] {
        guard let list = patches[fileName] else { return [] }
        var segments: [(vm: UInt64, size: UInt64, file: UInt64)] = []
        let ncmds = Int(MachOConvert.le32(data, 16))
        var off = 32
        for _ in 0..<ncmds {
            if MachOConvert.le32(data, off) == 0x19 {
                segments.append((MachOConvert.le64(data, off + 24), MachOConvert.le64(data, off + 32),
                                 MachOConvert.le64(data, off + 40)))
            }
            off += Int(MachOConvert.le32(data, off + 4))
        }
        var report: [String] = []
        for patch in list {
            guard let segment = segments.first(where: { patch.address >= $0.vm && patch.address < $0.vm + $0.size }) else {
                report.append("patch skipped (no such address): \(patch.title)")
                continue
            }
            let at = Int(segment.file + patch.address - segment.vm)
            guard at + patch.old.count <= data.count, Array(data[at..<(at + patch.old.count)]) == patch.old else {
                report.append("patch skipped (different bytes): \(patch.title)")
                continue
            }
            data.replaceSubrange(at..<(at + patch.new.count), with: patch.new)
            report.append("patch: \(patch.title)")
        }
        return report
    }
}
