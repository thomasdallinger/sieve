import Darwin
import Foundation

public enum EntryType: UInt8, Sendable {
    case file, directory, symlink, other
}

/// Reads directories with `getattrlistbulk(2)`: one syscall returns names, types, dates, flags and sizes for
/// hundreds of entries, which is several times faster than `FileManager` with prefetched resource keys.
public enum DirectoryReader {
    /// One directory entry. `name` points into the read buffer and is only valid inside the callback.
    public struct Raw {
        public let name: UnsafeRawBufferPointer
        public let type: EntryType
        public let size: Int64
        public let created: Double   // seconds since 1970
        public let modified: Double
        public let added: Double     // 0 when the volume does not track it
        public let flags: UInt32

        public var isHidden: Bool { name.first == UInt8(ascii: ".") || flags & UInt32(UF_HIDDEN) != 0 }
    }

    public struct ReadError: Error, CustomStringConvertible {
        public let path: String
        public let code: Int32
        public var description: String { "\(path): \(String(cString: strerror(code)))" }
        public var isPermissionDenied: Bool { code == EACCES || code == EPERM }
    }

    private static let bufferSize = 128 * 1024

    private static func bit<T: BinaryInteger>(_ v: T) -> UInt32 { UInt32(truncatingIfNeeded: v) }
    private static let cmnReturned = bit(ATTR_CMN_RETURNED_ATTRS)
    private static let cmnName = bit(ATTR_CMN_NAME)
    private static let cmnError = bit(ATTR_CMN_ERROR)
    private static let cmnType = bit(ATTR_CMN_OBJTYPE)
    private static let cmnCreated = bit(ATTR_CMN_CRTIME)
    private static let cmnModified = bit(ATTR_CMN_MODTIME)
    private static let cmnFlags = bit(ATTR_CMN_FLAGS)
    private static let cmnAdded = bit(ATTR_CMN_ADDEDTIME)
    private static let fileTotalSize = bit(ATTR_FILE_TOTALSIZE)

    /// Calls `body` for every entry of the directory at `path` (not recursive, `.` and `..` excluded).
    public static func scan(_ path: String, _ body: (Raw) -> Void) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw ReadError(path: path, code: errno) }
        defer { close(fd) }

        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = cmnReturned | cmnName | cmnError | cmnType | cmnCreated | cmnModified | cmnFlags | cmnAdded
        list.fileattr = fileTotalSize

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
        defer { buffer.deallocate() }

        while true {
            let count = getattrlistbulk(fd, &list, buffer, bufferSize, 0)
            if count < 0 { throw ReadError(path: path, code: errno) }
            if count == 0 { return }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                var p = entry + 4
                let returned = p.loadUnaligned(as: attribute_set_t.self)
                p += MemoryLayout<attribute_set_t>.size
                let common = returned.commonattr

                // Order follows the attribute bit order, except ATTR_CMN_ERROR which comes first.
                if common & cmnError != 0 {
                    let error = p.loadUnaligned(as: UInt32.self)
                    p += 4
                    if error != 0 { continue }
                }
                var name = UnsafeRawBufferPointer(start: nil, count: 0)
                if common & cmnName != 0 {
                    let ref = p.loadUnaligned(as: attrreference_t.self)
                    name = UnsafeRawBufferPointer(start: p + Int(ref.attr_dataoffset), count: max(0, Int(ref.attr_length) - 1))
                    p += MemoryLayout<attrreference_t>.size
                }
                var type = EntryType.other
                if common & cmnType != 0 {
                    switch p.loadUnaligned(as: UInt32.self) {
                    case UInt32(VREG.rawValue): type = .file
                    case UInt32(VDIR.rawValue): type = .directory
                    case UInt32(VLNK.rawValue): type = .symlink
                    default: type = .other
                    }
                    p += 4
                }
                var created = 0.0, modified = 0.0, added = 0.0
                if common & cmnCreated != 0 { created = seconds(p.loadUnaligned(as: timespec.self)); p += MemoryLayout<timespec>.size }
                if common & cmnModified != 0 { modified = seconds(p.loadUnaligned(as: timespec.self)); p += MemoryLayout<timespec>.size }
                var flags: UInt32 = 0
                if common & cmnFlags != 0 { flags = p.loadUnaligned(as: UInt32.self); p += 4 }
                if common & cmnAdded != 0 { added = seconds(p.loadUnaligned(as: timespec.self)); p += MemoryLayout<timespec>.size }
                var size: Int64 = 0
                if returned.fileattr & fileTotalSize != 0 { size = p.loadUnaligned(as: Int64.self) }
                guard name.count > 0 else { continue }
                body(Raw(name: name, type: type, size: size, created: created, modified: modified, added: added, flags: flags))
            }
        }
    }

    @inline(__always) private static func seconds(_ t: timespec) -> Double {
        Double(t.tv_sec) + Double(t.tv_nsec) / 1_000_000_000
    }
}
