import CryptoKit
import XCTest
@testable import NotchIslandCore

final class PortalPairingTests: XCTestCase {
    func testMessagesRoundTrip() {
        let all: [PortalMessage] = [
            .hello(mac: "m", nonce: Data([1, 2])), .auth(device: "d", name: "iPhone", nonce: Data([3]), proof: Data([4])),
            .welcome(proof: Data([5])), .unknown, .pair(device: "d", name: "n", commit: Data([6])),
            .pairKey(pub: Data([7])), .pairReveal(pub: Data([8])), .confirm, .paired, .denied,
        ]
        for m in all { XCTAssertEqual(PortalMessage.decode(m.encoded()), m) }
        XCTAssertNil(PortalMessage.decode(Data("nonsense".utf8)))
        XCTAssertNil(PortalMessage.decode(Data(count: PortalMessage.maxSize + 1)))
    }

    /// Both ends of an honest exchange get the same key and code.
    func testBothSidesDeriveTheSameKeyAndCode() throws {
        let phone = Curve25519.KeyAgreement.PrivateKey(), mac = Curve25519.KeyAgreement.PrivateKey()
        let pp = phone.publicKey.rawRepresentation, mp = mac.publicKey.rawRepresentation
        let a = try PortalPairing.derive(own: phone, peerPub: mp, phonePub: pp, macPub: mp)
        let b = try PortalPairing.derive(own: mac, peerPub: pp, phonePub: pp, macPub: mp)
        XCTAssertEqual(a.key, b.key)
        XCTAssertEqual(a.code, b.code)
        XCTAssertEqual(a.code.count, 6)
        XCTAssertEqual(a.key.count, 32)
    }

    /// A man in the middle ends up with different codes on the two screens.
    func testManInTheMiddleShowsDifferentCodes() throws {
        let phone = Curve25519.KeyAgreement.PrivateKey(), mac = Curve25519.KeyAgreement.PrivateKey()
        let evil = Curve25519.KeyAgreement.PrivateKey()
        let pp = phone.publicKey.rawRepresentation, mp = mac.publicKey.rawRepresentation, ep = evil.publicKey.rawRepresentation
        let onPhone = try PortalPairing.derive(own: phone, peerPub: ep, phonePub: pp, macPub: ep)
        let onMac = try PortalPairing.derive(own: mac, peerPub: ep, phonePub: ep, macPub: mp)
        XCTAssertNotEqual(onPhone.key, onMac.key)
    }

    func testCommitment() {
        let pub = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        XCTAssertEqual(PortalPairing.commitment(to: pub), PortalPairing.commitment(to: pub))
        XCTAssertNotEqual(PortalPairing.commitment(to: pub), PortalPairing.commitment(to: pub + Data([0])))
    }

    func testProofsAreDirectionalAndKeyed() {
        let key = PortalPairing.randomBytes(32), other = PortalPairing.randomBytes(32)
        let mn = PortalPairing.nonce(), pn = PortalPairing.nonce()
        let p = PortalPairing.proof(key: key, role: .phone, mac: "mac", macNonce: mn, phoneNonce: pn)
        XCTAssertTrue(PortalPairing.verify(p, key: key, role: .phone, mac: "mac", macNonce: mn, phoneNonce: pn))
        // Wrong key, replayed as the Mac's answer, another Mac, or a stale nonce: all rejected.
        XCTAssertFalse(PortalPairing.verify(p, key: other, role: .phone, mac: "mac", macNonce: mn, phoneNonce: pn))
        XCTAssertFalse(PortalPairing.verify(p, key: key, role: .mac, mac: "mac", macNonce: mn, phoneNonce: pn))
        XCTAssertFalse(PortalPairing.verify(p, key: key, role: .phone, mac: "mac2", macNonce: mn, phoneNonce: pn))
        XCTAssertFalse(PortalPairing.verify(p, key: key, role: .phone, mac: "mac", macNonce: PortalPairing.nonce(), phoneNonce: pn))
    }

    func testDisplayCode() {
        XCTAssertEqual(PortalPairing.display("482913"), "482 913")
        XCTAssertEqual(PortalPairing.display("12"), "12")
    }
}
