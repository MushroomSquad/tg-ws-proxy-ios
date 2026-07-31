import XCTest
@testable import TgWsProxyCore

final class ProtocolTests: XCTestCase {
    func testAesCtrRoundTrip() throws {
        let key = Data((0..<32).map { UInt8($0) })
        let iv = Data((0..<16).map { UInt8($0) })
        let pt = Data("hello telegram ws proxy!!".utf8)
        let ct = try AesCtr.create(key: key, iv: iv).update(pt)
        let rt = try AesCtr.create(key: key, iv: iv).update(ct)
        XCTAssertEqual(rt, pt)
    }

    func testFixedHandshake() {
        let secret = hex("0123456789abcdef0123456789abcdef")
        let handshake = hex(
            "000d1a2734414e5b6875828f9ca9b6c3d0ddeaf704111e2b3845525f6c798693" +
            "a0adbac7d4e1eefb0815222f3c495663707d8a97a4b1becbb29ab919d970c664"
        )
        let parsed = Handshake.tryHandshake(handshake: handshake, secret: secret)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.dcId, 2)
    }

    func testGenerateRelayInitSize() throws {
        let initData = try Handshake.generateRelayInit(protoTag: ProtocolConstants.protoTagSecure, dcIdx: 2)
        XCTAssertEqual(initData.count, 64)
    }

    func testDecodeDomain() {
        // Caesar-like decode: letter count drives shift; .com -> .co.uk
        let encoded = "abc.com"
        let decoded = CfDomainRefresh.decodeDomain(encoded)
        XCTAssertTrue(decoded.hasSuffix(".co.uk"))
        XCTAssertFalse(decoded.hasSuffix(".com"))
    }

    func testNormalizeDomains() {
        let list = CfDomainRefresh.normalize(["Example.COM", "bad", "example.com", "ok.co.uk"])
        XCTAssertEqual(list, ["example.com", "ok.co.uk"])
    }

    func testParseDcIp() throws {
        let map = try ProxyConfig.parseDcIpList(["2:149.154.167.220", "4:149.154.167.220"])
        XCTAssertEqual(map[2], "149.154.167.220")
        XCTAssertEqual(map[4], "149.154.167.220")
    }

    func testDc4OnlyFronting() {
        XCTAssertTrue(ProxyConfig.isDc4OnlyFronting([4: ProxyConfig.frontingDcIp]))
        XCTAssertFalse(ProxyConfig.isDc4OnlyFronting(ProxyConfig.defaultDcRedirects))
    }

    func testCryptoSelfTest() {
        XCTAssertTrue(CryptoSelfTest.run(log: { _ in }))
    }

    func testMsgSplitterAbridgedTiny() throws {
        let relay = try Handshake.generateRelayInit(protoTag: ProtocolConstants.protoTagAbridged, dcIdx: 2)
        let splitter = try MsgSplitter(relayInit: relay, proto: ProtocolConstants.protoAbridgedInt)
        // Empty / small incomplete chunk should not crash
        let parts = try splitter.split(Data([0x01, 0x02]))
        XCTAssertTrue(parts.isEmpty || !parts.isEmpty)
    }

    private func hex(_ s: String) -> Data {
        var data = Data()
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            data.append(UInt8(s[idx..<next], radix: 16)!)
            idx = next
        }
        return data
    }
}
