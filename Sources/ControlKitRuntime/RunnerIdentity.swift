import Darwin
import Foundation

struct RunnerIdentity {
    let pid: Int32
    let startedSeconds: UInt64
    let startedMicroseconds: UInt64

    init(pid: Int32, device: SimulatorDevice) throws {
        let info = try Self.info(pid)
        // Darwin's PROC_PIDPATHINFO_MAXSIZE macro is not imported into Swift.
        var bytes = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = proc_pidpath(pid, &bytes, UInt32(bytes.count))
        let path = String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
        let root = URL(fileURLWithPath: device.dataPath).resolvingSymlinksInPath().path
        try requireRuntime(
            count > 0 && info.pbi_uid == getuid() && path.hasPrefix(root + "/")
                && path.hasSuffix("/ControlKitRuntime-Runner.app/ControlKitRuntime-Runner"),
            "runner_identity", "Authenticated runner does not match the selected simulator product."
        )
        self.pid = pid
        startedSeconds = info.pbi_start_tvsec
        startedMicroseconds = info.pbi_start_tvusec
    }

    func isRetired() throws -> Bool {
        do {
            let info = try Self.info(pid)
            return info.pbi_start_tvsec != startedSeconds
                || info.pbi_start_tvusec != startedMicroseconds || info.pbi_status == SZOMB
        } catch {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            throw RuntimeFailure(
                "retirement_unconfirmed", "Cannot verify XCTest runner retirement.")
        }
    }

    private static func info(_ pid: Int32) throws -> proc_bsdinfo {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        try requireRuntime(
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
            "runner_identity", "Cannot inspect authenticated runner identity.")
        return info
    }
}
