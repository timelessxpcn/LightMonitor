import Foundation
import IOKit

struct SensorReading: Identifiable {
    let key: String
    let value: Double   // Celsius
    var id: String { key }
}

/// 用户态 SMC 直读（AppleSMC IOService），无需特权 Helper。
/// 温度键随 SoC 代际变化：首次启用时枚举全部键，按类型（sp78/flt）+ T 前缀筛选，
/// 不硬编码键表；键信息缓存，后续每次采样只发读命令。
/// 注意：读数是热区传感器编号，不代表单个核心温度。
final class SMCReader {
    private var conn: io_connect_t = 0
    private var tempKeys: [(key: UInt32, name: String, type: UInt32, size: UInt32)] = []
    private var enumerated = false

    private let kSMCHandleYPCEvent: UInt32 = 2
    private let kSMCReadKey: UInt8 = 5
    private let kSMCGetKeyFromIndex: UInt8 = 8
    private let kSMCGetKeyInfo: UInt8 = 9

    private let typeSp78: UInt32 = 0x7370_3738   // "sp78" 定点 7.8
    private let typeFlt: UInt32 = 0x666C_7420    // "flt " IEEE754

    deinit { close() }

    func close() {
        if conn != 0 {
            IOServiceClose(conn)
            conn = 0
        }
    }

    /// 返回有效温度读数（0~110°C），按值降序；瞬时失败返回 nil，下次采样自动重试
    func read() -> [SensorReading]? {
        if !open() { return nil }
        if !enumerated {
            enumerateTempKeys()
            if tempKeys.isEmpty { return nil }   // 不锁存，下次重试枚举
            enumerated = true
        }
        var result: [SensorReading] = []
        for k in tempKeys {
            guard let bytes = readKey(key: k.key, infoSize: k.size) else { continue }
            var v: Double? = nil
            if k.type == typeSp78 {
                let raw = Int16(bitPattern: UInt16(bytes.0) << 8 | UInt16(bytes.1))
                v = Double(raw) / 256.0
            } else if k.type == typeFlt {
                let bits = UInt32(bytes.0) | UInt32(bytes.1) << 8 | UInt32(bytes.2) << 16 | UInt32(bytes.3) << 24
                v = Double(Float(bitPattern: bits))
            }
            if let v, v > 0, v < 110 {
                result.append(SensorReading(key: k.name, value: v))
            }
        }
        return result.isEmpty ? nil : result.sorted { $0.value > $1.value }
    }

    // MARK: - Connection

    private func open() -> Bool {
        if conn != 0 { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &conn) == KERN_SUCCESS
    }

    // MARK: - Key enumeration

    private func enumerateTempKeys() {
        // #KEY → 键总数
        guard let countBytes = readKey(key: fourCC("#KEY"), infoSize: 4) else { return }
        let count = UInt32(countBytes.0) << 24 | UInt32(countBytes.1) << 16 | UInt32(countBytes.2) << 8 | UInt32(countBytes.3)
        guard count > 0, count < 10000 else { return }

        for i in 0..<count {
            var input = SMCParamStruct()
            input.data8 = kSMCGetKeyFromIndex
            input.data32 = i
            guard let output = call(&input), output.result == 0 else { continue }
            let key = output.key
            guard key >> 24 == 0x54 else { continue }   // 'T' 前缀

            var infoInput = SMCParamStruct()
            infoInput.key = key
            infoInput.data8 = kSMCGetKeyInfo
            guard let info = call(&infoInput), info.result == 0 else { continue }
            let type = info.keyInfo.dataType
            guard type == typeSp78 || type == typeFlt else { continue }
            tempKeys.append((key, nameFromCC(key), type, info.keyInfo.dataSize))
        }
    }

    // MARK: - Low level

    private func readKey(key: UInt32, infoSize: UInt32) -> SMCBytes? {
        var input = SMCParamStruct()
        input.key = key
        input.keyInfo.dataSize = infoSize
        input.data8 = kSMCReadKey
        guard let output = call(&input), output.result == 0 else { return nil }
        return output.bytes
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(conn, kSMCHandleYPCEvent,
                                           &input, MemoryLayout<SMCParamStruct>.stride,
                                           &output, &outSize)
        guard kr == KERN_SUCCESS else { return nil }
        return output
    }

    private func fourCC(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for b in s.utf8.prefix(4) { r = r << 8 | UInt32(b) }
        return r
    }

    private func nameFromCC(_ cc: UInt32) -> String {
        let chars = [UInt8(cc >> 24 & 0xFF), UInt8(cc >> 16 & 0xFF), UInt8(cc >> 8 & 0xFF), UInt8(cc & 0xFF)]
        return String(bytes: chars, encoding: .ascii) ?? "?"
    }
}

// MARK: - SMC param struct（与内核 AppleSMC 用户客户端布局一致）

typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                      UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

struct SMCKeyDataVers {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCKeyDataPLimit {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

struct SMCKeyDataKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // C 侧 sizeof 为 12（尾部对齐填充）；Swift 按 size 布局，需显式补齐，
    // 否则 SMCParamStruct 整体偏移 4 字节导致 IOConnectCallStructMethod 失败
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCKeyDataVers()
    var pLimitData = SMCKeyDataPLimit()
    var keyInfo = SMCKeyDataKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
}