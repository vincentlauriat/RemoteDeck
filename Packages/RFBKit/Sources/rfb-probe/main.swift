import Foundation
import os
import RFBKit

// Live probe for a real RFB server: runs RFBConnection.open and prints the outcome.
// Not part of the library or the app; build and run it from Packages/RFBKit with `swift run rfb-probe`.

let usage = """
    usage: rfb-probe <host> [--port N] [--user NAME]
                     [--password-prompt | --password-env VAR | --wrong-password] [--capture DIR]
      --password-prompt  read the password from the terminal (no echo)
      --password-env VAR read the password from environment variable VAR
      --wrong-password   send a random password (checks the failure path without real credentials)
      --capture DIR      write the server -> client bytes to DIR/<timestamp>-server.bin and a summary
                         to DIR/<timestamp>-summary.json (client bytes, which carry the credentials,
                         are never recorded)
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let host = args.first, !host.hasPrefix("--") else { fail(usage) }
args.removeFirst()
var port: UInt16 = 5900
var user: String?
var password: String?
var captureDirectory: URL?

@MainActor func value(for option: String) -> String {
    guard !args.isEmpty else { fail("\(option) needs a value\n\(usage)") }
    return args.removeFirst()
}

while !args.isEmpty {
    let option = args.removeFirst()
    switch option {
    case "--port":
        guard let parsed = UInt16(value(for: option)) else { fail("invalid port") }
        port = parsed
    case "--user": user = value(for: option)
    case "--password-env":
        let name = value(for: option)
        guard let fromEnvironment = ProcessInfo.processInfo.environment[name] else { fail("\(name) is not set") }
        password = fromEnvironment
    case "--wrong-password": password = "rfbprobe-wrong-\(UInt32.random(in: 0...UInt32.max))"
    case "--password-prompt":
        var buffer = [CChar](repeating: 0, count: 256)
        guard readpassphrase("Password: ", &buffer, buffer.count, 0) != nil else { fail("cannot read password (no tty?)") }
        password = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        for index in buffer.indices { buffer[index] = 0 }
    case "--capture": captureDirectory = URL(fileURLWithPath: value(for: option), isDirectory: true)
    default: fail("unknown argument \(option)\n\(usage)")
    }
}

let credentials = RFBCredentials(username: user, password: password)
let received = OSAllocatedUnfairLock(initialState: Data())
let record: @Sendable (Data) -> Void = { chunk in received.withLock { $0.append(chunk) } }
let observer = captureDirectory == nil ? nil : record
let connection = RFBConnection(host: host, port: port, receiveObserver: observer)

let start = ContinuousClock.now
var result: HandshakeResult?
var failure: RFBError?
do throws(RFBError) {
    result = try await connection.open(credentials: credentials, timeout: .seconds(20))
} catch {
    failure = error
}
let elapsed = ContinuousClock.now - start
await connection.close()

if let result {
    let pf = result.serverInit.pixelFormat
    print("OK in \(elapsed)")
    print("server version \(result.serverVersion), answered \(result.version), security type \(result.securityType)")
    print("desktop \(result.serverInit.width)x\(result.serverInit.height) name=\"\(result.serverInit.name)\"")
    print("pixel format bpp=\(pf.bitsPerPixel) depth=\(pf.depth) bigEndian=\(pf.bigEndian) trueColor=\(pf.trueColor) "
          + "max=\(pf.redMax)/\(pf.greenMax)/\(pf.blueMax) shift=\(pf.redShift)/\(pf.greenShift)/\(pf.blueShift)")
    print("remainder \(result.remainder.count) bytes")
} else if let failure {
    print("FAILED in \(elapsed): \(failure)")
}

if let captureDirectory {
    let bytes = [UInt8](received.withLock { $0 })
    var summary: [String: Any] = [
        "host": host, "port": Int(port), "elapsedSeconds": Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18,
        "serverBytes": bytes.count, "usernameSet": user != nil, "passwordSet": password != nil,
    ]
    // Server messages, parsed from the capture: banner, then (3.7+) U8 count + types, then for type 30
    // U16 generator + U16 key length.
    func u16(_ offset: Int) -> Int? { offset + 2 <= bytes.count ? Int(bytes[offset]) << 8 | Int(bytes[offset + 1]) : nil }
    if bytes.count >= 12 { summary["banner"] = String(decoding: bytes[0..<12], as: UTF8.self) }
    var chosen = result.map { Int($0.securityType) }
    if bytes.count >= 13, bytes[0..<4] == [0x52, 0x46, 0x42, 0x20], !String(decoding: bytes[4..<11], as: UTF8.self).hasPrefix("003.003") {
        let count = Int(bytes[12])
        let types = Array(bytes.dropFirst(13).prefix(count))
        summary["securityTypes"] = types.map(Int.init)
        if chosen == nil, count > 0, types.count == count {
            chosen = (try? RFBHandshake.selectSecurityType(offered: types, credentials: credentials)).map(Int.init)
        }
        if chosen == 30, let generator = u16(13 + count), let keyLength = u16(15 + count) {
            summary["appleDH"] = ["generator": generator, "keyLength": keyLength,
                                  "primePrefixHex": bytes.dropFirst(17 + count).prefix(16).map { String(format: "%02x", $0) }.joined()]
        }
    }
    summary["chosenSecurityType"] = chosen ?? NSNull()
    if let result {
        let pf = result.serverInit.pixelFormat
        summary["serverInit"] = [
            "width": Int(result.serverInit.width), "height": Int(result.serverInit.height), "name": result.serverInit.name,
            "bitsPerPixel": Int(pf.bitsPerPixel), "depth": Int(pf.depth), "bigEndian": pf.bigEndian, "trueColor": pf.trueColor,
            "redMax": Int(pf.redMax), "greenMax": Int(pf.greenMax), "blueMax": Int(pf.blueMax),
            "redShift": Int(pf.redShift), "greenShift": Int(pf.greenShift), "blueShift": Int(pf.blueShift),
        ]
        summary["serverVersion"] = "\(result.serverVersion)"
        summary["remainderBytes"] = result.remainder.count
    }
    summary["error"] = failure.map { "\($0)" } ?? NSNull()

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let stamp = formatter.string(from: Date())
    do {
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let binary = captureDirectory.appendingPathComponent("\(stamp)-server.bin")
        let json = captureDirectory.appendingPathComponent("\(stamp)-summary.json")
        try Data(bytes).write(to: binary)
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: json)
        print("capture: \(binary.path) (\(bytes.count) bytes), \(json.path)")
    } catch {
        fail("cannot write capture: \(error)")
    }
}

exit(result == nil ? 1 : 0)
